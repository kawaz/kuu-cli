// wire.mbt — kuu-cli MoonBit PoC の subcommand core (parse / complete / validate).
//
// `impl/mbt` の Design 目的は spec (kawaz/kuu) の CLI 入出力契約の輪郭を固めること (kuu-cli
// DR-0001 §3)。ここでは kuu.mbt (参照実装) の front_door 4 関数 (parse_definition / parse /
// resolve / complete) を直接呼び、fixture `expect` と概ね同じ語彙の JSON を stdout に emit
// する。
//
// 【front_door 2 段構成】(kuu.mbt MDR-005 §1 追記、2026-07-16、issue
// front-door-parse-missing-postprocessing の kuu-cli 側追随):
//
// 玄関 API は `parse` (spec 準拠の Outcome 骨格 = parse_tree + apply_requires_filter +
// promote_collision_ambiguous) と `resolve` (値源ラダー = env / config / inherit / default
// seat fill を子 scope まで再帰的に充填) の 2 段。`parse` は env / config / tty を optional
// 引数で受け、`resolve` も同じ引数を受ける (現状 kuu-cli は 3 系ともデフォルト = 空 で呼ぶ、
// CLI 面からの供給は今回スコープ外だが玄関 API としては存在する)。
//
// 出力 JSON の内訳 (spec DR-109 §2 = fixture expect と厳密一致、余剰フィールドは出さない):
//   - `effects`: parse Success の生 binds (resolve 前) から DR-045 §1 効果列を組む
//   - `result`: resolve Success の解決済み binds (値源ラダー充填後) から DR-052 result-key 軸
//     を適用した kv projection
//   - `sources`: resolve 済み出力に常時含める (DR-109 §3)。entity → 値源タグのマップ、キーは
//     scope-path 修飾 (CONFORMANCE §2)
//   - `warnings`: `warnings_structured(parse_outcome)` → `{element, kind}` の object 配列
//     (spec CONFORMANCE §2)。空でも `[]` を出す (fixture の `warnings: []` 期待と厳密一致)
//   - `interpretations` (ambiguous): 各解釈の `{result, claimants?}` (DR-053 §3 / DR-073)。
//     resolve 相は適用しない (DR-109 §4 — parse 相の骨格のみ)
//
// resolve 相の失敗 (DR-066 env/config seat parse 失敗、DR-009 §7 filter reject) は Outcome を
// Failure に転落させ、parse Success + resolve Failure の場合も Failure JSON を出す (spec
// DR-053 §2 の failure に resolve 相失敗も含まれる意味論と整合)。
//
// 【PoC 仮置き — 統括が正本化する材料】
//
// exit code は `--help` 系 (未実装) を除き 3 値: 0=成功、1=parse failure / validate 失敗、
// 2=CLI 使い方エラー (unknown subcommand, malformed args JSON 等)。PoC の暫定割当、後日正本化。

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
///
/// env / config / tty は値源ラダーの供給源 (DR-109 §6: 既定 = 実環境、試験用オプションで
/// 固定・注入)。呼び出し側 (main.mbt) が実環境取得とオプション解釈を済ませた形で渡す。
pub fn cmd_parse(
  def_text : String,
  args : Array[String],
  env? : Map[String, String] = Map([]),
  config? : (String) -> @kuu.ConfigVal? = fn(_p) { None },
  tty? : Map[String, @kuu.TtyObs] = Map([]),
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
  match @kuu.parse_definition(defj) {
    Err(@kuu.Malformed(reason)) =>
      { json: error_json("malformed_definition", reason), exit: 1 }
    Err(@kuu.Rejected(errs)) => { json: def_errors_json(errs), exit: 1 }
    Ok(ast) => {
      let outcome = @kuu.parse(ast, args, env~, config~, tty~)
      let (obj, exit) = outcome_to_json(ast, outcome, args, env, config, tty)
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
  match @kuu.parse_definition(defj) {
    Err(@kuu.Malformed(reason)) =>
      { json: error_json("malformed_definition", reason), exit: 1 }
    Err(@kuu.Rejected(errs)) => { json: def_errors_json(errs), exit: 1 }
    Ok(ast) => {
      let cands = @kuu.complete(ast, before, args_after=after)
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
  match @kuu.parse_definition(defj) {
    Ok(_) =>
      {
        json: Json::object({ "ok": Json::boolean(true) }).stringify(indent=2),
        exit: 0,
      }
    Err(@kuu.Malformed(reason)) => {
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
    Err(@kuu.Rejected(errs)) => {
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
/// Convert an `Outcome` into a (json_object, exit_code) pair. `po` は `front_door.parse` の返値
/// (Success の binds は CLI 由来の生 binds、resolve 未適用)。Success の場合はさらに
/// `front_door.resolve` を呼んで値源ラダーを充填した binds を得て、result / sources を組み立てる
/// — 相区分の 2 段構成 (kuu.mbt MDR-005 §1)。resolve 相の失敗は Failure に転落させ、Failure
/// JSON を出す。`args` は resolve が at_pos 計算 (DR-066 §4) に使う。
fn outcome_to_json(
  ast : @kuu.AtomicAST,
  po : @kuu.Outcome,
  args : Array[String],
  env : Map[String, String],
  config : (String) -> @kuu.ConfigVal?,
  tty : Map[String, @kuu.TtyObs],
) -> (Json, Int) {
  let ekmap = @kuu.export_map(ast)
  match po {
    @kuu.Success(pbinds) => {
      // parse 段の効果列は生 binds を素材にする (DR-045 §1 = cli fold の観測)。
      let effects = effects_to_json(ast.root, pbinds)
      // resolve 相を通して値源ラダー (env / config / inherit / default) を充填 (DR-109 §7 =
      // 既定で resolve 適用、値源は §6 の実環境 / 試験用オプション経由で呼び出し側が確定済み)。
      let ro = @kuu.resolve(ast, po, args, env~, config~, tty~)
      match ro {
        @kuu.Success(rbinds) => {
          // result / sources は front_door の production 射影 (kuu.mbt MDR-005 追記、DR-109 §5
          // の昇格) を使う — runner から写した 4 素材の手組みは重複だったので新 API に置換。
          let result = rval_to_json(@kuu.result(ast, rbinds))
          let sources = source_entries_to_json(@kuu.sources(ast, rbinds))
          // warnings は空でも `[]` を出す (DR-109 §2 の厳密一致 — fixture の `warnings: []`
          // 期待と同形)。
          let ws = @kuu.warnings_structured(po)
          let fields : Array[(String, Json)] = [
            ("outcome", Json::string("success")),
            ("effects", effects),
            ("result", result),
            ("sources", sources),
            ("warnings", warnings_to_json(ws)),
          ]
          (Json::object(Map::from_array(fields)), 0)
        }
        @kuu.Failure(d) => {
          // 値源解決 (env/config seat parse や DR-009 §7 filter reject) で転落した場合は
          // failure JSON を返す (spec DR-053 §2 の failure に resolve 相失敗も含まれる)。
          // warnings は parse Outcome から取る (deprecated marker は parse 段の binds に載る)。
          (failure_to_json(d, po), 1)
        }
        _ =>
          // spec 上 `resolve` は Ambiguous をパススルーするだけで新規 Ambiguous 化することは
          // ない (kuu.mbt MDR-005 §1)。到達不可の安全網。
          (failure_to_json(
            {
              errors: [],
              fired_action: None,
              help_entry: None,
              tried_triggers: [],
            },
            po,
          ), 1)
      }
    }
    @kuu.Failure(d) => (failure_to_json(d, po), 1)
    @kuu.Ambiguous(d) => {
      // DR-109 §4: interpretation は resolve 相を適用せず parse 相の骨格のみ返す。各解釈は
      // result ビュー (claimants 無し) または `{result, claimants}` (共露出衝突あり、DR-073 §1
      // の「組で保持」)。ビューの組み立ては conformance runner の render (build_result に
      // defaults を渡さない = ラダー未適用の parse 素材のみ) と同じ。
      let arr : Array[Json] = []
      for interp in d.interpretations {
        let view = @kuu.build_result(
          @kuu.apply_export_keys(interp.binds, ekmap),
          @kuu.accum_cells(ast.root, ekmap),
          [],
          [],
          nones=@kuu.none_cells(ast.root),
        )
        if interp.claimants.length() == 0 {
          arr.push(rval_to_json(view))
        } else {
          let cl : Array[(String, Json)] = []
          for kv in interp.claimants {
            cl.push((kv.0, Json::string(kv.1)))
          }
          arr.push(
            Json::object({
              "result": rval_to_json(view),
              "claimants": Json::object(Map::from_array(cl)),
            }),
          )
        }
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
/// `sources`: resolve 済み binds から entity → 値源タグのマップを組む (DR-109 §3 で常時出力、
/// CONFORMANCE §2 — キーは scope-path 修飾)。射影本体は front_door の production API
/// `@kuu.sources` (kuu.mbt MDR-005 追記) — ここは SourceEntry 列を JSON object に写すだけ。
fn source_entries_to_json(entries : Array[@kuu.SourceEntry]) -> Json {
  let items : Array[(String, Json)] = []
  for e in entries {
    let mut key = ""
    for seg in e.path {
      key = key + seg + "."
    }
    key = key + e.key
    items.push((key, Json::string(source_str(e.source))))
  }
  Json::object(Map::from_array(items))
}

///|
/// Assemble the failure JSON (Failure outcome or resolve-layer failure). `po` は warnings 素材
/// (deprecated marker は parse 段の binds に載る)。
fn failure_to_json(d : @kuu.FailureData, po : @kuu.Outcome) -> Json {
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
  let ws = @kuu.warnings_structured(po)
  if ws.length() > 0 {
    fields.push(("warnings", warnings_to_json(ws)))
  }
  Json::object(Map::from_array(fields))
}

///|
/// `warnings`: spec CONFORMANCE §2 が要求する `{element, kind}` の object 配列。素材は
/// `@kuu.warnings_structured` (kuu.mbt eval.mbt、旧 `warnings_of` の element 配列を kind 情報
/// つきに拡張したもの、codex M-1 解消)。
fn warnings_to_json(ws : Array[@kuu.Warning]) -> Json {
  let arr : Array[Json] = []
  for w in ws {
    arr.push(
      Json::object({
        "element": Json::string(w.element),
        "kind": Json::string(w.kind),
      }),
    )
  }
  Json::array(arr)
}

///|
/// `effects`: DR-045 §1 effect column. `config_file`, `TNone`, and `dd` cells are excluded
/// (mirrors `proj_effects_ex` in json_conformance_wbtest.mbt).
fn effects_to_json(sc : @kuu.Scope, binds : Array[@kuu.Binding]) -> Json {
  let arr : Array[Json] = []
  for b in binds {
    // sentinel (`[]` / `{}` / "" / `#row` / `#fire` / `@act:...` / `@depr:...`) は effects の
    // 素材ではない (kuu.mbt resolve.mbt の `is_sentinel`、pub 化済み — issue
    // front-door-parse-missing-postprocessing、codex M-1 の `@depr:port` が effects に漏れる
    // バグの根治)。旧 `is_sentinel_key` (`[]` / `{}` / `""` のみ) は狭すぎた。
    if @kuu.is_sentinel(b.key) {
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
      @kuu.Set => fields.push(("operand", value_to_json(b.value)))
      @kuu.Remove => fields.push(("operand", value_to_json(b.value)))
      _ => ()
    }
    // update の transform / args (DR-077 §1/§2、CONFORMANCE §2 の effects 語彙)。
    match b.op {
      @kuu.Update(transform, targs) => {
        fields.push(("transform", Json::string(transform)))
        if targs.length() > 0 {
          fields.push(("args", strs_to_json(targs)))
        }
      }
      _ => ()
    }
    fields.push(("source", Json::string(source_str(b.source))))
    // `scope` は fixture expect の effects 語彙に無い (CONFORMANCE §2 = {entity, op, operand?,
    // source, transform?, args?})。DR-109 §2 の厳密一致に従い出さない。
    arr.push(Json::object(Map::from_array(fields)))
  }
  Json::array(arr)
}

///|
fn rval_to_json(r : @kuu.RVal) -> Json {
  match r {
    @kuu.RScalar(v) => value_to_json(v)
    @kuu.RArr(xs) => {
      let arr : Array[Json] = []
      for x in xs {
        arr.push(rval_to_json(x))
      }
      Json::array(arr)
    }
    @kuu.RObj(kv) => {
      let pairs : Array[(String, Json)] = []
      for kv2 in kv {
        pairs.push((kv2.0, rval_to_json(kv2.1)))
      }
      Json::object(Map::from_array(pairs))
    }
  }
}

///|
fn value_to_json(v : @kuu.Value) -> Json {
  match v {
    @kuu.VStr(s) => Json::string(s)
    @kuu.VBool(b) => Json::boolean(b)
    @kuu.VNum(d) => Json::number(d)
  }
}

///|
fn parse_errors_to_json(errs : Array[@kuu.ParseError]) -> Json {
  let arr : Array[Json] = []
  for e in errs {
    let fields : Array[(String, Json)] = []
    // element 空文字 = 帰属先なし (unexpected_token 系)。fixture expect は element キー自体を
    // 省略する形なので、空値はフィールドごと出さない (DR-109 §2 の厳密一致)。
    if e.element.length() > 0 {
      fields.push(("element", Json::string(e.element)))
    }
    fields.push(("args_pos", Json::number(e.args_pos.to_double())))
    fields.push(("kind", Json::string(errkind_str(e.kind))))
    fields.push(("reason", Json::string(e.reason)))
    if e.path.length() > 0 {
      fields.push(("path", strs_to_json(e.path)))
    }
    // `message` は出さない (DR-109 §2: expect に無いフィールドは出さない。CONFORMANCE §3 も
    // message を常に無視する — 人間向けは将来の opt-in へ)。
    arr.push(Json::object(Map::from_array(fields)))
  }
  Json::array(arr)
}

///|
fn def_errors_json(errs : Array[@kuu.DefError]) -> String {
  let obj = Json::object({ "errors": deferrs_to_json(errs) })
  obj.stringify(indent=2)
}

///|
fn deferrs_to_json(errs : Array[@kuu.DefError]) -> Json {
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
fn cand_to_json(c : @kuu.Cand) -> Json {
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
fn effect_op_str(op : @kuu.EffectOp) -> String {
  match op {
    @kuu.Set => "set"
    @kuu.Default => "default"
    @kuu.Unset => "unset"
    @kuu.Empty => "empty"
    @kuu.Update(_, _) => "update"
    @kuu.Remove => "remove"
    @kuu.Splice => "splice"
  }
}

///|
fn source_str(s : @kuu.Source) -> String {
  match s {
    @kuu.Cli => "cli"
    @kuu.Env => "env"
    @kuu.Config => "config"
    @kuu.Inherit => "inherit"
    @kuu.Tty => "tty"
    @kuu.Default => "default"
  }
}

///|
fn errkind_str(k : @kuu.ErrKind) -> String {
  match k {
    @kuu.KParse => "parse"
    @kuu.KFilter => "filter"
    @kuu.KConstraint => "constraint"
  }
}

///|
fn deferr_kind_str(k : @kuu.DefErrKind) -> String {
  match k {
    @kuu.DVocabIntersection => "vocab-intersection"
    @kuu.DUnknownVocab => "unknown-vocab"
    @kuu.DInvalidRange => "invalid-range"
    @kuu.DAbsentRef => "absent-ref"
    @kuu.DCircularRef => "circular-ref"
    @kuu.DZeroProgress => "zero-progress"
    @kuu.DConfigCycle => "config-cycle"
    @kuu.DInvalidArgument => "invalid-argument"
  }
}

///|
/// DR-104 §2 明確化 (2026-07-15): custom type の `ty` は基底 primitive に解決した 5 種
/// (`string`/`number`/`int`/`float`/`bool`) のみが値位置候補として出現する。
/// flag/count/none は値スロットを取らないので値位置候補としては現れないが (万一渡された場合の
/// 安全側 fallback として) スペック上の綴りを返す。
fn ty_str(t : @kuu.Ty) -> String {
  match t {
    @kuu.TStr => "string"
    @kuu.TNum => "number"
    @kuu.TInt => "int"
    @kuu.TFloat => "float"
    @kuu.TBool => "bool"
    @kuu.TFlag => "flag"
    @kuu.TCount => "count"
    @kuu.TNone => "none"
  }
}

///|
fn term_str(t : @kuu.TermHint) -> String {
  match t {
    @kuu.WordEnd => "word_end"
    @kuu.Cont => "cont"
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION 5 — helpers
// ═════════════════════════════════════════════════════════════════════════════

///|
/// True when the entity of key `k` in scope `sc` has a config_file, TNone, or dd role — such
/// bindings are internal markers, not user-visible effects. Mirrors the trio of exclusions in
/// `proj_effects_ex` (json_conformance_wbtest.mbt). dd is a greedy-scan pattern — see
/// `is_dd_cell_scan`.
fn is_excluded_cell(sc : @kuu.Scope, k : String) -> Bool {
  for e in sc.entities {
    if e.name == k && (e.is_config_file || is_tnone(e.ty)) {
      return true
    }
  }
  is_dd_cell_scan(sc, k)
}

///|
fn is_tnone(t : @kuu.Ty) -> Bool {
  match t {
    @kuu.TNone => true
    _ => false
  }
}

///|
/// Walk the scope's greedy nodes looking for a DdSat/DdMatchSat trigger named `k`, recursing
/// into command scopes. Mirrors `is_dd_cell` in json_conformance_wbtest.mbt.
fn is_dd_cell_scan(sc : @kuu.Scope, k : String) -> Bool {
  fn scan(g : @kuu.Node) -> Bool {
    match g {
      @kuu.DdSat(trigger) => trigger == k
      @kuu.DdMatchSat(_, _, _, elem_name) => elem_name == k
      @kuu.Or(alts) => {
        for a in alts {
          if scan(a) {
            return true
          }
        }
        false
      }
      @kuu.Rooted(inner, _) => scan(inner)
      @kuu.CmdSat(_, child) => is_dd_cell_scan(child, k)
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
