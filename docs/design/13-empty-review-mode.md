# Plan 13: Empty / Unlinked Review Mode Design & Implementation Plan

> **Goal:** When `:LocalReviewStart` or review initialization runs on a local branch that does **not** have an active remote PR/MR yet, gracefully fall back to **Unlinked / Local Review Mode** instead of failing with a CLI error. This allows users to add inline draft comments, view modified files, and create a remote PR/MR directly from the summary panel.

---

## 1. Overview & Problem Statement

Currently, when `review.init_session(cwd)` runs:
If `gh` or `glab` returns `no pull requests found for branch "master"`, `init_session()` returns `nil, err` and displays an error message:
```
lreview: failed to start review session: Command failed: gh ... Error: no pull requests found for branch "master"
```

### Proposed Solution:
Instead of failing, `init_session()` initializes a local synthetic **Unlinked Review Session**:
- **Offline & Pre-PR Reviewing:** Users can review local changes (`git diff`), add local inline draft notes, and organize feedback *before* publishing a PR/MR.
- **Local File Overview:** `detail.files` is populated from `git.changed_files(cwd)` against the default branch (`main`/`master`).
- **Direct Creation Short-Circuit:** The Summary panel (`:LocalReviewSummary`) displays an unlinked status banner and provides a single keypress `[C]` shortcut to open `:LocalReviewCreate`.

---

## 2. Technical Architecture

### 2.1 Fallback Synthetic MR Detail (`lua/lreview/review.lua`)

When `adapter.get_mr_detail(cfg, ctx)` returns `nil` (or fails with no PR found):
`review.init_session(cwd)` constructs an unlinked detail object:

```lua
local branch = git.current_branch(cwd) or "head"
local fallback_detail = {
  mo_id = "local:" .. (ctx.repo or "workspace") .. ":" .. branch,
  number = 0,
  title = "Local Draft Review (" .. branch .. ")",
  description = "No remote PR/MR currently linked.",
  state = "draft",
  unlinked = true,
  source_branch = branch,
  target_branch = git.default_branch(cwd) or "main",
  files = git.changed_files(cwd) or {}, -- local git diff files
}
```

### 2.2 Summary Panel UI Modifications (`lua/lreview/ui/summary.lua`)

When `review.current.detail.unlinked == true`:

#### Header Banner:
```
=== Local Review Summary [Local / Unlinked] ===
Branch: master ──> main | No active remote PR/MR found
```

#### Action Footer & Shortcuts:
```
 [C] Create Remote PR/MR | [g] Toggle Files View | [q] Close
```

- Pressing **`C`** in the summary panel directly invokes `cmd_create()` (the scratchpad MR creation editor).

### 2.3 Review Submission Guard (`lua/lreview/review.lua` / `lua/lreview/ui/confirm.lua`)

When calling `:LocalReviewSubmit`:
If `review.current.detail.unlinked == true`, `submit_review()` notifies:
> *"No remote PR/MR is linked to branch 'master'. Please create a remote PR/MR first via [C] or :LocalReviewCreate."*
And offers an option to open `:LocalReviewCreate` with draft notes preserved!

---

## 3. Action Plan & Implementation Steps

1. **`lua/lreview/git.lua`:**
   - Add `M.changed_files(cwd)` helper to parse local `git diff --name-status` / `git status` into `{ path, additions, deletions }` table for unlinked reviews.
2. **`lua/lreview/review.lua`:**
   - Update `init_session(cwd)` to catch remote PR lookup failures and fall back to the unlinked synthetic MR detail object.
3. **`lua/lreview/ui/summary.lua`:**
   - Update banner and keymap handlers to support `unlinked` mode and `C` (Create PR/MR) keymap.
4. **`docs/design/13-empty-review-mode.md`:**
   - Save design document to codebase.
5. **Testing & Verification:**
   - Unit tests for unlinked fallback in `tests/test_review.lua`.
   - Verification via `just test` and `just test-ui`.
