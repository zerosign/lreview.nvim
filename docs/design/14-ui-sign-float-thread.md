# 14 — Sign + Floating Window Thread UI with Stacked Reply Float

**Status:** 📋 **Planned — pre-implementation**
**Domain:** 2 — Reviewing UX (Journey A)
**Depends on:** 09-async-model.md (uv.new_work thread model), 07-submit-atomicity.md (outbox push_ops)
**Related:** 02-file-overview.md (summary panel), 03-review-verdict.md (confirm popup), 04-sync-bus.md (debounced refresh)

> This plan adds the third, missing piece of the "Sign + Floating Window" comment UI:
> a **stacked reply input float docked beneath the thread window**. States 1 (gutter
> sign + EOL preview) and 2 (floating/split thread window) already exist in
> `decor.lua` and `thread_view.lua`. State 3 (typing a reply) currently opens a
> *separate* scratchpad window via `editor.open_reply()` that steals focus; this
> plan replaces that with a docked two-float layout (thread on top + inline
> markdown reply beneath), matching the pattern octo.nvim / gitlab.nvim use.

---

## 1. The Question

A reviewer browsing code needs to:

1. **See at a glance** which lines have comments — without the code shifting around.
2. **Open the full thread** for a line with one keystroke, in a floating window that overlays (doesn't push) surrounding lines.
3. **Type a reply** inside a real markdown buffer docked right beneath the thread, then submit it as a local draft (deferred) or push immediately (configured).

Today lreview does (1) via `decor.lua` extmarks (`sign_text` + `virt_text` at `eol`) and (2) via `thread_view.lua` (`nvim_open_win`, rounded border, `r`/`e`/`d`/`s`/`P`). But (3) opens `editor.open_reply()` → `create_scratchpad()` as a separate centered float (default `layout = "float"`) that covers the thread view. The reviewer loses sight of the thread while typing.

**Goal:** a stacked two-float reply layout — thread window on top, reply input docked beneath it — so the conversation stays visible while replying. The reply is saved as a `STATE.DRAFT` comment and enters the `push_ops` outbox on `:LocalReviewSubmit` (deferred path), exactly like `editor.open_reply()` in non-immediate mode.

---

## 2. Current State (what already exists)

### State 1 — Idle: gutter sign + EOL preview (`lua/lreview/ui/decor.lua`)

`M.refresh(bufnr)` clears the `lreview_decor` namespace, then for each line with threads sets one extmark:

| Field | Value | Purpose |
|---|---|---|
| `sign_text` | `💬` draft / `●` synced / `✔` resolved | Speech bubble in sign column |
| `sign_hl_group` | `LReviewSignDraft` / `LReviewSignSynced` / `Comment` | Linked to `WarningMsg` / `Comment` |
| `virt_text` | ` N comment(s) (N draft)` | Subtle EOL preview, `Comment`/`WarningMsg` hl |
| `virt_text_pos` | `"eol"` | Preview sits at end of line, zero layout shift |
| `number_hl_group` | `LReviewNumDraft` / `LReviewNumSynced` / `LReviewNumResolved` | Gutter line-number background |
| `priority` | 100 | Above diff-change highlights (priority 50) |

Highlights are defined once via `setup_highlights()` and linked to standard groups so they match the theme automatically.

### State 2 — Active: floating/split thread window (`lua/lreview/ui/thread_view.lua`)

`M.show(bufnr, rel_path, line)` opens the thread panel:
- Reuses a single `nofile` markdown buffer (`M.buf`), redrawn via `M.redraw()`.
- `format_threads_for_line()` renders each thread with header, body lines, separators, and a help footer (`[r] Reply | [e] Edit | [d] Delete | [s] Resolve | [P] Push | [q] Close`).
- Keymaps: `q`/`<esc>` close, `r` replies, `e` edits, `d` deletes, `s` resolves, `P` submits.
- Layout is config-driven (`ui.layout` = `float`/`split`/`vsplit`/`buffer`); `float` is currently coerced to `split` in `M.show()` (line 308-310).
- Subscribes to `sync.subscribe("panel", ...)` and auto-redraws on sync events.
- Subscribes to `sync.subscribe("panel", ...)` and auto-redraws on sync events.

**Gap:** `r` → `handle_action("reply")` → `editor.open_reply(t_id)` opens a separate centered scratchpad float that covers the thread. No stacked reply docked beneath the thread window exists.

### State 3 — Replying (the gap) — `lua/lreview/ui/editor.lua`

`create_scratchpad(initial_text, save_callback, extra_opts)`:
- Creates a `nofile` markdown buffer, `bufhidden = "wipe"`, named `lreview://comment/<uuid>`.
- Intercepts `:w` / `:wq` via `BufWriteCmd` autocmd → calls `save_callback(text)`.
- Keymaps: `<C-cr>`, `<leader>s`, `<C-s>` save; `q`/`<esc>`/`<C-c>` cancel/discard.
- `@mention` completion (cached repo users) and `!`/`#` MR/PR link completion via `TextChangedI`.
- `open_reply(thread_id)` → `create_scratchpad(nil, ...)` → on save either `push_reply_immediately()` (immediate) or `comments.add_comment(...)` as `STATE.DRAFT` (deferred).

The scratchpad is a single centered window — not docked beneath the thread.

---

## 3. Proposed Solution

### 3.1 New: stacked reply float (`thread_view.lua`)

Add `M.open_reply_float(t_id)` to `thread_view.lua`:

- **Creates a second floating window** docked beneath the thread window (`relative = "win"` anchored to the thread winid, or `relative = "cursor"` if no thread winid), `row = 1`, `col = 0`, `width = 72`, `height = 4`, rounded border, title ` ✍️ Reply `.
- **Buffer**: `nofile` markdown, `bufhidden = "wipe"`, named `lreview://reply/<t_id>`.
- **Keymaps**: `<C-s>` / `<C-cr>` submit; `q` / `<esc>` / `<C-c>` cancel; starts in `startinsert` so the user types immediately.
- **On submit**: `comments.add_comment({ c_id=uuid(), t_id, remote_id=nil, state=STATE.DRAFT, ... })` — **deferred**, no network call. Then `M.redraw()` + `decor.refresh()` so the draft reply appears immediately in the thread view and the gutter sign updates. Notify "reply added as draft (push with :LocalReviewSubmit)".
- **Close**: `M.close_reply()` closes the float + wipes the buffer, clearing `M.reply_state`.
- `M.close()` also calls `M.close_reply()` so the reply float never outlives the thread view.

### 3.2 Keymap change

In `M.show()`, the `r` keymap changes from `handle_action("reply")` (scratchpad) to:

```lua
vim.keymap.set("n", "r", function()
  local t_id = t_id_at_cursor()
  if t_id then
    M.open_reply_float(t_id)
  else
    vim.notify("lreview: move cursor into a thread block to reply", vim.log.levels.WARN)
  end
end, opts)
```

`t_id_at_cursor()` resolves the thread under/nearest the cursor line via `M.state.thread_line_map` (search up then down). `handle_action("reply")` is kept but updated to call `M.open_reply_float(t_id)` when `t_id` is resolved (for callers that don't have cursor context).

### 3.3 Config option (optional, future)

A `ui.reply_layout = "stacked" | "scratchpad"` toggle could let users choose. For this plan, **stacked is the default and only mode**; `editor.open_reply()` remains available for other callers.

---

## 4. Threading & Async Model (from doc 09)

All network+DB work for the reply flows through the existing `uv.new_work` thread model:

| Operation | Thread? | Where |
|---|---|---|
| `comments.add_comment()` (draft write) | No — main thread, local SQLite only | `editor` / `thread_view` |
| `M.redraw()` / `decor.refresh()` | No — main thread, UI only | `thread_view` / `decor` |
| `:LocalReviewSubmit` (push reply → remote) | **Yes** — `submit_review_thread` on `uv.new_work` | `review.lua` |
| `submit_reply` adapter call (`glab mr note create`) | Yes, inside the submit worker | `adapter/gitlab.lua` |
| Reconcile after submit | Yes, inside the submit worker | `review._reconcile_threads` |
| `vim.notify` from submit worker | Collected into result, replayed on main via `vim.schedule` | `review.lua` `_notifications` |

### Threading rules that must hold (doc 09 §2.5):

1. **No `vim.api` / `vim.fn` / `vim.notify` / `vim.ui` / `vim.schedule` inside a `uv.new_work` thread.** The reply float itself (`nvim_open_win`, `vim.keymap`, `startinsert`) runs on the **main thread** — it never touches a worker. Only the later `:LocalReviewSubmit` push runs on the worker.
2. **Adapter resolution (`adapter.resolve`/`adapter.ctx`) happens on the main thread first** (they use `vim.fn`, not thread-safe). The submit worker receives the resolved `resolved` + `ctx` as plain Lua values, serialized via `vim.mpack`.
3. **Worker opens its own SQLite connection** (`sqlite.new(db_path, { keep_open = true })`, WAL + `busy_timeout=5000`). No shared connection with the UI → no UI contention during push.
4. **Per-call completion callbacks** go through `thread.arm("review.submit", cb)` / `thread.dispatch_cb("review.submit", ...)` — never a captured closure variable, so singleton workers reply to the right caller.
5. **Notifications from the worker** are collected into `M._notifications` and replayed via `M.drain_notifications()` on the main thread.

---

## 5. Comment Lifecycle Integration

The reply drafted in the float follows the exact same lifecycle as `editor.open_reply()` in deferred mode:

| Stage | Action | Code | State |
|---|---|---|---|
| **Create** | User types in reply float, hits `<C-s>` | `comments.add_comment({..., state=STATE.DRAFT, remote_id=nil, t_id, in_reply_to=nil })` | `STATE.DRAFT` (never pushed), `remote_id = nil` |
| **Show** | Thread view redraws; decor refreshes | `M.redraw()` + `decor.refresh(bufnr)` | Visible as draft in thread + gutter |
| **Queue** | `:LocalReviewSubmit` → `review.submit_review()` → `_submit_pushes()` | `build_ops()` → `outbox.enqueue()` → row `QUEUED`, op `REPLY`, deduped by `(c_id, op)` | `push_ops` `QUEUED` |
| **Push** | Worker: `mark_running` → adapter `submit_reply` → `commit()` (txn: `mark_done` + `mark_comment_synced(c_id, remote_id)`) | `review.submit_review_thread` | `STATE.SYNCED`, `remote_id` set, op `DONE` |
| **Reconcile** | `_fetch_remote_threads()` → `_reconcile_threads()` adopts any `uncertain` op by body match | `review.lua` | Crash-safe; no duplicate posts |
| **Pull** | `:LocalReviewPull` fetches remote truth, merges back | `review.sync_review()` | Remote edits detected → `CONFLICT` if drift |

**Conflict gate:** `comments.count_conflicts(mo_id) > 0` blocks submit until resolved via `:LocalReviewConflicts` (keep local / accept remote). A draft reply is never blocked by conflicts on *other* comments — only if its own thread has a conflict.

**Deferred vs immediate:** If `config.get_defaults().submit_immediately` is true, the reply float's save callback calls `review.push_reply_immediately(t_id, text)` (network on main thread — existing behavior, kept for compatibility). Otherwise the draft goes to the outbox (recommended).

---

## 6. Failure Modes (network + async)

All failure handling already exists in the submit/outbox layer. The reply float adds no new failure surface — it only writes a local draft. Failures occur at submit time:

| Scenario | Behavior | User sees |
|---|---|---|
| **Network fails mid-push** (per-note platform, e.g. GitLab `glab mr note create`) | The failing `REPLY` op → `FAILED`; `break` out of the replies category. Earlier ops (creates) already `DONE` + committed. Later ops stay `QUEUED`. | `lreview: N change(s) still queued — they stay as drafts, run :LocalReviewSubmit again` |
| **Batch path fails** (GitHub `atomic_inline_batch=true`) | All creates locked `RUNNING`; one review POST; on failure all back to `QUEUED`. Nothing partially lands. | Same as above; no duplicate posts |
| **Process dies while op is RUNNING** | On next session start, `outbox.recover_stale()` re-queues as `uncertain`. Reconcile adopts by body match if the remote already has the reply. | `lreview: N interrupted push op(s) re-queued for verification` |
| **Network call succeeded, local write (commit) failed** | `mark_uncertain(op_id, ...)`; reconcile adopts by body match on next sync. | No duplicate; error surfaced |
| **gh/glab returns exit code 0 on error** | `adapter/base.lua` `check_error()` scans output for markers (`gh:`, `glab:`, `failed to create review`, `ERROR:`, etc.) instead of trusting `$?`. | Normalized error message |
| **Empty / non-JSON CLI output** | Commit `5900c7d` handles gracefully — no JSON parse error crash. | — |
| **Adapter declares `review_verdict` but no `submit_verdict`** | Reported as failed op, not a silent no-op. | `active adapter declares review_verdict but has no submit_verdict` |
| **Only replies/edits (no new threads) + verdict** | Verdict becomes its own `VERDICT` op (was silently dropped in v3). | — |
| **Local-only draft delete** (no `remote_id`) | Consumed locally, zero API calls (v3 sent a real call and 404'd). | — |

---

## 7. Implementation Sketch

### 7.1 Changes to `lua/lreview/ui/thread_view.lua`

1. Add `local decor = require("lreview.ui.decor")` to requires.
2. Add `M.reply_state = nil` alongside `M.state = nil`.
3. Add `uuid()` helper (mirrors `editor.lua`'s).
4. Add `t_id_at_cursor()` — resolves thread id under/nearest cursor line via `M.state.thread_line_map`.
5. Add `M.close_reply()` — closes `M.reply_state.winid`, wipes `M.reply_state.bufnr`, clears `M.reply_state`.
6. Add `M.open_reply_float(t_id)` — stacked reply float beneath the thread window (see §3.1).
7. Change `M.close()` to call `M.close_reply()` first.
8. Change the `r` keymap in `M.show()` to call `M.open_reply_float(t_id_at_cursor())`.
9. Update `handle_action("reply")` to call `M.open_reply_float(t_id)` when `t_id` is resolved.

### 7.2 No changes needed to

- `editor.lua` — `create_scratchpad()` and `open_reply()` remain for other callers.
- `review.lua` — submit path unchanged (outbox handles `REPLY` ops).
- `storage/comments.lua` — `add_comment()` already supports draft replies.
- `adapter/base.lua`, `adapter/gitlab.lua` — submit contract unchanged.

---

## 8. Verification Checklist

| # | Check | Method |
|---|---|---|
| V1 | `r` on a thread line opens a stacked reply float beneath the thread window | Manual + `test_mappers.lua` / `test_thread.lua` |
| V2 | Float starts in insert mode; `<C-s>` saves draft | Manual |
| V3 | Draft reply appears in thread view immediately (redraw) | `M.redraw()` after `add_comment` |
| V4 | Gutter sign / EOL preview updates (`decor.refresh`) | `decor.refresh(bufnr)` after add |
| V5 | `q`/`<esc>`/`<C-c>` cancel and close the float without saving | `M.close_reply()` |
| V6 | Reply float closes when thread view closes | `M.close()` → `M.close_reply()` |
| V7 | `:LocalReviewSubmit` pushes the draft reply as a `REPLY` op | `test_submit_contract.lua` via `executor_override` |
| V8 | Partial failure leaves reply `QUEUED`, retry sends only it | Outbox dedupe by `(c_id, op)` |
| V9 | No `vim.api`/`vim.fn`/`vim.notify` in any `uv.new_work` thread path | Thread rule (doc 09 §2.5) |
| V10 | Notification replay from submit worker works | `drain_notifications()` on main thread |
| V11 | Offline: reply draft saved locally with no network | `vim.g.lreview_test_mode` or no `gh`/`glab` |

---

## 9. Risks & Regressions

| Risk | Severity | Mitigation |
|---|---|---|
| Reply float overlaps editor content on small screens | MED | Fixed `width = 72`, `height = 4`; anchored to thread win not cursor so it stays with the conversation |
| `M.reply_state` stale after thread view switches lines | LOW | `M.close_reply()` called on every `M.show()` and `M.close()`; `open_reply_float` closes existing first |
| Draft reply redraw loses cursor position in thread view | LOW | `M.redraw()` preserves `M.state.winid`; cursor not moved |
| `t_id_at_cursor()` picks wrong thread when multiple on one line | LOW | Searches up then down via `thread_line_map`; same logic as `handle_action` already uses |
| `decor.refresh` flicker on every draft save | LOW | Debounced via sync bus (~80ms) already; `decor.refresh` is idempotent |

### Cross-plan impact

| Implementing | Could regress | Why |
|---|---|---|
| Doc 14 (this UI) | Doc 07 (submit atomicity) | Reply drafts enter the same outbox `REPLY` op path — no change needed, but submit tests cover it |
| Doc 14 | Doc 04 (sync bus) | `decor.refresh()` after draft save routes through the sync bus — unchanged |

---

## 10. Open Questions

1. **`ui.reply_layout` toggle?** Offer `stacked` (default) vs `scratchpad` (current `editor.open_reply`) via config. Deferred — stacked is sufficient for v1.
2. **Multi-line reply box?** Current float is `height = 4` (fixed). A taller/resizable reply box, or a split-within-float (read-only history top + editable bottom), is a natural follow-up.
3. **Immediate submit from the float?** If `submit_immediately` is set, the float's save could call `push_reply_immediately()` directly instead of drafting. Kept as deferred-only for v1 to match `editor.open_reply()` default.
4. **`virt_text` preview includes reply count?** `decor.lua` already shows `(N draft)` but not total reply count. Could enhance `virt_text_str` to show `+N replies`.

---

## 11. Implementation Order

1. Add `decor` require, `M.reply_state`, `uuid()`, `t_id_at_cursor()`, `M.close_reply()`, `M.open_reply_float()` to `thread_view.lua`.
2. Wire `r` keymap + `handle_action("reply")` to `M.open_reply_float()`.
3. Update `M.close()` to close the reply float.
4. Run `just test` (offline unit tier) — `test_thread.lua`, `test_mappers.lua`, `test_submit_contract.lua`.
5. Manual sanity: open thread view on a commented line, press `r`, type reply, `<C-s>`, verify draft appears; `:LocalReviewSubmit` pushes it.

---

*Modelled on docs/design/NN-*.md conventions: status banner → domain/depends → problem → current state → proposed solution → threading → lifecycle → failure modes → implementation sketch → verification → risks → open questions → order.*
