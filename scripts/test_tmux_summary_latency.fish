#!/usr/bin/env fish
# Automated Tmux Latency Test: LocalReviewSummary (first / initial open)
#
# Measures wall-clock time from issuing `:LocalReviewSummary` to the summary
# panel appearing on screen, on a fresh session where no review has been
# started yet (so the panel must initialize its session asynchronously).
#
# The regression this guards against: the summary previously called the
# synchronous init_session(), which ran a `gh pr view` network call
# (vim.system(...):wait()) on the main thread, freezing the UI until the
# network round-trip completed. With init_session_async, the panel renders
# immediately from a local fallback and resolves the real MR in the background.
#
# Usage:
#   ./scripts/test_tmux_summary_latency.fish
#
# Env:
#   LREVIEW_LATENCY_MS - fail if the summary takes longer than this (default 1500)

set -l PROJECT_ROOT (realpath (dirname (status filename))/..)
set -l TMUX_DRIVER "$PROJECT_ROOT/scripts/tmux-nvim.fish"
set -l LATENCY_MS (set -q LREVIEW_LATENCY_MS; and echo $LREVIEW_LATENCY_MS; or echo 1500)

echo "=========================================================================="
echo "  lreview.nvim — Tmux Latency: LocalReviewSummary (initial open)"
echo "  Threshold: $LATENCY_MS ms"
echo "=========================================================================="

# Step 1: Start fresh sandbox Neovim in tmux. Crucially, we do NOT run
# :LocalReviewStart — this is the "initial" open where no session exists yet,
# so summary.open() must bootstrap the session via init_session_async.
$TMUX_DRIVER stop >/dev/null
$TMUX_DRIVER start "$PROJECT_ROOT" >/dev/null
sleep 2

# Step 2: Baseline capture (confirm nvim is up and idle).
set -l baseline ($TMUX_DRIVER capture)
if not string match -q "*local*" "$baseline"
    echo "  [warn] unexpected baseline screen (nvim may still be starting):"
    echo "$baseline"
    sleep 2
end

# Step 3: Fire :LocalReviewSummary, measuring wall-clock latency.
echo "  [measure] sending :LocalReviewSummary..."
set -l t0 (date +%s%N)
$TMUX_DRIVER cmd ":LocalReviewSummary" >/dev/null

# Poll the screen until the summary panel renders (or timeout).
set -l appeared 0
set -l elapsed_ms -1
set -l screen ""
for i in (seq 1 200)
    set -l now (date +%s%N)
    set -l ms (math "($now - $t0) / 1000000")
    set screen ($TMUX_DRIVER capture)
    if string match -q "*Summary*" "$screen" or string match -q "*Filter*" "$screen" or string match -q "*Threads*" "$screen"
        set appeared 1
        set elapsed_ms (math "($now - $t0) / 1000000")
        echo "  ==> summary panel appeared at $elapsed_ms ms"
        break
    end
    # Stop early if we've already blown the threshold.
    if test "$ms" -gt "$LATENCY_MS"
        break
    end
    sleep 0.02
end

# Step 4: Report.
if test "$appeared" -ne 1
    echo "  ==> FAIL: summary panel never appeared within $LATENCY_MS ms."
    echo "  ==> Captured Screen Output:"
    echo "$screen"
    $TMUX_DRIVER stop >/dev/null
    exit 1
end

if test "$elapsed_ms" -gt "$LATENCY_MS"
    echo "  ==> FAIL: summary opened in $elapsed_ms ms (threshold $LATENCY_MS ms)."
    echo "      This suggests the UI blocked on the synchronous network MR resolution."
    $TMUX_DRIVER stop >/dev/null
    exit 1
end

echo "  ==> PASS: LocalReviewSummary opened in $elapsed_ms ms (<= $LATENCY_MS ms)."

# Step 5: Stop.
$TMUX_DRIVER stop >/dev/null

echo "=========================================================================="
echo "  TMUX SUMMARY LATENCY TEST PASSED in $elapsed_ms ms"
echo "=========================================================================="
