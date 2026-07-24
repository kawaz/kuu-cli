// `kuu` CLI entry. Its own command line is defined by kuu-cli.def.json and parsed by kuu.

extern "c" fn c_exit(code : Int) = "exit"

#borrow(buf)
extern "c" fn c_write(fd : Int, buf : Bytes, len : Int) -> Int = "write"

#borrow(buf)
extern "c" fn c_read(fd : Int, buf : Bytes, len : Int) -> Int = "read"

extern "c" fn c_isatty(fd : Int) -> Int = "isatty"

fn[T] die(code : Int) -> T {
  c_exit(code)
  panic()
}

fn eprintln(s : String) -> Unit {
  let bytes = @utf8.encode(s + "\n")
  let _ = c_write(2, bytes, bytes.length())
}

fn main {
  let argv = @env.args()
  let self_json = @json.parse(SELF_DEFINITION_JSON) catch {
    _ => die_with("kuu: embedded definition is not valid JSON", 2)
  }
  let self_ast = match @kuu.parse_definition(self_json) {
    Ok(ast) => ast
    Err(_) => die_with("kuu: embedded definition was rejected", 2)
  }
  let process_env = @env.get_env_vars()
  match @kuu.completion_entry(self_ast, argv, process_env) {
    @kuu.Respond(text) => {
      println(text)
      return
    }
    @kuu.NotCompletion => ()
  }

  let args = argv_tail(argv)
  if args.length() == 0 {
    print_self_help([])
    return
  }
  let sources = @kuu.value_sources()
  match @kuu.parse(self_ast, args, sources~) {
    @kuu.Failure(failure) => handle_self_failure(failure)
    @kuu.Ambiguous(ambiguity) => {
      eprintln("kuu: command line is ambiguous")
      for interpretation in ambiguity.interpretations {
        let claimants = interpretation.claimants()
        for claimant in claimants {
          eprintln("  " + claimant.0 + ": " + claimant.1)
        }
        match @kuu.resolve_interpretation(self_ast, interpretation, args, sources~) {
          @kuu.Success(resolved) => eprintln(result_repr(@kuu.output(self_ast, resolved).result))
          @kuu.Failure(_) => eprintln("  interpretation failed during resolve")
        }
      }
      die(2)
    }
    @kuu.Success(parsed) =>
      match @kuu.resolve(self_ast, parsed, args, sources~) {
        @kuu.Failure(failure) => handle_self_failure(failure)
        @kuu.Success(resolved) => dispatch(@kuu.output(self_ast, resolved).result)
      }
  }
}

fn argv_tail(argv : Array[String]) -> Array[String] {
  let args : Array[String] = []
  for i in 1..<argv.length() {
    args.push(argv[i])
  }
  args
}

fn handle_self_failure(failure : @kuu.ParseFailure) -> Unit {
  if failure.fired_action == Some("help") {
    print_self_help(failure_path(failure))
    return
  }
  if failure.fired_action == Some("version") {
    println(SELF_VERSION)
    return
  }
  if failure.errors.length() == 0 {
    eprintln("kuu: invalid command line")
  } else {
    for error in failure.errors {
      eprintln("kuu: " + error.message)
    }
  }
  die(2)
}

fn failure_path(failure : @kuu.ParseFailure) -> Array[String] {
  let path : Array[String] = []
  for error in failure.errors {
    if error.path.length() > path.length() {
      path.clear()
      for segment in error.path {
        path.push(segment)
      }
    }
  }
  path
}

fn print_self_help(path : Array[String]) -> Unit {
  let result = @lib.cmd_help_text(
    SELF_DEFINITION_JSON,
    path,
    @kuu.Scope,
    @kuu.Default,
    @lib.render_opts_default(),
  )
  if result.exit == 0 {
    println(result.json)
  } else {
    eprintln(result.json)
    die(2)
  }
}

fn dispatch(result : @kuu.ResultValue) -> Unit {
  let root = as_object(result, "root result")
  match field_opt(root, "help") {
    Some(@abi.Scalar(@abi.Bool(true))) => {
      print_self_help([])
      return
    }
    _ => ()
  }
  match string_field_opt(root, "version") {
    Some(_) => {
      println(SELF_VERSION)
      return
    }
    None => ()
  }
  match object_field_opt(root, "parse") {
    Some(command) => emit_payload(run_parse(command))
    None =>
      match object_field_opt(root, "complete") {
        Some(command) => emit_payload(run_complete(command))
        None =>
          match object_field_opt(root, "validate") {
            Some(command) => emit_payload(run_validate(command))
            None =>
              match object_field_opt(root, "help") {
                Some(command) => run_help(command)
                None =>
                  match object_field_opt(root, "completion") {
                    Some(command) => run_completion(command)
                    None => die_with("kuu: no command was selected", 2)
                  }
              }
          }
      }
  }
}

fn emit_payload(result : @lib.CmdResult) -> Unit {
  println(result.json)
  if result.exit != 0 {
    die(1)
  }
}

fn run_parse(command : Array[(String, @kuu.ResultValue)]) -> @lib.CmdResult {
  let def_text = read_definition(string_field(command, "definition"))
  let parse_args = strings_field(command, "args")
  let env = if bool_field(command, "no_env", false) {
    Map([])
  } else {
    @env.get_env_vars()
  }
  for raw in strings_field(command, "env") {
    match split_once(raw, '=') {
      Some(pair) => env.set(pair.0, pair.1)
      None => die_with("kuu parse: --env expects KEY=VALUE", 2)
    }
  }

  let config : (String) -> @kuu.ConfigVal? = if bool_field(
    command,
    "no_config",
    false,
  ) {
    fn(_) { None }
  } else {
    match string_field_opt(command, "config") {
      Some(raw) => {
        let value = config_value(raw, "kuu parse: --config")
        fn(_) { Some(value) }
      }
      None => {
        let entries = config_file_field(command)
        if entries.length() > 0 {
          let values : Map[String, @kuu.ConfigVal] = Map([])
          for entry in entries {
            values.set(
              entry.0,
              config_value(entry.1, "kuu parse: --config-file " + entry.0),
            )
          }
          fn(path) { values.get(path) }
        } else {
          fn(path) {
            match read_file_all(path) {
              Ok(text) => {
                let json = @json.parse(text) catch { _ => return None }
                Some(@kuu.config_from_json(json))
              }
              Err(_) => None
            }
          }
        }
      }
    }
  }

  let tty : Map[String, @kuu.TtyObs] = match string_field_opt(command, "tty") {
    Some(raw) => {
      let json = @json.parse(raw) catch {
        _ => die_with("kuu parse: --tty value is not valid JSON", 2)
      }
      match tty_from_json(json) {
        Ok(value) => value
        Err(message) => die_with("kuu parse: --tty " + message, 2)
      }
    }
    None =>
      Map([
        ("stdin", @kuu.tty_obs(c_isatty(0) == 1, false)),
        ("stdout", @kuu.tty_obs(c_isatty(1) == 1, false)),
        ("stderr", @kuu.tty_obs(c_isatty(2) == 1, false)),
      ])
  }
  @lib.cmd_parse(def_text, parse_args, env~, config~, tty~)
}

fn run_complete(command : Array[(String, @kuu.ResultValue)]) -> @lib.CmdResult {
  let def_text = read_definition(string_field(command, "definition"))
  let before = parse_str_array(
    string_field(command, "args_before"),
    "kuu complete: --args-before",
  )
  let after = match string_field_opt(command, "args_after") {
    Some(raw) => parse_str_array(raw, "kuu complete: --args-after")
    None => []
  }
  @lib.cmd_complete(def_text, before, after)
}

fn run_validate(command : Array[(String, @kuu.ResultValue)]) -> @lib.CmdResult {
  @lib.cmd_validate(read_definition(string_field(command, "definition")))
}

fn run_help(command : Array[(String, @kuu.ResultValue)]) -> Unit {
  let definitions = strings_field(command, "definition")
  if definitions.length() == 0 {
    print_self_help(["help"])
    return
  }
  let def_text = read_definition(definitions[0])
  let path = match string_field_opt(command, "path") {
    Some(raw) => parse_str_array(raw, "kuu help: --path")
    None => []
  }
  let depth = match string_field_opt(command, "depth") {
    Some("all") => @kuu.HelpDepth::All
    _ => @kuu.HelpDepth::Scope
  }
  let category_mode = match string_field_opt(command, "category_mode") {
    Some(raw) => parse_category_mode(raw)
    None => @kuu.Default
  }
  if string_field_opt(command, "format") == Some("text") {
    let bindings : Map[String, String] = Map([])
    for raw in strings_field(command, "binding") {
      match split_once(raw, '=') {
        Some(pair) => bindings.set(pair.0, pair.1)
        None => die_with("kuu help: --binding expects NAME=VALUE", 2)
      }
    }
    let opts : @lib.RenderOpts = {
      program_name: string_field_opt(command, "program_name"),
      show_hidden: bool_field(command, "show_hidden", false),
      bindings,
      style: {
        template: string_field_opt(command, "style_template"),
        value_structure_style: string_field_opt(
          command,
          "style_value_structure",
        ),
        types_style: string_field_opt(command, "style_types"),
        origin_style: string_field_opt(command, "style_origin"),
      },
      category_mode,
    }
    emit_payload(@lib.cmd_help_text(def_text, path, depth, category_mode, opts))
  } else {
    emit_payload(@lib.cmd_help(def_text, path, depth, category_mode))
  }
}

fn run_completion(command : Array[(String, @kuu.ResultValue)]) -> Unit {
  match object_field_opt(command, "generate") {
    Some(generate) =>
      emit_payload(
        @lib.cmd_completion_generate(
          read_definition(string_field(generate, "definition")),
          string_field(generate, "shell"),
          string_field(generate, "binary"),
          string_field(generate, "uuid"),
          string_field_opt(generate, "program_name"),
        ),
      )
    None =>
      match object_field_opt(command, "query") {
        Some(query) =>
          emit_payload(
            @lib.cmd_completion_query(
              read_definition(string_field(query, "definition")),
              strings_field(query, "words"),
              int_field_opt(query, "cword"),
            ),
          )
        None => die_with("kuu completion: no command was selected", 2)
      }
  }
}

fn result_repr(value : @kuu.ResultValue) -> String {
  match value {
    @abi.Scalar(@abi.String(text)) => "\"" + text + "\""
    @abi.Scalar(@abi.Bool(value)) => if value { "true" } else { "false" }
    @abi.Scalar(@abi.Number(value)) => value.to_string()
    @abi.Array(values) => {
      let parts : Array[String] = []
      for item in values { parts.push(result_repr(item)) }
      "[" + parts.join(",") + "]"
    }
    @abi.Object(fields) => {
      let parts : Array[String] = []
      for field in fields { parts.push(field.0 + ":" + result_repr(field.1)) }
      "{" + parts.join(",") + "}"
    }
  }
}

fn as_object(
  value : @kuu.ResultValue,
  label : String,
) -> Array[(String, @kuu.ResultValue)] {
  match value {
    @abi.Object(fields) => fields
    _ => die_with("kuu: invalid embedded result for " + label, 2)
  }
}

fn field_opt(
  fields : Array[(String, @kuu.ResultValue)],
  name : String,
) -> @kuu.ResultValue? {
  for field in fields {
    if field.0 == name {
      return Some(field.1)
    }
  }
  None
}

fn object_field_opt(
  fields : Array[(String, @kuu.ResultValue)],
  name : String,
) -> Array[(String, @kuu.ResultValue)]? {
  for field in fields {
    if field.0 == name {
      match field.1 {
        @abi.Object(value) => return Some(value)
        _ => ()
      }
    }
  }
  None
}

fn scalar_string(value : @kuu.ResultValue, name : String) -> String {
  match value {
    @abi.Scalar(@abi.String(text)) => text
    _ => die_with("kuu: embedded result field '" + name + "' is not a string", 2)
  }
}

fn string_field(
  fields : Array[(String, @kuu.ResultValue)],
  name : String,
) -> String {
  match field_opt(fields, name) {
    Some(value) => scalar_string(value, name)
    None => die_with("kuu: embedded result is missing '" + name + "'", 2)
  }
}

fn string_field_opt(
  fields : Array[(String, @kuu.ResultValue)],
  name : String,
) -> String? {
  match field_opt(fields, name) {
    Some(value) => Some(scalar_string(value, name))
    None => None
  }
}

fn bool_field(
  fields : Array[(String, @kuu.ResultValue)],
  name : String,
  default : Bool,
) -> Bool {
  match field_opt(fields, name) {
    Some(@abi.Scalar(@abi.Bool(value))) => value
    Some(_) => die_with("kuu: embedded result field '" + name + "' is not boolean", 2)
    None => default
  }
}

fn int_field_opt(
  fields : Array[(String, @kuu.ResultValue)],
  name : String,
) -> Int? {
  match field_opt(fields, name) {
    Some(@abi.Scalar(@abi.Number(value))) => Some(value.to_int())
    Some(_) => die_with("kuu: embedded result field '" + name + "' is not numeric", 2)
    None => None
  }
}

fn strings_field(
  fields : Array[(String, @kuu.ResultValue)],
  name : String,
) -> Array[String] {
  match field_opt(fields, name) {
    None => []
    Some(@abi.Array(values)) => {
      let out : Array[String] = []
      for value in values {
        out.push(scalar_string(value, name))
      }
      out
    }
    Some(value) => [scalar_string(value, name)]
  }
}

fn config_file_field(
  fields : Array[(String, @kuu.ResultValue)],
) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  match field_opt(fields, "config_file") {
    Some(@abi.Array(rows)) =>
      for row in rows {
        match row {
          @abi.Array(cells) => {
            let mut path : String? = None
            let mut value : String? = None
            for cell in cells {
              match cell {
                @abi.Object(object) =>
                  match string_field_opt(object, "path") {
                    Some(text) => path = Some(text)
                    None =>
                      match string_field_opt(object, "value") {
                        Some(text) => value = Some(text)
                        None => ()
                      }
                  }
                @abi.Scalar(@abi.String(text)) => value = Some(text)
                _ => ()
              }
            }
            match (path, value) {
              (Some(p), Some(v)) => out.push((p, v))
              _ => die_with("kuu: invalid --config-file result", 2)
            }
          }
          _ => die_with("kuu: invalid --config-file row", 2)
        }
      }
    Some(_) => die_with("kuu: invalid --config-file result", 2)
    None => ()
  }
  out
}

fn read_definition(path : String) -> String {
  match read_file_all(path) {
    Ok(text) => text
    Err(message) => die_with(message, 1)
  }
}

fn read_file_all(path : String) -> Result[String, String] {
  if path == "-" {
    return read_stdin_all()
  }
  Ok(@fs.read_file_to_string(path)) catch {
    _ => Err("cannot read '" + path + "'")
  }
}

fn read_stdin_all() -> Result[String, String] {
  let bytes : Array[Byte] = []
  while true {
    let chunk = Bytes::make(4096, 0)
    let count = c_read(0, chunk, chunk.length())
    if count < 0 {
      return Err("cannot read standard input")
    }
    if count == 0 {
      break
    }
    for i in 0..<count {
      bytes.push(chunk[i])
    }
  }
  Ok(@utf8.decode_lossy(Bytes::from_array(bytes)[:]))
}

fn config_value(raw : String, label : String) -> @kuu.ConfigVal {
  let json = @json.parse(raw) catch {
    _ =>
      match read_file_all(raw) {
        Ok(text) =>
          @json.parse(text) catch {
            _ => die_with(label + " is neither JSON nor a readable JSON file", 2)
          }
        Err(_) => die_with(label + " is neither JSON nor a readable JSON file", 2)
      }
  }
  @kuu.config_from_json(json)
}

fn tty_from_json(j : Json) -> Result[Map[String, @kuu.TtyObs], String] {
  match j {
    Object(object) => {
      let result : Map[String, @kuu.TtyObs] = Map([])
      for name, value in object {
        match value {
          Object(fields) => {
            let terminal = match fields.get("terminal") {
              Some(True) => true
              Some(False) => false
              _ => return Err("stream '" + name + "' needs boolean 'terminal'")
            }
            let cygwin = match fields.get("cygwin") {
              Some(True) => true
              Some(False) | None => false
              _ => return Err("stream '" + name + "' has non-boolean 'cygwin'")
            }
            result.set(name, @kuu.tty_obs(terminal, cygwin))
          }
          _ => return Err("stream '" + name + "' value must be an object")
        }
      }
      Ok(result)
    }
    _ => Err("value must be a JSON object of streams")
  }
}

fn split_once(s : String, separator : Char) -> (String, String)? {
  let mut index = -1
  let mut current = 0
  for char in s {
    if char == separator && index < 0 {
      index = current
    }
    current = current + 1
  }
  if index < 0 {
    None
  } else {
    Some((s[0:index].to_owned(), s[index + 1:].to_owned()))
  }
}

fn parse_str_array(raw : String, label : String) -> Array[String] {
  let json = @json.parse(raw) catch {
    _ => die_with(label + " is not valid JSON", 2)
  }
  match json {
    Array(items) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(text) => out.push(text)
          _ => die_with(label + " must contain only strings", 2)
        }
      }
      out
    }
    _ => die_with(label + " must be a JSON array", 2)
  }
}

fn parse_category_mode(raw : String) -> @kuu.HelpCategoryMode {
  if raw == "default" {
    @kuu.Default
  } else if raw == "all" {
    @kuu.All
  } else if raw.length() > 6 && raw[0:6].to_owned() == "named:" {
    @kuu.Named(raw[6:].to_owned())
  } else {
    die_with("kuu help: invalid --category-mode '" + raw + "'", 2)
  }
}

fn[T] die_with(message : String, code : Int) -> T {
  eprintln(message)
  die(code)
}
