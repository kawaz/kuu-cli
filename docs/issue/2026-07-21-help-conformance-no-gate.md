---
title: help conformance の恒常 gate が無い (P4 実装時の使い捨て検証のみ)
status: open
category: task
created: 2026-07-21T02:32:14+09:00
last_read:
open_entered: 2026-07-21T02:32:14+09:00
wip_entered:
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered:
discard_reason:
pending_reason:
close_reason:
blocked_by:
origin: 自リポ TODO
---

# help conformance の恒常 gate が無い (P4 実装時の使い捨て検証のみ)

## 概要

P4 で `kuu help` サブコマンドを追加した際、help fixture 25 case の構造等価検証は
実装 worker の使い捨て比較スクリプト (jq -cS + number 正規化) で実施し green を
確認したが、justfile に恒常 task として残していない。

現状の `impl-mbt-conformance` は `query == "parse"` のみ走査し、help query は
skip している (99 skipped の一部)。

## 背景

API-Q2 改名追随時に別 worker が「help 25/25 の gate task が存在しない」として
検出した (2026-07-21)。retreat-is-last-resort の観点で「gate が無い = 検証され
てない」状態を放置しない。

恒常化する場合の実装方針: spec の `fixtures/help/*.json` を読み、
`definition` + `path`/`depth`/`category_mode` で `kuu help` を実行して
`expect` と構造等価比較する task を justfile に追加する (= P4 時のスクリプト
相当の再実装)。

## 受け入れ条件

- [ ] justfile に help fixture 25 case を回す恒常 task がある
- [ ] `impl-mbt-conformance` (または新設 task) が help query を skip せず走査する
- [ ] 25/25 green がローカル/CI から再現可能

## TODO

<!-- wip 時のみ -->
