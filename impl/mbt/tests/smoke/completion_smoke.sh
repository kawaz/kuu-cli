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
# 使い方: KUU_CLI=<compiled main.exe path> ./completion_smoke.sh
# CI では justfile smoke task 経由。ローカルでは `just impl-mbt-smoke`。

set -euo pipefail

: "${KUU_CLI:?KUU_CLI must be set to compiled kuu-cli main.exe path}"

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
  # 形態 A の env プロトコルは self-embedded kuu-core binary (DR-117 §6 形態 A) を前提とし、
  # kuu-cli standalone (形態 B) はこのプロトコルに応じない。この gap を埋めるため mock binary
  # を用意し、KUU_COMPLETE env + UUID argv 一致を判定して `kuu completion query` (形態 B) へ
  # 橋渡しする — glue の 動作を kuu-cli の query capability で end-to-end に検証する形。
  # (mock は 3 引数目=shell, 以降=words を単純に query に転送。KUU_COMPLETE_INDEX を --cword に写す。)
  cat > "$tmpdir/mock_binary" << MOCK
#!/usr/bin/env bash
set -e
[[ "\$KUU_COMPLETE" == "$uuid" && "\$1" == "$uuid" ]] || { echo "mock: env/argv mismatch (KUU_COMPLETE=\$KUU_COMPLETE argv1=\$1)" >&2; exit 2; }
shift  # UUID
shift  # shell name
if [[ -n "\${KUU_COMPLETE_INDEX:-}" ]]; then
  exec "$KUU_CLI" completion query "$def_json" --cword "\$KUU_COMPLETE_INDEX" -- "\$@"
else
  exec "$KUU_CLI" completion query "$def_json" -- "\$@"
fi
MOCK
  chmod +x "$tmpdir/mock_binary"
  # mock を binary に指す glue を再生成
  "$KUU_CLI" completion generate "$def_json" \
    --shell bash --binary "$tmpdir/mock_binary" --uuid "$uuid" \
    > "$tmpdir/comp.bash.mock"
  out=$(bash -c '
    source "'"$tmpdir/comp.bash.mock"'"
    COMP_WORDS=("myapp" "--")
    COMP_CWORD=1
    COMP_LINE="myapp --"
    COMP_POINT=8
    _myapp
    printf "%s\n" "${COMPREPLY[@]}"
  ' 2>"$tmpdir/err.bash2" || true)
  # 期待: --port と --verbose が候補に含まれる (順序は shell 依存、問わない)
  if echo "$out" | grep -q -- '--port' && echo "$out" | grep -q -- '--verbose'; then
    report ok "bash function direct call (via mock binary)" "COMPREPLY contains --port and --verbose"
  else
    report fail "bash function direct call (via mock binary)" "unexpected COMPREPLY: '$out' (stderr: $(cat "$tmpdir/err.bash2"))"
  fi
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
  # fish は独立プロセスで source + complete -C を試す。
  out=$(fish -c 'source '"$tmpdir/comp.fish"'; complete -C "myapp --"' 2>"$tmpdir/err.fish2" || true)
  if echo "$out" | grep -q -- '--port' && echo "$out" | grep -q -- '--verbose'; then
    report ok "fish complete -C" "candidates contain --port and --verbose"
  else
    report fail "fish complete -C" "unexpected output: $out (stderr: $(cat "$tmpdir/err.fish2"))"
  fi
else
  report skip "fish complete -C" "fish not found"
fi

# ---- summary --------------------------------------------------------------
echo "---"
echo "smoke: pass=$pass fail=$fail skip=$skip"
if [[ $fail -gt 0 ]]; then
  exit 1
fi
exit 0
