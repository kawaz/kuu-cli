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
| fish | — | 未 install | — 未検証 (環境なし) |

fish は当該環境に無いため、fish 関連セルは spec TRANSLATION.md でも `未検証 (環境なし)`。fish 環境を用意した時点で本 findings に補追する。

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

## 未検証・残 TODO

- **fish 全セル**: 環境が無い。fish install 後に補追
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
