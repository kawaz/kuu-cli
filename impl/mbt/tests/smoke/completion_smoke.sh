#!/usr/bin/env bash
# completion_smoke.sh — DR-117 §8.2 の glue 常設煙テスト (findings 2026-07-23 §5.2、M4)。
#
# 目的: `kuu completion generate` が吐く glue script が (i) 各 shell の syntax-check を通ること、
# (ii) bash / fish の非対話ハーネスで補完関数を直接駆動して期待候補が得られること — の 2 点を
# CI 常設可能な範囲で確認する。表示レベル (順序・nospace の実挙動) は段 1 の tmux 実端末
# マトリクス (findings §5.1) の担当で本 script では扱わない。
#
# scope 限界 (findings §5.2 準拠):
#   - zsh: 非対話で compdef 関数を呼ぶには compinit が要り、CI 環境依存が大きい。ここでは
#     zsh -n の syntax-check のみ。関数直呼びレベルの検証は段 1 側へ。
#   - bash: 3.2 系での挙動差分は macOS 同梱 bash が 3.2 の場合のみだが、実行環境の bash に
#     依存する。存在する bash で syntax-check + 関数直呼び 1 ケースを行う。
#   - fish: `fish -c 'complete -C ...'` で候補列挙 (最も自動化が素直)。fish 未インストール = skip。
#
# 使い方: KUU_CLI=<compiled main.exe path> KUU_CLI_DEF=<kuu-cli.def.json> ./completion_smoke.sh
# CI では justfile smoke task 経由。ローカルでは `just impl-mbt-smoke`。

set -euo pipefail

: "${KUU_CLI:?KUU_CLI must be set to compiled kuu-cli main.exe path}"
: "${KUU_CLI_DEF:?KUU_CLI_DEF must be set to cli/kuu-cli.def.json (self-dogfood section)}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# minimal test definition (spec wire minimum: name + long option) — 実 fixture の subobject を
# 使わないのは smoke test が pin depend しないようにするため (fixture 改廃で smoke 落ちるのを避ける)。
def_json="$tmpdir/def.json"
cat > "$def_json" << 'EOF'
{
  "name": "myapp",
  "options": [
    {"name": "port", "type": "number", "long": true, "completer": "files"},
    {"name": "verbose", "type": "string", "long": true}
  ]
}
EOF

# ---- 生成 3 shell ---------------------------------------------------------
uuid=SMOKE-UUID-fixed-for-determinism
for shell in zsh bash fish; do
  "$KUU_CLI" completion generate "$def_json" \
    --shell "$shell" --binary "$KUU_CLI" --uuid "$uuid" \
    > "$tmpdir/comp.$shell"
done

pass=0
fail=0
skip=0
report() { # ok|fail|skip name reason
  local status="$1" name="$2" reason="${3:-}"
  printf "[%s] %s%s\n" "$status" "$name" "${reason:+ — $reason}"
  case "$status" in
    ok) pass=$((pass+1));;
    fail) fail=$((fail+1));;
    skip) skip=$((skip+1));;
  esac
}

# 形態 A の env プロトコルは self-embedded kuu-core binary (DR-117 §6 形態 A) を前提とし、
# kuu-cli standalone (形態 B) はこのプロトコルに応じない。この gap を埋める mock binary の
# factory を 2 つ持つ:
#   make_query_mock    <out> <def_json> — KUU_COMPLETE env + UUID argv 一致を判定して
#     `kuu completion query` (形態 B) へ橋渡しする。glue の動作を kuu-cli の query capability
#     で end-to-end に検証する用 (KUU_COMPLETE_INDEX を --cword に写す)。
#   make_recorder_mock <out> <log>      — 受け取った index / words をそのまま log に書き出して
#     終わる。glue が組み立てた **words / cword の形そのもの** を assert する用 (候補生成側の
#     挙動から独立させて素材の受け渡しだけを見る)。
make_query_mock() {
  local out="$1" def="$2"
  cat > "$out" << MOCK
#!/usr/bin/env bash
set -e
[[ "\$KUU_COMPLETE" == "$uuid" && "\$1" == "$uuid" ]] || { echo "mock: env/argv mismatch (KUU_COMPLETE=\$KUU_COMPLETE argv1=\$1)" >&2; exit 2; }
shift  # UUID
shift  # shell name
if [[ -n "\${KUU_COMPLETE_INDEX:-}" ]]; then
  exec "$KUU_CLI" completion query "$def" --cword "\$KUU_COMPLETE_INDEX" -- "\$@"
else
  exec "$KUU_CLI" completion query "$def" -- "\$@"
fi
MOCK
  chmod +x "$out"
}

make_recorder_mock() {
  local out="$1" log="$2"
  cat > "$out" << MOCK
#!/usr/bin/env bash
set -e
[[ "\$KUU_COMPLETE" == "$uuid" && "\$1" == "$uuid" ]] || { echo "mock: env/argv mismatch" >&2; exit 2; }
shift  # UUID
shift  # shell name
{ printf 'cword=%s\n' "\${KUU_COMPLETE_INDEX:-}"; printf 'word=<%s>\n' "\$@"; } > "$log"
MOCK
  chmod +x "$out"
}

# glue を source して補完関数を直接駆動し、COMPREPLY を 1 行 1 候補で返す。
# COMP_LINE / COMP_POINT は words から導出する (末尾補完の近似。`=` で COMP_WORDS が割れる形は
# 復元規則が別なので (4c) の check_words が受け持つ)。
drive_bash_completion() { # <glue> <comp_func> <cword> <word...>
  local glue="$1" func="$2" cword="$3"; shift 3
  local line="$*"
  bash -c '
    source "'"$glue"'"
    COMP_WORDS=('"$(printf '%q ' "$@")"')
    COMP_CWORD='"$cword"'
    COMP_LINE='"$(printf '%q' "$line")"'
    COMP_POINT='"${#line}"'
    '"$func"'
    printf "%s\n" "${COMPREPLY[@]}"
  ' 2>/dev/null || true
}

# COMPREPLY に期待候補が **行として** 含まれることを確認する (順序・余剰候補は問わない —
# 表示順は shell 依存で段 1 の実端末マトリクスの担当)。
assert_candidates() { # <label> <output> <want...>
  local label="$1" out="$2"; shift 2
  local want missing=""
  for want in "$@"; do
    grep -qxF -- "$want" <<<"$out" || missing="$missing $want"
  done
  if [[ -z "$missing" ]]; then
    report ok "$label" "candidates contain$(printf ' %s' "$@")"
  else
    report fail "$label" "missing:$missing (got: $(tr '\n' ' ' <<<"$out"))"
  fi
}

# ---- (1) syntax-check 3 shell --------------------------------------------

# bash: bash -n
if command -v bash >/dev/null 2>&1; then
  if bash -n "$tmpdir/comp.bash" 2>"$tmpdir/err.bash"; then
    report ok "bash syntax-check"
  else
    report fail "bash syntax-check" "$(cat "$tmpdir/err.bash")"
  fi
else
  report skip "bash syntax-check" "bash not found"
fi

# zsh: zsh -n
if command -v zsh >/dev/null 2>&1; then
  if zsh -n "$tmpdir/comp.zsh" 2>"$tmpdir/err.zsh"; then
    report ok "zsh syntax-check"
  else
    report fail "zsh syntax-check" "$(cat "$tmpdir/err.zsh")"
  fi
else
  report skip "zsh syntax-check" "zsh not found"
fi

# fish: fish -n (parse-only)。fish は POSIX shell と非互換なので `sh -n` 系は使えない。
if command -v fish >/dev/null 2>&1; then
  if fish -n < "$tmpdir/comp.fish" 2>"$tmpdir/err.fish"; then
    report ok "fish syntax-check"
  else
    report fail "fish syntax-check" "$(cat "$tmpdir/err.fish")"
  fi
else
  report skip "fish syntax-check" "fish not found"
fi

# ---- (2) bash 関数直呼び (COMP_WORDS/COMP_CWORD/COMP_LINE 設定 + COMPREPLY assert) --

if command -v bash >/dev/null 2>&1; then
  make_query_mock "$tmpdir/mock_binary" "$def_json"
  # mock を binary に指す glue を再生成
  "$KUU_CLI" completion generate "$def_json" \
    --shell bash --binary "$tmpdir/mock_binary" --uuid "$uuid" \
    > "$tmpdir/comp.bash.mock"
  out=$(drive_bash_completion "$tmpdir/comp.bash.mock" _myapp 1 myapp --)
  assert_candidates "bash function direct call (via mock binary)" "$out" --port --verbose
else
  report skip "bash function direct call" "bash not found"
fi

# ---- (2b) 形態 B 直接 (`kuu completion query`) の候補列挙 --------------------
# glue を介さない形態 B 直接口の確認。form-A 環境が無い環境でも回帰検知できる補完窓。
qout=$("$KUU_CLI" completion query "$def_json" --cword 1 -- myapp -- 2>&1 || true)
if echo "$qout" | grep -q -- '--port' && echo "$qout" | grep -q -- '--verbose'; then
  report ok "form B: kuu completion query" "response contains --port and --verbose"
else
  report fail "form B: kuu completion query" "unexpected response: '$qout'"
fi

# ---- (3) fish `complete -C` による候補列挙 --------------------------------

if command -v fish >/dev/null 2>&1; then
  # bash と同型: kuu-cli は形態 A (env プロトコル) に応じないため mock binary で
  # `kuu completion query` (形態 B) へ橋渡しし、glue の end-to-end を検証する。
  # mock は bash セクションと同じ script を再利用。
  "$KUU_CLI" completion generate "$def_json" \
    --shell fish --binary "$tmpdir/mock_binary" --uuid "$uuid" \
    > "$tmpdir/comp.fish.mock"
  # fish は独立プロセスで source + complete -C を試す。
  out=$(fish -c 'source '"$tmpdir/comp.fish.mock"'; complete -C "myapp --"' 2>"$tmpdir/err.fish2" || true)
  if echo "$out" | grep -q -- '--port' && echo "$out" | grep -q -- '--verbose'; then
    report ok "fish complete -C (via mock binary)" "candidates contain --port and --verbose"
  else
    report fail "fish complete -C (via mock binary)" "unexpected output: $out (stderr: $(cat "$tmpdir/err.fish2"))"
  fi
else
  report skip "fish complete -C" "fish not found"
fi

# ---- (4) self-dogfood: kuu-cli 自身の def.json ------------------------------
# findings 2026-07-24 §4.3。上の (1)〜(3) が最小 def の合成物なのに対し、ここは
# **出荷される cli/kuu-cli.def.json をそのまま食わせて kuu-cli を補完する** 経路を見る。
# subcommand 階層 (completion generate / query の 2 段)、seq 2 引数形 (--config-file)、
# dd (`--`)、enum values を持つ実物なので、最小 def では踏まない形が glue まで通る。

if [[ ! -f "$KUU_CLI_DEF" ]]; then
  report fail "self-dogfood" "KUU_CLI_DEF not found at $KUU_CLI_DEF"
else
  for shell in zsh bash fish; do
    "$KUU_CLI" completion generate "$KUU_CLI_DEF" \
      --shell "$shell" --binary "$KUU_CLI" --uuid "$uuid" \
      > "$tmpdir/self.$shell"
  done

  # (4a) 3 shell の syntax-check。自分自身の定義から出た glue が壊れていないこと。
  for shell in zsh bash fish; do
    if ! command -v "$shell" >/dev/null 2>&1; then
      report skip "self def: $shell syntax-check" "$shell not found"
      continue
    fi
    if [[ "$shell" == fish ]]; then
      # fish は POSIX 非互換なので parse-only は stdin 経由 (上の (1) と同型)
      ok=0; fish -n < "$tmpdir/self.fish" 2>"$tmpdir/err.self.$shell" && ok=1
    else
      ok=0; "$shell" -n "$tmpdir/self.$shell" 2>"$tmpdir/err.self.$shell" && ok=1
    fi
    if [[ "$ok" == 1 ]]; then
      report ok "self def: $shell syntax-check"
    else
      report fail "self def: $shell syntax-check" "$(cat "$tmpdir/err.self.$shell")"
    fi
  done

  if command -v bash >/dev/null 2>&1; then
    make_query_mock "$tmpdir/self_mock" "$KUU_CLI_DEF"
    "$KUU_CLI" completion generate "$KUU_CLI_DEF" \
      --shell bash --binary "$tmpdir/self_mock" --uuid "$uuid" \
      > "$tmpdir/self.bash.mock"

    # (4b) 自分自身の subcommand と global option が候補に出る (`kuu <TAB>`)。
    # 実端末 bash 5.3.9 の観測形: COMP_WORDS=(kuu "") / COMP_CWORD=1。
    out=$(drive_bash_completion "$tmpdir/self.bash.mock" _kuu 1 kuu "")
    assert_candidates "self def: top-level candidates" "$out" \
      parse complete validate help completion --help --version

    # (4c) 2 段目の subcommand (`kuu completion <TAB>`)。最小 def は 1 階層しか持たないので、
    # **command の入れ子が glue まで通る**ことはここでしか確認できない。
    out=$(drive_bash_completion "$tmpdir/self.bash.mock" _kuu 2 kuu completion "")
    assert_candidates "self def: nested subcommand candidates" "$out" generate query

    # (4d) enum values (`kuu completion generate --shell <TAB>`)。option の `values` が
    # 値位置の候補として glue へ流れることを確認する (最小 def は values を持たない)。
    out=$(drive_bash_completion "$tmpdir/self.bash.mock" _kuu 4 kuu completion generate --shell "")
    assert_candidates "self def: option enum values" "$out" zsh bash fish

    # (4e) COMP_WORDBREAKS 再結合 (H9)。bash は `=` で COMP_WORDS を割るため、glue が
    # 割れたトークンを再結合してから binary へ渡す必要がある (DR-117 §3.4 の words 契約)。
    # 下の COMP_WORDS / COMP_CWORD は **実端末 bash 5.3.9 で観測した実形** (tmux 上で
    # complete -F の中から COMP_WORDS を dump して採取):
    #   `kuu parse --config-file=<TAB>`    → (kuu parse --config-file =)      CWORD=3
    #   `kuu parse --config-file=/et<TAB>` → (kuu parse --config-file = /et)  CWORD=4
    # 期待は「再結合後の words が eq 形 1 トークンに戻り、cword がそれを指す」こと。
    make_recorder_mock "$tmpdir/self_recorder" "$tmpdir/rec.log"
    "$KUU_CLI" completion generate "$KUU_CLI_DEF" \
      --shell bash --binary "$tmpdir/self_recorder" --uuid "$uuid" \
      > "$tmpdir/self.bash.rec"
    check_words() { # label  want_log  cword  comp_words...
      local label="$1" want="$2" cword="$3"; shift 3
      rm -f "$tmpdir/rec.log"
      bash -c '
        source "'"$tmpdir/self.bash.rec"'"
        COMP_WORDS=('"$(printf '%q ' "$@")"')
        COMP_CWORD='"$cword"'
        _kuu
      ' >/dev/null 2>&1 || true
      local got
      got=$(cat "$tmpdir/rec.log" 2>/dev/null || true)
      if [[ "$got" == "$want" ]]; then
        report ok "self def: $label"
      else
        report fail "self def: $label" "got=$(tr '\n' '|' <<<"$got") want=$(tr '\n' '|' <<<"$want")"
      fi
    }
    check_words "COMP_WORDBREAKS rejoin (--config-file=)" \
      "$(printf 'cword=2\nword=<kuu>\nword=<parse>\nword=<--config-file=>')" \
      3 kuu parse --config-file =
    check_words "COMP_WORDBREAKS rejoin (--config-file=/et)" \
      "$(printf 'cword=2\nword=<kuu>\nword=<parse>\nword=<--config-file=/et>')" \
      4 kuu parse --config-file = /et
    # 以下の期待値は spec `templates/completion.bash` の再結合規則 (TRANSLATION.md の
    # 「単一 break char は直前 word へ連結し in_break を立てる / 直後の非空 word も継続連結 /
    # 空 word は独立保持 / cword は元 COMP_CWORD の指す word の再結合後 index」) から導出した。
    # 記号 1 種 (`=`) だけだと連続 break char・先頭 break char・空 word の分岐を踏まない。
    #
    # 連続 break char: `http://x` は [http, :, //x] に割れ、`:` の直後の `//x` も継続連結される。
    check_words "COMP_WORDBREAKS rejoin (http://x)" \
      "$(printf 'cword=2\nword=<kuu>\nword=<parse>\nword=<http://x>')" \
      4 kuu parse http : //x
    # カーソルが break char (`:`) の上にある場合も、再結合後の同じ word を指す。
    check_words "COMP_WORDBREAKS rejoin (cursor on break char)" \
      "$(printf 'cword=2\nword=<kuu>\nword=<parse>\nword=<http://x>')" \
      3 kuu parse http : //x
    # option 形でない素の eq 形 (`name=value`)。
    check_words "COMP_WORDBREAKS rejoin (name=value)" \
      "$(printf 'cword=2\nword=<kuu>\nword=<parse>\nword=<name=value>')" \
      4 kuu parse name = value
    # 末尾空白由来の空 word は「カーソルの新しい位置」として独立保持され、cword がそれを指す。
    check_words "COMP_WORDBREAKS rejoin (trailing empty word)" \
      "$(printf 'cword=3\nword=<kuu>\nword=<parse>\nword=<http://x>\nword=<>')" \
      5 kuu parse http : //x ""
    # 配列先頭の break char = 連結先の直前 word が無い形 (glue の `__j < 0` 分岐)。
    check_words "COMP_WORDBREAKS rejoin (leading break char)" \
      "$(printf 'cword=0\nword=<=value>')" \
      1 = value
  else
    # bash 不在時も報告件数を揃える (件数だけ見て回帰を判定できるようにする)
    report skip "self def: top-level candidates" "bash not found"
    report skip "self def: nested subcommand candidates" "bash not found"
    report skip "self def: option enum values" "bash not found"
    report skip "self def: COMP_WORDBREAKS rejoin (--config-file=)" "bash not found"
    report skip "self def: COMP_WORDBREAKS rejoin (--config-file=/et)" "bash not found"
    report skip "self def: COMP_WORDBREAKS rejoin (http://x)" "bash not found"
    report skip "self def: COMP_WORDBREAKS rejoin (cursor on break char)" "bash not found"
    report skip "self def: COMP_WORDBREAKS rejoin (name=value)" "bash not found"
    report skip "self def: COMP_WORDBREAKS rejoin (trailing empty word)" "bash not found"
    report skip "self def: COMP_WORDBREAKS rejoin (leading break char)" "bash not found"
  fi
fi

# ---- summary --------------------------------------------------------------
echo "---"
echo "smoke: pass=$pass fail=$fail skip=$skip"
if [[ $fail -gt 0 ]]; then
  exit 1
fi
exit 0
