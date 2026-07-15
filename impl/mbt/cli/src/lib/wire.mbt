// wire.mbt — kuu-cli MoonBit PoC の subcommand core (parse / complete / validate).
//
// `impl/mbt` の Design 目的は spec (kawaz/kuu) の CLI 入出力契約の輪郭を固めること (kuu-cli
// DR-0001 §3)。ここでは kuu.mbt (参照実装) の front_door 3 関数 (parse_definition / parse /
// complete) を直接呼び、fixture `expect` と概ね同じ語彙の JSON を stdout に emit する。
//
// 【PoC 仮置き — 統括が正本化する材料】
//
// 1. `result` 射影の export_key 適用は空 map で行う。理由: kuu.mbt の `dec_definition` /
//    `build_export_map` は `pub` でなく (wire_decode.mbt 内部 fn)、front_door.mbt が返す
//    `AtomicAST` からは生の `Definition` を復元できないため。結果、`export_key: null` (result
//    から drop) や `export_key: "..."` (rename) を含む definition では result キーが name
//    ベース (entity 名そのまま) になる。effects / errors / warnings は影響なし。修正には
//    kuu.mbt 側で `parse_definition` が Definition (または ekmap) を副戻り値で返す拡張が要る
//    (front_door.mbt 編集は本タスク scope 外)。
//
// 2. `interpretations` (ambiguous) は個数のみを返す (`{"outcome":"ambiguous","interpretations":N}`
//    ではなく `{"outcome":"ambiguous","interpretations":[空 object×N]}` で数だけ pin する)。
//    各 interpretation の詳細 (binds / claimants) をどの粒度で JSON 化するかは spec 側で
//    未確定 (DR-053 §3 / DR-073) — CONFORMANCE.md の compact 表現との対応を後日決める。
//
// 3. exit code は `--help` 系 (未実装) を除き 3 値: 0=成功、1=parse failure / validate 失敗、
//    2=CLI 使い方エラー (unknown subcommand, malformed args JSON 等)。PoC の暫定割当、後日
//    正本化。

///|
/// A subcommand result: the JSON string to write to stdout, plus the process exit code.
pub(all) struct CmdResult {
  json : String
  exit : Int
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION 1 — subcommand entry points
// ═════════════════════════════════════════════════════════════════════════════

///|
/// `kuu parse <def_json_text> -- <args...>`: parse `args` against the definition and emit the
/// outcome JSON (see file-level comment for the shape). exit 0 on success, 1 on failure /
/// ambiguous / definition-error, 2 on malformed def JSON.
pub fn cmd_parse(def_text : String, args : Array[String]) -> CmdResult {
  let defj = @json.parse(def_text) catch {
    _ =>
      return {
        json: error_json(
          "malformed_definition_json", "definition text is not valid JSON",
        ),
        exit: 2,
      }
  }
  match @core.parse_definition(defj) {
    Err(@core.Malformed(reason)) =>
      { json: error_json("malformed_definition", reason), exit: 1 }
    Err(@core.Rejected(errs)) => { json: def_errors_json(errs), exit: 1 }
    Ok(ast) => {
      let outcome = @core.parse(ast, args)
      let (obj, exit) = outcome_to_json(ast, outcome)
      { json: obj.stringify(indent=2), exit }
    }
  }
}

///|
/// `kuu complete <def_json_text> --args-before <json-array> [--args-after <json-array>]`:
/// emit candidates as `{"candidates":[...]}`.
pub fn cmd_complete(
  def_text : String,
  before : Array[String],
  after : Array[String],
) -> CmdResult {
  let defj = @json.parse(def_text) catch {
    _ =>
      return {
        json: error_json(
          "malformed_definition_json", "definition text is not valid JSON",
        ),
        exit: 2,
      }
  }
  match @core.parse_definition(defj) {
    Err(@core.Malformed(reason)) =>
      { json: error_json("malformed_definition", reason), exit: 1 }
    Err(@core.Rejected(errs)) => { json: def_errors_json(errs), exit: 1 }
    Ok(ast) => {
      let cands = @core.complete(ast, before, args_after=after)
      let arr : Array[Json] = []
      for c in cands {
        arr.push(cand_to_json(c))
      }
      let obj = Json::object({ "candidates": Json::array(arr) })
      { json: obj.stringify(indent=2), exit: 0 }
    }
  }
}

///|
/// `kuu validate <def_json_text>`: decode + lowering only; report definition errors.
/// Emits `{"ok":true}` (exit 0) or `{"ok":false,"errors":[...]}` (exit 1). Exit 2 on
/// malformed JSON.
pub fn cmd_validate(def_text : String) -> CmdResult {
  let defj = @json.parse(def_text) catch {
    _ =>
      return {
        json: error_json(
          "malformed_definition_json", "definition text is not valid JSON",
        ),
        exit: 2,
      }
  }
  match @core.parse_definition(defj) {
    Ok(_) =>
      {
        json: Json::object({ "ok": Json::boolean(true) }).stringify(indent=2),
        exit: 0,
      }
    Err(@core.Malformed(reason)) => {
      let obj = Json::object({
        "ok": Json::boolean(false),
        "errors": Json::array([
          Json::object({
            "kind": Json::string("malformed_definition"),
            "message": Json::string(reason),
          }),
        ]),
      })
      { json: obj.stringify(indent=2), exit: 1 }
    }
    Err(@core.Rejected(errs)) => {
      let out = Json::object({
        "ok": Json::boolean(false),
        "errors": deferrs_to_json(errs),
      })
      { json: out.stringify(indent=2), exit: 1 }
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION 2 — parse outcome → JSON
// ═════════════════════════════════════════════════════════════════════════════

///|
/// Convert an `Outcome` into a (json_object, exit_code) pair.
fn outcome_to_json(ast : @core.AtomicAST, o : @core.Outcome) -> (Json, Int) {
  match o {
    @core.Success(binds) => {
      let effects = effects_to_json(ast.root, binds)
      let result = result_to_json(ast.root, binds)
      let ws = @core.warnings_of(o)
      let fields : Array[(String, Json)] = [
        ("outcome", Json::string("success")),
        ("effects", effects),
        ("result", result),
      ]
      if ws.length() > 0 {
        fields.push(("warnings", strs_to_json(ws)))
      }
      (Json::object(Map::from_array(fields)), 0)
    }
    @core.Failure(d) => {
      let fields : Array[(String, Json)] = [
        ("outcome", Json::string("failure")),
        ("errors", parse_errors_to_json(d.errors)),
      ]
      match d.fired_action {
        Some(name) => fields.push(("fired_action", Json::string(name)))
        None => ()
      }
      if d.tried_triggers.length() > 0 {
        fields.push(("tried_triggers", strs_to_json(d.tried_triggers)))
      }
      match d.help_entry {
        Some(h) => fields.push(("help_entry", Json::string(h)))
        None => ()
      }
      let ws = @core.warnings_of(o)
      if ws.length() > 0 {
        fields.push(("warnings", strs_to_json(ws)))
      }
      (Json::object(Map::from_array(fields)), 1)
    }
    @core.Ambiguous(d) => {
      // PoC 仮置き #2: interpretation の詳細は spec 未確定なので個数だけ pin する。
      let arr : Array[Json] = []
      for _ in d.interpretations {
        arr.push(Json::empty_object())
      }
      let fields : Array[(String, Json)] = [
        ("outcome", Json::string("ambiguous")),
        ("interpretations", Json::array(arr)),
      ]
      match d.help_entry {
        Some(h) => fields.push(("help_entry", Json::string(h)))
        None => ()
      }
      (Json::object(Map::from_array(fields)), 1)
    }
  }
}

///|
/// `effects`: DR-045 §1 effect column. `config_file`, `TNone`, and `dd` cells are excluded
/// (mirrors `proj_effects_ex` in json_conformance_wbtest.mbt).
fn effects_to_json(sc : @core.Scope, binds : Array[@core.Binding]) -> Json {
  let arr : Array[Json] = []
  for b in binds {
    if is_sentinel_key(b.key) {
      continue
    }
    if is_excluded_cell(sc, b.key) {
      continue
    }
    let fields : Array[(String, Json)] = [
      ("entity", Json::string(b.key)),
      ("op", Json::string(effect_op_str(b.op))),
    ]
    // operand: only for Set / Remove (DR-045 §1 / DR-080 §2). default / unset / empty /
    // splice / update carry no operand.
    match b.op {
      @core.Set => fields.push(("operand", value_to_json(b.value)))
      @core.Remove => fields.push(("operand", value_to_json(b.value)))
      _ => ()
    }
    fields.push(("source", Json::string(source_str(b.source))))
    if b.scope.length() > 0 {
      fields.push(("scope", strs_to_json(b.scope)))
    }
    arr.push(Json::object(Map::from_array(fields)))
  }
  Json::array(arr)
}

///|
/// `result`: uses an empty ExportKey map (PoC 仮置き #1 — see file-level comment). The result
/// object mirrors what fixture `expect.result` asserts: kv view keyed by entity name (or
/// export_key when the caller has one; PoC does not consult ekmap so overrides do not apply).
fn result_to_json(sc : @core.Scope, binds : Array[@core.Binding]) -> Json {
  let ekmap : Map[String, @core.ExportKey] = Map([])
  let binds2 = @core.apply_export_keys(binds, ekmap)
  let accums = @core.accum_cells(sc, ekmap)
  let defaults = @core.apply_export_to_defaults(@core.default_cells(sc), ekmap)
  let nones = @core.none_cells(sc)
  let rval = @core.build_result(binds2, accums, defaults, [], nones~)
  rval_to_json(rval)
}

///|
fn rval_to_json(r : @core.RVal) -> Json {
  match r {
    @core.RScalar(v) => value_to_json(v)
    @core.RArr(xs) => {
      let arr : Array[Json] = []
      for x in xs {
        arr.push(rval_to_json(x))
      }
      Json::array(arr)
    }
    @core.RObj(kv) => {
      let pairs : Array[(String, Json)] = []
      for kv2 in kv {
        pairs.push((kv2.0, rval_to_json(kv2.1)))
      }
      Json::object(Map::from_array(pairs))
    }
  }
}

///|
fn value_to_json(v : @core.Value) -> Json {
  match v {
    @core.VStr(s) => Json::string(s)
    @core.VBool(b) => Json::boolean(b)
    @core.VNum(d) => Json::number(d)
  }
}

///|
fn parse_errors_to_json(errs : Array[@core.ParseError]) -> Json {
  let arr : Array[Json] = []
  for e in errs {
    let fields : Array[(String, Json)] = [
      ("element", Json::string(e.element)),
      ("args_pos", Json::number(e.args_pos.to_double())),
      ("kind", Json::string(errkind_str(e.kind))),
      ("reason", Json::string(e.reason)),
    ]
    if e.path.length() > 0 {
      fields.push(("path", strs_to_json(e.path)))
    }
    // message is caller-facing text only (CONFORMANCE.md §3 ignores it); we emit it as `message`
    // so callers CAN inspect it. Fixture comparison is expected to strip it.
    if e.message.length() > 0 {
      fields.push(("message", Json::string(e.message)))
    }
    arr.push(Json::object(Map::from_array(fields)))
  }
  Json::array(arr)
}

///|
fn def_errors_json(errs : Array[@core.DefError]) -> String {
  let obj = Json::object({ "errors": deferrs_to_json(errs) })
  obj.stringify(indent=2)
}

///|
fn deferrs_to_json(errs : Array[@core.DefError]) -> Json {
  let arr : Array[Json] = []
  for e in errs {
    let fields : Array[(String, Json)] = [
      ("element", Json::string(e.element)),
      ("kind", Json::string(deferr_kind_str(e.kind))),
      ("message", Json::string(e.message)),
      ("hint", Json::string(e.hint)),
    ]
    arr.push(Json::object(Map::from_array(fields)))
  }
  Json::array(arr)
}

///|
fn strs_to_json(xs : Array[String]) -> Json {
  let arr : Array[Json] = []
  for x in xs {
    arr.push(Json::string(x))
  }
  Json::array(arr)
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION 3 — completion candidate → JSON (DR-104 §2 wire format)
// ═════════════════════════════════════════════════════════════════════════════

///|
fn cand_to_json(c : @core.Cand) -> Json {
  let fields : Array[(String, Json)] = []
  // spelling: required for exact triggers; omitted (equivalent to "") for value positions.
  if !c.is_value {
    fields.push(("spelling", Json::string(c.spelling)))
  }
  fields.push(("is_value", Json::boolean(c.is_value)))
  if c.is_value {
    fields.push(("ty", Json::string(ty_str(c.ty))))
  }
  fields.push(("origin", Json::string(c.origin)))
  fields.push(("term", Json::string(term_str(c.term))))
  fields.push(
    (
      "meta",
      Json::object({
        "is_alias": Json::boolean(c.meta.is_alias),
        "hidden": Json::boolean(c.meta.hidden),
        "deprecated": Json::boolean(c.meta.deprecated),
      }),
    ),
  )
  match c.completer {
    Some(name) => fields.push(("completer", Json::string(name)))
    None => ()
  }
  Json::object(Map::from_array(fields))
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION 4 — small enum → wire-token string maps
// ═════════════════════════════════════════════════════════════════════════════

///|
fn effect_op_str(op : @core.EffectOp) -> String {
  match op {
    @core.Set => "set"
    @core.Default => "default"
    @core.Unset => "unset"
    @core.Empty => "empty"
    @core.Update(_, _) => "update"
    @core.Remove => "remove"
    @core.Splice => "splice"
  }
}

///|
fn source_str(s : @core.Source) -> String {
  match s {
    @core.Cli => "cli"
    @core.Env => "env"
    @core.Config => "config"
    @core.Inherit => "inherit"
    @core.Tty => "tty"
    @core.Default => "default"
  }
}

///|
fn errkind_str(k : @core.ErrKind) -> String {
  match k {
    @core.KParse => "parse"
    @core.KFilter => "filter"
    @core.KConstraint => "constraint"
  }
}

///|
fn deferr_kind_str(k : @core.DefErrKind) -> String {
  match k {
    @core.DVocabIntersection => "vocab-intersection"
    @core.DUnknownVocab => "unknown-vocab"
    @core.DInvalidRange => "invalid-range"
    @core.DAbsentRef => "absent-ref"
    @core.DCircularRef => "circular-ref"
    @core.DZeroProgress => "zero-progress"
    @core.DConfigCycle => "config-cycle"
    @core.DInvalidArgument => "invalid-argument"
  }
}

///|
/// DR-104 §2 明確化 (2026-07-15): custom type の `ty` は基底 primitive に解決した 5 種
/// (`string`/`number`/`int`/`float`/`bool`) のみが値位置候補として出現する。
/// flag/count/none は値スロットを取らないので値位置候補としては現れないが (万一渡された場合の
/// 安全側 fallback として) スペック上の綴りを返す。
fn ty_str(t : @core.Ty) -> String {
  match t {
    @core.TStr => "string"
    @core.TNum => "number"
    @core.TInt => "int"
    @core.TFloat => "float"
    @core.TBool => "bool"
    @core.TFlag => "flag"
    @core.TCount => "count"
    @core.TNone => "none"
  }
}

///|
fn term_str(t : @core.TermHint) -> String {
  match t {
    @core.WordEnd => "word_end"
    @core.Cont => "cont"
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION 5 — helpers
// ═════════════════════════════════════════════════════════════════════════════

///|
/// Sentinel binding keys used by resolve/build_result internally — not real effects, must be
/// filtered from the CLI output. Mirrors `is_sentinel` in json_conformance_wbtest.mbt.
fn is_sentinel_key(k : String) -> Bool {
  k == "[]" || k == "{}" || k == ""
}

///|
/// True when the entity of key `k` in scope `sc` has a config_file, TNone, or dd role — such
/// bindings are internal markers, not user-visible effects. Mirrors the trio of exclusions in
/// `proj_effects_ex` (json_conformance_wbtest.mbt). dd is a greedy-scan pattern — see
/// `is_dd_cell_scan`.
fn is_excluded_cell(sc : @core.Scope, k : String) -> Bool {
  for e in sc.entities {
    if e.name == k && (e.is_config_file || is_tnone(e.ty)) {
      return true
    }
  }
  is_dd_cell_scan(sc, k)
}

///|
fn is_tnone(t : @core.Ty) -> Bool {
  match t {
    @core.TNone => true
    _ => false
  }
}

///|
/// Walk the scope's greedy nodes looking for a DdSat/DdMatchSat trigger named `k`, recursing
/// into command scopes. Mirrors `is_dd_cell` in json_conformance_wbtest.mbt.
fn is_dd_cell_scan(sc : @core.Scope, k : String) -> Bool {
  fn scan(g : @core.Node) -> Bool {
    match g {
      @core.DdSat(trigger) => trigger == k
      @core.DdMatchSat(_, _, _, elem_name) => elem_name == k
      @core.Or(alts) => {
        for a in alts {
          if scan(a) {
            return true
          }
        }
        false
      }
      @core.Rooted(inner, _) => scan(inner)
      @core.CmdSat(_, child) => is_dd_cell_scan(child, k)
      _ => false
    }
  }

  for g in sc.greedy {
    if scan(g) {
      return true
    }
  }
  false
}

///|
/// Wrap an error kind + message into a JSON string (used for CLI-boundary errors).
fn error_json(kind : String, message : String) -> String {
  Json::object({
    "ok": Json::boolean(false),
    "errors": Json::array([
      Json::object({
        "kind": Json::string(kind),
        "message": Json::string(message),
      }),
    ]),
  }).stringify(indent=2)
}
