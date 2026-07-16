# conformance sweep fail 全数分類 (UX-Q 裁定の一次データ)

日付: 2026-07-16。対象: impl/mbt PoC binary、kuu spec fixtures pin 07699749、kuu.mbt pin 8364b981。
`just impl-mbt-conformance` の fail 全件 (320 case / 415 key 不一致) を排他分類した棚卸し。
統括依頼 (r27m7): 4 系統仮説で説明し切れるか、真の実装 bug の混入有無、および
**「expect にあるが CLI に無い」(機能未実装) と「CLI にあるが expect に無い」(射影裁定) の区別**。

## 判明した事実

- sweep 母数の訂正: 当初の 547 case は glob `*/*.json` の 1 階層走査で、`fixtures/lowering/<sub>/` と `fixtures/value-sources/config/` 等の 2 階層 fixture を取りこぼしていた。find 走査に直した確定値は **parse 565 case 中 245 pass / 320 fail、skip 73** (complete / definition_error / lower 系の非 parse query)。
- fail は **12 カテゴリで全 415 key 不一致を尽くし、残余 (G-other) は 11 件**。4 系統仮説 (sources / message / Infinity / scope) はおおむね成立するが、それより大きい軸として **B (env/config/tty 入力の未対応) 106 件**が隠れていた。
- **真の実装 bug と思われるものは G-other 内の 1 件のみ**: `export-key/collision.json :: single-exposure-ok` — `--a` 単独発火で `result.x` が `false` (期待 `true`)。共露出検査は動くのに、単独露出時の値射影が「未発火 b の preset default false」で上書きされている疑い。ただし fixture の why 自体が「preset default が export_key 共露出に参加するかは要確認 (§divergence)」と記しており、**spec 側の未確定点と絡む**。kuu.mbt (参照実装) 側の挙動確認が先。
- 残りは全て「未実装機能」か「射影の仕様裁定待ち」に落ち、**分類不能な謎の fail はゼロ**。

### 方向別 (統括の追加観点)

| 方向 | カテゴリ | key 件数 |
|---|---|---|
| **expect にあるが CLI に無い** (機能未実装) | C (sources 全欠落 115=B 内含む), I (warnings:[] を省略), J (transform 欠落), K (ref-rows 集約未実装), D3 (path 欠落), B の大半 | ~215 |
| **CLI にあるが expect に無い** (射影裁定: 余剰を許すか) | D (message 余剰), D2 (空 element 余剰), E (scope 余剰) | 159 |
| **表現の相違** (どちらにもあるが形が違う) | F (Infinity), H (interpretations stub), A (キー順序のみ) | 42 |

## カテゴリ全数 (415 key 不一致、排他・優先順で分類)

| cat | 件数 | 内容 | 性格 |
|---|---|---|---|
| B-nonargs-input | 106 | case が `env` / `config` / `config_files` / `tty` 入力を要求するが CLI に注入手段が無い (`kuu parse` は argv のみ) | **機能未実装** (CLI インターフェイス設計 = UX-Q 領域に隣接。値源ラダー系 fixture が全滅する主因) |
| D-errors-message-extra | 81 | error object の `message` field が余剰 (それを除けば一致) | 射影裁定 (エラー面の厳密 subset か余剰許容か) |
| C-sources-missing | 67 | expect の `sources` に対し CLI 出力に key ごと無い (B と重複しない分) | **機能未実装** (front_door の sources 射影を wire.mbt が未接続) |
| E-effects-scope-extra | 52 | effects の `scope` field が余剰 (それを除けば一致) | 射影裁定 |
| D2-errors-empty-element | 26 | `element:""` (空文字) が余剰 (del すれば一致)。unexpected_token 系で element 無帰属のケース | 射影裁定 (空値は省略すべきか) |
| A-order-only | 25 | JSON 意味論では等値、object キー順序のみ相違 | **比較器の問題** (CONFORMANCE §3 の緩比較未実装。case 単位ではこの 25 key だけで fail している case が 22 = 緩比較導入で即 +22 pass) |
| K-ref-rows-aggregation | 20 | ref-template / repeat rows 系で result の行集約が空 (`{"hlcolors":[]}` vs 期待の行配列)、effects の scope 付与も違う | **機能未実装** (rows 集約が resolve/export 射影に未接続) |
| G-other | 11 | 下記 | 個別 (実装 bug 候補 1 + 未実装系 10) |
| H-interpretations-poc-stub | 9 | ambiguous の interpretations が空 object スタブ (wire.mbt「PoC 仮置き #1」の設計通り) | 既知の仮置き (UX-Q envelope 裁定待ち) |
| F-infinity-repr | 8 | float の Infinity を数値 MAX_VALUE で出す (期待は文字列 "Infinity") | 射影裁定 (JSON に Infinity が無い問題の表現規約) |
| I-warnings-empty-omitted | 5 | warnings が空のとき key 省略 (期待は `[]`) | 射影裁定 (空配列を出すか省くか) |
| J-effects-transform-missing | 4 | count 系 effects の `transform:"increment"` field 欠落 | **機能未実装** (count の transform 射影) |
| D3-errors-path-missing | 1 | error の `path:[]` 欠落 | 射影裁定 (D2 の裏面: 空 path を出すか) |

### G-other 11 件の個別判定

| fixture :: id (key) | 判定 |
|---|---|
| export-key/collision.json :: single-exposure-ok (result) | **実装 bug 候補 (唯一)**。ただし fixture why に spec 未確定 (§divergence) の注記あり、kuu.mbt 側の確認が先 |
| value-typing/positional-group-factory-config.json :: ×2 (result/effects) | K と同根 (group factory の行集約未実装)。fixture 名の "config" は定義側 factory 設定の意で B ではない |
| failure-actions/held-candidate.json :: ×2 (errors) | 期待が `{element,args_pos,kind}` のみで **reason すら持たない** = held error の縮約射影が未実装 (got は完全 error)。D の変種だが「期待の方が短い」ので射影裁定側 |
| matcher-readings/prefix-guard-number.json :: undefined-into-number (errors) | 同上 (reason 無し期待) |
| multiple-parse/kv-map.json :: no-equals-piece-rejected (errors) | 同上 |
| repeat-parse/backtrack.json :: no-number-genuine-failure (errors) | **error の並び順**が相違 (args_pos 2,1 の順で期待、got は 1,2)。エラー整列規約の未実装/未裁定 |
| command-scope/early-close-viability.json :: constraint-not-consulted-on-exit (errors) | got に `path:["build"]` + message 余剰 (期待は path 無し)。D3 の裏面 = **path を出す/出さないの基準が case でまちまち** → 射影裁定に「path の出し分け規約」を含めるべき |
| failure-actions/tried-triggers-scope.json :: ×2 (errors/tried_triggers) | tried_triggers の scope 絞り込みが未実装 (ancestor spelling が混入) |

## 実用的な示唆 (UX-Q 裁定バッチへの入力)

1. **射影裁定 1 個 (余剰 field の扱い: message / scope / 空 element / 空 warnings / 空 path) で 165 key (~40%) が決着**する。厳密 subset 裁定なら CLI 側を削る、余剰許容裁定なら比較器を緩める、のどちらでも機械的に対応可能。
2. **緩比較 (キー順序無視) の導入だけで 22 case が即 pass** (245→267)。これは裁定不要 (JSON 意味論で自明) なので envelope 裁定を待たず前倒し可能。
3. **env/config/tty 注入は CLI インターフェイス設計そのもの** (フラグ形式・stdin 経由等の選択肢がある) なので UX-Q の subcommand/envelope 束に載せるべき。fixture の入力キーは `env` / `config` / `config_files` / `tty` の 4 種 (complete 系の `args_before`/`args_after` は既対応)。
4. sources 射影 (67+) と rows 集約 (20+) は裁定より **kuu.mbt front_door の露出 API 確認**が先 (露出済みなら wire.mbt の接続だけで済む可能性)。
5. 実装 bug 候補は single-exposure-ok の 1 件のみ。preset default × export_key の spec 未確定点に絡むため、kuu spec 側の §divergence 解消と同時に扱うのが安全。

## 検証の詳細

- 収集: 全 parse fixture case を CLI 実行し、expect の**全 top-level key** を jq 意味論比較 (sweep 本体は最初の不一致で break するが、棚卸しは break せず全 key を記録)。415 行の JSONL。
- 分類: 上表の順で排他判定 (先勝ち)。A → B → C → I → D → D2 → D3 → E → J → F → H → K → G。
- B の判定は「case が args/expect/id/why 以外の入力キーを持つ」で機械判定 (56 case が該当、うち fail は key 単位 106)。
- 再現: scratchpad の collect-fails.sh (セッション一時物、リポには含めない)。sweep 本体 `just impl-mbt-conformance` で per-directory 集計まで再現可能。
