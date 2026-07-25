# kuu-cli を自己 definition 駆動へ書き直す (2026-07-25)

spec 側 dogfooding サイクル (`kawaz/kuu` `docs/findings/2026-07-24-kuu-cli-dogfooding-plan.md`)
の D1〜D4 のうち、kuu-cli リポで起きたことの生記録。

## 完了サマリ

- **発端**: 敵対的レビュー台帳 (`kawaz/kuu` `docs/findings/2026-07-24-fresh-eyes-adversarial-review.md`)
  の H2-H9 / H14 = 「kuu を名乗る CLI 自身が CLI 慣習に反している」群。個別修理ではなく
  **kuu-cli の argv 解析を kuu 自身の definition で駆動する**書き直しで構造ごと消す方針
- **D1**: `impl/mbt/cli/kuu-cli.def.json` (368 行) を起草。表現力の穴は F1〜F9 として spec 側 findings
  (`2026-07-24-dogfooding-d1-expressiveness.md`) へ還流
- **D2** (`4855773f1013` refactor(cli): 自己 definition で dispatch を駆動): `main.mbt` を
  **878 行 → 625 行**へ全面書き直し。手書きの argv 走査を全廃し、`SELF_DEFINITION_JSON`
  (def.json を `just generate-self-definition` で `def_embedded.mbt` へ埋め込み) を
  `@kuu.parse_definition` → `@kuu.parse` → `@kuu.resolve` → `@kuu.output` に通し、
  得られた `result` object の形で dispatch する構造にした
- **D3** (`11baf1e90ed0` feat(cli): help 文言と bool hint を検証 / `9a9efc0732f4` test(smoke):
  補完 glue の self-dogfood 検証を追加): H6 の文言検査と H14 の hint、出荷 def.json をそのまま
  食わせる補完 self-dogfood を追加。H9 は spec 側で修理して pin bump (`0300198447f1`)
- **D4** (本 commit): README の exit code 節を実装と一致させ、この journal を書いた
- **現在 head**: kuu-cli `72049c54e835` / kuu.mbt pin `b23d9c5d` / spec pin `7268f01d`

## H 群をどう解消したか (実装参照は現行 head)

| ID | 指摘 | 解消形 |
|---|---|---|
| H2 | exit code が README と不一致 (読めないファイル / malformed JSON / parse 失敗が exit 0) | プロセス exit を決める場所を 2 箇所に集約: `main.mbt` の `emit_payload` (payload 級の非 0 を一律 **1** へ畳む) と `die_with(_, 2)` / `handle_self_failure` (kuu-cli 自身の command line 失敗 = **2**)。`CmdResult.exit` は payload 級であってプロセス code ではない、と `wire.mbt` の頭コメントに明記 |
| H3 | `--help` が stderr | `handle_self_failure` が `fired_action == Some("help")` を見て `print_self_help` → **stdout / exit 0** |
| H4 | `<subcmd> --help` が動かない | def.json の help option を `"global": true` で宣言しただけで全 scope に自然発生。**手書き分岐ゼロ** = dogfooding の価値実証点 |
| H5 | `--version` が無い | def.json に `{"name":"version","type":"string","long":[":set:0.0.0"],"global":true,"on_failure":true}`。dispatch は `result.version` の有無を見て `SELF_VERSION` を stdout へ |
| H6 | help 出力に DR 番号 + 日英混在 | def.json の文言を全文英語化。`just e2e` で `kuu --help` に DR 参照 0 件かつ**純 ASCII**を検査 (`impl/mbt/justfile` の self help 節) |
| H7 | stdin (`-`) 未対応 | `read_file_all` が `path == "-"` で `read_stdin_all()` (c_read ループ)。def.json 側の型は string のまま = パス解釈は I/O 層の責務 |
| H8 | 引数なしが exit 2 | `main` 冒頭の `args.length() == 0` 特判で root help + exit 0。**宣言席は要らない**が spec 側の裁定 (DOG-Q4γ=a): help をどう出すか・exit code をどうするかはアプリの裁量で、definition は関与しない |
| H9 | bash glue の TODO 平文焼き付き | kuu-cli 層ではなく **spec の `templates/completion.bash` が正本**。spec 側で実装 → kuu.mbt がテンプレ追従 → kuu-cli は pin bump のみ (下記「ハマり所 2」) |
| H14 | bool option が値要求で素人が詰む | `emit_bool_missing_operand_hint`: errors の `reason == "missing_operand"` かつ当該 element が def 内で `type: "bool"` のときだけ `hint: declare it as type "flag" if it takes no value` を stderr へ。wire 拡張は不要だった (def.json を引き当てれば型が分かる) |

## ハマり所と解決

### 1. 自己 parse が Ambiguous になって D2 が止まった (原因は kuu.mbt の bug)

**現象**: `kuu parse <def.json> -- parse ...` のように、`--` の後ろ (raw 域) の先頭に
サブコマンドと同綴りのトークンが来ると、自己 parse が Ambiguous に落ちる。kuu-cli の
def.json は `parse` / `complete` / `validate` … という command を持つので、
`kuu parse def.json -- parse def2.json` のような素直な argv で即踏む。

**切り分け**: kuu-cli 側の def.json の書き方 (dd の置き方・positional の Many) をいくら変えても
再現するので、engine 側を疑って統括が裏取り → **kuu.mbt の継続 (continuation) の bug** と判明。
dd (`--`) 発火後も command 境界の継続には `severed=false` が捕捉されたまま残っており、
親 scope へ resume した瞬間にその greedy face が復元されて、raw 域のトークンを
command trigger として再解釈していた。

**解決**: kuu.mbt `20df9ad3da4b` fix(parser): dd 継続の raw 状態を親背骨へ伝播 —
`src/internal/engine/cont.mbt` に `sever_cont` を新設し、dd 発火時に残り全 spine を
severed へ畳む。回帰は `src/kuu/eval_wbtest.mbt` の
`"REGRESSION dd continuation stays raw after returning from a command scope"`
(`["run","FILE","--","run","FILE2","--","z"]` → args が生のまま 4 個) で pin。
spec 側にも断面 fixture を追加 (`b22bedf57877`)。kuu-cli は pin bump で取り込み。

**教訓**: 「自分の def.json の書き方が悪い」で粘らず、engine 直の最小再現 (scope 2 段 + dd +
raw 域先頭に command 同綴り) を作って参照実装側を疑う方が早い。

### 2. H9 は「テンプレ文字列修正のみ」ではなかった

**見積り**: 台帳は H9 を「bash glue の TODO 平文焼き付き」= kuu.mbt の
`completion_template_bash` の文字列修正のみ、ABI 不変なので同乗可、としていた。

**実体**: (a) 正本は kuu.mbt ではなく **spec の `templates/completion.bash`** で、kuu.mbt 側は
そこからの生成物。修正は spec → kuu.mbt 追従 → kuu-cli pin bump の 3 リポ縦断になる。
(b) 焼き付いていた TODO 自体が**未実装の spec 準拠ギャップ**を指していた:
DR-117 §3.4 が要求する COMP_WORDBREAKS 分割の再結合 (`--flag=value` が
`[--flag, =, value]` に割れたまま binary へ転送されていた) が glue に無かった。

**解決**: spec 側 `9d290b0707ba` で glue に inline の再結合ループを実装
(`COMP_WORDBREAKS` から空白系を除いた集合を分割 char とし、単独の分割 char を直前 word へ
連結、cword も再結合後の index へ変換)。bash 5.3.9 / 3.2.57 × 5 ケースの実機マトリクスで
10/10 通過。COMP_WORDS ベースの再結合が空白情報を落とす原理的限界は
`templates/TRANSLATION.md` に既知の限界として明記し、忠実解 (COMP_LINE/COMP_POINT 再字句解析)
は spec 側 issue へ。kuu-cli 側は `0300198447f1` の pin bump + smoke の self-dogfood 検証
(`9a9efc0732f4`) で受け取り。

**教訓**: 「テンプレの文言直すだけ」に見える項目でも、**正本がどのリポにあるか**と
**TODO が何を指しているか**を先に確認する。

### 3. CI red: 日本語検出の grep が C locale で壊れる

**現象**: `just e2e` の「公開 help に日本語を漏らさない」検査がローカル (macOS, UTF-8 locale) では
green、Linux CI で red。

**原因**: `japanese_count=$(grep -Ec '[ぁ-んァ-ヶ一-龠]' <<<"$help_out" || true)` の
マルチバイト文字範囲が C locale (Linux CI 既定) の grep で `Invalid range end` になり、
その失敗が `|| true` に飲まれて**空文字**を返す。`assert_eq "$japanese_count" "0"` が
`got= want=0` で fail していた。

**解決**: `72049c54e835` — `non_ascii_count=$(LC_ALL=C grep -c '[^ -~<TAB>]' <<<"$help_out" || true)`
(`<TAB>` は justfile 内ではリテラルのタブ文字) のバイト単位判定へ置換。BSD/GNU grep で同じ挙動になり、かつ「公開 help は純 ASCII」という
より強い不変条件になる。

**教訓**: `|| true` は失敗を握り潰して**空文字**を通すので、その値を数値比較に使うと
「検査が壊れている」と「検査が通っている」の区別が付かない。locale 依存の文字クラスは
CI と手元で挙動が割れる典型。

### 4. H5 (`--version`) の実現形はプラン案と違った

プランの暫定案は「`type:"help"` 要素を name:"version" で置き、`fired_action=="version"` を
dispatch で判別」だったが、実装は `type:"string"` + `long: [":set:0.0.0"]` + `on_failure: true`
の形に落ち着いた (long 入口の値注入で version 文字列を席へ set する)。dispatch 側も
`fired_action` 経路と `result.version` 経路の両方を持つ (`handle_self_failure` /
`dispatch` の双方)。version の正式席は spec 側 DOG-Q1 の裁定待ちで、これは暫定形。

## exit code の実測マトリクス (README の根拠)

D4 で README に載せた表は、compiled binary
(`impl/mbt/_build/native/debug/build/kawaz/kuu-cli-mbt/main/main.exe`) の実測から起こした。
stdout / stderr は別ファイルへ分離して計測 (2026-07-25):

| 実行 | exit | stdout | stderr |
|---|---|---|---|
| 引数なし | 0 | root help 501B | — |
| `--help` | 0 | root help 501B | — |
| `parse --help` | 0 | parse scope help 885B | — |
| `--version` | 0 | `0.0.0` | — |
| `parse <def> -- --port 80 t` (成功) | 0 | 結果 JSON | — |
| `parse <def> --` (必須 positional 欠落) | 1 | failure JSON | — |
| `parse <存在しないファイル>` | 1 | — | `cannot read '...'` |
| `parse <非 JSON ファイル>` | 1 | `malformed_definition_json` JSON | — |
| `validate <reject される def>` | 1 | `ok:false` + errors JSON | — |
| `help <def> --path '["nosuch"]'` | 1 | `query-error` JSON | — |
| `nosuch` (未知サブコマンド) | 2 | — | `kuu: unexpected token` |
| `parse` (def 欠落) | 2 | — | `kuu: missing operand for definition` |
| `help <def> --path zzz` (非 JSON) | 2 | — | `kuu help: --path is not valid JSON` |
| `completion generate ... --shell tcsh` | 2 | — | `kuu: invalid command line` |

非対称が 1 箇所ある: exit 1 は原則 stdout に整った JSON を残すが、`<def.json>` が読めない場合
だけ stderr のプレーンテキスト (報告対象の definition 自体が無いため)。README にもその旨を書いた。

再現コマンド:

```sh
cd impl/mbt && just generate-self-definition && moon build --target native
BIN=_build/native/debug/build/kawaz/kuu-cli-mbt/main/main.exe
probe() { o=$(mktemp); e=$(mktemp); "$@" >"$o" 2>"$e"; printf 'exit=%d stdout=%dB stderr=%dB\n' "$?" "$(wc -c <"$o")" "$(wc -c <"$e")"; }
probe $BIN --help
```

## 節目レビュー (codex) 由来の修正

D4 の途中で codex-sol の節目レビューが入り、以下を追加で直した。

- **Ambiguous 提示が DR-118 §3 違反** (`f32bff29`): 自己 parse が Ambiguous に落ちた時の診断が
  `@kuu.resolve_interpretation` を呼んでいた。これは「解釈を 1 つ選んで前進する」API であって
  比較表示用ではなく、値源ラダーを適用するので env/config/default 由来の値が比較ビューに混ざる。
  加えて resolve に失敗した候補は `interpretation failed during resolve` に潰れ、parse 相では
  有効だった内容が消えていた。玄関 API の `@kuu.output_of_interpretation` へ置換
  (`wire.mbt` の interpretations 生成側は元から同 API を使っていた)。
  **皮肉なことに kuu-cli 自身の README がこの正しい規定を書いていた** — 文書と実装の
  双方向チェックが効いていなかった例
- **プロセス境界テストの未達** (`f78ccae0`): プラン §4.2 層 2 は「exit code / stream 分離 /
  stdin / --version を 1 ケースずつ固定」を要求していたが、既存 e2e は command substitution で
  stdout しか見ておらず stderr 空・exit 0 を assert していなかった。exit / stdout / stderr を
  個別ファイルへ採取する `proc_case` を足して 9 ケース pin
- **help 文言検査が root のみ** (`362dddd4`): renderer は scope ごとに文言を組むので root だけでは
  H6 の gate にならない。8 scope へ拡張
- **bash 再結合の検証が記号 1 種に偏り** (`4fc69efa`): `=` だけで、連続 break char・先頭 break
  char・空 word の分岐を踏んでいなかった。spec の再結合規則から期待値を導出して 5 形追加 —
  5 ケースとも実装と一致 (未検証範囲だったがオフバイワンは無し)

テストを足す時は **canary で red を確認**してから commit した (期待 exit を 2→0、期待 stderr を
empty→nonempty、stdout の ERE を通らない値、cword を 3→2、再結合語を `=value`→`value` の 5 本)。
「green だから通っている」は検知力の証明にならない。

## 残課題 / 観察

- **`tests/self/definition.sh` の jq 前処理はもう要らない**: 冒頭で
  `jq 'del(."$schema") | (.options[] | select(.name=="version")) |= del(.on_failure)'` して
  から食わせているが、`$schema` の inert 受理 (F7 / DOG-Q3=a) と汎用 `on_failure` の受理 (F8) が
  kuu.mbt に入ったので、**生の `cli/kuu-cli.def.json` をそのまま食わせても全 case 同結果**
  (2026-07-25 実測: validate `ok:true`、`--version` → `result.version == "0.0.0"`、
  `parse --help` → `fired_action == help`、排他違反 → `exclusive_group_violated`)。
  前処理と TODO コメントを外せる
- **help に `--version <VALUE>` と表示される**: version option を `type:"string"` で置いた副作用で
  value_name が出る。実際には値を取らない (long 入口が `:set:` で注入する) ので表示が実態とずれる。
  DOG-Q1 で version の正式席が決まるまでの暫定形の粗
- **`kuu help --help` と `kuu completion --help` が root help を出す** (H4 の残穴、要裁定):
  8 scope の help 検査を足す過程で発見。実測 (2026-07-25、Usage 行で判定):

  | argv | Usage 行 | 判定 |
  |---|---|---|
  | `kuu --help` | `Usage: kuu [OPTIONS] <COMMAND>` | 正 |
  | `kuu parse --help` | `Usage: kuu parse [OPTIONS] [--] <DEF_JSON> [ARG]...` | 正 |
  | `kuu complete --help` / `kuu validate --help` | 各 scope | 正 |
  | `kuu completion generate --help` / `kuu completion query --help` | 各 scope | 正 |
  | `kuu help --help` | `Usage: kuu [OPTIONS] <COMMAND>` | **root へ落ちる** |
  | `kuu completion --help` | `Usage: kuu [OPTIONS] <COMMAND>` | **root へ落ちる** |

  `kuu help` (引数なし) は正しく help scope を出すので `cmd_help_text` の path 解釈は健全
  (`kuu help <def> --path '["completion"]'` も正しい scope を返す)。落ちるのは
  **required 引数を持たない中間 scope** の 2 つだけ。`kuu completion --help` は自己 parse が
  success になり (`result = {"help": true, "completion": {}}`)、dispatch が
  `print_self_help([])` で常に root path を渡すのが原因。`kuu help --help` は result が
  `{"help": {...}}` (help command と help option が同じキーを取り合う) で経路が別、こちらは
  原因未特定。required を持つ scope は failure 経路に落ち、`failure_path` が errors の path から
  scope を復元するので正しく動いている = **成功経路に scope 復元が無い**のが本質。
  修正には「help がどの scope で立ったか」を result から辿る処理が要り、実装方針の裁定待ち
- **`--env` の piece_filters reject は usage error にならない**: `kuu parse def.json --env NOEQ -- ...`
  は `^[^=]+=.*$` の piece_filter で `--env` の解釈が落ち、`--env NOEQ` が **raw 域の args へ流れて**
  対象定義の parse 失敗 (exit 1) になる。`main.mbt` の `split_once` 失敗による exit 2 経路には
  到達しない。kuu の意味論 (trigger 不成立 → 別解釈へ) としては筋が通っているが、
  利用者から見た診断は分かりにくい (対象定義のエラーとして出る)。spec 側へ観察として渡す候補
