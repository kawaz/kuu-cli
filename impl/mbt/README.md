# impl/mbt — MoonBit PoC implementation

Reuses [kawaz/kuu.mbt](https://github.com/kawaz/kuu.mbt) (the spec reference implementation) as a library via a `moon.work` workspace with a symlinked dependency. See root [DR-0001](../../docs/decisions/DR-0001-multi-impl-architecture.md) for why this PoC exists.

## Layout

```
impl/mbt/
  moon.work            workspace: cli + deps/kuu.mbt
  cli/
    moon.mod           name="kawaz/kuu-cli-mbt", imports kawaz/kuu@0.1.0
    src/
      lib/wire.mbt         JSON emitters (parse / complete / validate)
      lib/wire_wbtest.mbt  hermetic wbtest
      main/main.mbt        argv dispatch + libc exit(3) binding
  deps/
    kuu.mbt              symlink to sibling kawaz/kuu.mbt/main (gitignored)
  justfile             setup / lint / test / e2e
```

## Dev setup

The `deps/kuu.mbt` symlink assumes `kawaz/kuu.mbt` is checked out as a **sibling** of `kawaz/kuu-cli` (both under `github.com/kawaz/`). Run once:

```sh
just impl-mbt-setup
```

This creates `deps/kuu.mbt -> ../../../../../kuu.mbt/main`. The symlink is gitignored — CI will replace it with a SHA-pinned `git clone` of kawaz/kuu.mbt at the same path.

## Build / test / e2e

```sh
just impl-mbt-test        # moon test cli/src/lib + CLI e2e against real spec fixtures
just impl-mbt-lint        # moon check --target native
```

The `e2e` recipe runs the compiled `kuu parse` binary against **five representative cases** picked from `kawaz/kuu/fixtures/`, reading each case's `args` and `expect` fields **directly from the fixture body via `jq`** (so a fixture rename or expected-value change is caught immediately, not masked by a hardcoded copy — cf. codex review #1 M-2). Current pin set:

| fixture | case id | axis |
|---|---|---|
| `multiple-parse/separator-typed.json` | `option-separator-number-success` | separator + type parse |
| `export-key/rename.json` | `rename-projection` | `export_key`: result-key rename |
| `export-key/collision.json` | `co-exposure-collision` | Ambiguous 昇格 (regression guard for C-1 = `front_door.parse` postprocessing) |
| `inheritable-parse/basic.json` | `ancestor-inherit-flowdown` | resolve 相の inherit 流下 (regression guard for C-1) |
| `alias-parse/deprecated.json` | `deprecated-entry-warns` | structured `warnings` + `@depr` sentinel not leaking into `effects` (regression guard for M-1) |

Reproducing the full CONFORMANCE-style comparison across every fixture is out of scope here (see v1 決定リスト item 8) — this layer only checks that the compiled binary agrees with each fixture's representative expected fields.

## CLI reference

```sh
kuu parse    <def.json> [--] <args...>
kuu complete <def.json> --args-before <json-array> [--args-after <json-array>]
kuu validate <def.json>
```

- Exit 0: success. Exit 1: parse/validate failure. Exit 2: CLI usage error (PoC assignment).
- **stdout / stderr split**: machine output (the single JSON object from `parse` / `complete` / `validate`, plus `kuu help`) is on stdout; human-oriented text (usage on startup errors, unknown subcommand, extra-arg errors) is on stderr. `kuu` (no args) / `kuu <unknown-sub>` / any subcommand missing its `<def.json>` writes usage to stderr and exits 2. `-h` short alias is intentionally NOT provided (kawaz CLI preference: short aliases only when explicitly asked for).
- See `cli/src/lib/wire.mbt` for the emit shape and the two "PoC 仮置き" notes (ambiguous rendering and exit-code assignment) that need spec-side ratification.

## Known issues

- `moon fmt --check` fails: the formatter (`moon` 0.1.20260709) rewrites `options("is-main": true)` → `pkgtype(kind: "executable")`, but the compiler in the same toolchain does not accept `pkgtype`. `just lint` therefore only runs `moon check`. To be resolved when a toolchain aligns the two.
- The two remaining "PoC 仮置き" items (ambiguous `interpretations` reduced to a count-only shape; PoC exit-code assignment 0/1/2) are documented in the file-level comment of `cli/src/lib/wire.mbt`. The former "result export_key application" note is resolved (kuu.mbt MDR-005 §1 追記 with `export_map(ast)` on `AtomicAST`, 2026-07-15).
