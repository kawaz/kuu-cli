# kuu-cli

> [English](./README.md) | 日本語

[kuu](https://github.com/kawaz/kuu) 引数定義 spec のスタンドアロン CLI。definition (JSON) と argv を渡すと、パース結果 / 補完候補 / 検証レポートを JSON で返す。

```sh
kuu parse def.json -- --port 8080 serve
kuu complete def.json --args-before '["myapp", "--po"]'
kuu validate def.json
```

## サブコマンド

```sh
kuu parse      <def.json> [options] [--] <args...>
kuu complete   <def.json> --args-before <json-array> [--args-after <json-array>]
kuu validate   <def.json>
kuu help       <def.json> [--path <json-array>] [--depth all] [--format text]
kuu completion generate <def.json> --shell <bash|zsh|fish> --binary <name> --uuid <id>
kuu completion query    <def.json> --cword <n> -- <words...>
```

`<def.json>` に `-` を渡すと definition を stdin から読む。`kuu --help` / `kuu <subcommand> --help` は kuu-cli 自身の definition を描画する — argv の解析に使うものと同一なので、help 表示が受理される command line からずれることがない。

## Exit code

| code | 意味 |
|---|---|
| `0` | 成功。`--help` / `--version` / 引数なし (root help を表示) もここ。 |
| `1` | payload の失敗: `<def.json>` が読めない、JSON として不正、definition として reject された、argv がその definition で parse できない、help query が存在しない path / category を指した。 |
| `2` | kuu-cli 自身の usage error: 未知のサブコマンド、オペランド欠落、オプション値の形不正 (`--args-before` / `--path` / `--tty` は JSON、`--env` は `KEY=VALUE`)。 |

機械可読な出力 (結果 JSON、生成した補完 glue、補完候補) と help テキストは **stdout**、kuu-cli 自身の診断は **stderr**。したがって exit `1` でも stdout には整った JSON レポートが残る — 唯一の例外は `<def.json>` が読めない場合で、報告対象の definition が無いため stderr にプレーンテキストで出る。

exit code は definition ではなくアプリケーションの裁量 (kuu spec は wire model の外に置いている)。この表は kuu-cli 自身の契約。

## なぜスタンドアロンバイナリか

kuu の definition は言語非依存。スタンドアロンの `kuu` バイナリがあれば、shell script・エディタ・CI・kuu 実装がまだ無い言語からでも、ライブラリをリンクせずに同じ spec 準拠の意味論でパース・補完できる。

## マルチ実装アーキテクチャ

このリポジトリは `impl/` 配下に複数言語の実装を持ち、すべて同じ [kuu spec](https://github.com/kawaz/kuu) に準拠して同一挙動になることを期待する (審判は spec の conformance fixtures)。canonical リリースバイナリの実装言語は**意図的に未確定** — binary size / cold start / cross compile / 保守コストで実装同士が競い、[kawaz/die](https://github.com/kawaz/die) の前例 (die 側 DR-0003/DR-0007) に倣ってリリース時に勝者を選定する。選定プロセスは `docs/decisions/` を参照。

| impl | status | notes |
|---|---|---|
| [`impl/mbt`](./impl/mbt/) (MoonBit) | PoC — 上記の全サブコマンドを kuu-cli 自身の kuu definition で dispatch、e2e で spec fixture の代表 5 case を fixture 本体から直接読み込んで pin (詳細 [`impl/mbt/README.md`](./impl/mbt/README.md)) | spec の参照実装 [kawaz/kuu.mbt](https://github.com/kawaz/kuu.mbt) を流用 |

## Status

PoC。v1 までインターフェイスと出力形は変わりうる。

## License

MIT © Yoshiaki Kawazu
