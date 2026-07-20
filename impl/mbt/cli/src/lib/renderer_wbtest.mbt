// renderer_wbtest.mbt — DR-115 canonical レンダラの golden テスト。
//
// spec 側 fixture pin は §6.2 で明示的に非規範 (canonical レンダラの出力は fixture pin しない)。
// このため product 側 (= kuu-cli) の golden として代表 case を pin する — DR-115 §6.3 の分担で
// spec fixture の代替として置く安定性担保レイヤ。
//
// 【選定】: 3 case で「default 骨格 + グループ + 継承 + テンプレ」を代表:
//   1. root-basic 相当 = 既定 skeleton + description + options + positional
//   2. group + inherited (origin_style=separate_section 既定の分割) + hidden group 入口注記
//   3. テンプレ + binding 補間 (§2 + §3 + program_name 暗黙 binding)

///|
/// テスト用: definition JSON → HelpModel を得る (lib.cmd_help の decode 経路と同じ)。
fn build_model_for_test(def_text : String) -> @kuu.HelpModel {
  let defj = @json.parse(def_text) catch {
    _ => abort("test: def text is not valid JSON")
  }
  let registry = @engine.Registry::new()
  @kuu.install_canonical(registry)
  let ast = match @kuu.parse_definition(defj, extensions=registry) {
    Ok(a) => a
    Err(_) => abort("test: parse_definition failed")
  }
  match @kuu.dispatch_help_query(registry, ast) {
    @kuu.Model(m) => m
    _ => abort("test: dispatch_help_query did not return Model")
  }
}

///|
/// GOLDEN 1: 既定 skeleton (usage → description → options → positionals)。
/// root-basic fixture 相当の最小 definition で pin する。
test "renderer golden: default skeleton with usage / description / options / positionals" {
  let def =
    #|{"name":"prog","help":"Serve files over HTTP","options":[
    #|  {"name":"port","type":"number","long":true,"short":"p","env":"PORT","default":8080,"value_name":"PORT","help":"listen port"},
    #|  {"name":"token","type":"string","long":true,"value_name":"TOKEN","required":true,"help":"required token"},
    #|  {"name":"tag","type":"string","long":true,"value_name":"TAG","multiple":"append","help":"repeatable tag"}
    #|],"positionals":[{"name":"file","type":"string","value_name":"FILE","help":"input file"}]}
  let model = build_model_for_test(def)
  let out = render_help(model, render_opts_default())
  inspect(
    out,
    content=(
      #|Usage: prog [OPTIONS] <FILE>
      #|
      #|Serve files over HTTP
      #|
      #|Options:
      #|  --port, -p <PORT>   listen port [default: 8080] [env: PORT]
      #|  --token <TOKEN>     required token (required)
      #|  --tag <TAG>         repeatable tag (repeatable)
      #|
      #|Arguments:
      #|  <FILE>   input file
      #|
    ),
  )
}

///|
/// GOLDEN 2: グループ (hidden group の入口注記) + inherited (origin_style=separate_section 既定)。
/// help-render-group-hidden + origin-inheritable の合成 minimal definition。
test "renderer golden: hidden group notice + separate_section inherited options" {
  // group 宣言は「name/title のみの option エントリ」で表現する (DR-113 §8.1 のフラット並び)。
  // hidden group + public group + 各グループに 1 option を配し、default category_mode で hidden
  // group が入口注記に落ちることを pin する (fixture help-render-group-hidden 相当の最小形)。
  let def =
    #|{"options":[
    #|  {"help_group_name":"internal","help_group_title":"Internal options","hidden":true},
    #|  {"help_group_name":"public","help_group_title":"Public options"},
    #|  {"name":"port","type":"number","long":true,"value_name":"PORT","help":"listen port","help_group_name":"public"},
    #|  {"name":"debug-dump","type":"flag","long":true,"help":"dump state","help_group_name":"internal"}
    #|]}
  let model = build_model_for_test(def)
  let out = render_help(model, render_opts_default())
  inspect(
    out,
    content=(
      #|Usage: [OPTIONS]
      #|
      #|Options:
      #|  (hidden group; use --category-mode named:internal to view)
      #|
      #|  Public options
      #|  --port <PORT>   listen port
      #|
    ),
  )
}

///|
/// GOLDEN 3: テンプレ (§2 プレースホルダ置換) + binding 補間 (§3 `{version}`) + program_name の
/// 暗黙 binding。テンプレ間バイト列 (改行) は definer 責任の逐語搬送 (§2.3)。
test "renderer golden: template with placeholders and binding interpolation" {
  // template + version binding 参照 + `{{` エスケープを 1 case で網羅。
  let def =
    #|{"name":"myapp","help":"myapp v{version} — do stuff (curly literal: {{lit}})","help_render":{"template":"{usage}\n\n{description}\n\n{options}\n"},
    #|  "options":[{"name":"port","type":"number","long":true,"value_name":"PORT","help":"listen port"}]}
  let model = build_model_for_test(def)
  let opts = render_opts_default()
  opts.bindings.set("version", "1.0.0")
  let out = render_help(model, opts)
  // template の空白・改行は逐語搬送 (§2.3)、description 内 {version} は §3 で置換、{{lit}} は
  // literal `{lit}` に戻る。
  inspect(
    out,
    content=(
      #|Usage: myapp [OPTIONS]
      #|
      #|myapp v1.0.0 — do stuff (curly literal: {lit}})
      #|
      #|Options:
      #|  --port <PORT>   listen port
      #|
    ),
  )
}

///|
/// 追加 pin: origin_style separate_section 分割 (single scope で inheritable 由来を持つ簡易 def)。
/// subcommand 経由の inheritable は spec fixture (origin-inheritable) が主戦場なので、ここでは
/// 「inherited 側が local と別 heading 下に出る」の shape だけ pin する — inheritable 系 fixture
/// は e2e 側 (help-conformance 33/33) で JSON model 面から担保されているので、text 面はスコープ
/// を絞る。
test "renderer golden: separate_section inherited options at parent scope" {
  // subcommand socket が inheritable な --timeout を宣言 (fixture origin-inheritable 相当)。
  // 親 scope (path=["prog"]) の help model は Inherited options: 見出しの下にその option を持つ
  // (§5.3 separate_section 既定)。commands セクションに subcommand も並ぶ。
  let def =
    #|{"name":"prog","commands":[{"type":"command","name":"socket","help":"manage sockets",
    #|  "options":[{"name":"timeout","type":"number","long":true,"inheritable":true,"value_name":"SECONDS","help":"socket timeout"}]}]}
  let defj = @json.parse(def) catch {
    _ => abort("test: def text is not valid JSON")
  }
  let registry = @engine.Registry::new()
  @kuu.install_canonical(registry)
  let ast = match @kuu.parse_definition(defj, extensions=registry) {
    Ok(a) => a
    Err(_) => abort("test: parse_definition failed")
  }
  let model = match @kuu.dispatch_help_query(registry, ast) {
    @kuu.Model(m) => m
    _ => abort("test: dispatch_help_query did not return Model")
  }
  let out = render_help(model, render_opts_default())
  inspect(
    out,
    content=(
      #|Usage: prog [OPTIONS] <COMMAND>
      #|
      #|Commands:
      #|  socket   manage sockets
      #|
      #|Inherited options:
      #|  --socket-timeout <SECONDS>   socket timeout
      #|
    ),
  )
}
