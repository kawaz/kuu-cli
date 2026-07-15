# kuu-cli

> English | [日本語](./README-ja.md)

A standalone CLI for the [kuu](https://github.com/kawaz/kuu) argument-definition spec: feed it a definition (JSON) and an argv, get back the parsed result / completion candidates / validation report as JSON.

```sh
kuu parse def.json -- --port 8080 serve
kuu complete def.json -- --po
kuu validate def.json
```

## Why a standalone binary

kuu definitions are language-agnostic. A standalone `kuu` binary lets any environment — shell scripts, editors, CI, languages without a kuu implementation yet — parse and complete against the same spec-conformant semantics without linking a library.

## Multi-implementation architecture

This repository hosts implementations in multiple languages under `impl/`, all conforming to the same [kuu spec](https://github.com/kawaz/kuu) and expected to behave identically (the spec's conformance fixtures are the arbiter). The language of the canonical release binary is **deliberately undecided** — implementations compete on binary size, cold start, cross-compilation, and maintenance cost, and the release picks the winner per the [kawaz/die](https://github.com/kawaz/die) precedent (DR-0003/DR-0007 there). See `docs/decisions/` for the selection process.

| impl | status | notes |
|---|---|---|
| [`impl/mbt`](./impl/mbt/) (MoonBit) | PoC (parse / complete / validate wired to spec fixtures) | reuses [kawaz/kuu.mbt](https://github.com/kawaz/kuu.mbt), the spec's reference implementation |

## Status

PoC. Interfaces and output shapes may change until v1.

## License

MIT © Yoshiaki Kawazu
