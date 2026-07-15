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
just impl-mbt-test        # moon test cli/src/lib + CLI e2e against a real spec fixture
just impl-mbt-lint        # moon check --target native
```

The `e2e` recipe invokes the compiled `kuu parse` binary against `kawaz/kuu/fixtures/multiple-parse/separator-typed.json` and checks the outcome + result shape (spec fixtures are the arbiter).

## CLI reference

```sh
kuu parse    <def.json> [--] <args...>
kuu complete <def.json> --args-before <json-array> [--args-after <json-array>]
kuu validate <def.json>
```

- Exit 0: success. Exit 1: parse/validate failure. Exit 2: CLI usage error (PoC assignment).
- All output is a single JSON object on stdout. See `cli/src/lib/wire.mbt` for the emit shape and the three "PoC 仮置き" notes (`result` export_key application, ambiguous rendering, exit-code assignment) that need spec-side ratification.

## Known issues

- `moon fmt --check` fails: the formatter (`moon` 0.1.20260709) rewrites `options("is-main": true)` → `pkgtype(kind: "executable")`, but the compiler in the same toolchain does not accept `pkgtype`. `just lint` therefore only runs `moon check`. To be resolved when a toolchain aligns the two.
- The two remaining PoC 仮置き items (ambiguous `interpretations` reduced to a count-only shape; PoC exit-code assignment 0/1/2) are documented in the file-level comment of `cli/src/lib/wire.mbt`.
