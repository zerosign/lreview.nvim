#!/usr/bin/env fish
# Harness: drive the comment insertion UI flow (visual select -> scratchpad ->
# save) and assert the SQLite state for a battery of markdown content.
#
# Verifies that ANY comment body (plain text, code fences, tables, unicode,
# emoji, HTML, links, lists, ...) survives the scratchpad -> SQLite round trip
# with the exact expected body, thread range, and draft flag.
#
# Usage: ./scripts/test-comment-flow.fish
#
# Env:
#   LREVIEW_TMUX_SESSION - tmux session name (default: lreview-comment-test)
#   LREVIEW_TEST_REPO    - repo to review (default: tmp/gitlab-sample-review)

set -l PROJECT_ROOT (realpath (dirname (status filename))/..)
set -l SESSION (set -q LREVIEW_TMUX_SESSION; and echo $LREVIEW_TMUX_SESSION; or echo lreview-comment-test)
set -l REPO (set -q LREVIEW_TEST_REPO; and echo $LREVIEW_TEST_REPO; or echo "$PROJECT_ROOT/tmp/gitlab-sample-review")
set -l DB "$PROJECT_ROOT/sandbox/data/nvim/lreview/lreview.db"
set -l TMUX_HELPER "$PROJECT_ROOT/scripts/tmux-nvim.fish"
set -l BUF_MARKER "$PROJECT_ROOT/tmp/lreview-buf.txt"

# --- tmux helpers -----------------------------------------------------------
function send_keys
  tmux send-keys -t "$SESSION" -l -- "$argv[1]"
end

function send_enter
  tmux send-keys -t "$SESSION" Enter
end

function send_escape
  tmux send-keys -t "$SESSION" Escape
end

function run_cmd
  send_keys "$argv[1]"
  send_enter
end

function capture_screen
  tmux capture-pane -t "$SESSION" -p | tail -4
end

# --- test cases -------------------------------------------------------------
# name<TAB>body ; body may contain \n for multi-line markdown.
set -l cases \
  "plain\tThis is a simple comment." \
  "inline-code\tUse `git rebase -i` to squash commits before merging." \
  "fenced-code\t```lua\nlocal x = 1\nreturn x\n```" \
  "emphasis\t**Bold** and *italic* and ~~strikethrough~~ and `code`." \
  "link\tSee the [GitLab markdown guide](https://docs.gitlab.com/ee/user/markdown.html) for details." \
  "bullet-list\t- First item\n- Second item\n- Third item" \
  "numbered-list\t1. First\n2. Second\n3. Third" \
  "heading\t## Suggestion\n\nConsider adding a changelog entry." \
  "blockquote\t> This is a quoted suggestion." \
  "table\t| A | B |\n|---|---|\n| 1 | 2 |" \
  "task-list\t- [ ] not done\n- [x] done" \
  "special-chars\tIt's a \"test\" with 'quotes', back\\slash, and unicode: café ☕ 🎉." \
  "html\t<details><summary>Click</summary>Hidden content</details>" \
  "image\t![screenshot](https://example.com/img.png)" \
  "mixed\t## Review notes\n\nThis MR looks good overall. A few points:\n\n- The `# manual test` heading (line 94) could be expanded.\n- See the [docs](https://docs.gitlab.com/ee/user/markdown.html).\n\n```sh\njust test\n```\n\n> Thanks!" \
  "empty\t" \
  "whitespace-only\t   \n  " \
  "leading-trailing\t  hello world  "

# --- start session ----------------------------------------------------------
rm -f "$BUF_MARKER"
LREVIEW_TMUX_SESSION="$SESSION" "$TMUX_HELPER" start "$REPO"
sleep 2
run_cmd ':e README.md'
sleep 1
run_cmd ':LocalReviewStart'
# Give the background pull_review_async job time to finish so it can't
# contend on the SQLite DB during the first cases.
sleep 6

set -l branch (git -C "$REPO" branch --show-current)
set -l mo_id (sqlite3 "$DB" "SELECT mo_id FROM pull_requests WHERE source_branch='$branch' ORDER BY rowid DESC LIMIT 1;")
if test -z "$mo_id"
  set mo_id (sqlite3 "$DB" "SELECT mo_id FROM pull_requests ORDER BY rowid DESC LIMIT 1;")
end
echo "== review session: $mo_id (branch: $branch)"

set -l pass 0
set -l fail 0

for case in $cases
  set -l parts (string split "\t" -- "$case")
  set -l name $parts[1]
  set -l body $parts[2]

  # Snapshot existing drafts for this MR.
  set -l before_ids (sqlite3 "$DB" "SELECT t_id FROM threads WHERE mo_id='$mo_id' AND is_draft=1;")

  # Open the comment scratchpad on line 94 via visual selection.
  run_cmd ':94'
  sleep 0.3
  send_keys 'V'
  send_keys ':'
  send_keys 'LocalReviewComment'
  send_enter
  sleep 1

  # Verify the scratchpad actually opened before typing anything.
  run_cmd ":lua local f=io.open('$BUF_MARKER','w'); if f then f:write(vim.api.nvim_buf_get_name(0)) f:close() end"
  sleep 0.3
  set -l bufname (cat "$BUF_MARKER" 2>/dev/null)
  if not string match -q 'lreview://comment/*' -- "$bufname"
    echo "FAIL [$name] scratchpad did not open (buf='$bufname')"
    set fail (math $fail + 1)
    continue
  end

  # Type the body (if any) and save.
  if test -n "$body"
    send_keys 'i'
    send_keys "$body"
    send_escape
  end
  run_cmd ':w'
  sleep 1

  # Assert: exactly one new draft thread should exist.
  set -l after_ids (sqlite3 "$DB" "SELECT t_id FROM threads WHERE mo_id='$mo_id' AND is_draft=1;")
  set -l new_id ""
  for id in $after_ids
    if not contains -- $id $before_ids
      set new_id $id
    end
  end

  set -l expected (string trim -- "$body")
  if test -z "$expected"
    # Rejected case: no new draft expected.
    if test -z "$new_id"
      echo "PASS [$name] rejected empty/whitespace comment"
      set pass (math $pass + 1)
      # Close the still-open scratchpad.
      send_escape
      run_cmd ':q!'
      sleep 0.5
    else
      echo "FAIL [$name] expected rejection but draft created: $new_id"
      set fail (math $fail + 1)
    end
  else
    if test -z "$new_id"
      echo "FAIL [$name] no draft created"
      capture_screen
      set fail (math $fail + 1)
    else
      set -l stored (sqlite3 "$DB" "SELECT c.body FROM comments c WHERE c.t_id='$new_id';")
      if test "$stored" = "$expected"
        set -l trow (sqlite3 "$DB" "SELECT path||'|'||start_line||'|'||end_line||'|'||is_draft FROM threads WHERE t_id='$new_id';")
        if test "$trow" = "README.md|94|94|1"
          echo "PASS [$name] body stored correctly"
          set pass (math $pass + 1)
        else
          echo "FAIL [$name] thread fields wrong: $trow"
          set fail (math $fail + 1)
        end
      else
        echo "FAIL [$name] body mismatch"
        echo "  expected: $expected"
        echo "  stored:   $stored"
        set fail (math $fail + 1)
      end
    end
  end
end

echo ""
echo "== results: $pass passed, $fail failed"

# Clean up test drafts (all drafts for this MR are harness artifacts).
sqlite3 "$DB" "DELETE FROM comments WHERE t_id IN (SELECT t_id FROM threads WHERE mo_id='$mo_id' AND is_draft=1); DELETE FROM threads WHERE mo_id='$mo_id' AND is_draft=1;"

if test $fail -gt 0
  exit 1
end