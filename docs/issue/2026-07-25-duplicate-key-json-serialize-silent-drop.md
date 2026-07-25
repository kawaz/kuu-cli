---
title: 重複キーを持つ result の JSON 直列化で片方が黙って落ちる
status: open
category: bug
created: 2026-07-25T17:23:32+09:00
last_read:
open_entered: 2026-07-25T17:23:32+09:00
wip_entered:
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered:
discard_reason:
pending_reason:
close_reason:
blocked_by:
origin: 自リポ TODO (dogfooding D4)
---

# 重複キーを持つ result の JSON 直列化で片方が黙って落ちる

## 概要

`@abi.ResultValue::Object` は `Array[(String, ResultValue)]` なので同名キーの
エントリを複数持てる。露出キー衝突 (例: global `--help` option と `help`
command が両方キー `help` を名乗る) が起きると、in-memory の result は
`[("help", Bool(true)), ("help", Object{...})]` の形になる。しかし
`impl/mbt/cli/src/lib/wire.mbt` の `rval_to_json` が `Map::from_array(pairs)`
を使って JSON へ落としているため、後勝ちで片方が黙って消える。

## 背景

### 実測

`kuu parse cli/kuu-cli.def.json --no-env --no-config -- help --help` の出力を
重複キー保持パーサ (python `json` の `object_pairs_hook`) で読んでも、result
のエントリは 1 件のみ。command scope の object が残り、option の bool が消える。

in-memory には両方存在することは `impl/mbt/cli/src/main/main.mbt` の
`help_requested` (全エントリを走査して `Bool(true)` を探す実装、commit
`b07b7406`) が実際に機能していることから確認できる。

### なぜ kuu-cli 単独で先に直すべきでないか

DR-109 §2 は `kuu parse` の出力を conformance fixture の expect 語彙と厳密に
同形と規定しており、fixture の `expect.result` は JSON object リテラルなので
重複キーを書く語彙が構文的に存在しない。つまり重複キー result は「fixture
として pin できない形」であり、通る expect が書けない。

したがって根本解決は spec 側の裁定 (spec `docs/QUESTIONS.md` の EXK-Q1 /
EXK-Q2) に依存する:

- 裁定が (a) や (c) 方向 (衝突を ambiguous に落とす) なら重複キー result 自体
  が生成されなくなり、この直列化の問題は到達不能になって本 issue は自然解消
- 裁定が (b) 方向 (commands を衝突対象から除外して重複を合法化) なら、逆に
  直列化規則を spec 側で新規に規定する必要が生じ、本 issue は spec の宿題の
  実装側として残る

いずれにせよ spec 裁定待ち。ただし「黙って落ちる」ことは診断上望ましくない
ため、暫定対応として重複キー検出時に stderr へ警告を出す、という選択肢は
裁定と独立に検討できる。

## 受け入れ条件

- [ ] spec `docs/QUESTIONS.md` EXK-Q1 / EXK-Q2 の裁定が下りている
- [ ] 裁定 (a)/(c) 方向: 重複キー result が到達不能であることを確認し、本
      issue を自然解消として close
- [ ] 裁定 (b) 方向: `rval_to_json` の直列化規則を spec 側の新規定に沿って
      修正し、conformance fixture で pin する
- [ ] (裁定と独立に検討可) 重複キー検出時の stderr 警告の要否を判断する
