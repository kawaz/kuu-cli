# kuu-cli

> English | [日本語](./README-ja.md)

A standalone CLI for the [kuu](https://github.com/kawaz/kuu) argument-definition spec: feed it a definition (JSON) and an argv, get back the parsed result / completion candidates / validation report as JSON.

```sh
kuu parse def.json -- --port 8080 serve
kuu complete def.json --args-before '["myapp", "--po"]'
kuu validate def.json
```

## Subcommands

```sh
kuu parse      <def.json> [options] [--] <args...>
kuu complete   <def.json> --args-before <json-array> [--args-after <json-array>]
kuu validate   <def.json>
kuu help       <def.json> [--path <json-array>] [--depth all] [--format text]
kuu completion generate <def.json> --shell <bash|zsh|fish> --binary <name> --uuid <id>
kuu completion query    <def.json> --cword <n> -- <words...>
```

`<def.json>` may be `-` to read the definition from stdin. `kuu --help` and `kuu <subcommand> --help` render kuu-cli's own definition — the same one it parses its argv with, so the help text can never drift from the accepted command line.

## Exit codes

| code | meaning |
|---|---|
| `0` | Success. Also `--help`, `--version`, and `kuu` with no arguments (which prints the root help). |
| `1` | The payload failed: `<def.json>` could not be read, was not valid JSON, was rejected as a definition, the argv did not parse against it, or a help query named a path / category that does not exist. |
| `2` | kuu-cli's own usage error: unknown subcommand, a missing operand, or an option value in the wrong shape (`--args-before` / `--path` / `--tty` take JSON, `--env` takes `KEY=VALUE`). |

Machine-readable output (the result JSON, generated completion glue, completion candidates) and help text go to **stdout**; kuu-cli's own diagnostics go to **stderr**. So exit `1` still leaves a well-formed JSON report on stdout — the one exception is an unreadable `<def.json>`, reported on stderr as plain text because there is no definition to report against.

Exit codes are the application's business, not the definition's: the kuu spec deliberately leaves them out of the wire model, so this table is kuu-cli's own contract.

## Why a standalone binary

kuu definitions are language-agnostic. A standalone `kuu` binary lets any environment — shell scripts, editors, CI, languages without a kuu implementation yet — parse and complete against the same spec-conformant semantics without linking a library.

## Multi-implementation architecture

This repository hosts implementations in multiple languages under `impl/`, all conforming to the same [kuu spec](https://github.com/kawaz/kuu) and expected to behave identically (the spec's conformance fixtures are the arbiter). The language of the canonical release binary is **deliberately undecided** — implementations compete on binary size, cold start, cross-compilation, and maintenance cost, and the release picks the winner per the [kawaz/die](https://github.com/kawaz/die) precedent (DR-0003/DR-0007 there). See `docs/decisions/` for the selection process.

| impl | status | notes |
|---|---|---|
| [`impl/mbt`](./impl/mbt/) (MoonBit) | PoC — all subcommands above, dispatched from kuu-cli's own kuu definition; e2e pins 5 representative spec fixture cases directly (see [`impl/mbt/README.md`](./impl/mbt/README.md)) | reuses [kawaz/kuu.mbt](https://github.com/kawaz/kuu.mbt), the spec's reference implementation |

## Status

PoC. Interfaces and output shapes may change until v1.

## License

MIT © Yoshiaki Kawazu
