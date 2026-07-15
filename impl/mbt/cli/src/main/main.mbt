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

///|
/// libc `exit(3)`. `moonbitlang/core/env` の pub API に process 終了コード制御が無いため
/// FFI で直接束縛する (kawaz/kuu-cli-mbt は native target 専用、DR-0001 §3 の PoC に必要な
/// 最小限の platform binding)。
extern "c" fn c_exit(code : Int) = "exit"

///|
/// `c_exit` を `T` 型として返せるようにする wrapper (never returns)。match arm や
/// let bind から型を揃えて呼べる。
fn[T] die(code : Int) -> T {
  c_exit(code)
  panic()
}

///|
fn main {
  let argv = @env.args()
  let args : Array[String] = []
  for i in 1..<argv.length() {
    args.push(argv[i])
  }
  if args.length() == 0 {
    print_usage()
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
    "help" | "--help" | "-h" => {
      print_usage()
      return
    }
    _ => {
      println("kuu: unknown subcommand '" + sub + "'")
      print_usage()
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
/// `kuu parse <def.json> -- <args...>`
fn run_parse(args : Array[String]) -> @lib.CmdResult {
  if args.length() == 0 {
    return usage_err("kuu parse: missing <def.json>")
  }
  let def_path = args[0]
  let def_text = match read_file_all(def_path) {
    Ok(s) => s
    Err(msg) => return usage_err("kuu parse: " + msg)
  }
  // The `--` separator between <def.json> and <args...> is required for POSIX-ish clarity but
  // optional in this PoC: everything after args[1] (skipping a lone "--") is the parse target.
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
    return usage_err("kuu complete: missing <def.json>")
  }
  let def_path = args[0]
  let def_text = match read_file_all(def_path) {
    Ok(s) => s
    Err(msg) => return usage_err("kuu complete: " + msg)
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
      return usage_err("kuu complete: unexpected arg '" + a + "'")
    }
  }
  if before_text == "" {
    return usage_err("kuu complete: missing --args-before")
  }
  let before = match parse_str_array(before_text) {
    Ok(xs) => xs
    Err(msg) => return usage_err("kuu complete: --args-before " + msg)
  }
  let after = if after_text == "" {
    []
  } else {
    match parse_str_array(after_text) {
      Ok(xs) => xs
      Err(msg) => return usage_err("kuu complete: --args-after " + msg)
    }
  }
  @lib.cmd_complete(def_text, before, after)
}

///|
/// `kuu validate <def.json>`
fn run_validate(args : Array[String]) -> @lib.CmdResult {
  if args.length() == 0 {
    return usage_err("kuu validate: missing <def.json>")
  }
  let def_text = match read_file_all(args[0]) {
    Ok(s) => s
    Err(msg) => return usage_err("kuu validate: " + msg)
  }
  @lib.cmd_validate(def_text)
}

// ═════════════════════════════════════════════════════════════════════════════
// tiny helpers
// ═════════════════════════════════════════════════════════════════════════════

///|
fn usage_err(msg : String) -> @lib.CmdResult {
  let obj = Json::object({
    "ok": Json::boolean(false),
    "errors": Json::array([
      Json::object({
        "kind": Json::string("usage"),
        "message": Json::string(msg),
      }),
    ]),
  })
  { json: obj.stringify(indent=2), exit: 2 }
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
fn print_usage() -> Unit {
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
  println(text)
}
