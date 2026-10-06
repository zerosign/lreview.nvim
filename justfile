# lreview.nvim — test runner, coverage, and benchmarks
#
# All recipes run through the sandbox Neovim (scripts/sandbox-nvim.fish) so
# tests never touch the real ~/.config/nvim. Coverage uses luacov (loaded from
# the system luarocks tree, exposed by the sandbox script).
#
# Test tiers:
#   unit        — fast, offline, mock-based (default)
#   integration — real GitHub/GitLab API calls against the sample repos
#
# The integration tier is matched by EXACT FILE NAME, not a suffix regex. A
# previous `test_(?:push_live)\.lua$` rule silently failed to match
# `test_push_live_gitlab.lua`, so the live tier ran inside `just test` and
# posted real comments to the sample MR. Do not make that mistake again: if you
# add a network test, list it below.
set shell := ["fish", "-c"]

integration_tests := "test_pull.lua test_gc_pull.lua test_multi_repo.lua test_push_live_gitlab.lua test_issues_live.lua"

# Initialize the sandbox dependencies locally if not present.
# NOTE: the old form (`test -d …; or command -v …; and begin; … end`) chained
# with fish's precedence, so it re-ran `luarocks install` on every invocation
# and tripped a stale lock. `if` makes the intent explicit.
setup-sandbox:
    if not test -d sandbox/luarocks; and command -v luarocks >/dev/null; echo "Installing lsqlite3 via luarocks into sandbox..."; luarocks install --tree=sandbox/luarocks lsqlite3; else if not test -d sandbox/luarocks; echo "Warning: no sandbox/luarocks and no luarocks CLI. Tests may fail if sqlite3 is not available globally."; end

# Run the unit test suite (default). Skips anything in {{integration_tests}}.
test: setup-sandbox
    for t in tests/test_*.lua; set -l b (basename $t); contains -- $b {{integration_tests}}; and continue; echo "=== $t ==="; ./scripts/sandbox-nvim.fish --headless -l $t; or exit 1; end
    echo "ALL UNIT TESTS PASSED"

# Run the integration test suite (network-dependent, hits live APIs).
# Enumerated from {{integration_tests}} so both tiers share one source of truth.
# (Do NOT reintroduce `string match -r` here: with a capturing group, fish also
# emits each captured substring, so the loop ran jobs named "gc_pull", "pull", …)
test-integration: setup-sandbox
    for name in {{integration_tests}}; test -e tests/$name; and begin; echo "=== tests/$name ==="; ./scripts/sandbox-nvim.fish --headless -l tests/$name; or exit 1; end; end
    echo "ALL INTEGRATION TESTS PASSED"

# Run the full suite (unit + integration)
test-all: setup-sandbox test test-integration

# Run a single test by name, e.g. `just test-one test_git`
test-one name: setup-sandbox
    ./scripts/sandbox-nvim.fish --headless -l tests/{{name}}.lua

# Run a single test with coverage, e.g. `just test-cov test_git`
test-cov name: setup-sandbox
    rm -f luacov.stats.out luacov.report.out
    ./scripts/sandbox-nvim.fish --headless -c "lua require('luacov')" -l tests/{{name}}.lua
    ./scripts/sandbox-nvim.fish --headless -c "lua require('luacov.reporter').report()" -c "qa"
    echo "Coverage report written to luacov.report.out"

# Run the unit suite under luacov and write luacov.report.out
coverage: setup-sandbox
    rm -f luacov.stats.out luacov.report.out
    for t in tests/test_*.lua; set -l b (basename $t); contains -- $b {{integration_tests}}; and continue; ./scripts/sandbox-nvim.fish --headless -c "lua require('luacov')" -l $t; or exit 1; end
    ./scripts/sandbox-nvim.fish --headless -c "lua require('luacov.reporter').report()" -c "qa"
    echo "Coverage report written to luacov.report.out"

# Regenerate luacov.report.out from existing luacov.stats.out
coverage-report: setup-sandbox
    ./scripts/sandbox-nvim.fish --headless -c "lua require('luacov.reporter').report()" -c "qa"

# Run automated tmux UI interactive scenario test suite
test-ui: setup-sandbox
    ./scripts/test_tmux_scenarios.fish

# Alias for test-ui
test-tmux: test-ui

# Measure LocalReviewSummary initial-open latency (tmux, wall-clock threshold)
bench-ui-summary: setup-sandbox
    ./scripts/test_tmux_summary_latency.fish

# Record per-operation durations (git, CLI, sqlite, flow) from real usage:
# provisions a fresh branch+MR+changes in zerodevs/sample-review, then drives
# LocalReviewStart (get MR) + LocalReviewSummary (local summary), tmux
bench-timing: setup-sandbox
    ./scripts/test_tmux_timing_gitlab.fish

# Comprehensive per-operation timing across ALL 26 commands / all categories:
# list MRs, get detail, sync discussions, submit comments, fetch users/PRs,
# close MR, add comment, schema migration. Providis a fresh branch+MR+changes.
bench-timing-all: setup-sandbox
    ./scripts/test_tmux_timing_comprehensive.fish

# Interactive tmux session helpers
tmux-start: setup-sandbox
    ./scripts/tmux-nvim.fish start

tmux-stop:
    ./scripts/tmux-nvim.fish stop

tmux-capture:
    ./scripts/tmux-nvim.fish capture
    echo "Coverage report written to luacov.report.out"

# Print a compact coverage summary from the last report
coverage-summary:
    grep -E "Total|Summary" luacov.report.out

# Run the SQL query latency benchmark (1000 iterations, temp DB)
bench: setup-sandbox
    ./scripts/sandbox-nvim.fish --headless -l scripts/bench.lua

# Drive the comment-insertion UI flow (tmux) and assert SQLite state for a
# battery of markdown content. Requires a tmux session + the gitlab sample repo.
comment-flow:
    ./scripts/test-comment-flow.fish

# Open interactive sandbox Neovim on the gitlab sandbox repo
run-gitlab:
    ./scripts/sandbox-nvim.fish tmp/gitlab-sample-review

# Open interactive sandbox Neovim on the github sandbox repo
run-github:
    ./scripts/sandbox-nvim.fish tmp/github-sample-review