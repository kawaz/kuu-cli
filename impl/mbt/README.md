# impl/mbt — MoonBit PoC implementation

Reuses [kawaz/kuu.mbt](https://github.com/kawaz/kuu.mbt) (the spec reference implementation) as a library via a `moon.work` workspace with a symlinked dependency. See root [DR-0001](../../docs/decisions/DR-0001-multi-impl-architecture.md) for why this PoC exists.

## Layout

```
impl/mbt/
  moon.work            workspace: cli + deps/kuu.mbt
  cli/
    kuu-cli.def.json   kuu-cli's own kuu definition (source of its argv parsing and help)
    moon.mod           name="kawaz/kuu-cli-mbt", imports kawaz/kuu@0.0.18
    src/
      lib/wire.mbt         JSON emitters (parse / complete / validate / help / completion)
      lib/renderer.mbt     help text renderer
      lib/wire_wbtest.mbt  hermetic wbtest
      main/main.mbt        self-parse + dispatch + libc exit(3) binding
      main/def_embedded.mbt  generated from kuu-cli.def.json + VERSION (just generate-self-definition)
  deps/
    kuu.mbt              symlink to sibling kawaz/kuu.mbt/main (gitignored)
  justfile             setup / lint / test / e2e / conformance
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

The `e2e` recipe runs the compiled `kuu parse` binary against **six representative cases** picked from `kawaz/kuu/fixtures/`, reading each case's `args` and `expect` fields **directly from the fixture body via `jq`** (so a fixture rename or expected-value change is caught immediately, not masked by a hardcoded copy — cf. codex review #1 M-2). Current pin set:

| fixture | case id | axis |
|---|---|---|
| `multiple-parse/separator-typed.json` | `option-separator-number-success` | separator + type parse |
| `export-key/rename.json` | `rename-projection` | `export_key`: result-key rename |
| `export-key/collision.json` | `mapped-pair-shares-key` | definition-error の `(element, kind)` 全列挙 (DR-120) |
| `path-search/variable-arity-ambiguous.json` | `color-arity-vs-name-receptacle` | 構造的 Ambiguous (regression guard for C-1 = `front_door.parse` postprocessing) |
| `value-sources/default-fn-borrow-ladder.json` | `outer-default-borrowed` | resolve 相の祖先参照 `default_fn: "borrow:<source>"` (regression guard for C-1) |
| `alias-parse/deprecated.json` | `deprecated-entry-warns` | structured `warnings` + `@depr` sentinel not leaking into `effects` (regression guard for M-1) |

Reproducing the full CONFORMANCE-style comparison across every fixture is out of scope here (see v1 決定リスト item 8) — this layer only checks that the compiled binary agrees with each fixture's representative expected fields.

### Conformance sweep (regression gate)

```sh
just impl-mbt-conformance   # run ALL parse fixtures through the CLI; regression gate on the pass count
```

Runs every `query: "parse"` fixture case through the compiled binary (fixing the environment via `--no-env` and injecting the case's `env` / `config` / `tty` inputs) and compares each `expect` top-level key per CONFORMANCE §3 (structural equality; `errors` / `interpretations` / `warnings` / `tried_triggers` as sets; `reason` / `path` opt-in; numbers by value). It is a **regression gate**: passing counts below the hand-maintained baseline (see the recipe) exit 1. The baseline is a manual ratchet — raise it when fails are resolved; it is never auto-tracked (that would hide new regressions). Remaining fails/blocked-skips are catalogued in `docs/findings/2026-07-16-conformance-fail-taxonomy.md`. Fixture location can be injected with `KUU_FIXTURES` (same convention as the kuu.mbt conformance runner); the default is the sibling `kawaz/kuu` checkout.

## CLI reference

The subcommand surface and the exit-code contract are documented in the root [README](../../README.md) (that table is the canonical one). This section covers what is specific to the MoonBit implementation.

- **Self-hosted dispatch**: `cli/kuu-cli.def.json` is kuu-cli's own kuu definition. `just generate-self-definition` embeds it (plus `VERSION`) into `cli/src/main/def_embedded.mbt`, and `main.mbt` parses its own argv with `@kuu.parse` / `@kuu.resolve` against it, then dispatches on the resulting `result` object. `--help` / `--version` / completion of `kuu` itself all come from the same definition, so the accepted command line and the rendered help cannot drift apart.
- **Exit mapping in the code**: `CmdResult.exit` (`cli/src/lib/wire.mbt`) is a *payload-level* class, not the process code — `main.mbt`'s `emit_payload` collapses every non-zero payload class to process exit **1**, and every failure of kuu-cli's own command line goes through `die_with(..., 2)` / `handle_self_failure` for **2**. Those two functions are the only places that decide a process exit code.
- **Value sources** (spec DR-109 §6 — kuu-cli is NOT a test tool; it must behave like an in-app kuu): by default `parse` takes the **real environment** (env vars via the process environment, tty via `isatty(3)`, config files read from disk when the definition's `config_file` cell resolves a path). Test-fixation options: `--no-env` / `--env k=v` (repeatable override) / `--no-config` / `--config <json|file>` (direct object supply) / `--tty <json>` (pin observations, same shape as fixture `tty` input).
- **Envelope** (spec DR-109 §2/§3/§4): output matches the conformance fixture expect vocabulary strictly — no extra fields (`message` / `scope` are not emitted; empty `element` is omitted; `warnings` is always present incl. `[]`). `sources` is always included on resolved success output. Ambiguous `interpretations` carry each interpretation's parse-phase result view — the value-source ladder is NOT applied to interpretations.
- `-h` short alias is intentionally NOT provided (kawaz CLI preference: short aliases only when explicitly asked for).

## Known issues

- `moon fmt --check` fails: the formatter (`moon` 0.1.20260709) rewrites `options("is-main": true)` → `pkgtype(kind: "executable")`, but the compiler in the same toolchain does not accept `pkgtype`. `just lint` therefore only runs `moon check`. To be resolved when a toolchain aligns the two.
