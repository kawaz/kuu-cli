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
/// `kuu parse <def.json> -- <args...>`。<def.json> の後ろの `--` は POSIX-ish な明示区切りだが
/// PoC では optional (先頭の lone `--` を 1 つだけ skip、残り全部を parse target 扱い)。
fn run_parse(args : Array[String]) -> @lib.CmdResult {
  if args.length() == 0 {
    usage_die("kuu parse: missing <def.json>", "kuu parse <def.json> [--] <args...>")
  }
  let def_path = args[0]
  let def_text = match read_file_all(def_path) {
    Ok(s) => s
    Err(msg) => usage_die("kuu parse: " + msg, "kuu parse <def.json> [--] <args...>")
  }
  let parse_args : Array[String] = []
  let mut i = 1
  if i < args.length() && args[i] == "--" {
    i = i + 1
  }
  while i < args.length() {
    parse_args.push(args[i])
    i = i + 1
  }
  @lib.cmd_parse(def_text, parse_args)
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
    #|  kuu parse    <def.json> [--] <args...>
    #|  kuu complete <def.json> --args-before <json-array> [--args-after <json-array>]
    #|  kuu validate <def.json>
    #|  kuu help
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
