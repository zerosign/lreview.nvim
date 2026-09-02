#!/usr/bin/env fish
# Tmux Timing E2E Scenario (real GitLab) for lreview.nvim
#
# For each run this script provisions a brand-new branch + MR + changes in
# https://gitlab.com/zerodevs/sample-review, then drives a real interactive
# nvim session in that repo and records per-operation durations (git, CLI/glab,
# sqlite, flow) captured from actual usage:
#   - :LocalReviewStart   -> get MR (resolve_current_mr / glab mr list)
#   - :LocalReviewSummary -> local summary (init_session_async / git + sqlite)
#
# Every run creates its own MR so measurements always target a freshly created
# merge request (never a reused one).
#
# Env:
#   LREVIEW_GITLAB_REPO  - repo to use, e.g. "zerodevs/sample-review"
#                         (default: zerodevs/sample-review)
#   LREVIEW_KEEP_REPO    - if set, reuse/update the existing tmp clone instead
#                         of recloning (default: fresh per run)

set -l PROJECT_ROOT (realpath (dirname (status filename))/..)
set -l TMUX_DRIVER "$PROJECT_ROOT/scripts/tmux-nvim.fish"
set -l REPO (set -q LREVIEW_GITLAB_REPO; and echo $LREVIEW_GITLAB_REPO; or echo zerodevs/sample-review)
set -l REPO_DIR "$PROJECT_ROOT/tmp/sample-review"
set -l TIMING_FILE "$PROJECT_ROOT/sandbox/data/nvim/lreview/timing.log"
set -l TIMING_SESSION lreview-timing
set -l STAMP (date +%s)
set -l BRANCH "feat/e2e-$STAMP"

echo "=========================================================================="
echo "  lreview.nvim — Tmux Timing E2E (real GitLab: $REPO)"
echo "  new branch + MR + changes per run: $BRANCH"
echo "=========================================================================="

# --- Provision a fresh branch + MR + changes in the sample repo -------------
echo "  [provision] preparing $REPO_DIR ..."

if not test -d "$REPO_DIR/.git"
    echo "  [provision] cloning $REPO ..."
    git clone --quiet "git@gitlab.com:$REPO.git" "$REPO_DIR"; or begin
        echo "  ERROR: clone failed"
        exit 1
    end
else
    # Keep local copy in sync with remote main (drop any leftover branch).
    git -C "$REPO_DIR" fetch --quiet origin; or true
    git -C "$REPO_DIR" checkout -q main 2>/dev/null; or git -C "$REPO_DIR" switch -q -c main origin/main
    git -C "$REPO_DIR" reset -q --hard origin/main; or true
end

git -C "$REPO_DIR" checkout -q main
git -C "$REPO_DIR" pull -q --ff-only origin main; or true

# Fresh branch with a real change (new file + edit to a tracked file).
git -C "$REPO_DIR" checkout -q -b "$BRANCH"
mkdir -p "$REPO_DIR/src"
set -l cal "$REPO_DIR/src/calculator_$STAMP.py"
cp "$PROJECT_ROOT/scripts/fixtures/calculator_template.py" "$cal"
printf '\n## E2E timing run\n\nThis branch adds a fresh file and change for a lreview.nvim timing run.\n' >> "$REPO_DIR/README.md"
git -C "$REPO_DIR" add src/ README.md
git -C "$REPO_DIR" -c user.name="lreview-e2e" -c user.email="lreview-e2e@local" \
    commit -q -m "feat(e2e): add calculator with changes ($STAMP)"; or begin
    echo "  ERROR: commit failed"
    exit 1
end

echo "  [provision] pushing $BRANCH ..."
git -C "$REPO_DIR" push -q -u origin "$BRANCH"; or begin
    echo "  ERROR: push failed"
    exit 1
end

echo "  [provision] opening MR ..."
# Run glab from inside the repo so its configured GitLab remote is used.
set -l mr_created (begin
    cd "$REPO_DIR"
    glab mr create --source-branch "$BRANCH" --target-branch main \
        --title "E2E timing changes $STAMP" \
        --description "Fresh MR + changes for lreview.nvim timing E2E run." -y 2>&1
end)
echo "  ==> $mr_created"
string match -q -r '!([0-9]+)|https?://[^ ]*/-/merge_requests/([0-9]+)' "$mr_created"
if test $status -ne 0
    echo "  WARN: could not detect created MR iid; continuing anyway (get_mr_by_branch may fail)."
end

# --- Timing instrumentation -------------------------------------------------
rm -f "$TIMING_FILE"
mkdir -p (dirname "$TIMING_FILE")
set -gx LREVIEW_TIMING_FILE "$TIMING_FILE"
set -gx LREVIEW_TMUX_SESSION "$TIMING_SESSION"

echo ""
echo "  [run] starting interactive nvim in $REPO_DIR (branch $BRANCH) ..."
$TMUX_DRIVER start "$REPO_DIR" >/dev/null
sleep 3

echo "  [1] :LocalReviewStart (get MR via glab)"
$TMUX_DRIVER cmd ":LocalReviewStart" >/dev/null
sleep 2

echo "  [2] :LocalReviewSummary (local summary)"
$TMUX_DRIVER cmd ":LocalReviewSummary" >/dev/null
sleep 1
set -l screen ($TMUX_DRIVER capture)
if string match -q "*Summary*" "$screen" or string match -q "*Filter*" "$screen" or string match -q "*Threads*" "$screen"
    echo "  ==> PASS: summary panel rendered."
else
    echo "  ==> WARN: summary panel text not detected (screen below):"
    echo "$screen"
end

sleep 1

# Stop the session; VimLeavePre flushes timing records to the file.
$TMUX_DRIVER stop >/dev/null
sleep 1

echo ""
echo "--------------------------------------------------------------------------"
echo "  Per-operation durations (ms) — category | op | ms"
echo "--------------------------------------------------------------------------"
if not test -s "$TIMING_FILE"
    echo "  (no timing records captured)"
    exit 1
end

echo "  --- chronological ---"
cat "$TIMING_FILE"
echo ""
echo "  --- slowest first ---"
awk -F'\t' '{printf "%10.3f  %-8s %s\n", $4, $2, $3}' "$TIMING_FILE" | sort -rn -k1,1

echo ""
echo "=========================================================================="
echo "  TIMING E2E COMPLETE (branch '$BRANCH'; MR created and left open)"
echo "=========================================================================="
