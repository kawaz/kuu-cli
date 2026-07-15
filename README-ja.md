# kuu-cli

> [English](./README.md) | 日本語

[kuu](https://github.com/kawaz/kuu) 引数定義 spec のスタンドアロン CLI。definition (JSON) と argv を渡すと、パース結果 / 補完候補 / 検証レポートを JSON で返す。

```sh
kuu parse def.json -- --port 8080 serve
kuu complete def.json -- --po
kuu validate def.json
```

## なぜスタンドアロンバイナリか

kuu の definition は言語非依存。スタンドアロンの `kuu` バイナリがあれば、shell script・エディタ・CI・kuu 実装がまだ無い言語からでも、ライブラリをリンクせずに同じ spec 準拠の意味論でパース・補完できる。

## マルチ実装アーキテクチャ

このリポジトリは `impl/` 配下に複数言語の実装を持ち、すべて同じ [kuu spec](https://github.com/kawaz/kuu) に準拠して同一挙動になることを期待する (審判は spec の conformance fixtures)。canonical リリースバイナリの実装言語は**意図的に未確定** — binary size / cold start / cross compile / 保守コストで実装同士が競い、[kawaz/die](https://github.com/kawaz/die) の前例 (die 側 DR-0003/DR-0007) に倣ってリリース時に勝者を選定する。選定プロセスは `docs/decisions/` を参照。

| impl | status | notes |
|---|---|---|
| `impl/mbt` (MoonBit) | PoC | spec の参照実装 [kawaz/kuu.mbt](https://github.com/kawaz/kuu.mbt) を流用 |

## Status

PoC。v1 までインターフェイスと出力形は変わりうる。

## License

MIT © Yoshiaki Kawazu
