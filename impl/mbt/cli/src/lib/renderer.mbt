// renderer.mbt — DR-115 canonical help レンダラ (テキスト出力本体).
//
// 【責務】 (DR-115 §6.1/§6.2):
//   - HelpModel + RenderOpts → 人間向けテキスト。model 射影は kuu.mbt / wire.mbt 側、レンダラは
//     model を読むだけの consumer (spec 側では非規範 §6.2 — バイト単位検証は product 側 golden)
//   - style 3 段 override の 3 段目 (API 引数) を適用: model.render (定義者宣言) < RenderOpts.style
//   - §2 テンプレ (プレースホルダ逐次置換 + `{{` エスケープ、閉集合 8 種 + binding 参照 fallback)
//   - §3 binding 補間: help / help_long / help_epilog 中の `{name}` 置換 + `{{` エスケープ
//   - §4 グループ hidden: default = 所属 entry 省略 + 入口注記 / all = 表示 / named = 表示
//   - §5 canonical 既定: value_structure_style=auto / types_style=auto (共有型 ≥2 で集約) /
//     origin_style=separate_section (gh の INHERITED FLAGS 型)
//
// 【美観の magic number は全部このモジュール冒頭に集約】(kawaz が後から一括調整できるように):

///|
/// エントリ行のインデント (option / command / positional の左空白幅)。clap/cobra は 2 spaces、
/// kubectl は 4 spaces。canonical は 2 を採用。
const INDENT : String = "  "

///|
/// エントリ本体 (`--flag <V>`) と help 説明の間のギャップ幅。clap 2 spaces、cobra tab。
/// canonical は 3 spaces (視認性優先、TBD で kawaz が調整)。
const GAP : String = "   "

///|
/// エントリの説明行が折り返して次行に来た場合のハンギングインデント。
/// canonical: `INDENT + GAP` 相当の幅を確保する (spellings 側との左境界一致)。
const HANG : String = "      "

///|
/// セクション見出し (Usage: / Options: 等)。canonical は clap/cobra 準拠の Capitalized + colon。
const SEC_USAGE : String = "Usage:"

///|
const SEC_COMMANDS : String = "Commands:"

///|
const SEC_OPTIONS : String = "Options:"

///|
const SEC_POSITIONALS : String = "Arguments:"

///|
const SEC_INHERITED_OPTIONS : String = "Inherited options:"

///|
const SEC_TYPES : String = "Types:"

///|
/// hidden group の「入口注記」文言 (DR-115 §4)。非規範 (§6.2 の «入口注記の文言» exclusion)。
const HIDDEN_GROUP_NOTE_PREFIX : String = "  (hidden group; use --category-mode named:"

///|
const HIDDEN_GROUP_NOTE_SUFFIX : String = " to view)"

// ═════════════════════════════════════════════════════════════════════════════
// public API — RenderOpts / render_help
// ═════════════════════════════════════════════════════════════════════════════

///|
/// style overrides (DR-115 §1 の 3 段目 = レンダラ API 引数)。全キー optional。model.render を
/// 前段実効値として受け、None のキーは前段を残す。
pub(all) struct RenderStyle {
  template : String?
  value_structure_style : String?
  types_style : String?
  origin_style : String?
} derive(Eq, Debug)

///|
/// レンダラ API opts。program_name は §3 の暗黙 binding として供給 (未指定なら command_path[0])。
/// category_mode は default/all/named の 3 分岐で表示 policy を制御 (DR-115 §4):
/// default = hidden group を入口注記のみ / all = hidden group も所属 entry 込みで表示 /
/// named(name) = 名指しは明示要求なので表示。default/all は model 素材が同一なため renderer 側で
/// 分岐する必要がある。
pub(all) struct RenderOpts {
  program_name : String?
  show_hidden : Bool
  bindings : Map[String, String]
  style : RenderStyle
  category_mode : @kuu.HelpCategoryMode
} derive(Eq, Debug)

///|
/// 既定 RenderOpts (bindings 空 / show_hidden=false / style 全 None)。
pub fn render_opts_default() -> RenderOpts {
  {
    program_name: None,
    show_hidden: false,
    bindings: Map([]),
    style: {
      template: None,
      value_structure_style: None,
      types_style: None,
      origin_style: None,
    },
    category_mode: @kuu.Default,
  }
}

///|
/// canonical レンダラ本体。DR-115 §6.2 の非規範出力 — spec fixture では pin しない
/// (product 側 golden で担保)。
pub fn render_help(model : @kuu.HelpModel, opts : RenderOpts) -> String {
  let ctx = build_context(model, opts)
  match ctx.style.template {
    Some(tpl) => render_template(tpl, ctx)
    None => render_default_skeleton(ctx)
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// context — effective style + binding lookup + program_name
// ═════════════════════════════════════════════════════════════════════════════

///|
/// レンダラ内部で全 section 関数が共有する読み取り専用 context。
priv struct RenderCtx {
  model : @kuu.HelpModel
  opts : RenderOpts
  style : EffectiveStyle
  program_name : String
  bindings : Map[String, String]
}

///|
/// 3 段 override 適用後の実効 style (§1 の階層継承は model 射影で解決済み、ここは
/// model.render × RenderOpts.style の overlay だけ)。値未指定は canonical 既定へ落とす。
priv struct EffectiveStyle {
  template : String?
  value_structure_style : String // "auto" | "inline" | "detail"
  types_style : String // "auto" | "aggregate" | "inline"
  origin_style : String // "merge" | "separate_section" | "reference" | "omit"
}

///|
fn build_context(model : @kuu.HelpModel, opts : RenderOpts) -> RenderCtx {
  // model.render の 4 キーを受け、opts.style で 3 段目上書き、最後に canonical 既定 (§5) で埋める。
  let (m_tpl, m_vs, m_ts, m_os) = match model.render {
    Some(r) => (r.template, r.value_structure_style, r.types_style, r.origin_style)
    None => (None, None, None, None)
  }
  let template = match opts.style.template {
    Some(_) as v => v
    None => m_tpl
  }
  let vs = match opts.style.value_structure_style {
    Some(v) => v
    None => m_vs.unwrap_or("auto")
  }
  let ts = match opts.style.types_style {
    Some(v) => v
    None => m_ts.unwrap_or("auto")
  }
  let os = match opts.style.origin_style {
    Some(v) => v
    None => m_os.unwrap_or("separate_section")
  }
  // program_name: opts 優先、なければ command_path 先頭、それも空なら "" (usage 行で空表示)。
  let program_name = match opts.program_name {
    Some(n) => n
    None => if model.command_path.length() > 0 { model.command_path[0] } else { "" }
  }
  // bindings に program_name の暗黙供給を混ぜる (明示指定が優先)。
  let bindings : Map[String, String] = Map([])
  bindings.set("program_name", program_name)
  for k, v in opts.bindings {
    bindings.set(k, v)
  }
  {
    model,
    opts,
    style: {
      template,
      value_structure_style: vs,
      types_style: ts,
      origin_style: os,
    },
    program_name,
    bindings,
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// template application (§2)
// ═════════════════════════════════════════════════════════════════════════════

///|
/// テンプレ文字列を逐次置換で render する。`{{` → literal `{`、`{ident}` → セクション or
/// binding 参照。閉集合 8 種はセクション見出し込みで置換、それ以外は binding で解決、未解決は
/// literal `{ident}` を残す (canonical、§3)。
fn render_template(tpl : String, ctx : RenderCtx) -> String {
  brace_scan(tpl.to_array(), fn(ident) { resolve_placeholder(ident, ctx) })
}

///|
/// `{{` → literal `{`、`{ident}` → resolver(ident) の逐次置換。ident 規則に合わない brace 列は
/// literal 素通し (寛容モード = §3 の文言位置寛容と共通機構、テンプレ位置の strict 検査は
/// wire 側の §2.4 で済んでいる前提)。
fn brace_scan(chars : Array[Char], resolver : (String) -> String) -> String {
  let out = StringBuilder::new()
  let n = chars.length()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == '{' {
      if i + 1 < n && chars[i + 1] == '{' {
        out.write_char('{')
        i = i + 2
      } else {
        let start = i + 1
        let mut j = start
        while j < n && chars[j] != '}' {
          j = j + 1
        }
        if j < n && j > start && is_ident(chars, start, j) {
          let ident = chars_to_string(chars, start, j)
          out.write_string(resolver(ident))
          i = j + 1
        } else {
          out.write_char(c)
          i = i + 1
        }
      }
    } else {
      out.write_char(c)
      i = i + 1
    }
  }
  out.to_string()
}

///|
fn chars_to_string(chars : Array[Char], start : Int, end : Int) -> String {
  let out = StringBuilder::new()
  let mut i = start
  while i < end {
    out.write_char(chars[i])
    i = i + 1
  }
  out.to_string()
}

///|
/// snake_case ident 判定 (`[a-z][a-z0-9_]*`、DR-115 §2.1 / DR-022 系)。start..end の範囲を検査。
fn is_ident(chars : Array[Char], start : Int, end : Int) -> Bool {
  if end <= start {
    return false
  }
  let c0 = chars[start]
  if !(c0 >= 'a' && c0 <= 'z') {
    return false
  }
  let mut i = start + 1
  while i < end {
    let c = chars[i]
    if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// ident (閉集合 8 種 or binding) を解決。閉集合はセクション見出し込みテキスト、binding は
/// 変数値、未解決は literal `{ident}`。
fn resolve_placeholder(ident : String, ctx : RenderCtx) -> String {
  match ident {
    "usage" => section_usage(ctx)
    "description" => section_description(ctx, long=false)
    "description_long" => section_description(ctx, long=true)
    "epilog" => section_epilog(ctx)
    "commands" => section_commands(ctx)
    "options" => section_options(ctx)
    "positionals" => section_positionals(ctx)
    "types" => section_types(ctx)
    _ =>
      match ctx.bindings.get(ident) {
        Some(v) => v
        None => "{" + ident + "}" // §3: 未解決 binding は literal
      }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// default skeleton (§2.3: template 不在時 = canonical 内蔵挙動、条件分岐なしテンプレでは
// 「空なら見出しごと省略」が書けないためテンプレ還元しない設計、DR-115 §2.3)
// ═════════════════════════════════════════════════════════════════════════════

///|
/// 空セクションを含めず、間に空行を 1 つ挟む。順序: usage → description → types → commands →
/// options → positionals → epilog。既定骨格の順は canonical、§6.2 で非規範。
fn render_default_skeleton(ctx : RenderCtx) -> String {
  let parts : Array[String] = []
  let push = fn(s : String) {
    if s.length() > 0 {
      parts.push(s)
    }
  }
  push(section_usage(ctx))
  push(section_description(ctx, long=false))
  push(section_types(ctx))
  push(section_commands(ctx))
  push(section_options(ctx))
  push(section_positionals(ctx))
  push(section_epilog(ctx))
  // section 間は空行 (改行 2 つ) で区切る (clap/cobra 慣習)。末尾には改行 1 つ。
  let out = StringBuilder::new()
  let mut first = true
  for p in parts {
    if !first {
      out.write_string("\n\n")
    }
    out.write_string(p)
    first = false
  }
  if !first {
    out.write_char('\n')
  }
  out.to_string()
}

// ═════════════════════════════════════════════════════════════════════════════
// sections
// ═════════════════════════════════════════════════════════════════════════════

///|
/// Usage: 行 (canonical)。`Usage: <program> [OPTIONS] [--] <ARGS>... <COMMAND>` の形。
fn section_usage(ctx : RenderCtx) -> String {
  let u = ctx.model.usage
  let out = StringBuilder::new()
  out.write_string(SEC_USAGE)
  // program name: opts / command_path から展開。command_path が multi-segment なら space 結合
  // (clap 慣習: `git remote add`)。program 名が空なら [OPTIONS] を直接くっつける。
  let full_prog = if ctx.opts.program_name is Some(_) {
    ctx.program_name
  } else if ctx.model.command_path.length() > 0 {
    join_strings(ctx.model.command_path, " ")
  } else {
    ""
  }
  if full_prog.length() > 0 {
    out.write_char(' ')
    out.write_string(full_prog)
  }
  if u.has_options {
    out.write_string(" [OPTIONS]")
  }
  if u.has_dd {
    out.write_string(" [--]")
  }
  for p in u.positionals {
    out.write_char(' ')
    out.write_string(value_structure_inline(p.value_structure))
  }
  if u.has_subcommands {
    out.write_string(" <COMMAND>")
  }
  out.to_string()
}

///|
fn section_description(ctx : RenderCtx, long~ : Bool) -> String {
  let src = if long {
    match ctx.model.description_long {
      Some(_) as v => v
      None => ctx.model.description
    }
  } else {
    ctx.model.description
  }
  match src {
    Some(text) => interpolate_bindings(text, ctx.bindings)
    None => ""
  }
}

///|
fn section_epilog(ctx : RenderCtx) -> String {
  match ctx.model.epilog {
    Some(text) => interpolate_bindings(text, ctx.bindings)
    None => ""
  }
}

///|
/// Commands: セクション。hidden は show_hidden=false で省略、deprecated は marker 併記。
/// depth=all で scope 埋め込みは model 側で解決済み (子の scope フィールドは今は展開しない —
/// canonical は 1 階層フラット表示、詳細は `<cmd> --help`)。
fn section_commands(ctx : RenderCtx) -> String {
  let cmds : Array[@kuu.HelpCommand] = []
  for c in ctx.model.commands {
    if c.hidden && !ctx.opts.show_hidden {
      continue
    }
    cmds.push(c)
  }
  if cmds.length() == 0 {
    return ""
  }
  let out = StringBuilder::new()
  out.write_string(SEC_COMMANDS)
  out.write_char('\n')
  // 列幅計算: name + aliases の最長 (INDENT 除外)
  let mut w = 0
  for c in cmds {
    let l = command_head(c).length()
    if l > w {
      w = l
    }
  }
  for c in cmds {
    out.write_string(INDENT)
    let head = command_head(c)
    out.write_string(head)
    let help_text = command_help_text(c, ctx)
    if help_text.length() > 0 {
      let pad_n = w - head.length()
      let mut p = 0
      while p < pad_n {
        out.write_char(' ')
        p = p + 1
      }
      out.write_string(GAP)
      out.write_string(help_text)
    }
    out.write_char('\n')
  }
  strip_trailing_nl(out.to_string())
}

///|
fn command_head(c : @kuu.HelpCommand) -> String {
  if c.aliases.length() == 0 {
    c.name
  } else {
    c.name + " (" + join_strings(c.aliases, ", ") + ")"
  }
}

///|
fn command_help_text(c : @kuu.HelpCommand, ctx : RenderCtx) -> String {
  let base = match c.help {
    Some(h) => interpolate_bindings(h, ctx.bindings)
    None => ""
  }
  if c.deprecated {
    if base.length() == 0 {
      "[deprecated]"
    } else {
      "[deprecated] " + base
    }
  } else {
    base
  }
}

///|
/// Options: セクション。DR-115 §4 (グループ hidden) + §5.3 (origin_style separate_section で
/// inherited を独立見出しへ)。
fn section_options(ctx : RenderCtx) -> String {
  // 1. entry を「表示可否」フィルタ (hidden group 所属を丸ごと除去、entry hidden は show_hidden で)。
  // 2. origin_style="separate_section" のとき、local 系と inheritable/global 系に分割。
  // 3. group 見出し + 所属 option を出力 (model は宣言順、hidden group は入口注記 1 行)。
  let all_entries = filter_visible_options(ctx)
  if all_entries.length() == 0 {
    return ""
  }
  let (local_entries, inherited_entries) = split_by_origin(all_entries, ctx.style.origin_style)
  let out = StringBuilder::new()
  if local_entries.length() > 0 {
    out.write_string(render_option_block(SEC_OPTIONS, local_entries, ctx))
  }
  if inherited_entries.length() > 0 {
    if out.to_string().length() > 0 {
      out.write_char('\n')
      out.write_char('\n')
    }
    out.write_string(render_option_block(SEC_INHERITED_OPTIONS, inherited_entries, ctx))
  }
  // origin_style="reference" のときは案内文だけ出す (詳細列挙は omit)。
  if ctx.style.origin_style == "reference" && any_inherited(all_entries) {
    if out.to_string().length() > 0 {
      out.write_char('\n')
      out.write_char('\n')
    }
    out.write_string("  (use `--help --category-mode all` to view inherited options)")
  }
  out.to_string()
}

///|
/// hidden group 所属 entry の除去 + entry hidden の show_hidden 判定。入口注記 sentinel entry を
/// group 位置に残す (Group entry として保持、レンダラ側で注記描画)。
fn filter_visible_options(ctx : RenderCtx) -> Array[@kuu.HelpOptionEntry] {
  // DR-115 §4 category_mode 分岐:
  //   Default → hidden group を入口注記化 (所属 entry 全省略)
  //   All     → hidden group も所属 entry 込みで表示
  //   Named(n)→ 名指しは明示要求なので表示 (all と同じ扱い、entry 側フィルタは model が済ませている)
  let expand_hidden_groups = match ctx.opts.category_mode {
    @kuu.Default => false
    @kuu.All => true
    @kuu.Named(_) => true
  }
  // まず hidden group 名の集合を作る (expand=true なら空集合 = 全 entry 表示)。
  let hidden_groups : Map[String, Bool] = Map([])
  if !expand_hidden_groups {
    for e in ctx.model.options {
      match e {
        @kuu.Group(g) => if g.hidden { hidden_groups.set(g.name, true) }
        _ => ()
      }
    }
  }
  let out : Array[@kuu.HelpOptionEntry] = []
  for e in ctx.model.options {
    match e {
      @kuu.Group(g) => out.push(@kuu.Group(g))
      @kuu.Option(o) => {
        // hidden group 所属 entry は entry hidden を問わず全省略 (DR-115 §4 「hidden group ×
        // hidden entry の交差」規則: group hidden が優先、show_hidden は entry 軸のみ)。
        let in_hidden_group = match o.help_group_name {
          Some(name) => hidden_groups.get(name).unwrap_or(false)
          None => false
        }
        if in_hidden_group {
          continue
        }
        if o.hidden && !ctx.opts.show_hidden {
          continue
        }
        out.push(@kuu.Option(o))
      }
    }
  }
  out
}

///|
/// origin_style="separate_section" のとき local / inherited に分割 (§5.3)。他 style は全部
/// local 側に集約 (merge / omit / reference は続く render_option_block で自明扱い)。
fn split_by_origin(
  entries : Array[@kuu.HelpOptionEntry],
  style : String,
) -> (Array[@kuu.HelpOptionEntry], Array[@kuu.HelpOptionEntry]) {
  if style != "separate_section" {
    // reference / omit は inherited を出さない、merge は inherited も local 側で混ぜる。
    if style == "omit" || style == "reference" {
      // inherited entry を除去。ただし所属 group 見出しは残す判定が難しいので group もそのまま。
      let filtered : Array[@kuu.HelpOptionEntry] = []
      for e in entries {
        match e {
          @kuu.Option(o) => if !is_inherited_origin(o.origin) { filtered.push(@kuu.Option(o)) }
          @kuu.Group(_) => filtered.push(e)
        }
      }
      return (filtered, [])
    }
    return (entries, [])
  }
  // separate_section: inherited を後段へ振り分ける。group 見出しは前段 (local) にのみ残す
  // (canonical の gh 型: INHERITED FLAGS 側は group 分けせずフラット列挙する慣習)。
  let locals : Array[@kuu.HelpOptionEntry] = []
  let inherited : Array[@kuu.HelpOptionEntry] = []
  for e in entries {
    match e {
      @kuu.Group(_) => locals.push(e)
      @kuu.Option(o) =>
        if is_inherited_origin(o.origin) {
          inherited.push(@kuu.Option(o))
        } else {
          locals.push(@kuu.Option(o))
        }
    }
  }
  (locals, inherited)
}

///|
fn is_inherited_origin(o : @kuu.HelpOrigin) -> Bool {
  match o {
    @kuu.Local => false
    @kuu.Global(_) => true
    @kuu.Inheritable(_) => true
  }
}

///|
fn any_inherited(entries : Array[@kuu.HelpOptionEntry]) -> Bool {
  for e in entries {
    match e {
      @kuu.Option(o) => if is_inherited_origin(o.origin) { return true }
      _ => ()
    }
  }
  false
}

///|
/// 「見出し + entry 群」の 1 ブロックを組む。group 宣言 entry (hidden 含む) は所属境界の
/// 見出しとして扱い、その後の Option entry を列挙する。
fn render_option_block(
  header : String,
  entries : Array[@kuu.HelpOptionEntry],
  ctx : RenderCtx,
) -> String {
  let out = StringBuilder::new()
  out.write_string(header)
  out.write_char('\n')
  // 列幅: 全 option entry (grouping 横断) の head 長さで揃える。
  let mut w = 0
  for e in entries {
    match e {
      @kuu.Option(o) => {
        let l = option_head(o, ctx).length()
        if l > w {
          w = l
        }
      }
      _ => ()
    }
  }
  // model は「group 宣言」と「option entry」が同じ配列にフラットに並ぶ形 (DR-113 §8.1)。
  // canonical レンダラは group 単位でまとめる — group 宣言に出会うたびに、その group に属する
  // 全 option を後続の配列からピックアップして出す。group_name の一致しない option は「無所属」
  // 扱いで、末尾の暗黙 default 見出し (見出し文言なし = 直接列挙) に落ちる。
  // 順序: model の group 宣言順 → 各 group の option は宣言順を保つ → 最後に無所属 option。
  let grouped = collect_by_group(entries)
  let mut first_entry = true
  for e in grouped {
    match e {
      @kuu.Group(g) => {
        // DR-115 §4: default = 入口注記のみ、all/named = 通常見出し (所属 entry 込みで表示)。
        let notice_only = g.hidden &&
          (match ctx.opts.category_mode {
            @kuu.Default => true
            _ => false
          })
        if notice_only {
          if !first_entry {
            out.write_char('\n')
          }
          out.write_string(HIDDEN_GROUP_NOTE_PREFIX)
          out.write_string(g.name)
          out.write_string(HIDDEN_GROUP_NOTE_SUFFIX)
          out.write_char('\n')
          first_entry = false
        } else {
          // 見える group: title (or name) 見出し (subheader 位置、canonical は空行 + 見出し 1 行)。
          if !first_entry {
            out.write_char('\n')
          }
          let title = g.title.unwrap_or(g.name)
          out.write_string(INDENT)
          out.write_string(title)
          if g.description is Some(d) {
            out.write_char('\n')
            out.write_string(INDENT)
            out.write_string(interpolate_bindings(d, ctx.bindings))
          }
          out.write_char('\n')
          first_entry = false
        }
      }
      @kuu.Option(o) => {
        out.write_string(render_option_row(o, w, ctx))
        first_entry = false
      }
    }
  }
  strip_trailing_nl(out.to_string())
}

///|
/// フラットな entry 列を「group 宣言 → 所属 option 列 → group 宣言 → …」の順に再整列する。
/// model 内の group 宣言順を保ち、各 group の option は宣言順 (=model の元順) を保つ。
/// help_group_name が空 or 未宣言 group を指す option は無所属扱いで、grouped 末尾に置く。
fn collect_by_group(
  entries : Array[@kuu.HelpOptionEntry],
) -> Array[@kuu.HelpOptionEntry] {
  // group name → 宣言順 index の map を組む (0 は無所属バケット用に予約したいので +1 する)。
  let group_order : Map[String, Int] = Map([])
  let group_decls : Array[@kuu.HelpOptionEntry] = []
  for e in entries {
    match e {
      @kuu.Group(g) => {
        if !group_order.contains(g.name) {
          group_order.set(g.name, group_decls.length())
          group_decls.push(@kuu.Group(g))
        }
      }
      _ => ()
    }
  }
  // 各 group のバケット + 無所属バケット。
  let n_groups = group_decls.length()
  let buckets : Array[Array[@kuu.HelpOption]] = []
  for _i in 0..<(n_groups + 1) {
    buckets.push([])
  }
  for e in entries {
    match e {
      @kuu.Option(o) => {
        let bi = match o.help_group_name {
          Some(name) =>
            match group_order.get(name) {
              Some(idx) => idx
              None => n_groups // 未宣言 group 参照 = 無所属
            }
          None => n_groups
        }
        buckets[bi].push(o)
      }
      _ => ()
    }
  }
  // 再整列: 各 group 宣言 + そのバケット → 最後に無所属バケット (見出しなし)。
  let out : Array[@kuu.HelpOptionEntry] = []
  let mut i = 0
  while i < n_groups {
    out.push(group_decls[i])
    for o in buckets[i] {
      out.push(@kuu.Option(o))
    }
    i = i + 1
  }
  for o in buckets[n_groups] {
    out.push(@kuu.Option(o))
  }
  out
}

///|
/// option 1 entry を 1 行 (or 折返し数行) にレンダリング。
fn render_option_row(o : @kuu.HelpOption, w : Int, ctx : RenderCtx) -> String {
  let out = StringBuilder::new()
  out.write_string(INDENT)
  let head = option_head(o, ctx)
  out.write_string(head)
  // help + 付加 marker (default / env / required / multiple / deprecated) を組む。
  let help_text = option_help_text(o, ctx)
  if help_text.length() > 0 {
    let pad_n = w - head.length()
    let mut p = 0
    while p < pad_n {
      out.write_char(' ')
      p = p + 1
    }
    out.write_string(GAP)
    out.write_string(help_text)
  }
  out.write_char('\n')
  // value_structure_style=detail のとき、value tree の枝を追加行で列挙。
  let vs_style = effective_option_vs_style(o, ctx)
  if vs_style == "detail" {
    match o.value_structure {
      Some(vs) => {
        for line in value_structure_detail_lines(vs) {
          out.write_string(HANG)
          out.write_string(line)
          out.write_char('\n')
        }
      }
      None => ()
    }
  }
  out.to_string()
}

///|
/// option の実効 value_structure_style (entry 個別席 > 一括席、§1)。
fn effective_option_vs_style(o : @kuu.HelpOption, ctx : RenderCtx) -> String {
  match o.value_structure_style {
    Some(v) => v
    None => ctx.style.value_structure_style
  }
}

///|
/// option の「頭」 (`--flag, --short <VAL>`)。types_style=aggregate の共有型は value_name 短縮
/// (`{types}` 側で詳細)。
fn option_head(o : @kuu.HelpOption, ctx : RenderCtx) -> String {
  let out = StringBuilder::new()
  let mut first = true
  for s in o.spellings {
    if !first {
      out.write_string(", ")
    }
    out.write_string(s)
    first = false
  }
  for s in o.alias_spellings {
    out.write_string(", ")
    out.write_string(s)
  }
  match o.value_structure {
    Some(vs) => {
      // value 部の表記は inline (option head 位置は 1 行制約)。detail 展開は下段。
      let s = value_structure_inline_aware(
        vs,
        effective_option_vs_style(o, ctx),
        ctx.style.types_style,
        ctx.model,
      )
      if s.length() > 0 {
        out.write_char(' ')
        out.write_string(s)
      }
    }
    None => ()
  }
  out.to_string()
}

///|
/// option の help 本文 + 付加情報 (default / env / required / multiple / deprecated)。canonical
/// は「[deprecated] help本文 [default: X] [env: NAME] (required)」の順。
fn option_help_text(o : @kuu.HelpOption, ctx : RenderCtx) -> String {
  let parts : Array[String] = []
  if o.deprecated {
    parts.push("[deprecated]")
  }
  match o.help {
    Some(h) => parts.push(interpolate_bindings(h, ctx.bindings))
    None => ()
  }
  match o.default {
    Some(d) => parts.push("[default: " + render_default(d) + "]")
    None => ()
  }
  if o.env.length() > 0 {
    parts.push("[env: " + join_strings(o.env, ", ") + "]")
  }
  if o.required {
    parts.push("(required)")
  }
  if o.multiple {
    parts.push("(repeatable)")
  }
  join_strings(parts, " ")
}

///|
fn render_default(d : @kuu.HelpDefault) -> String {
  match d {
    @kuu.Scalar(v) => value_to_str(v)
    @kuu.Array(xs) => {
      let parts : Array[String] = []
      for v in xs {
        parts.push(value_to_str(v))
      }
      "[" + join_strings(parts, ", ") + "]"
    }
  }
}

///|
fn value_to_str(v : @engine.Value) -> String {
  match v {
    @engine.String(s) => s
    @engine.Bool(true) => "true"
    @engine.Bool(false) => "false"
    @engine.Number(d) => d.to_string()
  }
}

///|
/// Arguments: セクション (positional)。canonical は value_structure を左に、help を右に。
fn section_positionals(ctx : RenderCtx) -> String {
  let ps : Array[@kuu.HelpPositional] = []
  for p in ctx.model.positionals {
    if p.hidden && !ctx.opts.show_hidden {
      continue
    }
    ps.push(p)
  }
  if ps.length() == 0 {
    return ""
  }
  let out = StringBuilder::new()
  out.write_string(SEC_POSITIONALS)
  out.write_char('\n')
  let mut w = 0
  for p in ps {
    let head = value_structure_inline_aware(
      p.value_structure,
      p.value_structure_style.unwrap_or(ctx.style.value_structure_style),
      ctx.style.types_style,
      ctx.model,
    )
    if head.length() > w {
      w = head.length()
    }
  }
  for p in ps {
    out.write_string(INDENT)
    let head = value_structure_inline_aware(
      p.value_structure,
      p.value_structure_style.unwrap_or(ctx.style.value_structure_style),
      ctx.style.types_style,
      ctx.model,
    )
    out.write_string(head)
    let help_text = positional_help_text(p, ctx)
    if help_text.length() > 0 {
      let pad_n = w - head.length()
      let mut i = 0
      while i < pad_n {
        out.write_char(' ')
        i = i + 1
      }
      out.write_string(GAP)
      out.write_string(help_text)
    }
    out.write_char('\n')
  }
  strip_trailing_nl(out.to_string())
}

///|
fn positional_help_text(p : @kuu.HelpPositional, ctx : RenderCtx) -> String {
  let parts : Array[String] = []
  if p.deprecated {
    parts.push("[deprecated]")
  }
  match p.help {
    Some(h) => parts.push(interpolate_bindings(h, ctx.bindings))
    None => ()
  }
  join_strings(parts, " ")
}

///|
/// Types: セクション (§5.2 aggregate)。canonical: types_style=auto かつ used_as.length >= 2 の
/// 共有型を集約 (aggregate 強制も含む)。inline 強制 or 未使用型は emit しない。
fn section_types(ctx : RenderCtx) -> String {
  if ctx.style.types_style == "inline" {
    return ""
  }
  let show : Array[@kuu.HelpTypeEntry] = []
  for t in ctx.model.types {
    if ctx.style.types_style == "aggregate" || t.used_as.length() >= 2 {
      show.push(t)
    }
  }
  if show.length() == 0 {
    return ""
  }
  let out = StringBuilder::new()
  out.write_string(SEC_TYPES)
  out.write_char('\n')
  for t in show {
    out.write_string(INDENT)
    out.write_string(t.id)
    out.write_string(" = ")
    out.write_string(value_structure_inline(t.value_structure))
    out.write_char('\n')
    match t.help {
      Some(h) => {
        out.write_string(HANG)
        out.write_string(interpolate_bindings(h, ctx.bindings))
        out.write_char('\n')
      }
      None => ()
    }
    if t.used_as.length() > 0 {
      out.write_string(HANG)
      out.write_string("used as: ")
      out.write_string(join_strings(t.used_as, ", "))
      out.write_char('\n')
    }
  }
  strip_trailing_nl(out.to_string())
}

// ═════════════════════════════════════════════════════════════════════════════
// value_structure rendering (§5.1)
// ═════════════════════════════════════════════════════════════════════════════

///|
/// types_style を意識した inline 表記。aggregate モード (or auto かつ共有型) の type_ref は
/// value_name 短縮 (`<COLOR>`)、inline モード or 未共有は展開 (`<COLOR_NAME | <R G B>>`)。
fn value_structure_inline_aware(
  vs : @engine.HelpValueStructure,
  vs_style : String,
  types_style : String,
  model : @kuu.HelpModel,
) -> String {
  // vs_style=detail は上位 (render_option_row) で追加行に落とすが、head 位置には inline 表記を
  // 出す (head は 1 行制約)。auto/inline はここで inline を返す。
  ignore(vs_style)
  match vs {
    @engine.TypeRef(ref_) => {
      let aggregate = if types_style == "inline" {
        false
      } else if types_style == "aggregate" {
        true
      } else {
        // auto: 参照 >= 2 で集約
        type_ref_count(model, ref_.id) >= 2
      }
      if aggregate {
        match ref_.value_name {
          Some(vn) => "<" + vn + ">"
          None => "<" + ref_.id + ">"
        }
      } else {
        // inline 展開: 参照先の value_structure を substitute
        match find_type(model, ref_.id) {
          Some(t) => value_structure_inline_aware(t.value_structure, vs_style, types_style, model)
          None =>
            match ref_.value_name {
              Some(vn) => "<" + vn + ">"
              None => "<" + ref_.id + ">"
            }
        }
      }
    }
    _ => value_structure_inline(vs)
  }
}

///|
/// value_structure の 1 行表記 (types_style 非考慮の base 実装)。
fn value_structure_inline(vs : @engine.HelpValueStructure) -> String {
  match vs {
    @engine.Single(sv) => {
      let vn = sv.value_name.unwrap_or("VALUE")
      "<" + vn + ">"
    }
    @engine.Seq(nodes) => {
      let parts : Array[String] = []
      for n in nodes {
        parts.push(value_structure_inline(n))
      }
      join_strings(parts, " ")
    }
    @engine.Or(nodes) => {
      let parts : Array[String] = []
      for n in nodes {
        parts.push(value_structure_inline(n))
      }
      "<" + join_strings(parts, " | ") + ">"
    }
    @engine.Repeat(spec) => render_repeat(spec)
    @engine.TypeRef(ref_) => {
      let vn = ref_.value_name.unwrap_or(ref_.id)
      "<" + vn + ">"
    }
  }
}

///|
/// Repeat の表記 (**暫定採用 2026-07-21 kawaz、根決定でない**、RIMPL-Q5)。
///
/// 現行規則:
///   - optional 単発: `[FILE]` / required 単発: `<FILE>` (外側ブラケットが min の 0/1 境界を担う)
///   - 上限なし: min 回 unroll + `...`
///       min0 = `[FILE]...` / min1 = `<FILE>...` / min2 = `<FILE> <FILE>...`
///   - 有限上限: `{..n}` / `{m..n}` を**内側**に内包
///       0..3 = `[FILE{..3}]` / 1..3 = `<FILE{..3}>` (外側 <> が min1 を語るので 1 省略)
///       2..5 = `<FILE{2..5}>` (min≥2 の有限上限は unroll せず range 内包一発)
///   - 冗長な数字は省略 (0..n / 1..n は内側から min を落とす)
///
/// 内側 node が Single 以外 (Or / Seq / TypeRef ネスト) は現状 fixture に corpus 無し。
/// 安全に fallback (旧: `inner + {m..n}` 外付け) で受ける — 表記確定時に見直す (kawaz 裁定待ち)。
fn render_repeat(spec : @engine.HelpRepeatSpec) -> String {
  let min_v = spec.min.unwrap_or(0)
  // core name: Single の value_name (or "VALUE")。Single 以外は fallback へ。
  match spec.node {
    @engine.Single(sv) => {
      let vn = sv.value_name.unwrap_or("VALUE")
      render_repeat_with_core(vn, min_v, spec.max)
    }
    _ => {
      // fallback: 外付け suffix (旧表記)
      let inner = value_structure_inline(spec.node)
      inner + fallback_repeat_suffix(min_v, spec.max)
    }
  }
}

///|
/// core value name (裸文字、ブラケットなし) を受け、min / max から新表記を組む。
fn render_repeat_with_core(vn : String, min_v : Int, max : Int?) -> String {
  match max {
    None =>
      // 上限なし: min 回 unroll + `...`
      if min_v <= 0 {
        "[" + vn + "]..."
      } else {
        let out = StringBuilder::new()
        let mut i = 0
        while i < min_v {
          if i > 0 {
            out.write_char(' ')
          }
          out.write_char('<')
          out.write_string(vn)
          out.write_char('>')
          i = i + 1
        }
        out.write_string("...")
        out.to_string()
      }
    Some(ma) =>
      // 有限上限: 内側 `{..n}` / `{m..n}` を内包
      if min_v <= 0 {
        "[" + vn + "{.." + ma.to_string() + "}]"
      } else if min_v == 1 {
        "<" + vn + "{.." + ma.to_string() + "}>"
      } else {
        "<" + vn + "{" + min_v.to_string() + ".." + ma.to_string() + "}>"
      }
  }
}

///|
/// Single 以外 (複合 node) を Repeat で包む場合の fallback suffix。新表記の内包規則を Single
/// 以外へ広げる corpus が無いので旧表記 (外付け `{m..n}` / `...`) で保持する — kawaz 裁定待ち。
fn fallback_repeat_suffix(min_v : Int, max : Int?) -> String {
  match max {
    None => if min_v <= 1 { "..." } else { "{" + min_v.to_string() + "..}" }
    Some(ma) => "{" + min_v.to_string() + ".." + ma.to_string() + "}"
  }
}

///|
/// value_structure_style="detail" 時に option 行の下に追加する枝説明行。
fn value_structure_detail_lines(vs : @engine.HelpValueStructure) -> Array[String] {
  let out : Array[String] = []
  match vs {
    @engine.Or(nodes) => {
      for n in nodes {
        out.push(value_structure_inline(n))
      }
    }
    @engine.Seq(nodes) => {
      for n in nodes {
        out.push(value_structure_inline(n))
      }
    }
    _ => out.push(value_structure_inline(vs))
  }
  out
}

///|
fn type_ref_count(model : @kuu.HelpModel, id : String) -> Int {
  for t in model.types {
    if t.id == id {
      return t.used_as.length()
    }
  }
  0
}

///|
fn find_type(model : @kuu.HelpModel, id : String) -> @kuu.HelpTypeEntry? {
  for t in model.types {
    if t.id == id {
      return Some(t)
    }
  }
  None
}

// ═════════════════════════════════════════════════════════════════════════════
// binding interpolation (§3)
// ═════════════════════════════════════════════════════════════════════════════

///|
/// 文言位置の binding 補間 (§3): `{ident}` → binding 値、`{{` → literal `{`。ident 規則に
/// 合わない brace 列は literal 素通し (寛容モード、§3 の「文言位置寛容」)。
fn interpolate_bindings(s : String, bindings : Map[String, String]) -> String {
  brace_scan(s.to_array(), fn(ident) {
    match bindings.get(ident) {
      Some(v) => v
      None => "{" + ident + "}" // §3: 未解決 binding は literal
    }
  })
}

// ═════════════════════════════════════════════════════════════════════════════
// tiny helpers
// ═════════════════════════════════════════════════════════════════════════════

///|
fn join_strings(xs : Array[String], sep : String) -> String {
  let out = StringBuilder::new()
  let mut first = true
  for x in xs {
    if !first {
      out.write_string(sep)
    }
    out.write_string(x)
    first = false
  }
  out.to_string()
}

///|
fn strip_trailing_nl(s : String) -> String {
  let chars = s.to_array()
  let n = chars.length()
  if n > 0 && chars[n - 1] == '\n' {
    chars_to_string(chars, 0, n - 1)
  } else {
    s
  }
}

///|
fn[T] ignore(_x : T) -> Unit {
  ()
}
