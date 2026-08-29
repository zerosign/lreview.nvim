# lreview.nvim — test runner, coverage, and benchmarks
#
# All recipes run through the sandbox Neovim (scripts/sandbox-nvim.fish) so
# tests never touch the real ~/.config/nvim. Coverage uses luacov (loaded from
# the system luarocks tree, exposed by the sandbox script).
#
# Test tiers:
#   unit        — fast, offline, mock-based (default)
#   integration — real GitHub/GitLab API calls against the sample repos

set shell := ["fish", "-c"]

# Run the unit test suite (default)
test:
    for t in (string match -v -r 'test_(?:pull|gc_pull|multi_repo)\.lua$' tests/test_*.lua); echo "=== $t ==="; ./scripts/sandbox-nvim.fish --headless -l $t; or exit 1; end
    echo "ALL UNIT TESTS PASSED"

# Run the integration test suite (network-dependent, hits live APIs)
test-integration:
    for t in (string match -r '.*test_(?:pull|gc_pull|multi_repo)\.lua$' tests/test_*.lua); echo "=== $t ==="; ./scripts/sandbox-nvim.fish --headless -l $t; or exit 1; end
    echo "ALL INTEGRATION TESTS PASSED"

# Run the full suite (unit + integration)
test-all: test test-integration

# Run a single test by name, e.g. `just test-one test_git`
test-one name:
    ./scripts/sandbox-nvim.fish --headless -l tests/{{name}}.lua

# Run a single test with coverage, e.g. `just test-cov test_git`
test-cov name:
    rm -f luacov.stats.out luacov.report.out
    ./scripts/sandbox-nvim.fish --headless -c "lua require('luacov')" -l tests/{{name}}.lua
    ./scripts/sandbox-nvim.fish --headless -c "lua require('luacov.reporter').report()" -c "qa"
    echo "Coverage report written to luacov.report.out"

# Run the unit suite under luacov and write luacov.report.out
coverage:
    rm -f luacov.stats.out luacov.report.out
    for t in (string match -v -r 'test_(?:pull|gc_pull|multi_repo)\.lua$' tests/test_*.lua); ./scripts/sandbox-nvim.fish --headless -c "lua require('luacov')" -l $t; or exit 1; end
    ./scripts/sandbox-nvim.fish --headless -c "lua require('luacov.reporter').report()" -c "qa"
    echo "Coverage report written to luacov.report.out"

# Regenerate luacov.report.out from existing luacov.stats.out
coverage-report:
    ./scripts/sandbox-nvim.fish --headless -c "lua require('luacov.reporter').report()" -c "qa"
    echo "Coverage report written to luacov.report.out"

# Print a compact coverage summary from the last report
coverage-summary:
    grep -E "Total|Summary" luacov.report.out

# Run the SQL query latency benchmark (1000 iterations, temp DB)
bench:
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