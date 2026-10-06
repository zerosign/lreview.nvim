# 07 — Submit Atomicity & `sync_review` Decomposition

**Area:** Core engine robustness (`review.lua`)
**Domain:** 4 — Correctness & Maintainability
**Status:** ✅ **Implemented — superseded the `IN_FLIGHT` design with a `push_ops` outbox**

> **Implementation status (current):** submit runs on `uv.new_work`
> (`submit_review` → `submit_review_thread`), `sync_review` is decomposed into
> `_fetch_remote_threads` + `_reconcile_threads`, the batched reconcile and the
> `with_transaction` wrapper are in place, and crash recovery exists.
>
> **The `IN_FLIGHT` mechanism described throughout this document is NOT what
> shipped, and should not be re-implemented.** Encoding the push lock in
> `comments.state` (bit 4) failed in two ways:
>
> 1. **Stranding.** `PENDING_PUSH_MASK` deliberately excludes `IN_FLIGHT`, so any
>    partial failure that left siblings marked made those drafts invisible to
>    `get_pending_comments` — unpushable until the user restarted Neovim
>    (`recover_in_flight` only ran on session init). Reverting only the *failed*
>    item, as §2.7's code did, guaranteed this on every mid-batch error.
> 2. **Duplicates.** Because success was recorded per category rather than per
>    op, a platform whose API is one-note-per-call (GitLab) had its whole batch
>    reverted to `DRAFT` after a mid-loop failure — re-posting the notes that had
>    already landed on the next submit.
>
> The shipped design keeps §2.6's *separation of concerns* but moves the lock to
> its own table: a comment's state describes only its **content**, and
> `push_ops` rows (`QUEUED → RUNNING → DONE | FAILED`, plus `uncertain` after a
> crash) describe **transmission**. See §2.6.1 and §2.6.2 below, and
> `lua/lreview/storage/outbox.lua`.

---

## 1. Problem

Two correctness/maintainability issues found in the initial architecture review:

### 1.1 Non-Atomic Submit → Partial-Failure Inconsistency

In `submit_review()`:

- New threads are batched, but **replies/edits/deletes are pushed one-by-one in
  a loop**.
- On the first failure it returns `count, err` **mid-way**.
- Already-pushed items were **deleted locally**, but failed ones remain.
- The final `M.sync_review()` only runs on **full success** — so after a partial
  failure, the local DB is out of sync with the remote (some pushed, some not),
  and there is **no resume/retry path** that knows which were already sent.

This is the single most likely source of real-world data inconsistency.

### 1.2 `sync_review()` Is a 40-Complexity Monolith

`sync_review()` (complexity 40) handles ~4 distinct concerns in one 200-line
function with nested loops and manual `vim.mpack.decode` re-decoding:

1. New thread insert + draft preservation + synced update.
2. Modified/conflict detection.
3. Remote-side comment deletion reconciliation.
4. Remote-side thread deletion reconciliation.

The `local_c` → `decoded_lc` re-find dance queries the same comment 2–3 times —
a code smell.

---

## 2. Proposed Solution

### 2.1 Make Submit Resumable / Idempotent

> **Cross-cutting:** whether new threads can be submitted in one batch (vs.
> one-by-one) is gated by the `batch_submit` capability in
> [08-capability-system.md](08-capability-system.md).
>
> **This capability changes the atomicity requirements, not just the code
> path.** With `batch_submit = true`, all new threads go in one network call →
> the batch succeeds or fails together (simpler atomicity). With
> `batch_submit = false`, each thread is a separate call → partial failure is
> *more likely*, so the `IN_FLIGHT` + idempotent-retry machinery below is
> *more critical*. The design must be correct for the one-by-one path even
> though the batch path is the common case.

**Goal:** after a partial failure, a retry must not double-push, and the local
DB must reflect reality.

**Approach — per-item `IN_FLIGHT` state + idempotent retry:**

> **Superseded as written, kept for the reasoning.** The goal above is met, but
> the mechanism is not this one: the transient state lives in the `push_ops`
> outbox (§2.6.1b), not on the comment. Placing it on the comment is precisely
> what broke the goal — the naming note below was the first symptom, since
> "pending" vs "in flight" only conflicts when both are crammed into one column.
> See the status banner at the top of this document.

> **Naming note:** the transient state is `IN_FLIGHT` (not `PUSHING` or
> `PENDING`). `PENDING` would collide with the existing `PENDING_PUSH_MASK`
> (which already means "needs to be pushed" = DRAFT/MODIFIED/DELETED) and
> describes the wrong phase — the item isn't waiting, it's actively being
> transmitted. `IN_FLIGHT` is unambiguous about the transient in-progress
> nature.

1. Add an `IN_FLIGHT` state (or an `in_flight` flag) to comments that are
   currently being submitted.
2. Before pushing each item, mark it `IN_FLIGHT` (persisted).
3. On success, transition to `SYNCED` (or delete for new threads) and store the
   `remote_id`.
4. On failure, revert `IN_FLIGHT` → original state, and **record which items
   succeeded** so a retry skips them.
5. Always run `sync_review()` at the end — even on partial failure — to
   reconcile local state with the remote.

**Idempotency:** because each item stores its `remote_id` once pushed, a retry
can detect "already pushed" and skip. New threads get their `remote_id` back
from the batch response.

```lua
-- review.lua (submit_review, revised)
for _, r in ipairs(replies) do
  comments.mark_in_flight(r.c_id)               -- persist IN_FLIGHT
  local comment_id, err = adapter.submit_reply(...)
  if not comment_id then
    comments.revert_in_flight(r.c_id)           -- back to DRAFT/MODIFIED
    M.sync_review()                             -- reconcile, even on failure
    return count, err
  end
  comments.mark_synced(r.c_id, comment_id)      -- store remote_id
  count = count + 1
end
M.sync_review()                                 -- always reconcile at end
```

### 2.2 Decompose `sync_review()` into Focused Functions

Split into small, testable pieces:

```lua
-- review.lua (sync_review, decomposed)
function M.sync_review()
  local remote_threads, err = adapter.fetch_threads(...)
  if not remote_threads then return 0, err end

  local remote_t_ids, remote_c_ids = M._sync_threads(remote_threads, detail)
  M._reconcile_remote_comment_deletions(detail, remote_c_ids)
  M._reconcile_remote_thread_deletions(detail, remote_t_ids)
  return #remote_threads, nil
end

function M._sync_threads(remote_threads, detail) ... end   -- insert/update threads + comments
function M._reconcile_remote_comment_deletions(detail, remote_c_ids) ... end
function M._reconcile_remote_thread_deletions(detail, remote_t_ids) ... end
```

**Also:** introduce a single `decode_row()`/`encode_row()` helper (or a typed
accessor layer) to replace the manual `vim.mpack.decode` re-decoding and the
`local_c` → `decoded_lc` re-find dance.

### 2.3 The Change-Diff / Intent Model — the Foundation for Idempotency

> **Key insight (from review):** idempotency is the real win here, but it
> requires **diffing the pending changes first** — computing exactly *what* is
> added, removed, and updated — before submitting. The `IN_FLIGHT` state alone is
> not enough; we need a **change-set** that both drives the submit and lets a
> retry detect what was already pushed.

The plugin already has the raw material: `get_pending_comments()` queries
comments whose state matches `PENDING_PUSH_MASK` (DRAFT + MODIFIED + DELETED).
But this is an implicit, ad-hoc diff. We should make it an **explicit, typed
change-set**:

```lua
-- review.lua — compute the change-set (the "diff" of local intent)
-- Returns a typed structure, NOT a flat list of comments.
function M.compute_change_set(mo_id)
  local pending = comments.get_pending_comments(mo_id)
  local cs = {
    additions = {},   -- new threads (DRAFT thread + DRAFT comment)
    replies   = {},   -- replies to existing synced threads
    updates   = {},   -- MODIFIED comments (edit)
    deletions = {},   -- DELETED comments (soft-delete to push)
  }
  for _, d in ipairs(pending) do
    if d.state == comments.STATE.DELETED then
      cs.deletions[#cs.deletions + 1] = d
    elseif d.state == comments.STATE.MODIFIED then
      cs.updates[#cs.updates + 1] = d
    elseif comments.thread_is_draft(d.thread_state) then
      cs.additions[#cs.additions + 1] = d
    else
      cs.replies[#cs.replies + 1] = d
    end
  end
  return cs
end
```

**Why this is the foundation for idempotency:**

- **It defines "what needs to be pushed"** — the change-set is the single source
  of truth for the submit loop. No scattered `if state == ...` checks.
- **It enables "what was already pushed"** — after a partial failure, the
  change-set is recomputed; items that transitioned to `SYNCED` (or were
  deleted) drop out of the set, so a retry naturally skips them. **This is what
  makes retries idempotent** — not a separate "already pushed" list, but the
  state transition itself.
- **It's the same lens as `sync_review`** — the reconcile logic (doc 07 §2.2)
  and the submit logic both operate on the same state machine, so they agree on
  what's pending vs. synced.

**The state machine as the diff:**

| Local state | Meaning | In change-set? | After successful push |
|:--|:--|:--|:--|
| `DRAFT` (new thread) | addition | ✅ additions | thread → `SYNCED`, comment → `SYNCED` + `remote_id` |
| `DRAFT` (reply) | reply | ✅ replies | comment → `SYNCED` + `remote_id` |
| `MODIFIED` | update | ✅ updates | comment → `SYNCED` (body = pushed body) |
| `DELETED` | removal | ✅ deletions | comment hard-deleted |
| `SYNCED` | clean | ❌ not in set | — |
| `CONFLICT` | blocked | ❌ (blocks submit) | — |

**The change-set is the contract between submit and sync.** Both consume the
same state machine, so a retry after partial failure recomputes the set, sees
only the still-pending items, and pushes exactly those. This is the cleanest
form of idempotency — it falls out of the state transitions, not a parallel
bookkeeping structure.

### 2.4 User Feedback — Success / Failure / Partial-Failure

> **Gap (from review):** the current `submit_review` returns `count, err` but
> gives the user **no clear feedback** on what happened. The revised flow must
> tell the user, unambiguously, whether the submit fully succeeded, partially
> failed, or failed entirely — and what to do next.

**Feedback contract** (all via `vim.notify`, replayed on the main thread from
the `uv.new_work` callback — see §2.5):

| Outcome | User sees | Next step |
|:--|:--|:--|
| **Full success** | `"Pushed N change(s) to <provider>"` (INFO) | none |
| **Partial failure** | `"Pushed N of M change(s); K failed. Retry with :LocalReviewSubmit"` (WARN) + per-item error detail | retry; already-pushed items are skipped (idempotent) |
| **Full failure** | `"Failed to push: <err>"` (ERROR) | fix and retry |
| **Blocked by conflicts** | `"K conflict(s) must be resolved before pushing"` (WARN) | resolve conflicts first |
| **Cancelled** | `"push cancelled"` (INFO) | none |

**Per-item detail:** on partial failure, the notification should list *which*
items failed and why (e.g. `"reply to <path>:<line> failed: <err>"`), so the
user knows what to fix. This is collected into the change-set result and
replayed on the main thread.

**The `IN_FLIGHT` state also gives feedback:** while a submit is in flight, the
statusline (doc 04) can show `"pushing 3/5..."` — a live progress indicator
driven by the change-set count.

### 2.5 Integration with `uv.new_work` (from Doc 09)

> **Cross-cutting:** the submit path is **network I/O** (the slowest category in
> doc 09 §8). It must run on the `uv.new_work` thread, not block the main thread.
>
> **Capability interplay (doc 08):** the submit path's network calls
> (`submit_inline_review`, `submit_reply`, `update_comment`, `delete_comment`,
> `approve_mr`) all run on the thread. The `batch_submit` capability decides
> whether the new-thread call is one batched call or N one-by-one calls — both
> run on the thread. The verdict path (`review_verdict` → `approve_mr`) is also
> thread work. See doc 08 §3.1 for the full capability→action→event matrix.

The submit flow runs on the thread exactly like `sync_review` (doc 09 §7):

1. **On the main thread:** resolve the adapter/ctx (uses `vim.fn`, not
   thread-safe), compute the change-set (pure DB read), and show the confirm
   popup (doc 03).
2. **On the thread:** run the push loop (network calls via `base.run`), updating
   the DB via the thread's **own** connection. Collect `{msg, level}`
   notifications and the per-item results.
3. **Back on the main thread (via `vim.schedule`):** replay notifications,
   refresh panels, and show the outcome (success/partial/failure per §2.4).

```lua
-- review.lua — submit on the thread
local submit_work = vim.uv.new_work(function(cwd, detail, resolved, change_set, db_path, lazy_sqlite)
  -- open own connection, run the push loop, update DB, collect notifications
  return { ok = ..., pushed = n, failed = m, notifications = {...} }
end, function(result)
  vim.schedule(function()
    for _, n in ipairs(result.notifications) do vim.notify(n[1], n[2]) end
    -- refresh panels
  end)
end)
```

**Thread-awareness of the `IN_FLIGHT` state (doc 09 §8.6):** the `IN_FLIGHT` state
lives in the DB, which the thread writes via its own connection. Because the
thread and main process use **separate connections** (WAL), the state transition
is safe. The main thread reads `IN_FLIGHT` for the statusline progress indicator;
the thread writes it. No shared-memory race (separate connections, WAL).

**Idempotency across the thread boundary:** the change-set is computed on the
main thread *before* queueing, but the **state transitions happen on the
thread**. On a retry, the change-set is recomputed on the main thread from the
(now-updated) DB — so items the thread already pushed to `SYNCED` drop out. The
idempotency comes from the state machine, not from passing the stale change-set
around.

### 2.6 State Machine (Graph)

> **Rendering:** these are **Mermaid `stateDiagram-v2`** diagrams, which render
> natively in leaf/GitHub markdown viewers (no plugin needed). Nodes = states,
> edges = the action that triggers the transition.

#### 2.6.1 Comment state machine (content only)

A comment's state describes **what its content is** relative to the hub. It says
nothing about transmission — that is the outbox's job (§2.6.1b). This separation
is the whole point: the v3 design folded the push lock into this graph as
`IN_FLIGHT`, and that is what stranded drafts and duplicated notes.

```mermaid
stateDiagram-v2
    [*] --> DRAFT : create comment / reply

    DRAFT --> SYNCED : reply landed (remote id recorded)
    DRAFT --> [*] : new thread landed (row consumed, reconcile re-imports)

    SYNCED --> MODIFIED : edit locally
    SYNCED --> DELETED : delete locally (soft)

    MODIFIED --> SYNCED : edit landed (mark_clean)
    MODIFIED --> CONFLICT : remote edited while pending
    DELETED --> CONFLICT : remote edited while pending
    DELETED --> [*] : delete landed

    CONFLICT --> MODIFIED : resolve keep-local
    CONFLICT --> SYNCED : resolve accept-remote
```

**Legend of the edges (actions):**

| Edge | Action | Function |
|:--|:--|:--|
| `[*] → DRAFT` | Create comment / reply | `add_comment` |
| `SYNCED → MODIFIED` | Edit a synced comment | `update_comment_body_and_state(..., MODIFIED)` |
| `SYNCED → DELETED` | Delete a synced comment (soft) | `soft_delete_comment` |
| `MODIFIED → SYNCED` | Edit pushed | `mark_clean` (inside the op's commit txn) |
| `DRAFT → SYNCED` | Reply pushed | `mark_comment_synced` (inside the op's commit txn) |
| `DRAFT/DELETED → [*]` | New thread / delete pushed | `delete_comment` (inside the op's commit txn) |
| `MODIFIED/DELETED → CONFLICT` | Remote changed while pending | `mark_comment_conflict` |
| `CONFLICT → MODIFIED` | Resolve keep-local | `resolve_conflict_keep_local` |
| `CONFLICT → SYNCED` | Resolve accept-remote | `resolve_conflict_accept_remote` |

Bit 4 is reserved (it was `IN_FLIGHT`) so a v3 row cannot be misread.

#### 2.6.1b Push-op outbox state machine (transmission)

Each pending mutation is one row in `push_ops`, keyed `(c_id, op)`. This is the
`RUNNING`/`DONE`/`FAILED` machinery §2.1 asked for — kept in its own table so a
comment's content state is never a lock.

```mermaid
stateDiagram-v2
    [*] --> QUEUED : outbox.enqueue (dedupe on c_id + op)
    QUEUED --> RUNNING : about to call the hub
    RUNNING --> DONE : call ok and local transition committed
    RUNNING --> FAILED : call errored
    RUNNING --> QUEUED : all-or-nothing batch failed, nothing landed
    RUNNING --> QUEUED : recover_stale after a crash, sets uncertain
    FAILED --> RUNNING : the next submit retries it
    QUEUED --> DONE : reconcile adopts it by body match (uncertain)
    DONE --> [*] : prune_done / GC

    DONE --> DONE : terminal, never re-executed
```

**Legend:**

| Edge | Action | Function |
|:--|:--|:--|
| `[*] → QUEUED` | Build ops from the change-set, then queue | `review.build_ops` + `outbox.enqueue` |
| `QUEUED → RUNNING` | Take the lock before the call | `outbox.mark_running` |
| `RUNNING → DONE` | Commit success (same txn as the comment transition) | `outbox.mark_done` |
| `RUNNING → FAILED` | Record the error, stop the category | `outbox.mark_failed` |
| `RUNNING → QUEUED` | Batch failed as a whole (GitHub) | `outbox.mark_queued` |
| `RUNNING → QUEUED(uncertain)` | Startup crash recovery | `outbox.recover_stale` |
| `QUEUED → DONE` | Remote already has our body | `outbox.adopt` from `_reconcile_threads` |
| `FAILED → RUNNING` | Retry | next `:LocalReviewSubmit` (`pending` includes FAILED) |

**Invariants:**
- A comment's state is **never** a push lock, so nothing can become unpushable
  because a submit was interrupted.
- `DONE` is **terminal**: `pending()` excludes it, and `enqueue` dedupes on
  `(c_id, op)` over non-terminal rows, so a mutation cannot be queued twice.
- `pending` = anything not `DONE` (`QUEUED`, `RUNNING`, `FAILED`) — FAILED rows
  are retried by definition, which is why no revert step is needed anywhere.
- `uncertain` is only ever set by crash recovery or a lost local commit, and is
  the sole permission for reconcile to adopt a remote comment into a local op.
- `CONFLICT` remains a **sink** requiring user action — it blocks submit until
  `:LocalReviewConflicts` resolves it.
- `SYNCED` is the **stable** state — matches remote, absent from the change-set.

#### 2.6.2 Thread state machine

Threads are simpler — the `RESOLVED` bit is combinable with `SYNCED`.

```mermaid
stateDiagram-v2
    [*] --> DRAFT : create new thread (local)
    DRAFT --> SYNCED : push ok (new thread batch)
    SYNCED --> SYNCED_RESOLVED : resolve
    SYNCED_RESOLVED --> SYNCED : unresolve
    SYNCED --> CONFLICT : remote deleted while local drafts
    DRAFT --> CONFLICT : remote deleted while local drafts
    CONFLICT --> [*] : resolve / delete
```

**Legend:**

| Edge | Action | Function |
|:--|:--|:--|
| `[*] → DRAFT` | Create new thread | `create_thread` |
| `DRAFT → SYNCED` | New thread pushed | `mark_synced` |
| `SYNCED ↔ SYNCED_RESOLVED` | Resolve / unresolve | `resolve_thread` |
| `→ CONFLICT` | Remote deleted while local drafts | `mark_thread_conflict` |

> **Note:** `SYNCED_RESOLVED` is not a separate state value — it's the `SYNCED`
> bit OR'd with the `RESOLVED` bit (state = 2 | 4 = 6). The diagram shows it as
> a distinct node for clarity.

### 2.7 SQLite Transaction Strategy

**Today:** every `storage.execute`/`storage.query` is a single auto-commit
statement. There is no `BEGIN`/`COMMIT`/`ROLLBACK` wrapper anywhere. Each
`mark_comment_synced` is actually *two* statements (a `SELECT` + an
`INSERT OR REPLACE` via `add_comment`), each committed independently.

**Why the submit path needs transactions:** the submit does a multi-item,
multi-step write — mark all items `IN_FLIGHT` (N writes) → push → mark all
items `SYNCED` (N writes). Without a transaction, a crash mid-way leaves the
DB half-committed (some `IN_FLIGHT`, some `SYNCED`, some still `DRAFT`) — the
exact inconsistency this doc exists to prevent.

#### 2.7.1 The critical rule: never hold a write txn across the network

The network push **must never be inside a SQLite write transaction**. Holding
a write lock across a network round-trip (seconds) would:
- block the UI thread's per-buffer reads for the whole duration,
- block the GC thread's writes,
- defeat the entire point of the async model (doc 09).

So the structure is **two short transactions bracketing the network call**:

```
BEGIN IMMEDIATE;              -- Txn 1: fast, local, all-or-nothing
  mark all items IN_FLIGHT
COMMIT;
... network push (NO txn) ... -- slow, on uv.new_work thread
BEGIN IMMEDIATE;              -- Txn 2: fast, local, all-or-nothing
  mark all items SYNCED (or revert to prior state on failure)
COMMIT;
```

#### 2.7.2 Perf: this is cheap, not a lag source

The transactions are **microsecond-scale**, so they do not lag the UI:

- **WAL mode is already on** (`storage/init.lua:87`) — readers don't block
  writers and writers don't block readers.
- **`synchronous=NORMAL`** (`storage/init.lua:88`) — no fsync per commit, only
  at checkpoint.
- Each txn is a handful of tiny `UPDATE`/`INSERT` statements on indexed rows.
- The **only slow part is the network call, and it's outside any txn** — and it
  runs on the `uv.new_work` thread (doc 09), so the UI never blocks on it.

The UI-lag concern is really about *network + DB writes on the main thread*.
Doc 09 already moves the network to a thread. The DB writes are so fast
(sub-ms for a few rows in WAL) they don't need to move off the main thread —
but if we want to be extra safe, the whole submit (txn 1 + network + txn 2)
runs on the thread with its **own connection**, which is doc 09 §7's sketch.

#### 2.7.3 Helper

Add a small transaction wrapper to `storage/init.lua`:

```lua
--- Run a function inside a transaction. Returns (ok, err).
---@param fn fun(): boolean|nil, string|nil
---@return boolean, string|nil
function M.transaction(fn)
  ensure_db()
  M.db:execute("BEGIN IMMEDIATE")
  local ok, err = pcall(fn)
  if not ok then
    M.db:execute("ROLLBACK")
    return false, err
  end
  M.db:execute("COMMIT")
  return true, nil
end
```

`BEGIN IMMEDIATE` (not `BEGIN`) takes the write lock up front, so the
all-or-nothing guarantee holds even if a concurrent writer sneaks in between
the `BEGIN` and the first write.

#### 2.7.4 Where transactions wrap in the submit path

| Phase | Wrapped? | Why |
|:--|:--|:--|
| Mark `IN_FLIGHT` (before push) | **Yes** (txn 1) | all-or-nothing: no partial in-flight |
| Network push | **No** | must not hold write lock across network |
| Mark `SYNCED` / revert (after push) | **Yes** (txn 2) | all-or-nothing: no partial sync |
| `sync_review()` reconcile | **Yes** (own txn) | batch of inserts/updates from remote |

### 2.8 Scaling for Large MRs

**The transaction design is O(1) overhead regardless of MR size** — txn 1 and
txn 2 are each a single `BEGIN`/`COMMIT` pair, identical for 1 comment or 500.
WAL + `synchronous=NORMAL` keep commits cheap. The network (the real O(N)
cost) is outside any txn and on the thread. **Transactions are not the scaling
concern.**

The real scaling pressure is in the **existing `sync_review` reconcile loop**
(`review.lua:426-560`), which is **O(N) queries for N comments**:

| Line | Query | Runs per |
|:--|:--|:--|
| `review.lua:469` | `SELECT * FROM comments WHERE t_id = ?` | every remote comment |
| `review.lua:480` | `comments.comments_for_thread(t_id)` | every remote comment |
| `review.lua:491` | `SELECT * FROM comments WHERE c_id = ?` | every DELETED comment |

So a single comment can trigger **3 separate queries** (parse + bind + step +
finalize each). A 300-comment MR → ~900 queries, on the main thread today.
**This is the real lag source on big MRs.**

#### 2.8.1 Fix: batch the reconcile into one query + in-memory index

Load all local comments for the MR **once**, index them in a Lua table, then do
the reconciliation in memory — zero DB queries in the inner loop:

```lua
-- ONE query for the whole MR, indexed by t_id → c_id
local local_by_thread = {}
for _, lc in ipairs(storage.query([[
  SELECT c.*, t.path, t.line_start, t.line_end, t.state as thread_state
  FROM comments c JOIN threads t ON c.t_id = t.t_id
  WHERE t.mo_id = ?
]], detail.mo_id)) do
  local_by_thread[lc.t_id] = local_by_thread[lc.t_id] or {}
  local_by_thread[lc.t_id][lc.c_id] = lc
end

-- inner loop: pure in-memory lookup, no DB
local lc = local_by_thread[t.t_id] and local_by_thread[t.t_id][c.c_id]
```

This turns **~3N queries → 1 query + O(N) in-memory lookups**. The same
batching applies to the remote-deletion pass (`review.lua:568`) and the
thread-deletion pass (`review.lua:600`), which already use single queries.

#### 2.8.2 The UI hot path already scales

`comments_for_buffer` (`comments.lua:342`) is a **single indexed query** using
`idx_threads_buffer(mo_id, path, line_start, line_end)` — it returns all
comments for a file+line range in one shot. That's O(comments in buffer), not
O(comments in MR). Rendering a buffer does not degrade with MR size.

#### 2.8.3 Submit path already scales

`submit_review` does one `get_pending_comments(mo_id)` query (single indexed
query), then groups into `new_threads_batch`/`replies`/`edits`/`deletes`. The
per-item work is the network push (on the thread) + txn-wrapped state
transitions. No N+1 there.

#### 2.8.4 Composition with the async model

The batched `sync_review` runs on the `uv.new_work` thread (doc 09) with its
**own connection**, so even the O(N) reconcile work never blocks the UI. The
main thread only ever runs the O(1) per-buffer query.

#### 2.8.5 Measured benchmark (lsqlite3, in-memory, WAL)

> Full methodology, raw data, and the bitmap analysis live in
> [10-benchmark.md](10-benchmark.md). This is the summary.

Benchmarked the actual query patterns with `lsqlite3` (SQLite 3.53.4) across
the three scaling dimensions — **files changed**, **threads per file**, and
**pending comment changes** (creation/replies/edits/deletions). Times are
single-run wall-clock on the main thread (the worst case, before the async
move):

| Scenario | files | threads | total cmts | pending | N+1 reconcile | batched reconcile | txn (500) | per-buffer | change-set |
|:--|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| small | 5 | 10 | 40 | 10 | 0.7 ms | 0.11 ms | 0.02 ms | 0.04 ms | 0.08 ms |
| medium | 20 | 80 | 450 | 50 | 8.5 ms | 0.96 ms | 0.07 ms | 0.06 ms | 0.18 ms |
| large | 50 | 400 | 3,400 | 200 | **72 ms** | 6.5 ms | 0.30 ms | 0.13 ms | 0.77 ms |
| huge | 100 | 1,200 | 14,900 | 500 | **361 ms** | 31 ms | 0.78 ms | 0.32 ms | 2.9 ms |

**What the data confirms:**

- **The N+1 reconcile is the real lag source.** It grows linearly with comment
  count: 0.7 → 8.5 → 72 → 361 ms. At 3,400 comments it's a visible UI hitch;
  at 14,900 it's a half-second freeze — **on the main thread today**.
- **Batching is an ~11x win.** 72 → 6.5 ms (large), 361 → 31 ms (huge). Even at
  15k comments the batched reconcile is 31 ms — and it runs on the thread
  (doc 09), so the UI never sees it.
- **Transactions are negligible** — and actually *faster* than auto-commit
  (0.78 → 0.63 ms for 500 writes) because a single commit avoids per-statement
  fsyncs. Confirms §2.7: wrap the local writes, never the network.
- **The per-buffer query scales flat** (0.04 → 0.32 ms) — indexed by
  `(mo_id, path, line_start, line_end)`, it's O(comments in buffer), not
  O(comments in MR). The UI hot path is not a concern even at 15k comments.
- **The change-set query scales fine** (0.08 → 2.9 ms) — one indexed query.

**On the bitmap idea:** the batched reconcile is already 31 ms at 15k comments
via a single SQL scan + in-memory hash index. A bitmap would add a data
structure to represent a set SQLite already produces efficiently — and comment
IDs are UUIDs, not dense integers, so a bitmap would need a hash→index mapping
(a *second* structure). The measured cost is the SQL scan, not the in-memory
work, so a bitmap buys nothing. **Rejected — keep the batched query + hash
index.**

---

## 3. Flow / Sequence

### Submit (shipped — outbox-driven)

```
submit_review(thread_id?, callback)                   [main thread]
  ├─ guards: session, adapter.resolve, count_conflicts → bail if any
  ├─ confirm_submit(resolved, thread_id, done)         [float; done fires on keypress]
  │    └─ lines built from compute_change_set(mo_id)
  └─ done(verdict, cancelled):
       ├─ test mode → _submit_pushes(...) + sync_review()   [synchronous]
       └─ else → ensure_submit_worker()
                 thread.arm("review.submit", callback)      ← per-call callback
                 submit_worker:queue({cwd, detail, thread_id, verdict})

_submit_pushes(detail, resolved, ctx, thread_id, verdict)   [shared main/worker]
  ├─ conflicts → return 0, "...:LocalReviewConflicts...", pending
  ├─ build_ops(...)            → op descriptors (pure; verdict op when it cannot ride)
  ├─ outbox.enqueue(ops)       1 txn, dedupe by (c_id, op), delete supersedes edit
  └─ per category in create → reply → edit → delete → verdict:
       ├─ outbox.mark_running(op)
       ├─ adapter call
       ├─ ok  → txn { outbox.mark_done(op, remote_id); comment transition }  pushed++
       └─ err → outbox.mark_failed(op)  (or mark_queued for an atomic batch
              that failed as a whole) → stop THIS category, rest stay QUEUED

submit_review_thread(...)  [uv.new_work]
  ├─ _submit_pushes(...)
  ├─ _fetch_remote_threads + _reconcile_threads   (adopts uncertain ops)
  ├─ outbox.prune_done(mo_id)
  └─ return { ok, count, err, remaining, notifications }

completion                                   [main thread, vim.schedule]
  ├─ replay queued notifications
  ├─ success → refresh_review_ui(): invalidate diff cache + mark_dirty + schedule
  ├─ err      → vim.notify("push failed: ...")
  ├─ remaining>0 → notify "N still queued, run :LocalReviewSubmit again"
  └─ thread.dispatch_cb("review.submit", ok, count, err, remaining) → callback
```

### Sync (decomposed)

```
sync_review()  =  _fetch_remote_threads(detail, resolved, ctx)   [network]
                  _reconcile_threads(detail, remote_threads)     [pure DB, one batch]

_reconcile_threads() does, in order:
  ├─ load every local comment for the MR once → in-memory index by (t_id, c_id)
  ├─ build the uncertain-op index (outbox.uncertain_by_body) for crash adoption
  ├─ upsert remote threads (DRAFT threads never overwritten)
  ├─ per remote comment: DRAFT untouched / SYNCED refresh / MODIFIED+DELETED
  │    conflict-detect / no local copy → adopt-or-insert
  ├─ remote-deleted comments  (uses idx_comments_remote)
  └─ remote-deleted threads   (orphaned drafts become a thread conflict)
```

---

## 4. Before / After

### Before (submit)

```
loop replies/edits/deletes:
  push → delete locally on success
  on failure: return count, err   ← mid-way, no reconcile
sync_review() only on full success
```

**Problems:** Partial failure leaves DB out of sync. No resume path. No
reconcile on failure.

### After (submit — as shipped)

```
build_ops() → outbox.enqueue()  [1 txn, dedupe by (c_id, op)]
queue submit_review_thread (uv.new_work):
  per category (create → reply → edit → delete → verdict):
    mark_running → push → txn{ mark_done(remote_id) + comment transition }
    on failure: mark_failed (or mark_queued for an atomic batch) → stop category
  _fetch_remote_threads + _reconcile_threads   ← ALWAYS runs, even on partial failure
  outbox.prune_done()
completion (main thread): replay notifications → refresh UI → (ok, count, err, remaining)
```

**Improvements:** Idempotent by construction (`DONE` is terminal and `enqueue`
dedupes), so a retry can never re-post what landed. Partial failure leaves the
untouched ops `QUEUED` rather than in a state the pending mask excludes. Local DB
reconciled even on failure. Crash recovery adopts landed-but-unrecorded ops by
body match. Verdict is an op of its own, so it is never dropped. Reports
"pushed N, M left" instead of aborting as if atomic. Runs on the thread (no UI
block).

### Before (sync)

```
sync_review() — 40-complexity monolith, nested loops, manual mpack re-decoding
```

### After (sync)

```
sync_review() → _sync_threads + _reconcile_remote_comment_deletions
              + _reconcile_remote_thread_deletions
```

**Improvements:** Testable, readable, single decode helper.

---

## 5. Pros & Cons

### Pros

- **Data integrity** — no more partial-failure inconsistency.
- **Resumable** — retries are safe and idempotent (via the change-set + state
  transitions).
- **Clear feedback** — user always knows success/partial/failure and next step.
- **Non-blocking** — submit runs on the `uv.new_work` thread (doc 09).
- **Maintainable** — `sync_review` becomes testable units; the change-set is a
  typed, testable structure.
- **Foundation** — Doc 03 (verdict) builds on the revised submit flow.

### Cons

- **New table** (`push_ops`) — a schema bump and one more thing to keep tidy
  (GC and `prune_done` handle it, but it is real bookkeeping).
- **Change-set abstraction** — a new typed structure + `compute_change_set()`
  to build and maintain.
- **Refactor risk** — `sync_review` is the highest-risk function; needs good
  test coverage before/after.
- **Per-op round trips on non-atomic hubs** — GitLab gets one CLI call per note,
  so a large batch is slower than GitHub's single review POST (the price of
  knowing exactly which notes landed).
- **Thread plumbing** — the submit path needs the `uv.new_work` wrapper + own
  connection (doc 09 §7), notification replay, and per-call callback slots.
- **Verdict shape differs per hub** — expressed as three capability flags rather
  than one boolean, which is more honest but more to document.

---

## 6. Alternatives

### Alt A — Make the whole submit a single atomic batch (all-or-nothing)
- **Pros:** Simplest mental model.
- **Cons:** Not all platforms support batch replies/edits/deletes; a single
  failure would roll back everything (or require compensating calls). Hard to
  guarantee. **Rejected** — not feasible across platforms.

### Alt B — Keep per-item push, but always run `sync_review()` on failure
- **Pros:** Minimal change (just move the reconcile call).
- **Cons:** Doesn't solve the resume problem — a retry could double-push items
  that succeeded but weren't reconciled. **Partial** — good first step.

### Alt C — Recommended: change-set + transient push state + idempotent retry + reconcile
- **Pros:** Correct, resumable, safe retries (idempotency falls out of the state
  transitions). Clear feedback. Runs on the thread.
- **Cons:** More state + a change-set abstraction. **Accepted.**
- **Shipped variant:** the *transient push state* component was replaced. Putting
  it on the comment (§2.6.1 as originally drawn) is what stranded drafts and
  duplicated notes; the shipped design keeps the rest of Alt C and moves the
  transient state into the `push_ops` table (§2.6.1b). Same guarantees, and the
  comment's content state is never a lock.

---

## 7. Open Questions (resolved)

1. **Persisted transient state or in-memory flag?** — Persisted, but in its own
   table (`push_ops.status`), not on the comment. On the comment it collided with
   the pending-push mask, which is how drafts got stranded.
2. **Crash during a push?** — `outbox.recover_stale()` (called from
   `init_session` / `init_session_async`) re-queues any `RUNNING` row and sets
   `uncertain = 1`. The next reconcile adopts the comment by body match if the hub
   already has it, so the answer is "adopt, don't re-send".
3. **Per-item `remote_id`s from the new-thread batch?** — Not available. GitHub's
   review POST returns the review, not comment ids, so the batch commits its ops
   as `DONE` with no `remote_id` and the following reconcile re-imports the synced
   rows. The per-note (GitLab) path likewise relies on reconcile. Idempotency does
   not depend on having the ids, because `DONE` is terminal.
4. **Pure function or materialized change-set?** — Pure function
   (`compute_change_set(mo_id)`), *plus* the outbox rows. The change-set decides
   what to queue; the outbox records what has been attempted. A materialized
   pending-changes table would have duplicated the outbox.
5. **Aggregated or per-item error feedback?** — First error of the run is reported
   (`_submit_pushes` returns one `err`), with the count of ops still queued
   (`remaining`), and each failed op stores its own error on its row so
   `push_ops.error` is the per-item record when someone wants the detail.

---

## 8. Implementation Status (current)

### 8.1 Implemented (verified in source)

| Piece | Location | Notes |
|:--|:--|:--|
| Push-op outbox | `storage/outbox.lua` | `push_ops` table (schema v4): `enqueue` (dedupe by `(c_id, op)` + delete-supersedes-edit + payload refresh), `mark_running/done/failed/queued/uncertain`, `pending`, `recover_stale`, `uncertain_by_body`, `adopt`, `prune_done` |
| `with_transaction` wrapper | `storage/init.lua` | `BEGIN` / `COMMIT` / `ROLLBACK`; used for enqueue and for each op's commit |
| `compute_change_set` | `review.lua` | Typed `{additions, replies, updates, deletions}`; feeds `build_ops` |
| `build_ops` / `reply_parent` | `review.lua` | Pure op-descriptor builder; resolves a threadable parent or reports why not |
| Outbox-driven submit | `review.lua` `_submit_pushes` | Category order create → reply → edit → delete → verdict; per-op commit; returns `(pushed, err, remaining)` |
| Batched reconcile + adoption | `review.lua` `_reconcile_threads` | Single query + in-memory index (doc 10 ~11x win), plus uncertain-op adoption by body match |
| Submit on a thread | `review.lua` `submit_review_thread` | `uv.new_work` + own DB connection + notification replay |
| Per-call callback slots | `thread.lua` `arm` / `dispatch_cb` | Singleton workers no longer replay the first caller's callback |
| Verdict as an op | `adapter/github.lua`, `adapter/gitlab.lua` `submit_verdict` | Capability-gated; an unsupported verdict reports instead of dropping |
| Crash recovery | `review.lua` `init_session` / `init_session_async` | `outbox.recover_stale()` on session start |
| Conflict resolution surface | `ui/conflicts.lua`, `:LocalReviewConflicts` | The exit door the conflict-gate error message promises |

### 8.2 Follow-up work (not part of this plan)

1. **Multi-line comment fidelity.** `build_ops` snapshots `end_line`, but neither
   adapter sends a range yet — ranged drafts collapse to a single line on both hubs.
2. **Head-sha pre-flight.** Drafts written against an older `head_sha` are pushed
   as-is; GitHub rejects comments on lines outside the current diff (422), which
   surfaces as a failed create group rather than a "changes landed since you
   started reviewing" warning.
3. **Further `sync_review` decomposition.** `_fetch_remote_threads` +
   `_reconcile_threads` split the original monolith; the reconcile body is still
   one long function and could be split per phase (threads / comments / deletions).

### 8.3 Verification checklist

Covered by `tests/test_submit_contract.lua`, which intercepts the CLI layer
(`adapter.base.executor_override`) so it can assert endpoints and arguments and
script partial failures without touching the network.

- [x] `submit_review` runs on a thread (UI stays responsive during push)
- [x] `sync_review` decomposed into `_fetch_remote_threads` + `_reconcile_threads`
- [x] Interrupted ops recovered and adopted, not re-sent (`recover_stale` + adoption)
- [x] Partial failure still reconciles + reports `pushed N / M queued`
- [x] Retry is idempotent (`DONE` terminal + `(c_id, op)` dedupe; GitLab re-post case)
- [x] Verdict never dropped and never duplicated (rides the batch only when the hub can)
- [x] Edit/delete use correct adapter arity, including local-only deletes
