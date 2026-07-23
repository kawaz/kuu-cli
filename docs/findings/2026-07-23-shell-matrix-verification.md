# shell 補完マトリクス実機検証 (findings §5.1 段 1)

- 日付: 2026-07-23
- 対象: spec `templates/completion.{zsh,bash,fish}` glue + `templates/TRANSLATION.md`
- 手法: tmux (`send-keys` + `capture-pane`) による対話端末での <TAB> 観測。fabricated wire 応答を返す fake binary + mock binary + `kuu completion query` の 3 経路を組み合わせ
- 検証者環境: macOS Darwin 25.5.0 arm64
- 根拠: spec `docs/findings/2026-07-23-completion-ux-layer-plan.md` §5.1 / `docs/decisions/DR-117-completion-generator-abi.md` §4

## 検証環境棚卸し

| shell | binary | version | 検証結果 |
|---|---|---|---|
| zsh | `/etc/profiles/per-user/kawaz/bin/zsh` | 5.9.1 | ✓ 実機検証済 |
| bash 5.x | `/etc/profiles/per-user/kawaz/bin/bash` | 5.3.9 | ✓ 実機検証済 |
| bash 3.2 | `/bin/bash` (macOS 同梱) | 3.2.57 | ✓ 実機検証済 (縮退経路) |
| fish | `/opt/homebrew/bin/fish` | 4.8.1 | ✓ 実機検証済 (2026-07-24 補追) |

fish は 2026-07-24 に brew install で環境用意し補追。fish セクションは本 findings §「fish 補追 (2026-07-24)」を参照。

## 手法

### fake binary (fabricated wire 応答)

各セルを独立に検証するため、query が返す wire を任意に固定する fake binary を作成:

```bash
# fake: 純候補 3 個, 説明列付き, 逆順で order 検証
printf 'cherry\tred fruit\n'
printf 'apple\tgreen fruit\n'
printf 'banana\tyellow fruit\n'

# fake: 中間 1 個に nospace
printf 'apple\tred\n'
printf 'banana\tyellow\tnospace\n'
printf 'cherry\tdark\n'

# fake: shell_action だけ
printf ':shell_action files\n'
printf ':shell_action dirs\n'
```

`kuu completion generate` で glue を吐かせ、`--binary` に fake を指定。fake が glue から起動されて fixed wire を返す形。

### tmux ハーネス

```bash
tmux new-session -d -s <s> -x 200 -y 60 "<shell> -f"    # -f: no rc
tmux send-keys -t <s> "PS1='PROMPT> '" Enter
tmux send-keys -t <s> "source <glue>" Enter             # zsh は compinit 前置
tmux send-keys -t <s> "clear" Enter
tmux send-keys -t <s> "myapp "                           # 入力
tmux send-keys -t <s> $'\t'                              # TAB
tmux capture-pane -t <s> -p
```

bash は候補一覧を出すのに TAB 2 回押しが要る (`show-all-if-ambiguous` の反映)。

## 観測マトリクス (期待 vs 実態)

### 順序保持 (input `cherry, apple, banana`)

| shell | 期待 | 実測 | 判定 |
|---|---|---|---|
| zsh 5.9.1 | 入力順 (`cherry apple banana`) | `cherry, apple, banana` | ✓ `_describe -V` で unsorted group |
| bash 5.3.9 | 入力順 (nosort) | `cherry apple banana` | ✓ `compopt -o nosort` |
| bash 3.2.57 | 縮退 (sort) | `apple banana cherry` | ✓ 諦め仕様通り (`compopt -o nosort` は unknown option でエラーになるが glue の `\|\| true` で無視) |

### 説明列

| shell | 期待 | 実測 | 判定 |
|---|---|---|---|
| zsh 5.9.1 | `cand  -- desc` 形 | `cherry  -- red fruit` 形で表示 | ✓ `_describe` の native 説明列 |
| bash 5.3.9 | 説明列は落ちる (bash 標準の縮退) | `cherry apple banana` (説明列なし) | ✓ 仕様通りの縮退 |
| bash 3.2.57 | 同上 | 同上 | ✓ |

### nospace (input `apple, banana(nospace), cherry`)

| shell | 期待 | 実測 | 判定 |
|---|---|---|---|
| zsh 5.9.1 | banana のみ nospace 挙動 (per-candidate) | 2 group 表示: normal (`apple, cherry`) + nospace (`banana`) | ✓ per-candidate 実現、ただし cross-group 順序は崩れる (制約) |
| bash 5.3.9 | 関数単位 nospace (per-candidate 不可) | 全候補列挙、`compopt -o nospace` 立てる | ✓ 仕様通りの縮退 (DR-117 §4.1) |
| bash 3.2.57 | 同上 | 同上 | ✓ |

### `:shell_action files`

| shell | 実測 | 判定 |
|---|---|---|
| zsh 5.9.1 | cwd の全 file/dir 表示 (`README.md`, `docs/`, `LICENSE` 等) | ✓ `_files` |
| bash 5.3.9 | 同上 (dotfile 含む) | ✓ `compgen -f` |
| bash 3.2.57 | 同上 | ✓ |

### `:shell_action dirs`

| shell | 実測 | 判定 |
|---|---|---|
| zsh 5.9.1 | dir のみ (`docs/, scripts/, templates/` 等) | ✓ `_files -/` |
| bash 5.3.9 | dir のみ | ✓ `compgen -d` |
| bash 3.2.57 | dir のみ | ✓ |

### words / cword

mock binary (env プロトコル判定 + `kuu completion query` へ橋渡し) 経由の end-to-end で:
- zsh: `CURRENT - 1` 変換で `KUU_COMPLETE_INDEX` が正しく渡り、query が候補を返す ✓
- bash: `COMP_CWORD` をそのまま渡し、query が候補を返す ✓
- `COMP_WORDBREAKS` による `--flag=value` 分割の再結合は未実装 = TODO (DR-117 §3.4 末尾) / 単純ケースでは未発生

## 検証中に発見して修正した glue bug

### zsh: nospace group の display bug

修正前 (`templates/completion.zsh`):

```zsh
compadd -V ${PROGRAM_NAME}-nospace -S '' -d ns_pairs -- "${ns_pairs[@]%%:*}"
```

`-d ns_pairs` に渡す `ns_pairs` は `insert:desc` 形式 (`_describe` 用) で、`compadd -d` は表示配列を要求するため、候補一覧に `banana:yellow` のような raw ペアが表示された。

修正後: display 用配列 `ns_display` (`"$ins  -- $d"` 形式) を別途組み立てて渡す形に変更。実機再検証で `banana  -- yellow` 表示を確認。

### zsh: `local` 印字問題

修正前 は `local p ins d` (値なし宣言) を使用していたが、外側 for 内で既に `ins=...` に代入済みの `ins` に対して値なし `local ins` を書くと、zsh は `typeset` 互換で現在の binding (`ins=cherry` 等) を stdout に印字してしまう (実測)。補完候補一覧の外に `ins=cherry` が漏れて UI 汚染。

修正後: `local p='' d=''; ins=''` と初期値付き宣言に変更。実機再検証で漏れ解消を確認。

## fish 補追 (2026-07-24)

fish 4.8.1 (`brew install fish`) を用意して段 1 の残セルを実機検証した。方法は zsh/bash と同型 (tmux + send-keys + capture-pane、fake binary で wire を fixed emit、mock binary で `kuu completion query` 経路の end-to-end)。

### 観測マトリクス (fish 4.8.1)

| セル | 期待 | 実測 | 判定 |
|---|---|---|---|
| 順序保持 (`cherry, apple, banana`) | 諦め (fish 常時ソート) | 表示 `apple, banana, cherry` (アルファベット順) | ✓ 諦め仕様通り (DR-116 §2 の順序規則は fish で成立しない、DR-117 §4.2 `:keep_order` 不採用と整合) |
| 説明列 | native `候補\t説明` 素通し | `apple  (green fruit)` 形式で表示 (fish のカッコ表記) | ✓ TAB 素通し成立 |
| nospace 一般候補 (`apple, banana(nospace), cherry`) | per-candidate 表現手段なし | 3 候補列挙、unique match 時は必ず末尾に空白挿入 (`apple<TAB>X` → `apple X`、`banana<TAB>X` → `banana X`) | ✓ per-candidate nospace は fish で表現できず、glue が flag 列を落とす縮退は正当 |
| nospace `--flag=` 形 (insert_form:"eq" 相当) | `=` 直後の空白 native 抑制 | `--port=<TAB>X` → `--port=X` (空白入らず) | ✓ eq 経路のみ縮退が実効的に機能 |
| `:shell_action files` | cwd file/dir 混合列挙 | `LICENSE, README.md, subdir1/, subdir2/` を実機観測 | ✓ `__fish_complete_path` |
| `:shell_action dirs` | dir のみ | `subdir1/, subdir2/` + `(Directory)` 表示 | ✓ `__fish_complete_directories` |
| 未知 directive | 無視 | `:unknown_directive foo\napple` 応答 → apple のみ候補化 | ✓ `case ':*'` 経路 |
| words/cword (末尾空白) | `myapp foo bar <TAB>` で `KUU_COMPLETE_INDEX=3`、argv 末尾は empty current-token | 修正後 glue で observed | ✓ 修正後 (下記 §「fish 補追で発見・修正した glue bug」参照) |
| words/cword (中間トークン) | `myapp foo ba<TAB>` で `KUU_COMPLETE_INDEX=2`、argv 末尾は "ba" | observed | ✓ |

### fish 補追で発見・修正した glue bug

**cword 算出 bug** (修正前 `templates/completion.fish`、spec 側):

```fish
set -l words (commandline -o)
set -l cword (math (count $words) - 1)
```

`commandline -o` は「完了済みトークン列」で、末尾空白時に empty current-token を含めない (fish 4.8.1 実測):

- `myapp foo bar ` (末尾空白) → `commandline -o` = [myapp, foo, bar]、count=3 → cword=2 (最終確定 "bar" を指す)。DR-117 §3.4 の期待値 3 (空の新規位置 = 新規引数を補完中) と齟齬
- `myapp foo ba` (中間) → `commandline -o` = [myapp, foo, ba]、count=3 → cword=2 (mid-token "ba" を指す)。これは正しい

つまり末尾空白ケースでのみ cword が 1 ずれる。修正後:

```fish
set -l cut_toks (commandline -oc)   # -c: カーソル位置より前の完了済みトークン
set -l cur_tok (commandline -ct)    # -t: カーソル位置の現在編集中トークン (末尾空白時は空文字)
set -l words $cut_toks $cur_tok
set -l cword (count $cut_toks)
```

mock binary 経由の実機検証で:
- 末尾空白: `KUU_COMPLETE_INDEX=3 argv=U fish myapp foo bar ` (末尾に empty 引数) ✓
- 中間トークン: `KUU_COMPLETE_INDEX=2 argv=U fish myapp foo ba` ✓

spec `templates/completion.fish` に反映済み (該当コミット参照)。kuu.mbt 側の埋込 template (`deps/kuu.mbt/src/kuu/completion_templates.mbt` L282- 付近) は spec templates とは別レポの vendor コピーであり、次の kuu.mbt push 窓で追従する必要がある (本 findings 起票のみ、修正はスコープ外)。

### fish 補追で見つけた TRANSLATION.md 記述の精度不足

修正前の spec `templates/TRANSLATION.md` の fish/nospace 備考には「fish は既定で `--flag=` の後ろに空白を入れない挙動がある」とだけ書かれていた。読み方によっては「一般候補への per-candidate nospace も fish 既定で近似される」と誤解可能。実機で:

- 一般候補 (`apple`, `banana`, `cherry`) の unique match は **必ず末尾空白挿入** (`banana<TAB>X` → `banana X`)
- `--flag=` 形候補のみ `=` 直後の空白を native 抑制 (`--port=<TAB>X` → `--port=X`)

両者を分離観測し、TRANSLATION.md nospace/fish セルと fish 経路の glue コメントを明示区別する記述に更新した。

### fish で smoke test を pass にした変更

`impl/mbt/tests/smoke/completion_smoke.sh` の fish セクションを bash と同型化 (mock binary で `kuu completion query` 経路へ橋渡し)。修正前は `--binary "$KUU_CLI"` のまま fish glue を生成しており、kuu-cli standalone は form-A env プロトコルに応じないため glue の env 呼び出しが unknown subcommand で失敗 → `or return 1` で候補空 → fail していた。修正で bash と共通の mock binary を fish glue にも指定するよう変更。実機 `just smoke` で 6/6 pass を確認 (2026-07-24)。

## 未検証・残 TODO
- **kuu.mbt 埋込 fish template 追従**: spec `templates/completion.fish` の cword 算出修正は spec 側のみ反映済み。`deps/kuu.mbt/src/kuu/completion_templates.mbt` の埋込 template は別リポ (kawaz/kuu.mbt) のため未追従。kuu.mbt 側での修正 + kuu-cli の deps 更新 + smoke 再確認をロックステップウィンドウで実施する必要あり
- **bash `COMP_WORDBREAKS` 分割再結合**: 単純ケースでは未発生だが `--flag=value` パターンの実機検証は未 (DR-117 §3.4 の TODO 残)
- **cross-group 順序 (zsh nospace)**: 混在時に normal/nospace で group 境界が入り DR-116 §2 の "input 順そのまま" 表示にならない。現状の 2-group 分割は per-candidate nospace のための正当な縮退 (代替手段なし) と判断し、制約として記録 (spec TRANSLATION.md に注記追加)
- **説明列の bash 表示**: bash では原理的に candidate 文字列に混ぜられない (混ぜると補完入力に埋め込まれる)。cobra V2 型の列フォーマット擬似表示は現 glue で未実装 — 実装するなら描画は端末幅・マルチバイト依存で高リスク、現時点で見送り (DR-117 リスク節通り)

## 参照

- spec `templates/TRANSLATION.md` (本検証の反映先、status 列更新済み)
- spec `templates/completion.{zsh,bash,fish}` (glue、zsh は 2 bug-fix 適用済み)
- spec `docs/findings/2026-07-23-completion-ux-layer-plan.md` §5.1 (検証方法の正本)
- spec `docs/decisions/DR-117-completion-generator-abi.md` §4 (行文法) / §3.4 (words/cword)
- spec `docs/decisions/DR-116-completion-generator-policy.md` §2 (順序規則)
- 本リポ `impl/mbt/tests/smoke/completion_smoke.sh` (段 2 の常設煙テスト)
