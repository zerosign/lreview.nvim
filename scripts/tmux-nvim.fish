#!/usr/bin/env fish
# Drive the sandbox Neovim inside a tmux session for interactive testing.
#
# This lets us simulate a real interactive nvim session (visual mode, commands,
# UI) rather than --headless, and capture the resulting screen/output.
#
# Every run (start/cmd/capture) is appended to a dated log file so we always
# have a record of what was executed and what came back.
#
# Usage:
#   ./scripts/tmux-nvim.fish start [dir]     - start sandbox nvim in a tmux session
#   ./scripts/tmux-nvim.fish send '<keys>'   - send literal keys to the session
#   ./scripts/tmux-nvim.fish cmd  ':LocalReviewQuery'  - run an Ex command
#   ./scripts/tmux-nvim.fish capture         - capture the current screen
#   ./scripts/tmux-nvim.fish stop            - kill the session
#
# Env:
#   LREVIEW_TMUX_SESSION - session name (default: lreview-nvim)
#   LREVIEW_RUN_LOG      - log file path (default: <root>/tmp/nvim-run.log)

set -l PROJECT_ROOT (realpath (dirname (status filename))/..)
set -l SESSION (string join '' (set -q LREVIEW_TMUX_SESSION; and echo $LREVIEW_TMUX_SESSION; or echo lreview-nvim))
set -l SANDBOX_NVIM "$PROJECT_ROOT/scripts/sandbox-nvim.fish"
# Global so the __log function (own scope) can see it.
set -g RUN_LOG (set -q LREVIEW_RUN_LOG; and echo $LREVIEW_RUN_LOG; or echo "$PROJECT_ROOT/tmp/nvim-run.log")

# Append a line to the run log (mkdir -p the parent first).
function __log
  mkdir -p (dirname "$RUN_LOG")
  echo (date '+%Y-%m-%d %H:%M:%S') "$argv" >> "$RUN_LOG"
end

switch "$argv[1]"
  case start
    set -l dir (test -n "$argv[2]"; and echo "$argv[2]"; or echo "$PROJECT_ROOT")
    # Kill any existing session first.
    tmux kill-session -t "$SESSION" 2>/dev/null; or true
    tmux new-session -d -s "$SESSION" -x 200 -y 50
    tmux send-keys -t "$SESSION" "cd '$dir' && $SANDBOX_NVIM" Enter
    sleep 1
    __log "=== START session=$SESSION cwd=$dir branch="(git -C "$dir" branch --show-current 2>/dev/null)
    echo "started sandbox nvim in tmux session '$SESSION' (cwd: $dir)"

  case send
    tmux send-keys -t "$SESSION" -l "$argv[2]"
    __log "SEND: $argv[2]"

  case cmd
    # Send an Ex command (handles leading ':' and Enter).
    tmux send-keys -t "$SESSION" -l "$argv[2]"
    tmux send-keys -t "$SESSION" Enter
    __log "CMD: $argv[2]"

  case capture
    set -l out (tmux capture-pane -t "$SESSION" -p)
    __log "CAPTURE:"
    __log "$out"
    echo "$out"

  case stop
    tmux kill-session -t "$SESSION" 2>/dev/null; or true
    __log "=== STOP session=$SESSION"
    echo "stopped session '$SESSION'"

  case '*'
    echo "usage: $argv[0] {start|send|cmd|capture|stop} [args]" >&2
    exit 1
end
