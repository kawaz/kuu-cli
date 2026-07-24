#!/usr/bin/env bash
set -euo pipefail

: "${KUU_CLI:?set KUU_CLI to the compiled kuu binary}"
: "${KUU_CLI_DEF:?set KUU_CLI_DEF to kuu-cli.def.json}"

tmp_def=$(mktemp)
trap 'rm -f "$tmp_def"' EXIT

# parse_definition rejects the editor-facing JSON Schema annotation.
# TODO: Remove the on_failure deletion after kuu.mbt implements the existing
# wire vocabulary. The source definition remains the canonical complete form.
jq 'del(."$schema") | (.options[] | select(.name == "version")) |= del(.on_failure)' \
  "$KUU_CLI_DEF" >"$tmp_def"

assert_eq() {
  local label=$1 got=$2 want=$3
  if [[ "$got" != "$want" ]]; then
    printf >&2 'self definition FAIL (%s): got=%s want=%s\n' "$label" "$got" "$want"
    exit 1
  fi
}

validated=$("$KUU_CLI" validate "$tmp_def")
assert_eq 'validate ok' "$(jq -r '.ok' <<<"$validated")" true
assert_eq 'validate errors' "$(jq -c '.errors // []' <<<"$validated")" '[]'
printf 'self definition OK: decode and lowering converged with zero definition errors\n'

parse_case() {
  local label=$1 expected=$2
  shift 2
  local out
  out=$("$KUU_CLI" parse "$tmp_def" --no-env --no-config --tty '{}' -- "$@")
  assert_eq "$label outcome" "$(jq -r '.outcome' <<<"$out")" success
  assert_eq "$label result" "$(jq -cS "$expected" <<<"$out")" true
  printf 'self definition OK: %s -> %s\n' "$label" "$(jq -cS '.result' <<<"$out")"
}

parse_case parse '.result.parse.definition == "def.json" and .result.parse.args == ["--port", "80"]' \
  parse def.json -- --port 80
parse_case complete '.result.complete.definition == "def.json" and .result.complete.args_before == "[]"' \
  complete def.json --args-before '[]'
parse_case validate '.result.validate.definition == "def.json"' \
  validate def.json
parse_case help-default '.result.help.definition == []' \
  help
parse_case help-definition '.result.help.definition == ["def.json"] and .result.help.depth == "all" and .result.help.format == "text"' \
  help def.json --depth all --format text
parse_case completion-generate '.result.completion.generate.definition == "def.json" and .result.completion.generate.shell == "zsh" and .result.completion.generate.binary == "kuu" and .result.completion.generate.uuid == "test-uuid"' \
  completion generate def.json --shell zsh --binary kuu --uuid test-uuid
parse_case completion-query '.result.completion.query.definition == "def.json" and .result.completion.query.cword == 1 and .result.completion.query.words == ["kuu", "pa"]' \
  completion query def.json --cword 1 -- kuu pa
parse_case version '.result.version == "0.0.0"' --version
parse_case no-arguments '.result.help == false and (.result | keys) == ["help"]'

set +e
help_out=$("$KUU_CLI" parse "$tmp_def" --no-env --no-config --tty '{}' -- parse --help)
help_exit=$?
set -e
assert_eq 'inherited help exit' "$help_exit" 1
assert_eq 'inherited help outcome' "$(jq -r '.outcome' <<<"$help_out")" failure
assert_eq 'inherited help action' "$(jq -r '.fired_action' <<<"$help_out")" help
printf 'self definition OK: inherited --help fires at a child scope\n'

set +e
exclusive_out=$("$KUU_CLI" parse "$tmp_def" --no-env --no-config --tty '{}' -- \
  parse def.json --no-config --config '{}')
exclusive_exit=$?
set -e
assert_eq 'config exclusivity exit' "$exclusive_exit" 1
assert_eq 'config exclusivity outcome' "$(jq -r '.outcome' <<<"$exclusive_out")" failure
assert_eq 'config exclusivity reason' "$(jq -r '.errors[0].reason' <<<"$exclusive_out")" exclusive_group_violated
printf 'self definition OK: config source exclusivity is enforced\n'
