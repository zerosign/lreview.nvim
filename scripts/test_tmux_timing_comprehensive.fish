#!/usr/bin/env fish
# Comprehensive tmux timing E2E for lreview.nvim
#
# Provisions a fresh branch + MR + changes in zerodevs/sample-review, then
# drives every user-facing operation via :lua inside the sandbox nvim and
# captures per-op durations (git / CLI / sqlite / flow) for optimization.
#
# What is measured:
#   1. list_pull_requests   (:LocalReviewQuery all)
#   2. get_mr_detail        (review.init_session sync path)
#   3. init_session_async   (:LocalReviewSummary, local fallback)
#   4. local_fallback_detail (git + sqlite inside async)
#   5. sync_review          (:LocalReviewPull, fetch discussions)
#   6. add_comment          (local sqlite only)
#   7. submit_review        (push comment to remote)
#   8. fetch_users          (list repo collaborators)
#   9. fetch_pull_requests  (list MRs async)
#  10. close_mr             (close the MR)
#  11. sqlite migrations    (schema version check)

set -l PROJECT_ROOT (realpath (dirname (status filename))/..)
set -l TMUX_DRIVER "$PROJECT_ROOT/scripts/tmux-nvim.fish"
set -l REPO_DIR "$PROJECT_ROOT/tmp/sample-review"
set -l TIMING_FILE "$PROJECT_ROOT/sandbox/data/nvim/lreview/timing.log"
set -l TIMING_SESSION lreview-timing
set -l STAMP (date +%s)
set -l BRANCH "feat/e2e-$STAMP"

echo "=========================================================================="
echo "  lreview.nvim — Comprehensive Tmux Timing E2E (real GitLab)"
echo "  branch: $BRANCH"
echo "=========================================================================="

# --- Provision a fresh branch + MR + changes --------------------------------
echo "  [provision] preparing $REPO_DIR ..."
if not test -d "$REPO_DIR/.git"
    git clone --quiet "git@gitlab.com:zerodevs/sample-review.git" "$REPO_DIR"; or begin
        echo "  ERROR: clone failed"; exit 1
    end
else
    git -C "$REPO_DIR" fetch --quiet origin; or true
    git -C "$REPO_DIR" checkout -q main 2>/dev/null; or git -C "$REPO_DIR" switch -q -c main origin/main
    git -C "$REPO_DIR" reset -q --hard origin/main; or true
end

git -C "$REPO_DIR" checkout -q main
git -C "$REPO_DIR" pull -q --ff-only origin main; or true

git -C "$REPO_DIR" checkout -q -b "$BRANCH"
mkdir -p "$REPO_DIR/src"
cp "$PROJECT_ROOT/scripts/fixtures/calculator_template.py" "$REPO_DIR/src/calculator_$STAMP.py"
printf '\n## E2E timing run\n\nThis branch adds a fresh file and change for a lreview.nvim timing run.\n' >> "$REPO_DIR/README.md"
git -C "$REPO_DIR" add src/ README.md
git -C "$REPO_DIR" -c user.name="lreview-e2e" -c user.email="lreview-e2e@local" \
    commit -q -m "feat(e2e): add calculator with changes ($STAMP)"; or begin
    echo "  ERROR: commit failed"; exit 1
end

echo "  [provision] pushing $BRANCH ..."
git -C "$REPO_DIR" push -q -u origin "$BRANCH"; or begin
    echo "  ERROR: push failed"; exit 1
end

echo "  [provision] opening MR ..."
set -l mr_created (begin
    cd "$REPO_DIR"
    glab mr create --source-branch "$BRANCH" --target-branch main \
        --title "E2E timing changes $STAMP" \
        --description "Comprehensive E2E timing test for lreview.nvim" -y 2>&1
end)
echo "  ==> $mr_created"

# Extract MR number from URL or output
set -l mr_number (echo "$mr_created" | grep -oP 'merge_requests/\K[0-9]+' | head -1)
if test -z "$mr_number"
    echo "  WARN: could not detect MR number; using branch name as ref"
    set -l mr_number "$BRANCH"
end
echo "  [provision] MR number: $mr_number"

# --- Timing instrumentation -------------------------------------------------
rm -f "$TIMING_FILE"
mkdir -p (dirname "$TIMING_FILE")
set -gx LREVIEW_TIMING_FILE "$TIMING_FILE"
set -gx LREVIEW_TMUX_SESSION "$TIMING_SESSION"

echo ""
echo "  [run] starting interactive nvim in $REPO_DIR ..."
$TMUX_DRIVER start "$REPO_DIR" >/dev/null
sleep 3

# Enable timing + test mode (so async ops run sync for per-op capture).
$TMUX_DRIVER cmd ":lua require('lreview.timing').configure({timing=true,timing_file='"$TIMING_FILE"'})" >/dev/null
sleep 0.5
$TMUX_DRIVER cmd ":lua vim.g.lreview_test_mode = 1" >/dev/null
sleep 0.5

# =========================================================================
#  FLOW 1: List MRs (:LocalReviewQuery)
# =========================================================================
echo "  [1/10] list_pull_requests (:LocalReviewQuery all)"
$TMUX_DRIVER cmd ":lua local t=require('lreview.timing'); local s=vim.uv.hrtime()/1e6; require('lreview').api.fetch_pull_requests(vim.fn.getcwd()); t.record(t.CAT_FLOW,'wall_list_pull_requests',vim.uv.hrtime()/1e6-s); t.flush()" >/dev/null
sleep 2

# =========================================================================
#  FLOW 2: Start review (get MR detail - sync path)
# =========================================================================
echo "  [2/10] get_mr_detail (review.init_session sync)"
$TMUX_DRIVER cmd ":lua local t=require('lreview.timing'); local s=vim.uv.hrtime()/1e6; require('lreview.review').init_session(); t.record(t.CAT_FLOW,'wall_init_session_sync',vim.uv.hrtime()/1e6-s); t.flush()" >/dev/null
sleep 3

# =========================================================================
#  FLOW 3: Local summary (keeps M.current linked so later flows hit the real MR)
# =========================================================================
echo "  [3/10] init_session_async / local summary (linked MR)"
$TMUX_DRIVER cmd ":lua require('lreview.timing').flush()" >/dev/null
sleep 0.5
$TMUX_DRIVER cmd ":LocalReviewSummary" >/dev/null
sleep 2
$TMUX_DRIVER cmd ":lua require('lreview.timing').flush()" >/dev/null

# =========================================================================
#  FLOW 4: Sync discussions (fetch threads from remote)
# =========================================================================
echo "  [4/10] sync_review (fetch discussions from remote)"
$TMUX_DRIVER cmd ":lua local t=require('lreview.timing'); local s=vim.uv.hrtime()/1e6; require('lreview.review').sync_review(); t.record(t.CAT_FLOW,'wall_sync_review',vim.uv.hrtime()/1e6-s); t.flush()" >/dev/null
sleep 3

# =========================================================================
#  FLOW 5: Fetch repo users
# =========================================================================
echo "  [5/10] fetch_users (list repo collaborators)"
$TMUX_DRIVER cmd ":lua local t=require('lreview.timing'); local s=vim.uv.hrtime()/1e6; require('lreview.users').fetch_users(vim.fn.getcwd()); t.record(t.CAT_FLOW,'wall_fetch_users',vim.uv.hrtime()/1e6-s); t.flush()" >/dev/null
sleep 2

# =========================================================================
#  FLOW 6: Add local comment (sqlite only)
# =========================================================================
echo "  [6/10] add_comment (local sqlite insert)"
$TMUX_DRIVER cmd ":lua local t=require('lreview.timing'); local s=vim.uv.hrtime()/1e6; require('lreview.review').add_comment('src/calculator_$STAMP.py', 8, 8, 'E2E timing test comment'); t.record(t.CAT_FLOW,'wall_add_comment',vim.uv.hrtime()/1e6-s); t.flush()" >/dev/null
sleep 1

# =========================================================================
#  FLOW 7: Submit comment (push to remote)
# =========================================================================
echo "  [7/10] submit_review (push comment to remote)"
$TMUX_DRIVER cmd ":lua local t=require('lreview.timing'); local s=vim.uv.hrtime()/1e6; require('lreview.review').submit_review(nil, function(ok,cnt,err) t.record(t.CAT_FLOW,'wall_submit_review',vim.uv.hrtime()/1e6-s); t.flush(); end); t.flush()" >/dev/null
sleep 3

# =========================================================================
#  FLOW 8: Pull request list (fetch MRs async)
# =========================================================================
echo "  [8/10] fetch_pull_requests (list MRs)"
$TMUX_DRIVER cmd ":lua local t=require('lreview.timing'); local s=vim.uv.hrtime()/1e6; require('lreview.pull_request').fetch(vim.fn.getcwd()); t.record(t.CAT_FLOW,'wall_fetch_pull_requests',vim.uv.hrtime()/1e6-s); t.flush()" >/dev/null
sleep 2

# =========================================================================
#  FLOW 9: Close MR
# =========================================================================
echo "  [9/10] close_mr (close the MR)"
$TMUX_DRIVER cmd ":lua local r=require('lreview.review'); if r.current then local t=require('lreview.timing'); local s=vim.uv.hrtime()/1e6; r.close_review(); t.record(t.CAT_FLOW,'wall_close_mr',vim.uv.hrtime()/1e6-s); t.flush() else print('no active review to close') end" >/dev/null
sleep 2

# =========================================================================
#  FLOW 10: Schema migration check (sqlite version check)
# =========================================================================
echo "  [10/10] schema migration (sqlite version check)"
$TMUX_DRIVER cmd ":lua local t=require('lreview.timing'); local s=vim.uv.hrtime()/1e6; require('lreview.storage').open(); require('lreview.storage').migrate(); t.record(t.CAT_FLOW,'wall_schema_migration',vim.uv.hrtime()/1e6-s); t.flush()" >/dev/null
sleep 1

# --- Stop and flush ---------------------------------------------------------
$TMUX_DRIVER stop >/dev/null
sleep 1

# =========================================================================
#  REPORT
# =========================================================================
echo ""
echo "=========================================================================="
echo "  COMPREHENSIVE TIMING RESULTS"
echo "=========================================================================="
if not test -s "$TIMING_FILE"
    echo "  (no timing records captured)"
    exit 1
end

echo ""
echo "  --- All operations (chronological) ---"
cat "$TIMING_FILE"

echo ""
echo "  --- Slowest operations first ---"
awk -F'\t' '{printf "%10.3f  %-8s %s\n", $4, $2, $3}' "$TIMING_FILE" | sort -rn -k1,1

echo ""
echo "  --- Summary by category ---"
awk -F'\t' '{
    cat=$2; dur=$4+0; count[cat]++; total[cat]+=dur;
    if(dur>max[cat]) max[cat]=dur;
    if(min[cat]=="" || dur<min[cat]) min[cat]=dur;
} END {
    printf "%-8s %5s %10s %10s %10s\n", "CAT", "COUNT", "TOTAL(ms)", "AVG(ms)", "MAX(ms)"
    printf "%-8s %5s %10s %10s %10s\n", "----", "-----", "---------", "-------", "-------"
    for(c in count) printf "%-8s %5d %10.3f %10.3f %10.3f\n", c, count[c], total[c], total[c]/count[c], max[c]
}' "$TIMING_FILE"

echo ""
echo "=========================================================================="
echo "  COMPREHENSIVE E2E COMPLETE (branch '$BRANCH')"
echo "=========================================================================="
