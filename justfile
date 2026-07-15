# kuu-cli — standalone CLI for the kuu spec (kawaz/kuu).
#
# Canonical task runner. push flow は kawaz/bump-semver の justfile を模倣する
# (kuu.mbt と同型)。release は canonical 実装選定後に開始する (DR-0001 §2、
# VERSION=0.0.0 placeholder の間は release 休眠)。

set shell := ["bash", "-euo", "pipefail", "-c"]

set script-interpreter := ["bash", "-euo", "pipefail"]

set positional-arguments

# default: lint + test
default: lint test

# show the recipe list
list:
    @just --list --unsorted

# ---------- lint / test (impl 毎に追加) ----------

# lint all implementations
lint: impl-mbt-lint

# test all implementations
test: impl-mbt-test

# impl/mbt (MoonBit PoC — DR-0001 §3): 各 impl は自リポ内 justfile を持つ
impl-mbt-setup:
    cd impl/mbt && just setup

impl-mbt-lint:
    cd impl/mbt && just lint

impl-mbt-test:
    cd impl/mbt && just test

# ---------- push flow (bump-semver canonical 模倣) ----------

# working copy is clean (= 未コミット変更を巻き込ませない)
[private]
ensure-clean:
    bump-semver vcs is clean

# fail if the current bookmark / branch is not the default
[private]
[script]
check-on-default-branch:
    if ! bump-semver vcs is on-default-branch; then
        cur=$(bump-semver vcs get current-branch 2>/dev/null || echo "(ambiguous)")
        bn=$(bump-semver vcs get default-branch)
        printf >&2 "⚠ 現在 '%s' にいます。%s に合流してから push してください (just sync / just promote)\n" "$cur" "$bn"
        exit 1
    fi

# 現在の worktree を default branch (= origin/main) に rebase
sync:
    bump-semver vcs sync --onto $(bump-semver vcs get default-branch)@origin

# default branch bookmark を現在の commit に forward (push はしない)
promote:
    bump-semver vcs promote

# push to origin/main with canonical gates
push: check-on-default-branch lint test
    bump-semver vcs push --branch "$(bump-semver vcs get default-branch)" --jj-bookmark-auto-advance
    cmux-msg notify --self --text "Monitor で 'just watch' を起動して" 2>/dev/null || true

# push 後の CI を SHA-pin で監視 (gh-monitor plugin)
watch:
    watch-workflow.sh --sha $(bump-semver vcs get commit-id --rev "$(bump-semver vcs get default-branch)") kawaz/kuu-cli
