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
//   - `warnings`: `@kuu.warnings(parse_outcome)` (kuu 玄関 API) → `{element, kind}` の object 配列
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
  config? : (String) -> @engine.ConfigVal? = fn(_p) { None },
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
/// `kuu help <def_json_text> [--path ...] [--depth ...] [--category-mode ...]`:
/// dispatch the DR-113 §1 help_query capability against the parsed definition and emit the
/// canonical help model JSON (schema `$defs/helpModel` — mirrors kuu.mbt json_conformance_test
/// のシリアライズ経路。§4/§4.4 準拠、余剰キー不出力)。
///
/// - Ok(HelpModel) → `{"outcome":"help", ...}` (exit 0)
/// - Err(HelpQueryError) → `{"outcome":"query-error","errors":[{"kind":"absent-path"|"absent-category"}]}` (exit 1)
/// - malformed definition JSON → exit 2 (parse subcommand と同じ扱い)
/// - malformed definition (Rejected) → definition-error JSON (exit 1)
/// - help_query capability 未登録 → exit 2 の error_json (canonical registry は必ず含むので通常発生しない)
pub fn cmd_help(
  def_text : String,
  path : Array[String],
  depth : @kuu.HelpDepth,
  category_mode : @kuu.HelpCategoryMode,
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
  // capability lookup 経路のため extensions を明示ビルドする (canonical と同じ = @kuu.install_canonical)。
  let registry = @engine.Registry::new()
  @kuu.install_canonical(registry)
  match @kuu.parse_definition(defj, extensions=registry) {
    Err(@kuu.Malformed(reason)) =>
      { json: error_json("malformed_definition", reason), exit: 1 }
    Err(@kuu.Rejected(errs)) =>
      // help wire envelope (DR-113 §9): {"outcome":"definition-error","errors":[{"element","kind"}]}
      // fixture の allowed_keys が element+kind に限られており、message / hint は出さない
      // (DR-109 §2 の「余剰フィールドは出さない」を help 経路にも適用)。help 以外の subcommand
      // 経路 (parse / complete / validate) では従来通り def_errors_json(message + hint 含む) を
      // 使う — spec の envelope が subcommand で異なるための分岐 (help は query 前提の canonical
      // JSON wire、他は legacy CLI 慣習)。
      { json: def_errors_help_envelope(errs).stringify(indent=2), exit: 1 }
    Ok(ast) =>
      match
        @kuu.dispatch_help_query(
          registry,
          ast,
          path~,
          depth~,
          category_mode~,
        ) {
        @kuu.Unavailable =>
          {
            json: error_json(
              "help_query_not_registered",
              "help_query capability is not registered in the active assembly",
            ),
            exit: 2,
          }
        @kuu.QueryError(err) =>
          { json: help_query_error_json(err).stringify(indent=2), exit: 1 }
        @kuu.Model(model) =>
          { json: help_model_json(model).stringify(indent=2), exit: 0 }
      }
  }
}

///|
/// `kuu help --format text` の実行本体。`cmd_help` と同じ dispatch 経路で HelpModel を取得し、
/// canonical レンダラ (DR-115) を通してテキストを stdout 出力する。エラー envelope (definition-error
/// / query-error / malformed) は JSON 版と同一の形で stdout に出す (人間向け text 出力に混ぜず、
/// エラーは machine parse 可能な形を維持する — machine tail / lint との組合せで扱いやすい)。
pub fn cmd_help_text(
  def_text : String,
  path : Array[String],
  depth : @kuu.HelpDepth,
  category_mode : @kuu.HelpCategoryMode,
  render_opts : RenderOpts,
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
  let registry = @engine.Registry::new()
  @kuu.install_canonical(registry)
  match @kuu.parse_definition(defj, extensions=registry) {
    Err(@kuu.Malformed(reason)) =>
      { json: error_json("malformed_definition", reason), exit: 1 }
    Err(@kuu.Rejected(errs)) =>
      { json: def_errors_help_envelope(errs).stringify(indent=2), exit: 1 }
    Ok(ast) =>
      match
        @kuu.dispatch_help_query(
          registry,
          ast,
          path~,
          depth~,
          category_mode~,
        ) {
        @kuu.Unavailable =>
          {
            json: error_json(
              "help_query_not_registered",
              "help_query capability is not registered in the active assembly",
            ),
            exit: 2,
          }
        @kuu.QueryError(err) =>
          { json: help_query_error_json(err).stringify(indent=2), exit: 1 }
        @kuu.Model(model) => { json: render_help(model, render_opts), exit: 0 }
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
  po : @engine.Outcome,
  args : Array[String],
  env : Map[String, String],
  config : (String) -> @engine.ConfigVal?,
  tty : Map[String, @kuu.TtyObs],
) -> (Json, Int) {
  match po {
    @engine.Success(pbinds) => {
      // resolve 相を通して値源ラダー (env / config / inherit / default) を充填 (DR-109 §7 =
      // 既定で resolve 適用、値源は §6 の実環境 / 試験用オプション経由で呼び出し側が確定済み)。
      let ro = @kuu.resolve(ast, po, args, env~, config~, tty~)
      match ro {
        @engine.Success(rbinds) => {
          // effects / result / sources は front_door の OutputView 1 発 (kuu.mbt MDR-005 追記) を
          // 使う — sentinel / config_file / none / dd の除外規則は front_door 側の正本 1 箇所に
          // 集約済み (旧 `@kuu.is_sentinel` + 手組み `is_excluded_cell` の重複実装を解消)。
          // effects は parse 段の生 binds (`pbinds`)、result / sources は resolve 済み binds
          // (`rbinds`) から組む — 相区分は変えない (DR-045 §1 / DR-109 §5-§7 と同じ素材の対応)。
          let view = @kuu.output(ast, effects=pbinds, resolved=rbinds)
          let effects = output_effects_to_json(view.effects)
          let result = rval_to_json(view.result)
          let sources = source_entries_to_json(view.sources)
          // warnings は空でも `[]` を出す (DR-109 §2 の厳密一致 — fixture の `warnings: []`
          // 期待と同形)。
          let ws = @kuu.warnings(po)
          let fields : Array[(String, Json)] = [
            ("outcome", Json::string("success")),
            ("effects", effects),
            ("result", result),
            ("sources", sources),
            ("warnings", warnings_to_json(ws)),
          ]
          (Json::object(Map::from_array(fields)), 0)
        }
        @engine.Failure(d) =>
          // 値源解決 (env/config seat parse や DR-009 §7 filter reject) で転落した場合は
          // failure JSON を返す (spec DR-053 §2 の failure に resolve 相失敗も含まれる)。
          // warnings は parse Outcome から取る (deprecated marker は parse 段の binds に載る)。
          (failure_to_json(d, po), 1)
        _ =>
          // spec 上 `resolve` は Ambiguous をパススルーするだけで新規 Ambiguous 化することは
          // ない (kuu.mbt MDR-005 §1)。到達不可の安全網。
          (
            failure_to_json(
              {
                errors: [],
                fired_action: None,
                help_entry: None,
                tried_triggers: [],
              },
              po,
            ),
            1,
          )
      }
    }
    @engine.Failure(d) => (failure_to_json(d, po), 1)
    @engine.Ambiguous(d) => {
      // DR-109 §4: interpretation は resolve 相を適用せず parse 相の骨格のみ返す。各解釈は
      // result ビュー (claimants 無し) または `{result, claimants}` (共露出衝突あり、DR-073 §1
      // の「組で保持」)。ビューの組み立ては kuu 玄関 API `@kuu.output_of_interpretation` へ委譲
      // (TRI-Q4、部品直呼びを解消)。
      let arr : Array[Json] = []
      for interp in d.interpretations {
        let view = @kuu.output_of_interpretation(ast, interp)
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
/// CONFORMANCE §2 — キーは scope-path 修飾)。射影本体は front_door の `OutputView.sources`
/// (`@kuu.output`、kuu.mbt MDR-005 追記) — ここは SourceEntry 列を JSON object に写すだけ。
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
fn failure_to_json(d : @engine.FailureData, po : @engine.Outcome) -> Json {
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
  let ws = @kuu.warnings(po)
  if ws.length() > 0 {
    fields.push(("warnings", warnings_to_json(ws)))
  }
  Json::object(Map::from_array(fields))
}

///|
/// `warnings`: spec CONFORMANCE §2 が要求する `{element, kind}` の object 配列。素材は
/// `@kuu.warnings` (kuu 玄関 API、内部は kuu.mbt eval.mbt の `warnings_structured` へ委譲。旧
/// `warnings_of` の element 配列を kind 情報つきに拡張したもの、codex M-1 解消)。
fn warnings_to_json(ws : Array[@engine.Warning]) -> Json {
  let arr : Array[Json] = []
  for w in ws {
    let kind = match w.kind {
      @engine.Deprecated => "deprecated"
    }
    arr.push(
      Json::object({
        "element": Json::string(w.element),
        "kind": Json::string(kind),
      }),
    )
  }
  Json::array(arr)
}

///|
/// `effects`: DR-045 §1 effect column. `OutputEffect` (kuu.mbt front_door.mbt) は sentinel
/// (`[]` / `{}` / "" / `#row` / `#fire` / `@act:...` / `@depr:...`) と `config_file` /
/// `type:"none"` / `dd` の内部セルを既に除外済み (front_door `project_effects` が正本、旧
/// wire.mbt 手組み `is_excluded_cell` の重複実装は解消)。
fn output_effects_to_json(effects : Array[@kuu.OutputEffect]) -> Json {
  let arr : Array[Json] = []
  for e in effects {
    let fields : Array[(String, Json)] = [
      ("entity", Json::string(e.entity)),
      ("op", Json::string(effect_op_str(e.op))),
    ]
    // operand: OutputEffect.operand は Set / Remove のみ Some (front_door.mbt project_effects の
    // 契約、DR-045 §1 / DR-080 §2 と同じ規則)。
    match e.operand {
      Some(v) => fields.push(("operand", value_to_json(v)))
      None => ()
    }
    // update (旧 Update(transform, args) / DR-114 で Invoke(FnInvocation) へ改称) の transform /
    // args (DR-077 §1/§2、CONFORMANCE §2 の effects 語彙)。実 fixture (count-parse 等) では
    // front_door `project_effects` が descriptor 呼び出しで既に Set に折り畳んでいるため、Invoke
    // arm がここに残るのは descriptor 未登録の safety net 経路のみ (旧 Update 経路と同じ書式で emit)。
    match e.op {
      @engine.Invoke(inv) => {
        fields.push(("transform", Json::string(inv.name)))
        if inv.args.length() > 0 {
          fields.push(("args", strs_to_json(inv.args)))
        }
      }
      _ => ()
    }
    fields.push(("source", Json::string(source_str(e.source))))
    // `scope` は fixture expect の effects 語彙に無い (CONFORMANCE §2 = {entity, op, operand?,
    // source, transform?, args?})。DR-109 §2 の厳密一致に従い出さない。
    arr.push(Json::object(Map::from_array(fields)))
  }
  Json::array(arr)
}

///|
fn rval_to_json(r : @engine.ResultValue) -> Json {
  match r {
    @engine.ResultValue::Scalar(v) => value_to_json(v)
    @engine.ResultValue::Array(xs) => {
      let arr : Array[Json] = []
      for x in xs {
        arr.push(rval_to_json(x))
      }
      Json::array(arr)
    }
    @engine.ResultValue::Object(kv) => {
      let pairs : Array[(String, Json)] = []
      for kv2 in kv {
        pairs.push((kv2.0, rval_to_json(kv2.1)))
      }
      Json::object(Map::from_array(pairs))
    }
  }
}

///|
fn value_to_json(v : @engine.Value) -> Json {
  match v {
    @engine.String(s) => Json::string(s)
    @engine.Bool(b) => Json::boolean(b)
    // DR-092 §1/§2: JSON に inf リテラルは無いため、float 値位置の無限大は
    // protobuf3 準拠の文字列 sentinel ("Infinity" / "-Infinity") で表現する。
    // NaN は DR-074 で parse 段 Reject 済み (両型 Error) のためここに到達しない。
    @engine.Number(d) if d.is_pos_inf() => Json::string("Infinity")
    @engine.Number(d) if d.is_neg_inf() => Json::string("-Infinity")
    @engine.Number(d) => Json::number(d)
  }
}

///|
fn parse_errors_to_json(errs : Array[@engine.ParseError]) -> Json {
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
fn def_errors_json(errs : Array[@engine.DefError]) -> String {
  let obj = Json::object({ "errors": deferrs_to_json(errs) })
  obj.stringify(indent=2)
}

///|
fn deferrs_to_json(errs : Array[@engine.DefError]) -> Json {
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
fn cand_to_json(c : @engine.Candidate) -> Json {
  let fields : Array[(String, Json)] = []
  // spelling: required for exact triggers; omitted (equivalent to "") for value positions.
  if !c.is_value {
    fields.push(("spelling", Json::string(c.spelling)))
  }
  fields.push(("is_value", Json::boolean(c.is_value)))
  if c.is_value {
    fields.push(("type", Json::string(c.ty)))
  }
  fields.push(("origin", Json::string(c.origin)))
  fields.push(("term", Json::string(term_str(c.term))))
  fields.push(
    (
      "meta",
      Json::object({
        "is_alias": Json::boolean(c.is_alias),
        "hidden": Json::boolean(c.hidden),
        "deprecated": Json::boolean(c.deprecated),
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
fn effect_op_str(op : @engine.EffectOp) -> String {
  match op {
    @engine.Set => "set"
    @engine.Default => "default"
    @engine.Unset => "unset"
    @engine.Empty => "empty"
    @engine.Invoke(_) => "update"
    @engine.Remove => "remove"
    @engine.Splice => "splice"
  }
}

///|
fn source_str(s : @engine.Source) -> String {
  match s {
    @engine.Cli => "cli"
    @engine.Env => "env"
    @engine.Config => "config"
    @engine.Inherit => "inherit"
    @engine.Tty => "tty"
    @engine.Default => "default"
  }
}

///|
fn errkind_str(k : @engine.ErrorKind) -> String {
  match k {
    @engine.ErrorKind::Parse => "parse"
    @engine.ErrorKind::Filter => "filter"
    @engine.ErrorKind::Constraint => "constraint"
  }
}

///|
fn deferr_kind_str(k : @engine.DefErrorKind) -> String {
  match k {
    @engine.VocabIntersection => "vocab-intersection"
    @engine.UnknownVocab => "unknown-vocab"
    @engine.InvalidRange => "invalid-range"
    @engine.AbsentRef => "absent-ref"
    @engine.CircularRef => "circular-ref"
    @engine.ZeroProgress => "zero-progress"
    @engine.ConfigCycle => "config-cycle"
    @engine.InvalidArgument => "invalid-argument"
  }
}

///|
fn term_str(t : @engine.TermHint) -> String {
  match t {
    @engine.WordEnd => "word_end"
    @engine.Continue => "cont"
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION 4b — help model → JSON (DR-113 §4/§4.4 wire format)
// ═════════════════════════════════════════════════════════════════════════════
//
// kuu.mbt (src/kuu/json_conformance_test.mbt) の help_* helpers を wire 語彙のまま移植。
// schema (`$defs/helpModel` 等) と fixture expect の厳密一致が要件 (DR-109 §2 と同じ思想:
// 期待に無いキーは emit しない、schema required キーは false でも emit)。

///|
/// DR-113 §1/§9 query-error envelope の serialize。help_query 固有の失敗 (合法な definition に
/// 対する呼び出し側入力の失敗) を definition-error と別 outcome で pin する。fixture 期待は
/// `{"outcome":"query-error","errors":[{"kind":"absent-path"}]}` の形式。
fn help_query_error_json(err : @kuu.HelpQueryError) -> Json {
  let kind = match err {
    @kuu.AbsentPath => "absent-path"
    @kuu.AbsentCategory => "absent-category"
  }
  Json::object({
    "outcome": Json::string("query-error"),
    "errors": Json::array([Json::object({ "kind": Json::string(kind) })]),
  })
}

///|
/// help wire の definition-error envelope (DR-113 §9)。help_query は「合法な definition」を前提と
/// するので、definition が Rejected な場合は query 経路を通さず `{"outcome":"definition-error",
/// "errors":[{"element","kind"}]}` を返す。message / hint は fixture allowed_keys 外なので出さない。
fn def_errors_help_envelope(errs : Array[@engine.DefError]) -> Json {
  let arr : Array[Json] = []
  for e in errs {
    let fields : Array[(String, Json)] = []
    // element 空文字は「帰属先なし」— fixture 側も element キー自体を省略するので同形で omit
    // (parse errors の parse_errors_to_json と同じ規則、DR-109 §2 の厳密一致方針)。
    if e.element.length() > 0 {
      fields.push(("element", Json::string(e.element)))
    }
    fields.push(("kind", Json::string(deferr_kind_str(e.kind))))
    arr.push(Json::object(Map::from_array(fields)))
  }
  Json::object({
    "outcome": Json::string("definition-error"),
    "errors": Json::array(arr),
  })
}

///|
fn help_model_json(model : @kuu.HelpModel) -> Json {
  let object : Map[String, Json] = Map([])
  object.set("outcome", Json::string("help"))
  object.set("command_path", strs_to_json(model.command_path))
  if model.usage.has_options ||
    model.usage.positionals.length() > 0 ||
    model.usage.has_subcommands ||
    model.usage.has_dd {
    object.set("usage", help_usage_json(model.usage))
  }
  match model.description {
    Some(v) => object.set("description", Json::string(v))
    None => ()
  }
  match model.description_long {
    Some(v) => object.set("description_long", Json::string(v))
    None => ()
  }
  match model.epilog {
    Some(v) => object.set("epilog", Json::string(v))
    None => ()
  }
  match model.render {
    Some(view) => object.set("render", help_render_view_json(view))
    None => ()
  }
  if model.types.length() > 0 {
    let arr : Array[Json] = []
    for e in model.types {
      arr.push(help_type_entry_json(e))
    }
    object.set("types", Json::array(arr))
  }
  if model.commands.length() > 0 {
    let arr : Array[Json] = []
    for c in model.commands {
      arr.push(help_command_json(c))
    }
    object.set("commands", Json::array(arr))
  }
  if model.options.length() > 0 {
    let arr : Array[Json] = []
    for o in model.options {
      arr.push(help_option_entry_json(o))
    }
    object.set("options", Json::array(arr))
  }
  if model.positionals.length() > 0 {
    let arr : Array[Json] = []
    for p in model.positionals {
      arr.push(help_positional_json(p))
    }
    object.set("positionals", Json::array(arr))
  }
  match model.help_entry {
    Some(v) => object.set("help_entry", Json::string(v))
    None => ()
  }
  Json::object(object)
}

///|
fn help_render_view_json(view : @kuu.HelpRenderView) -> Json {
  let object : Map[String, Json] = Map([])
  match view.template {
    Some(v) => object.set("template", Json::string(v))
    None => ()
  }
  match view.value_structure_style {
    Some(v) => object.set("value_structure_style", Json::string(v))
    None => ()
  }
  match view.types_style {
    Some(v) => object.set("types_style", Json::string(v))
    None => ()
  }
  match view.origin_style {
    Some(v) => object.set("origin_style", Json::string(v))
    None => ()
  }
  Json::object(object)
}

///|
fn help_usage_json(usage : @kuu.HelpUsage) -> Json {
  let object : Map[String, Json] = Map([])
  if usage.has_options {
    object.set("has_options", Json::boolean(true))
  }
  if usage.positionals.length() > 0 {
    let arr : Array[Json] = []
    for p in usage.positionals {
      arr.push(help_usage_positional_json(p))
    }
    object.set("positionals", Json::array(arr))
  }
  if usage.has_subcommands {
    object.set("has_subcommands", Json::boolean(true))
  }
  if usage.has_dd {
    object.set("has_dd", Json::boolean(true))
  }
  Json::object(object)
}

///|
fn help_usage_positional_json(p : @kuu.HelpUsagePositional) -> Json {
  Json::object({
    "value_structure": help_value_structure_json(p.value_structure),
  })
}

///|
fn help_type_entry_json(entry : @kuu.HelpTypeEntry) -> Json {
  let out : Map[String, Json] = Map([])
  out.set("id", Json::string(entry.id))
  out.set("value_structure", help_value_structure_json(entry.value_structure))
  match entry.help {
    Some(v) => out.set("help", Json::string(v))
    None => ()
  }
  out.set("used_as", strs_to_json(entry.used_as))
  Json::object(out)
}

///|
fn help_command_json(c : @kuu.HelpCommand) -> Json {
  let object : Map[String, Json] = Map([])
  object.set("name", Json::string(c.name))
  if c.aliases.length() > 0 {
    object.set("aliases", strs_to_json(c.aliases))
  }
  match c.help {
    Some(v) => object.set("help", Json::string(v))
    None => ()
  }
  match c.help_long {
    Some(v) => object.set("help_long", Json::string(v))
    None => ()
  }
  // hidden / deprecated / origin は schema required — false でも常時 emit (DR-113 §4/§4.4)。
  object.set("hidden", Json::boolean(c.hidden))
  object.set("deprecated", Json::boolean(c.deprecated))
  object.set("origin", help_origin_json(c.origin))
  match c.scope {
    Some(sub) => object.set("scope", help_model_json(sub))
    None => ()
  }
  Json::object(object)
}

///|
fn help_positional_json(p : @kuu.HelpPositional) -> Json {
  let object : Map[String, Json] = Map([])
  object.set("value_structure", help_value_structure_json(p.value_structure))
  match p.value_structure_style {
    Some(v) => object.set("value_structure_style", Json::string(v))
    None => ()
  }
  match p.help {
    Some(v) => object.set("help", Json::string(v))
    None => ()
  }
  match p.help_long {
    Some(v) => object.set("help_long", Json::string(v))
    None => ()
  }
  object.set("hidden", Json::boolean(p.hidden))
  object.set("deprecated", Json::boolean(p.deprecated))
  Json::object(object)
}

///|
fn help_option_entry_json(entry : @kuu.HelpOptionEntry) -> Json {
  match entry {
    @kuu.Group(g) => {
      let group_obj : Map[String, Json] = Map([])
      group_obj.set("name", Json::string(g.name))
      match g.title {
        Some(v) => group_obj.set("title", Json::string(v))
        None => ()
      }
      match g.description {
        Some(v) => group_obj.set("description", Json::string(v))
        None => ()
      }
      let object : Map[String, Json] = Map([])
      object.set("group", Json::object(group_obj))
      if g.hidden {
        object.set("hidden", Json::boolean(true))
      }
      Json::object(object)
    }
    @kuu.Option(o) => help_option_json(o)
  }
}

///|
fn help_option_json(o : @kuu.HelpOption) -> Json {
  let object : Map[String, Json] = Map([])
  object.set("spellings", strs_to_json(o.spellings))
  if o.alias_spellings.length() > 0 {
    object.set("alias_spellings", strs_to_json(o.alias_spellings))
  }
  match o.value_structure {
    Some(vs) => object.set("value_structure", help_value_structure_json(vs))
    None => ()
  }
  match o.value_structure_style {
    Some(v) => object.set("value_structure_style", Json::string(v))
    None => ()
  }
  match o.display_name {
    Some(v) => object.set("display_name", Json::string(v))
    None => ()
  }
  match o.help {
    Some(v) => object.set("help", Json::string(v))
    None => ()
  }
  match o.help_long {
    Some(v) => object.set("help_long", Json::string(v))
    None => ()
  }
  match o.help_group_name {
    Some(v) => object.set("help_group_name", Json::string(v))
    None => ()
  }
  match o.default {
    Some(v) => object.set("default", help_default_json(v))
    None => ()
  }
  // env: 1 要素は string、2 要素以上は array (DR-113 §4 wire schema)。
  if o.env.length() == 1 {
    object.set("env", Json::string(o.env[0]))
  } else if o.env.length() > 1 {
    object.set("env", strs_to_json(o.env))
  }
  if o.required {
    object.set("required", Json::boolean(true))
  }
  if o.multiple {
    object.set("multiple", Json::boolean(true))
  }
  object.set("hidden", Json::boolean(o.hidden))
  object.set("deprecated", Json::boolean(o.deprecated))
  object.set("origin", help_origin_json(o.origin))
  Json::object(object)
}

///|
fn help_origin_json(origin : @kuu.HelpOrigin) -> Json {
  match origin {
    @kuu.Local => Json::string("local")
    @kuu.Global(declared_at) =>
      Json::object({
        "kind": Json::string("global"),
        "declared_at": strs_to_json(declared_at),
      })
    @kuu.Inheritable(declared_at) =>
      Json::object({
        "kind": Json::string("inheritable"),
        "declared_at": strs_to_json(declared_at),
      })
    @kuu.Alias(of) =>
      Json::object({
        "kind": Json::string("alias"),
        "of": Json::string(of),
      })
  }
}

///|
fn help_default_json(v : @kuu.HelpDefault) -> Json {
  match v {
    @kuu.Scalar(scalar) => help_value_json(scalar)
    @kuu.Array(values) => {
      let arr : Array[Json] = []
      for item in values {
        arr.push(help_value_json(item))
      }
      Json::array(arr)
    }
  }
}

///|
/// help model 内の default 値専用の Value → JSON 変換 (parse 相の value_to_json と別関数)。
/// help wire ではスカラー 3 型 (string/number/bool) のみを直接 JSON リテラルへ落とす。float の
/// ±∞ は spec 上 help_default に現れない (DR-113 §4)。
fn help_value_json(v : @engine.Value) -> Json {
  match v {
    @engine.String(s) => Json::string(s)
    @engine.Bool(b) => Json::boolean(b)
    @engine.Number(d) => Json::number(d)
  }
}

///|
fn help_value_structure_json(vs : @engine.HelpValueStructure) -> Json {
  match vs {
    @engine.Single(single) => {
      let inner : Map[String, Json] = Map([])
      match single.value_name {
        Some(v) => inner.set("value_name", Json::string(v))
        None => ()
      }
      match single.value_type {
        Some(t) => inner.set("type", Json::string(t))
        None => ()
      }
      match single.values_enum {
        Some(values) => inner.set("values_enum", strs_to_json(values))
        None => ()
      }
      Json::object({ "single": Json::object(inner) })
    }
    @engine.Seq(nodes) => {
      let arr : Array[Json] = []
      for n in nodes {
        arr.push(help_value_structure_json(n))
      }
      Json::object({ "seq": Json::array(arr) })
    }
    @engine.Or(nodes) => {
      let arr : Array[Json] = []
      for n in nodes {
        arr.push(help_value_structure_json(n))
      }
      Json::object({ "or": Json::array(arr) })
    }
    @engine.Repeat(spec) => {
      let inner : Map[String, Json] = Map([])
      match spec.min {
        Some(m) => inner.set("min", Json::number(m.to_double()))
        None => ()
      }
      match spec.max {
        Some(m) => inner.set("max", Json::number(m.to_double()))
        None => ()
      }
      inner.set("node", help_value_structure_json(spec.node))
      Json::object({ "repeat": Json::object(inner) })
    }
    @engine.TypeRef(ref_) => {
      let out : Map[String, Json] = Map([])
      out.set("type_ref", Json::string(ref_.id))
      match ref_.value_name {
        Some(v) => out.set("value_name", Json::string(v))
        None => ()
      }
      Json::object(out)
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION 5 — helpers
// ═════════════════════════════════════════════════════════════════════════════

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
