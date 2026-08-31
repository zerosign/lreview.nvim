# 04 — Centralized Sync Bus & Efficient Propagation

**Journey:** A 7 (Track review state / panel & status sync)
**Domain:** 2 — Reviewing UX
**Status:** ⚠️ **Partially implemented — core bus exists, 2 wiring gaps remain**

> **Implementation status (rediscovered):** `lua/lreview/sync.lua` is
> **implemented** — `mark_dirty`, debounced `schedule` (uv timer + `vim.schedule`),
> `flush`, `subscribe`, and the in-memory `diff_cache` with `get_changed_lines`
> + `invalidate_diff_cache`. **Two gaps remain:** (1) `invalidate_diff_cache` is
> **never called** (no invalidation on pull/branch change → stale highlights),
> and (2) `pull_review_async`'s callback **bypasses the bus** — it manually calls
> `decor.refresh`/`tv.redraw`/`summary.redraw` instead of `mark_dirty`+`flush_now`.
> See §11.

---

## 1. Problem

After any comment/thread action, the plugin must keep all surfaces in sync:

- Gutter decor (signs, virtual text, line-number highlights)
- The thread view panel
- The summary panel
- (future) the statusline component

**The current propagation is eager and redundant:**

1. Every action handler manually calls `M.redraw()` + `refresh_buffer_highlights(path)`.
2. `refresh_buffer_highlights` iterates **all enabled buffers** and calls
   `decor.refresh()` on each match.
3. `decor.refresh()` re-runs `git.changed_lines()` **synchronously every time** —
   the expensive part — on every single action.

With many files/changes in a single MR, this **blocks the UI** on every action.

There is also a **keymap conflict**: `<leader>od` is documented as
`LocalReviewSummary` in the README, but the user's mental model maps it to
"open thread view" (`LocalReviewOpen`/`LocalReviewHover` → `cmd_open`).

---

## 2. Proposed Solution — A Centralized, Debounced, Event-Driven Sync Bus

New module `lua/lreview/sync.lua` that **owns all propagation**. Action handlers
stop manually calling redraw/refresh; they just emit a cheap "mark dirty" event.

### 2.1 The Sync Module

```lua
-- lua/lreview/sync.lua (new)
local M = {}
local dirty = {}        -- set of dirty bufnrs
local timer = nil
local subscribers = {}  -- kind -> { fn }

--- Mark a buffer as needing a refresh. Cheap, no rendering.
function M.mark_dirty(bufnr) ... end

--- Schedule a debounced flush.
function M.schedule() ... end

--- The debounced flush: recompute diff cache once, refresh dirty buffers,
--- notify subscribed panels.
function M.flush()
  diff_cache.invalidate_if_needed()      -- recompute changed_lines ONCE
  for bufnr in dirty do
    decor.refresh(bufnr)                 -- dirty buffers only
  end
  for _, fn in ipairs(subscribers.panel) do
    fn()                                  -- summary.redraw(), thread_view.redraw()
  end
  dirty = {}
end

--- Panels register to be notified on flush.
function M.subscribe(kind, fn) ... end
```

### 2.2 Debounce

Use a timer (~80ms) so rapid actions (e.g. typing in a scratchpad that triggers
multiple events) coalesce into one flush cycle.

```
[action: add/reply/edit/delete/resolve]
        │
        ▼
   sync.mark_dirty(bufnr)      ← cheap, no rendering
        │
        ▼
   [debounce ~80ms]
        │
        ▼
   sync.flush()
     ├─ recompute diff cache ONCE (not per buffer)
     ├─ decor.refresh(dirty buffers only)
     ├─ summary.redraw()   (if open)
     └─ thread_view.redraw() (if open)
```

### 2.3 Diff Cache

`git.changed_lines()` is the expensive operation. Cache it per
`(target_branch, path)`, invalidated only when:
- The branch changes (new session), or
- A pull/sync happens.

This is the single biggest performance win — currently recomputed on every
refresh.

```lua
-- lua/lreview/diff_cache.lua (new, or fold into sync.lua)
local cache = {}   -- key = target_branch .. ":" .. path -> { lines, at }
function M.get(target_branch, path, cwd) ... end
function M.invalidate_all() ... end
```

### 2.4 Keymap Conflict Resolution

Decouple and make the mapping explicit:

- `<leader>od` → **Summary** (keep README's intent).
- Thread view on hover stays via `LocalReviewHover` (autocmd/keymap).
- Add a distinct key for "open thread at cursor" if needed.
- The summary panel's `open` action (jump to thread) becomes the canonical way
  to reach the thread view from the overview.

Document the split clearly in the README.

---

## 3. Concurrency Model — Main Thread + Worker Threads

> **Update (C1/C2 resolved):** this section previously described a **two-process**
> model (main UI + headless Neovim subprocess). Per [09-async-model.md](09-async-model.md)
> (decided), **all async work migrates to `uv.new_work` threads**. The sync-bus
> concept (debounce, dirty-only, diff cache) is unchanged; only the async
> mechanism differs.

**Critical clarification before designing the implementation.** The user asked
whether this should be modeled as an **SPMC channel** (single-producer,
multiple-consumer). The answer requires distinguishing **which thread** we're
talking about, because there are **two distinct execution contexts** involved,
each with its own producer/consumer relationship.

### 3.1 There Are Two Execution Contexts, Not One

The plugin's async work (pull, user fetch, submit, diff) runs on **`uv.new_work`
worker threads**, not subprocesses. Each thread has its **own** SQLite
connection (WAL allows concurrent access):

```lua
-- review.lua (pull_review_async, migrated to thread)
local pull_work = vim.uv.new_work(function(cwd, detail, db_path, lazy_sqlite)
  -- open own SQLite connection, run sync_review, collect notifications
  return { synced = n, notifications = {...} }
end, function(result)
  vim.schedule(function()
    sync.mark_dirty(all enabled buffers)   -- just another producer event
    sync.flush_now()                       -- immediate flush, skip debounce
  end)
end)
```

So there are **two execution contexts**:

| | **Main Thread (UI)** | **Worker Threads (`uv.new_work`)** |
|:--|:--|:--|
| **What** | The Neovim main thread the user sees | Short-lived worker threads spawned on demand |
| **Lifetime** | Long (the whole editing session) | Short (one pull/sync/submit, then done) |
| **Has UI?** | Yes (buffers, windows, panels) | No (thread, no UI) |
| **Has the DB?** | Yes (its own SQLite connection) | Yes (its **own** SQLite connection) |
| **Runs** | Single-threaded LuaJIT on the main thread | Single-threaded LuaJIT on the worker thread |
| **Communicates** | — | Back to main via `uv.new_work` callback + `vim.schedule` |

**Key point:** there is **no shared memory** between the main thread and worker
threads. Each thread has its **own** SQLite connection (WAL). The only
communication is the worker's return value, delivered to the main thread's event
loop via `vim.schedule`.

### 3.2 Producer/Consumer Inside the Main Thread (the sync bus)

Everything on the main thread runs on **one thread** (driven by Neovim's event
loop). The sync bus lives here:

- **Single producer:** the main thread's event loop. All of these are *producers*
  that call `sync.mark_dirty()`:
  - User actions (add/reply/edit/delete/resolve) — triggered by keymaps/commands.
  - `vim.schedule` callbacks — e.g. a worker thread's completion, libuv timer ticks.
  - Autocmds (hover, buffer events).
- **Multiple consumers:** the panels that subscribe to the bus:
  - `decor.refresh()` (gutter signs/virtual text)
  - `summary.redraw()` (summary panel)
  - `thread_view.redraw()` (thread panel)
  - (future) statusline component

Because producer and consumers share **one thread**, there is **no locking, no
mutex, no race condition** on the bus itself. The "SPMC" framing is a useful
*mental model* (one source of events, many listeners), but the implementation is
a simple **subscriber list + debounce timer**, not a lock-protected queue.

```
        ┌─────────────────────────────────────────────────────────┐
        │  Main Neovim thread (single-threaded)                  │
        │                                                         │
        │  PRODUCERS (all on the main thread)                     │
        │    [user action] ──► sync.mark_dirty()                  │
        │    [vim.schedule] ──► sync.mark_dirty()                 │
        │    [autocmd] ──► sync.mark_dirty()                      │
        │                                                         │
        │        sync.lua (event bus, single-threaded)            │
        │          │                                              │
        │          ├─► decor.refresh()      (consumer)            │
        │          ├─► summary.redraw()     (consumer)            │
        │          └─► thread_view.redraw() (consumer)            │
        └─────────────────────────────────────────────────────────┘
```

### 3.3 Producer/Consumer Across the Thread Boundary (main ← worker)

The **only** place true concurrency exists is **between the main thread and a
worker thread**. Here the producer/consumer relationship is *reversed* relative
to the bus:

- **Worker thread is the producer** — it does the network/DB work and returns a
  result.
- **Main thread is the consumer** — it receives the result via the
  `uv.new_work` callback and reacts.

This boundary is handled by `uv.new_work`'s callback + `vim.schedule`: the
callback fires on the main thread's event loop, and `vim.schedule` defers it to
the main thread. The sync bus must treat the worker's completion as **just
another producer event** inside the main thread:

```
 Worker thread (producer)        Main thread (consumer)
 ┌──────────────────┐  return    ┌──────────────────────────────────┐
 │ uv.new_work      │ ────────►  │ vim.schedule ──► sync.mark_dirty │
 │ does sync_review │            │   (all buffers)   └─► sync.flush │
 └──────────────────┘            └──────────────────────────────────┘
```

### 3.4 The Two Producer/Consumer Relationships, Side by Side

| Relationship | Producer | Consumer | Shared memory? | Synchronization |
|:--|:--|:--|:--|:--|
| **Inside main (the bus)** | Main thread event loop | Panels (decor, summary, thread_view) | Yes (same thread) | None needed — single-threaded |
| **Across main↔worker (thread)** | Worker thread | Main UI | **No** (separate threads, own DB connections) | `uv.new_work` callback + `vim.schedule` |

**The key insight:** the sync bus unifies **both** relationships into one event
stream *inside the main thread*. Whether a change came from a user action
(in-process) or from a worker thread (cross-thread), it arrives as a
`mark_dirty` call on the main thread, and the panels don't care where it came
from. The cross-thread complexity is fully contained at the `vim.schedule`
boundary — the bus itself never sees it.

---

## 4. Tradeoffs & UI Latency

The user asked specifically about the tradeoffs of touching the entire codebase,
and whether there's a UI-latency cost. Here is the honest analysis.

### 4.1 Tradeoff: Refactor Scope vs. Benefit

| Aspect | Cost | Benefit |
|:-------|:-----|:--------|
| **Code touched** | Every action handler in `summary.lua`, `thread_view.lua`, `editor.lua`, `decor.lua` | Single source of truth for propagation |
| **New module** | `sync.lua` + `diff_cache.lua` | Centralized, testable logic |
| **Behavior change** | Redraws become debounced (slightly delayed) | No more per-action full refresh |
| **Risk** | Cache invalidation bugs → stale highlights | Correctness if done right |

**The honest tradeoff:** the sync bus is a **moderate refactor** that touches
most UI files, but the *benefit is concentrated* in one place (the diff cache +
dirty-only refresh). If the diff cache were the only goal, you could get 80% of
the win with a much smaller change (Alt A). The sync bus adds the debounce +
coalescing + extensibility on top.

### 4.2 UI Latency: The Debounce Is the Only Added Latency

The sync bus does **not** add latency to the *action itself* — only to the
*visual refresh* that follows. Specifically:

- **Action latency (unchanged):** the DB write (`comments.add_comment`, etc.)
  happens synchronously in the action handler. The user's comment is saved
  instantly. The sync bus does **not** delay this.
- **Visual refresh latency (added):** the panel/decor update is deferred by the
  debounce (~80ms). This is the *only* added latency, and it's imperceptible for
  a single action.

**The critical rule:** the sync bus must **never** gate the DB write on the
flush. `mark_dirty` is fire-and-forget; the action returns immediately after the
DB write. If the flush were synchronous with the action, we'd reintroduce the
blocking we're trying to remove.

```
action ──► DB write (sync, instant) ──► mark_dirty (fire-and-forget) ──► return
                                                          │
                                                          ▼ (debounce)
                                                   flush (visual only)
```

### 4.3 When Debounce Hurts

Debounce is a net win, but there are edge cases where it's wrong:

- **Immediate feedback expectations:** if a user resolves a thread and expects
  the sign to change *instantly*, an 80ms delay is fine. But if they expect it
  *before* the next keystroke in a fast sequence, it can feel laggy. Mitigation:
  keep the debounce small (50–80ms) and flush immediately on the *last* event.
- **Pull completion:** after a pull, the user expects the panels to update
  promptly. The pull callback should trigger an **immediate flush** (skip the
  debounce), not wait for the next timer tick.

### 4.4 The Real UI-Latency Risk Is Not the Bus — It's the Diff Cache Miss

The biggest UI-latency risk is a **diff-cache miss** during a flush. If
`git.changed_lines()` must run synchronously on a cache miss (e.g. first refresh
of a large MR), that blocks the UI. Mitigations:

1. **Prefetch/warm the cache** asynchronously when the session starts (in the
   background, not on first refresh).
2. **Cache aggressively** — per (target_branch, path), invalidated only on
   branch change / pull.
3. **Fall back to stale-but-fast:** if a recompute would block, show the cached
   (possibly slightly stale) highlights and recompute in the background.

---

## 5. LuaJIT-Specific Quirks & Implementation Details

The user is right to worry about LuaJIT quirks. Here are the concrete ones that
affect this design.

### 5.1 `vim.defer_fn` vs. `vim.uv.new_timer` — Timer Semantics

- `vim.defer_fn(fn, ms)` is the simplest debounce primitive, but it has a quirk:
  it **cannot be cancelled** in older Neovim versions. If you call
  `defer_fn` repeatedly, you can stack up multiple pending callbacks.
- **Recommended:** use a single `vim.uv.new_timer()` that you `:stop()` and
  `:start()` on each `mark_dirty`. This gives a true "reset the debounce"
  semantic (only the last event triggers a flush).

```lua
-- sync.lua — correct debounce with a resettable uv timer
local timer = vim.uv.new_timer()
function M.schedule()
  timer:stop()
  timer:start(80, 0, function()
    vim.schedule(function() M.flush() end)  -- uv timer runs on libuv thread
  end)
end
```

**Quirk:** `vim.uv` timers fire on the **libuv thread**, not the main thread.
You **must** wrap the callback in `vim.schedule()` to get back onto the main
thread before touching Neovim APIs. This is a classic LuaJIT/Neovim gotcha.

### 5.2 `vim.schedule` Is Mandatory for Cross-Thread Callbacks

Any callback that originates from a worker thread (`uv.new_work`) or a libuv
timer runs off the main thread. Touching `vim.api`, buffers, or the DB from
there is **undefined behavior** (can crash or corrupt state). Always wrap in
`vim.schedule`. The sync bus must enforce this at its boundary: `mark_dirty`
from a `vim.schedule` callback is fine; `mark_dirty` from a raw libuv callback
is not.

### 5.3 LuaJIT FFI / SQLite — Per-Thread Connections, No Shared State

The storage layer uses LuaJIT FFI to bind `libsqlite3`. **SQLite connections
are not thread-safe by default.** The sync bus itself is single-threaded
(in-process), so all main-thread DB access stays on one thread. Worker threads
(`uv.new_work`) each open their **own** SQLite connection (WAL mode allows
concurrent readers/writers across threads). The rule: **never share a
connection across threads** — each thread opens its own. This is the thread
model's answer to FFI threading (see [09-async-model.md](09-async-model.md)).

### 5.4 Garbage Collection Pauses

LuaJIT's GC can pause the main thread. The sync bus should avoid allocating
large tables during a flush (e.g. don't build a huge diff table on every
refresh). The diff cache mitigates this by reusing cached tables.

### 5.5 Table Identity & `pairs` Order

The `dirty` set is a Lua table keyed by bufnr. Iterating with `pairs` has
**non-deterministic order** — fine for "refresh all dirty," but if you ever need
ordered refresh (e.g. priority), use an explicit ordered list. For this design,
unordered is fine.

---

## 6. Flow / Sequence

### Before (eager, redundant)

```
handle_action("resolve")
  ├─ review.resolve_thread()
  ├─ M.redraw()                       ← summary redraw
  ├─ refresh_buffer_highlights(path)  ← iterates ALL enabled buffers
  │    └─ decor.refresh(bufnr)        ← re-runs git.changed_lines() per buffer
  └─ vim.notify(...)
```

### After (debounced, dirty-only)

```
handle_action("resolve")
  ├─ review.resolve_thread()          ← DB write, instant
  ├─ sync.mark_dirty(bufnr)           ← fire-and-forget
  └─ sync.schedule()                  ← resettable uv timer
        │  (~80ms later, on main thread via vim.schedule)
        ▼
  sync.flush()
    ├─ diff_cache recompute (once, if needed)
    ├─ decor.refresh(dirty buffers only)
    ├─ summary.redraw() (if open)
    └─ thread_view.redraw() (if open)
```

### Pull Completion (immediate flush, no debounce)

```
[worker thread] ──uv.new_work callback──► vim.schedule
        │
        ▼
  sync.mark_dirty(all enabled buffers)
  sync.flush_now()                ← skip debounce, refresh immediately
```

---

## 7. Before / After

### Before

- Every action: full redraw + refresh of **all** enabled buffers.
- `git.changed_lines()` recomputed synchronously on every refresh.
- Panels redraw independently, not coalesced.
- `<leader>od` ambiguous (Summary vs thread-view).

### After

- Actions emit cheap `mark_dirty` events (fire-and-forget).
- One debounced flush recomputes the diff cache **once**, refreshes **dirty**
  buffers only, and coalesces panel redraws.
- Pull completion triggers an immediate flush.
- Keymaps decoupled and documented.

---

## 8. Pros & Cons

### Pros

- **Responsive UI** even with large MRs (debounced, batched, cached).
- **Single source of truth** for propagation — no scattered redraw calls.
- **Extensible** — new surfaces (statusline) just subscribe.
- **Unifies in-process actions and worker-thread completions** into one event
  stream.
- **No threading complexity** — single-threaded in-process bus, no locks.
- **Fixes the keymap conflict** as part of the rework.

### Cons

- **Refactor risk** — touches every action handler in `summary.lua`,
  `thread_view.lua`, `editor.lua`, `decor.lua`.
- **Debounce introduces visual-refresh latency** (~80ms) — imperceptible for
  single actions, but must be tuned and skipped on pull completion.
- **Cache invalidation correctness** — must invalidate the diff cache on branch
  change / pull, or stale highlights appear.
- **LuaJIT quirks** — `vim.uv` timer threading, `vim.schedule` discipline, GC
  pauses. These are known and manageable, but add implementation care.

---

## 9. Alternatives

### Alt A — Keep eager propagation, just cache `git.changed_lines()`
- **Pros:** Minimal change; biggest single win (diff caching).
- **Cons:** Still refreshes all buffers on every action; panels still redraw
  independently. **Partial** — good first step, but doesn't fully solve it.

### Alt B — Full reactive framework (e.g. event emitter + subscriptions everywhere)
- **Pros:** Cleanest separation.
- **Cons:** Over-engineered for this plugin's size. **Rejected.**

### Alt C — Recommended: sync bus + diff cache (this doc)
- **Pros:** Right-sized; solves the actual bottleneck (diff recompute + all-buffer
  refresh) with a debounced, dirty-only model.
- **Cons:** Moderate refactor. **Accepted.**

### Alt D — Two-phase: diff cache first, sync bus later
- **Pros:** De-risks the refactor — land the diff cache (Alt A) first, measure,
  then add the sync bus on top.
- **Cons:** Two migrations instead of one.
- **Verdict:** Pragmatic. If the diff cache alone solves the latency problem,
  the sync bus may be unnecessary. **Worth considering as the actual rollout
  path.**

---

## 10. Open Questions

1. What debounce interval is best (50ms / 80ms / 100ms)?
2. Should the diff cache be persisted across sessions or only in-memory?
3. Should the statusline component (Doc 02 Alt B) subscribe to the sync bus?
4. How to handle the case where a pull/sync happens while a flush is pending?
   (Proposed: `flush_now()` cancels the pending debounce and flushes
   immediately.)
5. Should the diff cache be **warmed asynchronously** at session start to avoid
   a first-refresh cache-miss block?
6. Should the sync bus expose a `flush_now()` for high-priority events (pull
   completion, explicit user action), or always debounce?

---

## 11. Implementation Status (rediscovered)

The sync bus is **implemented** in `lua/lreview/sync.lua`. This section records
what exists vs the two remaining wiring gaps.

### 11.1 Implemented (verified in source)

| Piece | Location | Notes |
|:--|:--|:--|
| `mark_dirty(bufnr)` | `sync.lua` L59 | Marks dirty + `schedule(80)` |
| Debounced `schedule` | `sync.lua` L77 | `uv.new_timer`, `:stop()`/`:start()`, `vim.schedule` → `flush` |
| `flush()` | `sync.lua` L96 | Refreshes dirty buffers + notifies `panel`/`decor` subscribers |
| `subscribe(kind, fn)` | `sync.lua` L69 | `panel` / `decor` subscriber lists |
| Diff cache | `sync.lua` L11, L27 | `get_changed_lines(cwd, path)` + `invalidate_diff_cache(cwd)` |
| `git.changed_lines` arg fix | `sync.lua` L49 | Resolves target_branch, calls `changed_lines(target, path, cwd)` |

### 11.2 Remaining gaps

1. **Diff-cache invalidation never wired.** `invalidate_diff_cache()` exists
   (L15) but is **never called**. It must be called:
   - On pull completion (in `pull_review_async` callback).
   - On branch change / new session (in `LocalReviewStart`).
   Without this, highlights go stale after a pull or branch switch.
2. **`pull_review_async` bypasses the bus.** `review.lua` L959-977 manually
   iterates `decor.enabled_buffers` + calls `tv.redraw()` + `summary.redraw()`
   instead of going through `sync.mark_dirty(all)` + `sync.flush_now()`. This
   duplicates the bus logic and skips the diff-cache invalidation. Fix: replace
   the manual refresh with `sync.invalidate_diff_cache(cwd)` +
   `sync.mark_dirty(bufnr)` for each enabled buffer + `sync.flush_now()`.

### 11.3 Verification checklist

- [ ] `invalidate_diff_cache` called on pull completion
- [ ] `invalidate_diff_cache` called on branch change / session start
- [ ] `pull_review_async` callback routes through `sync.mark_dirty` + `flush_now`
- [ ] Panels still refresh after pull (no regression)
- [ ] Highlights not stale after pull/branch switch
