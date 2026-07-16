// main.mbt — `kuu` CLI entry (subcommand dispatch).
//
// 3 subcommands (kuu-cli DR-0001 §3 で確定させる CLI 入出力契約の輪郭を先に固めるため):
//
//   kuu parse    <def.json> -- <args...>
//   kuu complete <def.json> --args-before <json-array> [--args-after <json-array>]
//   kuu validate <def.json>
//
// 入出力の形は `../lib/wire.mbt` の頭部コメントを参照。CLI 引数解析は手書き (kawaz の CLI 設計
// 好み [cli-design-preferences] に沿った将来設計は kuu 自身での dogfooding 後に決める; PoC は
// 卵と鶏の dogfooding を避け最小手書きに留める)。
//
// 【stdout / stderr 分離】 (codex #1 M-5、統括裁定 2026-07-16):
//
//   - **stdout**: machine 消費される単一 JSON object (parse / complete / validate の CmdResult 直列化)
//     + `kuu help` の明示要求 (ユーザが受け取りたい情報、GNU coreutils 慣習)
//   - **stderr**: human-oriented text (usage 表示、unknown subcommand、余剰引数エラー、
//     子 subcommand の引数不足)。machine には食わせない前提
//
// 引数なし / unknown subcommand / 子 subcommand の引数不足 は **stderr に usage + exit 2**
// (kawaz の CLI 好み [cli-design-preferences] 「引数なし実行 = usage 表示」を stdout/stderr 分離
// と両立させる形)。`-h` short alias は明示指示なしに追加しない (m-4)。

///|
/// libc `exit(3)`. `moonbitlang/core/env` の pub API に process 終了コード制御が無いため
/// FFI で直接束縛する (kawaz/kuu-cli-mbt は native target 専用、DR-0001 §3 の PoC に必要な
/// 最小限の platform binding)。
extern "c" fn c_exit(code : Int) = "exit"

///|
/// libc `write(2)`。stderr (fd=2) への human-text 出力に使う (M-5: stdout は machine JSON
/// only、human text は stderr、codex レビュー #1 の統括裁定 2026-07-16)。MoonBit の core は
/// `println` (stdout only) しか提供しないので FFI で fd 指定の低レベル write を束縛する
/// — 出力量が小さい (usage 数行) ので buffer 分割の心配は不要 (単一 `write(2)` で足りる)。
/// `#borrow(buf)` は MoonBit の FFI calling convention 明示 (pointer 型は #borrow か #owned
/// が要求される、core/env の `get_env_var_ffi` と同型)。
#borrow(buf)
extern "c" fn c_write(fd : Int, buf : Bytes, len : Int) -> Int = "write"

///|
/// `c_exit` を `T` 型として返せるようにする wrapper (never returns)。match arm や
/// let bind から型を揃えて呼べる。
fn[T] die(code : Int) -> T {
  c_exit(code)
  panic()
}

///|
/// `s` を UTF-8 encode して stderr (fd=2) に書き出す (末尾改行付き)。標準 `println` の
/// stderr 相当 — machine JSON と human text の stdout/stderr 分離のための唯一の primitive。
/// `String::to_bytes` は UTF-16LE を返すので使わない (deprecated かつ非 UTF-8)。
fn eprintln(s : String) -> Unit {
  let bytes = @utf8.encode(s + "\n")
  let _ = c_write(2, bytes, bytes.length())

}

///|
fn main {
  let argv = @env.args()
  let args : Array[String] = []
  for i in 1..<argv.length() {
    args.push(argv[i])
  }
  if args.length() == 0 {
    print_usage_stderr()
    die(2)
  }
  let sub = args[0]
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  let result : @lib.CmdResult = match sub {
    "parse" => run_parse(rest)
    "complete" => run_complete(rest)
    "validate" => run_validate(rest)
    "help" | "--help" => {
      // 明示的な help 要求 → stdout (ユーザが読みたい情報、GNU coreutils 慣習)、exit 0
      println(usage_text())
      return
    }
    _ => {
      eprintln("kuu: unknown subcommand '" + sub + "'")
      print_usage_stderr()
      die(2)
    }
  }
  println(result.json)
  if result.exit != 0 {
    c_exit(result.exit)
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// subcommand runners — parse CLI args → call into @lib
// ═════════════════════════════════════════════════════════════════════════════

///|
/// libc `isatty(3)`。tty 観測の実環境既定取得 (DR-109 §6) に使う。fd: 0=stdin, 1=stdout,
/// 2=stderr。返値 1 = terminal。
extern "c" fn c_isatty(fd : Int) -> Int = "isatty"

///|
/// parse subcommand の usage (エラー時 stderr 表示の共通素材)。
const PARSE_USAGE : String = "kuu parse <def.json> [--no-env] [--no-config] [--env k=v]... [--config <json|file>] [--tty <json>] [--] <args...>"

///|
/// `kuu parse <def.json> [options] [--] <args...>`。<def.json> の後ろの `--` は POSIX-ish な
/// 明示区切りだが PoC では optional (lone `--` を 1 つだけ skip、残り全部を parse target 扱い)。
///
/// 【env / config / tty の取得契約】 (spec DR-109 §6): kuu-cli はテストツールではなく、アプリ内
/// kuu と同一挙動が本義 — **既定 = 実環境の取得** (env は実環境変数、tty は isatty(3) 観測。
/// config は definition の config_file 宣言が実ファイルパスを解決する形なので、既定では
/// 供給関数なし = 実ファイル読みは将来実装、現状は config_file 未宣言 definition で差が出ない)。
/// その上で試験用の固定・注入オプションを持つ:
///   --no-env           実環境変数を無視する (注入 --env のみが env 面に残る)
///   --env k=v          env に k=v を注入 (繰返し可、実環境より優先 = 上書き)
///   --no-config        config 供給を空に固定する
///   --config <json|file>  config オブジェクトを JSON 文字列 or ファイルパスで注入
///   --tty <json>       tty 観測を固定 (例: '{"stdout":{"terminal":true,"cygwin":false}}')。
///                      未指定は isatty(3) の実観測 (cygwin は false — MSYS/Cygwin 検出は将来)
fn run_parse(args : Array[String]) -> @lib.CmdResult {
  if args.length() == 0 {
    usage_die("kuu parse: missing <def.json>", PARSE_USAGE)
  }
  let def_path = args[0]
  let def_text = match read_file_all(def_path) {
    Ok(s) => s
    Err(msg) => usage_die("kuu parse: " + msg, PARSE_USAGE)
  }
  // オプションと parse target を分離する。オプションは <def.json> の後・`--` の前のみ有効
  // ([cli-design-preferences] の「メイン引数の後ろにもオプションを置ける」は、ここでは target
  // args との曖昧衝突を `--` セパレータで解く形で満たす)。
  let mut no_env = false
  let mut no_config = false
  let env_overrides : Array[(String, String)] = []
  let mut config_text : String? = None
  let mut tty_text : String? = None
  let parse_args : Array[String] = []
  let mut i = 1
  let mut seen_dd = false
  while i < args.length() {
    let a = args[i]
    if seen_dd {
      parse_args.push(a)
      i = i + 1
      continue
    }
    if a == "--" {
      seen_dd = true
      i = i + 1
    } else if a == "--no-env" {
      no_env = true
      i = i + 1
    } else if a == "--no-config" {
      no_config = true
      i = i + 1
    } else if a == "--env" && i + 1 < args.length() {
      let kv = args[i + 1]
      match split_once(kv, '=') {
        Some(pair) => env_overrides.push(pair)
        None => usage_die("kuu parse: --env expects k=v, got '" + kv + "'", PARSE_USAGE)
      }
      i = i + 2
    } else if a == "--config" && i + 1 < args.length() {
      config_text = Some(args[i + 1])
      i = i + 2
    } else if a == "--tty" && i + 1 < args.length() {
      tty_text = Some(args[i + 1])
      i = i + 2
    } else {
      // オプションでも `--` でもない = parse target の先頭 (以降は全て target)
      parse_args.push(a)
      seen_dd = true
      i = i + 1
    }
  }

  // env 面: 実環境既定 (DR-109 §6) → --no-env で空に → --env k=v を上書き注入。
  let env : Map[String, String] = if no_env { Map([]) } else { @env.get_env_vars() }
  for kv in env_overrides {
    env.set(kv.0, kv.1)
  }

  // config 面: --config 注入 (JSON 文字列 or ファイルパス) > --no-config > 既定 (供給なし)。
  // 既定の「実 config ファイル読み」は definition の config_file 宣言がパスを解決する形
  // (DR-050) なので、provider の既定は「パスを受けたらファイルを読んで config_from_json」。
  // --no-config はその実ファイル読みを塞ぐ。
  let config : (String) -> @core.ConfigVal? = if no_config {
    fn(_p) { None }
  } else {
    match config_text {
      Some(t) => {
        // JSON として parse できればそのまま、できなければファイルパスとして読む
        let j = @json.parse(t) catch {
          _ =>
            match read_file_all(t) {
              Ok(s) =>
                @json.parse(s) catch {
                  _ =>
                    usage_die(
                      "kuu parse: --config '" +
                      t +
                      "' is neither valid JSON nor a readable JSON file",
                      PARSE_USAGE,
                    )
                }
              Err(_) =>
                usage_die(
                  "kuu parse: --config '" +
                  t +
                  "' is neither valid JSON nor a readable JSON file",
                  PARSE_USAGE,
                )
            }
        }
        let cv = @core.config_from_json(j)
        fn(_p) { Some(cv) }
      }
      // 既定: definition が config_file でパスを解決してきたら実ファイルを読む
      // (アプリ内 kuu と同一挙動、DR-109 §6)。読めない / JSON でないパスは供給なし。
      None =>
        fn(p) {
          match read_file_all(p) {
            Ok(s) => {
              let j = @json.parse(s) catch { _ => return None }
              Some(@core.config_from_json(j))
            }
            Err(_) => None
          }
        }
    }
  }

  // tty 面: --tty 固定 > 既定 (isatty(3) 実観測、cygwin=false — MSYS/Cygwin 検出は将来)。
  let tty : Map[String, @core.TtyObs] = match tty_text {
    Some(t) => {
      let j = @json.parse(t) catch {
        _ => usage_die("kuu parse: --tty value is not valid JSON", PARSE_USAGE)
      }
      match tty_from_json(j) {
        Ok(m) => m
        Err(msg) => usage_die("kuu parse: --tty " + msg, PARSE_USAGE)
      }
    }
    None =>
      Map([
        ("stdin", @core.tty_obs(c_isatty(0) == 1, false)),
        ("stdout", @core.tty_obs(c_isatty(1) == 1, false)),
        ("stderr", @core.tty_obs(c_isatty(2) == 1, false)),
      ])
  }
  @lib.cmd_parse(def_text, parse_args, env~, config~, tty~)
}

///|
/// `--tty` の JSON (`{"stdout":{"terminal":bool,"cygwin":bool},...}`) を Map[String, TtyObs] に
/// decode する。fixture の `tty` 入力と同形 (DR-099 §4)。キー不在 = 提供なし、`cygwin` 省略 =
/// false。
fn tty_from_json(j : Json) -> Result[Map[String, @core.TtyObs], String] {
  match j {
    Object(o) => {
      let m : Map[String, @core.TtyObs] = Map([])
      for k, v in o {
        match v {
          Object(vo) => {
            let terminal = match vo.get("terminal") {
              Some(True) => true
              Some(False) => false
              _ => return Err("stream '" + k + "' needs boolean 'terminal'")
            }
            let cygwin = match vo.get("cygwin") {
              Some(True) => true
              Some(False) => false
              None => false
              _ => return Err("stream '" + k + "' has non-boolean 'cygwin'")
            }
            m.set(k, @core.tty_obs(terminal, cygwin))
          }
          _ => return Err("stream '" + k + "' value must be an object")
        }
      }
      Ok(m)
    }
    _ => Err("value must be a JSON object of streams")
  }
}

///|
/// `s` を最初の `sep` で 2 分割する。sep が無ければ None。
fn split_once(s : String, sep : Char) -> (String, String)? {
  let mut idx = -1
  let mut i = 0
  for c in s {
    if c == sep && idx < 0 {
      idx = i
    }
    i = i + 1
  }
  if idx < 0 {
    None
  } else {
    Some((s[0:idx].to_owned(), s[idx + 1:].to_owned()))
  }
}

///|
/// `kuu complete <def.json> --args-before <json-array> [--args-after <json-array>]`
fn run_complete(args : Array[String]) -> @lib.CmdResult {
  if args.length() == 0 {
    usage_die(
      "kuu complete: missing <def.json>",
      "kuu complete <def.json> --args-before <json-array> [--args-after <json-array>]",
    )
  }
  let def_path = args[0]
  let def_text = match read_file_all(def_path) {
    Ok(s) => s
    Err(msg) =>
      usage_die(
        "kuu complete: " + msg,
        "kuu complete <def.json> --args-before <json-array> [--args-after <json-array>]",
      )
  }
  let mut before_text : String = ""
  let mut after_text : String = ""
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    if a == "--args-before" && i + 1 < args.length() {
      before_text = args[i + 1]
      i = i + 2
    } else if a == "--args-after" && i + 1 < args.length() {
      after_text = args[i + 1]
      i = i + 2
    } else {
      usage_die(
        "kuu complete: unexpected arg '" + a + "'",
        "kuu complete <def.json> --args-before <json-array> [--args-after <json-array>]",
      )
    }
  }
  if before_text == "" {
    usage_die(
      "kuu complete: missing --args-before",
      "kuu complete <def.json> --args-before <json-array> [--args-after <json-array>]",
    )
  }
  let before = match parse_str_array(before_text) {
    Ok(xs) => xs
    Err(msg) =>
      usage_die(
        "kuu complete: --args-before " + msg,
        "kuu complete <def.json> --args-before <json-array> [--args-after <json-array>]",
      )
  }
  let after = if after_text == "" {
    []
  } else {
    match parse_str_array(after_text) {
      Ok(xs) => xs
      Err(msg) =>
        usage_die(
          "kuu complete: --args-after " + msg,
          "kuu complete <def.json> --args-before <json-array> [--args-after <json-array>]",
        )
    }
  }
  @lib.cmd_complete(def_text, before, after)
}

///|
/// `kuu validate <def.json>`。余剰引数 (2 番目以降の positional) は usage error (M-5、
/// codex #1、統括裁定 2026-07-16): 「validate は path 先頭だけ読み余剰引数を検査しない」
/// バグを潰す。
fn run_validate(args : Array[String]) -> @lib.CmdResult {
  if args.length() == 0 {
    usage_die("kuu validate: missing <def.json>", "kuu validate <def.json>")
  }
  if args.length() > 1 {
    usage_die(
      "kuu validate: unexpected extra arg '" + args[1] + "'",
      "kuu validate <def.json>",
    )
  }
  let def_text = match read_file_all(args[0]) {
    Ok(s) => s
    Err(msg) => usage_die("kuu validate: " + msg, "kuu validate <def.json>")
  }
  @lib.cmd_validate(def_text)
}

// ═════════════════════════════════════════════════════════════════════════════
// tiny helpers
// ═════════════════════════════════════════════════════════════════════════════

///|
/// Usage error は stderr にメッセージ + subcommand usage を書き、exit 2 で終了する。旧
/// `usage_err` は JSON envelope を stdout に返していたが、M-5 の「stdout=machine JSON only、
/// stderr=human text」規約に合わせて完全に stderr へ振る (統括裁定 2026-07-16)。返り値は `T`
/// (never return) — 呼び出し側の `let ... = match ... {} `arm から型を揃えて呼べる。
fn[T] usage_die(msg : String, sub_usage : String) -> T {
  eprintln(msg)
  eprintln("Usage: " + sub_usage)
  die(2)
}

///|
fn parse_str_array(s : String) -> Result[Array[String], String] {
  let j = @json.parse(s) catch { _ => return Err("value is not valid JSON") }
  match j {
    Array(items) => {
      let out : Array[String] = []
      for it in items {
        match it {
          String(x) => out.push(x)
          _ => return Err("array must contain only strings")
        }
      }
      Ok(out)
    }
    _ => Err("value is not a JSON array")
  }
}

///|
fn read_file_all(path : String) -> Result[String, String] {
  Ok(@fs.read_file_to_string(path)) catch {
    _ => Err("cannot read '" + path + "'")
  }
}

///|
/// Usage text (help 表示 / エラー時 usage の共通素材)。
fn usage_text() -> String {
  let text =
    #|kuu — parse / complete / validate against a kuu definition (JSON in, JSON out).
    #|
    #|Usage:
    #|  kuu parse    <def.json> [options] [--] <args...>
    #|  kuu complete <def.json> --args-before <json-array> [--args-after <json-array>]
    #|  kuu validate <def.json>
    #|  kuu help
    #|
    #|parse options (value-source control; default = the real environment, DR-109 §6):
    #|  --no-env             ignore real environment variables
    #|  --env k=v            inject/override an env var (repeatable)
    #|  --no-config          disable config-file reading
    #|  --config <json|file> supply the config object directly (JSON text or a JSON file path)
    #|  --tty <json>         pin tty observations, e.g. '{"stdout":{"terminal":true,"cygwin":false}}'
    #|
    #|Exit codes: 0=success, 1=parse/validate failure, 2=usage error.
    #|Output channels: machine JSON is on stdout; human text (usage / errors) is on stderr.
  text
}

///|
/// Usage を stderr に書き出す (引数なし / unknown subcommand の human 経路)。
fn print_usage_stderr() -> Unit {
  eprintln(usage_text())
}
