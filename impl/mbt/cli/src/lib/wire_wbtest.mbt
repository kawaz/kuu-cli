// wire_wbtest.mbt — wbtest for the 3 subcommand entrypoints. Fixtures live inline (small
// definition literals) so this test is hermetic. Real spec fixtures go through the CLI-level
// e2e in `impl/mbt/justfile` (which shells the compiled binary against
// `kuu.mbt/../kuu/fixtures/` — the same spec fixtures the reference implementation runs).

// ═════════════════════════════════════════════════════════════════════════════
// helpers — Json navigation for tests (raise on missing / wrong shape). Bespoke because
// `moonbitlang/core/json`'s `.value/.as_string/.as_number` all return `?` (Option), and
// the test bodies would balloon with `.unwrap()` at every step.
// ═════════════════════════════════════════════════════════════════════════════

///|
fn jkey(j : Json, k : String) -> Json {
  match j {
    Object(o) =>
      match o.get(k) {
        Some(v) => v
        None => abort("key '" + k + "' missing in JSON")
      }
    _ => abort("value is not a JSON object")
  }
}

///|
fn jstr(j : Json) -> String {
  match j {
    String(s) => s
    _ => abort("value is not a JSON string")
  }
}

///|
fn jnum(j : Json) -> Double {
  match j {
    Number(d, ..) => d
    _ => abort("value is not a JSON number")
  }
}

///|
fn jbool(j : Json) -> Bool {
  match j {
    True => true
    False => false
    _ => abort("value is not a JSON bool")
  }
}

///|
fn jarr(j : Json) -> Array[Json] {
  match j {
    Array(xs) => xs
    _ => abort("value is not a JSON array")
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// cmd_parse
// ═════════════════════════════════════════════════════════════════════════════

///|
/// success path with a scalar option; effects + result shape (mirrors the simplest
/// scalar-option pattern from kuu/fixtures).
test "cmd_parse success — scalar number option" {
  let def =
    #|{"options": [{"name": "port", "type": "number", "long": true}]}
  let r = cmd_parse(def, ["--port", "8080"])
  inspect(r.exit, content="0")
  let j = @json.parse(r.json)
  inspect(jstr(jkey(j, "outcome")), content="success")
  let result = jkey(j, "result")
  inspect(jnum(jkey(result, "port")), content="8080")
  let effects = jarr(jkey(j, "effects"))
  inspect(effects.length(), content="1")
  let e0 = effects[0]
  inspect(jstr(jkey(e0, "entity")), content="port")
  inspect(jstr(jkey(e0, "op")), content="set")
  inspect(jstr(jkey(e0, "source")), content="cli")
  inspect(jnum(jkey(e0, "operand")), content="8080")
}

///|
/// export_key rename: result キーが `export_key: "alias"` で上書きされ、effects の entity は
/// 元の値セル名 `port` のまま (fixture export-key/rename.json :: rename-projection の pin する
/// 「パース不変・結果キーのみ変化」)。front_door の `export_map(ast)` から取得した ekmap が
/// 効いていることを直接検証する — 空 ekmap の頃は result.port になっていた case。
test "cmd_parse export_key: result キーだけ rename、effects の entity は cell name" {
  let def =
    #|{"options": [{"name": "port", "type": "number", "long": true, "export_key": "alias"}]}
  let r = cmd_parse(def, ["--port", "80"])
  inspect(r.exit, content="0")
  let j = @json.parse(r.json)
  inspect(jstr(jkey(j, "outcome")), content="success")
  // result のキーは export_key で rename 済 (`alias`、`port` ではない)
  let result = jkey(j, "result")
  inspect(jnum(jkey(result, "alias")), content="80")
  // effects の entity は cell name のまま (rename の pin 半分)
  let effects = jarr(jkey(j, "effects"))
  inspect(effects.length(), content="1")
  inspect(jstr(jkey(effects[0], "entity")), content="port")
}

///|
/// failure path with a type-parse reject (fixture pattern separator-typed.json ::
/// option-separator-piece-parse-rejected — the 2nd piece 'abc' fails number type parse).
test "cmd_parse failure — number type parse rejects 'abc'" {
  let def =
    #|{"options": [{"name": "ports", "type": "number", "long": true, "multiple": {"accumulator": "append", "separator": ","}}]}
  let r = cmd_parse(def, ["--ports", "5,abc"])
  inspect(r.exit, content="1")
  let j = @json.parse(r.json)
  inspect(jstr(jkey(j, "outcome")), content="failure")
  let errs = jarr(jkey(j, "errors"))
  inspect(errs.length(), content="1")
  let e = errs[0]
  inspect(jstr(jkey(e, "element")), content="ports")
  inspect(jstr(jkey(e, "kind")), content="parse")
  inspect(jstr(jkey(e, "reason")), content="not_a_number")
  inspect(jnum(jkey(e, "args_pos")), content="1")
}

///|
/// malformed JSON → usage error (exit 2, ok:false).
test "cmd_parse malformed definition text → exit 2" {
  let r = cmd_parse("not a json", [])
  inspect(r.exit, content="2")
  let j = @json.parse(r.json)
  inspect(jbool(jkey(j, "ok")), content="false")
}

// ═════════════════════════════════════════════════════════════════════════════
// cmd_complete
// ═════════════════════════════════════════════════════════════════════════════

///|
/// exact-trigger candidates from an empty args_before. `--port` is expected to appear as an
/// exact trigger with origin="port" (DR-104 §2 exact-required fields).
test "cmd_complete emits exact trigger candidate --port" {
  let def =
    #|{"options": [{"name": "port", "type": "number", "long": true}]}
  let r = cmd_complete(def, [], [])
  inspect(r.exit, content="0")
  let j = @json.parse(r.json)
  let cs = jarr(jkey(j, "candidates"))
  let mut saw = false
  for c in cs {
    if !jbool(jkey(c, "is_value")) && jstr(jkey(c, "spelling")) == "--port" {
      saw = true
      // DR-104 §2 明確化 (a): exact triggers require `origin`.
      inspect(jstr(jkey(c, "origin")), content="port")
      // DR-104 §2 meta is required (`Cand.meta` direct projection).
      let meta = jkey(c, "meta")
      inspect(jbool(jkey(meta, "is_alias")), content="false")
      inspect(jbool(jkey(meta, "hidden")), content="false")
      inspect(jbool(jkey(meta, "deprecated")), content="false")
    }
  }
  inspect(saw, content="true")
}

// ═════════════════════════════════════════════════════════════════════════════
// cmd_validate
// ═════════════════════════════════════════════════════════════════════════════

///|
/// well-formed definition validates.
test "cmd_validate ok" {
  let def =
    #|{"options": [{"name": "port", "type": "number", "long": true}]}
  let r = cmd_validate(def)
  inspect(r.exit, content="0")
  let j = @json.parse(r.json)
  inspect(jbool(jkey(j, "ok")), content="true")
}

///|
/// unknown type name → definition wire-decode failure (surfaces as `Malformed` rather than
/// `Rejected` because it happens in wire_decode before lowering). Both routes emit ok:false + exit 1.
test "cmd_validate unknown type — error reported" {
  let def =
    #|{"options": [{"name": "port", "type": "unknown-type", "long": true}]}
  let r = cmd_validate(def)
  inspect(r.exit, content="1")
  let j = @json.parse(r.json)
  inspect(jbool(jkey(j, "ok")), content="false")
  let errs = jarr(jkey(j, "errors"))
  inspect(errs.length() >= 1, content="true")
}

///|
/// malformed definition text → exit 2.
test "cmd_validate malformed JSON → exit 2" {
  let r = cmd_validate("not a json")
  inspect(r.exit, content="2")
  let j = @json.parse(r.json)
  inspect(jbool(jkey(j, "ok")), content="false")
}
