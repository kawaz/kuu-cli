# codex レビュー #1 (PoC 全体、2026-07-15) — 指摘全文

gpt-5.6-sol による初回全方位レビュー。main = 42f07aee 時点。要旨: 「単純 parse の起動 PoC としては動くが、『conformance fixtures が審判』『fixture protocol を CLI に転用』という設計主張を満たさない。最大要因は CLI が conformance runner の正規 pipeline でなく raw parse_tree 相当だけを呼ぶこと」。

パス表記はレビュー時点の絶対パス由来をリポ相対に正規化。kuu.mbt / spec 側参照は「kuu.mbt の <path>」「spec の <path>」表記。行番号はレビュー時点 (main = 42f07aee、kuu.mbt = 99a7e5b5) のもの。

## Critical

### C-1 CLI が conformance 後処理を通らず、spec と異なる outcome/result を返す

- CLI は `@core.parse(ast,args)` を直接呼ぶ: impl/mbt/cli/src/lib/wire.mbt:45-52
- front door parse は `parse_tree` の薄い wrapper: kuu.mbt の src/core/front_door.mbt:115-120
- conformance runner はその後に値源解決後 requires、export-key collision の Success→Ambiguous、env/config/inherit/default/tty resolve を適用: kuu.mbt の src/core/json_conformance_wbtest.mbt:2903-2936
- spec は fixture protocol を CLI I/O にそのまま転用すると規定: spec の docs/VISION.md:54-65

実機確認 (レビュー時):
1. `export-key/collision.json::co-exposure-collision` は fixture 期待 ambiguous + 2 interpretations に対し、CLI は success/result={x:true}/exit0
2. `inheritable-parse/basic.json::ancestor-inherit-flowdown` は fixture 期待 `{"ttl":30,"sub":{"ttl":30}}` + sub.ttl source=inherit に対し、CLI は `{"ttl":30,"sub":{}}`、sources なし
3. それでも `just test` は wbtest 8/8 + e2e 2/2 green (= 現 gate が非準拠を見逃す)

修正要求: runner 処理を CLI にコピーせず、**kuu.mbt に parse + env/config/inherit/default/tty resolve + resolve 後 constraint + collision promotion + canonical result/sources/warnings 射影を担う production front door を設け、CLI は wire encode のみにする** (→ kuu.mbt の issue front-door-parse-missing-postprocessing で追跡)。

## Major

### M-1 warning marker が effects に漏れ、warnings の JSON 形も spec と違う

- CLI sentinel 除外は `[]`/`{}`/空文字だけ: impl/mbt/cli/src/lib/wire.mbt:446-451
- 参照実装は #row/#fire/action/deprecation marker も除外: kuu.mbt の src/core/resolve.mbt:66-75
- CLI は `warnings_of()` を文字列配列化: impl/mbt/cli/src/lib/wire.mbt:144-152
- spec は `[{"element":"port","kind":"deprecated"}]`: spec の docs/CONFORMANCE.md:89、fixtures/alias-parse/deprecated.json:13-23

実機では deprecated alias で effects に `@depr:port` が露出し warnings は `["port"]`。

修正要求: sentinel 除外と warning 構造化を production projection API へ集約し、CLI ローカルコピーを廃止 (C-1 と同根 — front door 側の射影 API に含める)。

### M-2 e2e が fixture expect を審判にしておらず silent pass 可能

- fixture から読むのは `.definition` のみ。case id/args/expect を読まず argv と期待値を hardcode: impl/mbt/justfile:81-131
- unit 対象も `cli/src/lib` のみで argv parser `main.mbt` は対象外: impl/mbt/justfile:54-57
- fixture case 削除・改名、同 definition の意味変更時も古い impl + 古い hardcode が一致すれば green。今回 C-1 を実際に見逃した

修正要求: 選択 case の id/args/expect を fixture 本体から取得。最終的には全 parse/complete/definition_error/lower fixture を CLI adapter 経由で実行し CONFORMANCE の緩比較規則で比較。

### M-3 CI 用 SHA-pin checkout を setup が拒否

- DR-0001:30-33 は CI で `deps/kuu.mbt` に SHA-pin checkout を想定
- real directory を CI checkout として残す分岐はある (impl/mbt/justfile:39-40) が、その前に sibling kuu.mbt の存在を要求して exit する (impl/mbt/justfile:25-31)

修正要求: まず deps/kuu.mbt real directory を受理し、symlink/未作成の場合だけ sibling を検査。dependency version 0.1.0 自体は一致 (cli/moon.mod:13-16 ↔ kuu.mbt の moon.mod:1-4)。

### M-4 subcommand と JSON envelope が upstream 構想から分岐

- upstream は parse/complete/lower/validate(=definition_error) と fixture protocol 直接転用を規定: spec の docs/VISION.md:54-65
- 現 CLI は lower 不在: impl/mbt/cli/src/main/main.mbt:43-55
- parse は outcome、complete は candidates のみで outcome=complete なし: impl/mbt/cli/src/lib/wire.mbt:78-86
- validate は独自 ok bool: impl/mbt/cli/src/lib/wire.mbt:104-127
- parse_definition reject は errors のみ: impl/mbt/cli/src/lib/wire.mbt:45-49,300-304

修正要求: CONFORMANCE outcome union をそのまま使うか CLI 独自 protocol を設計して VISION を改訂するか明示選択。一部だけ借用する現状は他言語互換判定が曖昧。**= v1 入出力契約の正本化そのもの、kuu-ux 設計と合わせて裁定**。

### M-5 argv parser が余剰引数を黙殺し help/stdout 契約も不一致

- validate は path 先頭だけ読み余剰引数を検査しない: impl/mbt/cli/src/main/main.mbt:136-147。実機 `kuu validate def.json extra` が exit0
- README は「全 output が stdout の単一 JSON object」: impl/mbt/README.md:48-49
- 引数なし/unknown/help は human text を stdout: impl/mbt/cli/src/main/main.mbt:34-55
- 子 subcommand 引数なしも個別 help でなく JSON error のみ: impl/mbt/cli/src/main/main.mbt:68-72,93-97,136-141

修正要求: validate 余剰を usage error、top/各 subcommand help、stdout machine JSON・stderr human text 等を正本化 (kawaz の CLI 設計好み: 引数なしは usage、全レベル共通)。

## Minor

### m-1 e2e build mode と binary path が不一致、fallback が stale/別 binary を拾いうる

`moon build --target native` 後に release path を探し、無ければ `_build/native` 以下の最初の `main*` executable を採用 (impl/mbt/justfile:67-76)。workspace に別 executable/stale build が増えると誤実行しうる。修正要求: build mode と exact artifact path を一致させ `find|head -1` を削除。

### m-2 ensure-clean が push gate に未接続

定義 (justfile:40-43) はあるが push dependency は check-on-default-branch/lint/test のみ (justfile:64-67)。修正要求: bump-semver 側が同保証なら dead recipe 削除、保証しないなら push dependency へ。

### m-3 README が fixture 接続範囲を過大表現

English README は parse/complete/validate が spec fixtures に接続済みと読める (README.md:21-24)。impl README も「CLI e2e against real fixture」と表現 (impl/mbt/README.md:31-38)。実際の real fixture e2e は parse 2 本のみで complete/validate は inline wbtest。修正要求: 「parse の代表 2 case のみ」と明示。

### m-4 指示なしの `-h` short alias

`-h` を top-level help alias として受理 (impl/mbt/cli/src/main/main.mbt:47-50)。kawaz の CLI 設計好みは「short alias を明示指示なしに追加しない」。正本化前なら外すか採用判断を契約へ。

## Nit

- n-1: PoC 仮置き番号ずれ — header は ambiguous=#1、exit=#2 だが実装コメントは ambiguous を #2 (impl/mbt/cli/src/lib/wire.mbt:7-18,177-179)
- n-2: README の PoC note 数が自己矛盾 — 同一 README で three PoC notes / two remaining PoC items (impl/mbt/README.md:48-54)

## v1 契約正本化前に決めること (レビュー結語)

1. canonical parse API 責務: raw vs full parse+resolve、env/config/inherit/default/tty の供給者、requires/collision promotion の実行層
2. subcommand 集合: parse/complete/lower/validate(=definition_error)/help
3. JSON protocol: CONFORMANCE outcome union 採否、sources、構造化 warnings、ambiguous result/claimants、definition-error、complete outcome、message/hint 規範性
4. exit code matrix: success / parse failure / ambiguous / definition reject / malformed def JSON / usage / file I/O
5. human/machine 境界: stdout/stderr、引数なし help、subcommand help、unknown/extra、`-h`
6. completion 入力: `-- <args_before>...` vs JSON array、args_after、word_before/after
7. 依存再現性: kuu.mbt SHA pin 正本、local moving-main symlink と CI pin、version 一致だけで足りるか、checkout 受理条件
8. conformance gate: 全 fixture、case ID、fixture args/expect 直接消費、field-specific comparison、全 query 網羅

**推奨順: 完全 front door API → 全 fixture CLI gate → JSON/exit/argv 契約正本化** (表層を先に固定すると破壊変更になる)。

## Positive (問題なし確認)

- `result_to_json` の 4 素材 (apply_export_keys / accum_cells / apply_export_to_defaults / none_cells) は runner と同形
- `export_map(ast)` 経路、completion candidate 6 面、MoonBit dependency version 0.1.0 一致
- `just lint` green、`just test` green、検証後 jj status clean

## 消化状況 (統括、2026-07-15)

- C-1 + M-1: kuu.mbt の issue `front-door-parse-missing-postprocessing` (bug) で追跡 — production front door 側に後段処理 + 射影 API を設ける方向。**レビュー推奨順 (front door API が先、表層契約は後) を採用**
- M-2 / M-3 / M-5 / m-1〜m-4 / n-1〜n-2: kuu-cli 側の実装修正 (次サイクル、worker 委譲可)
- M-4 + 「v1 契約正本化前に決めること」8 項目: 設計判断 — kuu-ux 設計と合わせて扱う (項目 6 の completion 入力形と項目 3 の envelope は DR-053 §3 / DR-073 の interpretations 射影と同じ束)
