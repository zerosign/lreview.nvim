# 09 — Async Execution Model: Subprocess vs. Thread vs. Async Refactor

**Status:** ✅ **Decided — Option 2 (`uv.new_work` thread), confirmed by audit + focused sanity checks**
**Domain:** Cross-Cutting (foundation for 04-sync-bus.md)
**Depends on:** nothing
**Related:** 04-sync-bus.md (concurrency model), 07-submit-atomicity.md, 12-async-audit.md

> **✅ Audit resolution (12-async-audit.md + focused sanity checks):** every
> problem the audit surfaced for `uv.new_work` has a **verified solution** (see
> §2.6). The completion callback runs in **fast event context** (new finding —
> `vim.api`/`vim.notify` fail inside it; must wrap in `vim.schedule`, verified).
> Overheads are negligible (thread spawn ~0.1ms, io.popen ≈ vim.system ~1.5ms,
> msgpack sub-ms for 90KB, sqlite open on thread ~0.4ms, +4KB RSS). The
> alternative `vim._async` remains **not recommended** (internal API + biggest
> rewrite + no true parallelism). **Decision stands: `uv.new_work`.**

> **✅ Implementation status (rediscovered):** the thread model is **largely
> implemented** — `thread.lua` (generic `create_worker` with msgpack + `vim.g`
> bootstrap + `vim.schedule` escape), `adapter/base.lua` (io.popen fallback for
> threads), `sync_review_thread` + `pull_review_async` (thread-based sync), and
> the `gc_work` fix (keep_open + `vim.g`). **Remaining:** (1) move `submit_review`
> to a thread, (2) decompose `sync_review` monolith, (3) replay `vim.notify`
> from thread callback (currently silently lost), (4) wire sync-bus diff-cache
> invalidation + bypass fix. See §9.

---

## 1. The Question

The plugin's pull/sync work currently runs in a **headless Neovim subprocess**
spawned via `vim.system`:

```lua
-- review.lua (pull_review_async)
local cmd = { vim.v.progpath, "--headless", ..., "-c", "lua ...sync_review()", "-c", "qa" }
vim.system(cmd, { cwd = current_cwd }, function(res)
  vim.schedule(function() ... refresh panels ... end)
end)
```

The user asks: **why a subprocess?** The GC path already uses `uv.new_work`
(a libuv **thread**), not a subprocess:

```lua
-- storage/init.lua
local gc_work = uv.new_work(function(db_path, lazy_sqlite, age_days)
  -- opens its OWN sqlite connection, runs DELETEs, closes
end, function(result)
  vim.schedule(function() ... end)  -- back on main thread
end)
```

So the plugin already has a **working precedent** for running DB work on a
thread. The pull job is the odd one out. This doc analyzes whether the
subprocess is justified, and what the alternatives cost.

---

## 2. The Decisive Fact: `sync_review` Is Blocking

`sync_review()` calls `fetch_threads()`, which calls `base.run(argv, { cwd })`
**without a callback**:

```lua
-- adapter/base.lua (run, no callback path)
local res = vim.system(args, o):wait()   -- ← BLOCKS the calling thread
```

So `sync_review` **blocks the thread it runs on**. That is the *only* hard
constraint: it must run somewhere that is not the main UI thread (or it must be
made non-blocking).

Everything else — network calls, DB writes — is already safe to run off the
main thread:
- `vim.system` with a callback is **already async** (does not block).
- `uv.new_work` runs on a separate thread with its **own** SQLite connection
  (proven by GC).

---

## 2.5 Verification: Can the Operations Actually Move Off the Main Thread?

Before committing to Option 2 (thread) or Option 3 (async), we audited every
`vim.*` call reachable from `sync_review` to confirm it can run off the main
thread. **The rule:** anything touching Neovim UI/API (`vim.api`, `vim.fn`,
`vim.notify`, `vim.ui`, `vim.schedule`) cannot run on a `uv.new_work` thread —
it must be deferred via `vim.schedule` or moved to the main thread. Pure data
calls (`vim.mpack`, `vim.tbl_extend`, `vim.trim`, `vim.json`) are safe anywhere.

### Audit of the `sync_review` call path

| Call site | `vim.*` used | Thread-safe? | Notes |
|:--|:--|:--|:--|
| `sync_review` (review.lua L494, L577) | `vim.mpack.decode` | ✅ Yes | Pure data |
| `sync_review` (L495) | `vim.tbl_extend` | ✅ Yes | Pure data |
| `sync_review` (L523, L535, L586, L611) | `vim.notify` | ❌ **No** | Conflict warnings — must be deferred via `vim.schedule` |
| `storage.comments.*` (called by sync_review) | `vim.mpack` (module L11) | ✅ Yes | Pure data |
| `storage.query` / `storage.execute` | `vim.mpack`, `vim.notify` (L239 error path) | ⚠️ Mostly | `vim.notify` only on the *error* path of `execute` — must be deferred |
| `adapter.fetch_threads` → `base.run` (no callback) | `vim.system(...):wait()` | ✅ Yes | Blocking but thread-safe (spawns a process) |
| `base.run` (L52, L143) | `vim.trim`, `vim.json.decode` | ✅ Yes | Pure data |
| `adapter.resolve` / `adapter.ctx` | `vim.fn.getcwd`, `vim.fn.fnamemodify` | ⚠️ | `vim.fn` is **not** thread-safe — resolve on main thread first, pass the resolved adapter/ctx into the thread |

### The two things that must change for a thread (Option 2)

1. **`vim.notify` calls must be deferred.** `sync_review` emits conflict
   warnings via `vim.notify` (L523/535/586/611), and `storage.execute` emits an
   error via `vim.notify` (L239). On a thread these must be collected and
   replayed on the main thread via `vim.schedule`. **Cleanest approach:** have
   the thread return a list of `{msg, level}` notifications as part of its
   result, and the main-thread callback fires them. This keeps the thread free
   of any `vim.*` UI call.

2. **Adapter resolution must happen on the main thread first.** `adapter.resolve`
   and `adapter.ctx` use `vim.fn.getcwd` / `vim.fn.fnamemodify` (not
   thread-safe). Resolve the adapter + ctx **before** spawning the thread, then
   pass the resolved plain-Lua values into the thread. `sync_review` already
   takes `M.current` (a plain table) — the thread only needs `cwd`, `detail`,
   and the resolved adapter.

### What this means for each option

- **Option 2 (thread):** Feasible with two small changes — (a) collect
  `vim.notify` calls into the result and replay on the main thread, (b) resolve
  the adapter on the main thread and pass it in. The DB writes (`storage.query`/
  `execute`) are already thread-safe via the thread's own connection.
- **Option 3 (async refactor):** Feasible with no thread at all — `vim.notify`
  is already safe on the main thread, and `vim.system` with a callback is
  already non-blocking. The only work is restructuring `sync_review` into
  callback form.
- **Option 1 (subprocess, current):** No changes needed — the headless job is a
  separate process where `vim.*` is safe. This is *why* the subprocess "just
  works" today, but it's also why it's heavier than necessary.

**Conclusion:** both Option 2 and Option 3 are **verified feasible** with
bounded, well-understood changes. The `vim.notify` deferral (Option 2) and the
async restructuring (Option 3) are the only real work; neither is a blocker.

---

## 2.6 Every Audit Problem Has a Verified Solution

The async audit (doc 12) surfaced several `uv.new_work` restrictions. Each has
a **concrete, verified solution** — none is a blocker:

| # | Problem (doc 12) | Solution | Verified |
|:--|:--|:--|:--|
| 1 | Thread `vim` is a limited proxy (`vim.g` nil) | `rawset(vim, "g", {})` bootstrap | ✅ `sanity_work.lua` |
| 2 | sqlite.lua lazy-open fails on thread | `sqlite.new(db, { keep_open = true })` | ✅ `sanity_work.lua` |
| 3 | No table/function/cdata args across boundary | **msgpack** serialize (`vim.mpack.encode`/`decode`) | ✅ `sanity_serialize.lua` |
| 4 | `vim.system` is nil on thread | `io.popen`/`uv.spawn` fallback in `adapter/base.lua` | ✅ `sanity_thread_subprocess.lua` |
| 5 | `vim.notify` is nil on thread | Collect notifications into result, replay on main via `vim.schedule` | ✅ `sanity_callback_ctx2.lua` |
| 6 | Completion callback runs in **fast event context** (new) | Wrap callback body in `vim.schedule` | ✅ `sanity_callback_ctx2.lua` |
| 7 | `vim.fn` not thread-safe (adapter resolve) | Resolve adapter/ctx on main thread first, pass plain values in | ✅ design (doc 09 §2.5) |
| 8 | WAL concurrent access | Thread opens own connection + `PRAGMA busy_timeout` | ✅ `sanity_wal.lua` |

**Overhead measurements** (doc 12 §9, `bench_thread_overhead.lua` +
`bench_precise.lua`):

| Operation | Latency |
|:--|:--|
| `uv.new_work` queue+run+callback (reused) | ~0.1 ms |
| `io.popen` echo (thread-style) | ~1.8 ms |
| `vim.system` echo `:wait()` (main) | ~1.5 ms |
| `vim.mpack.encode` (90KB payload) | ~0.8 ms |
| `vim.mpack.decode` (90KB payload) | ~0.6 ms |
| sqlite open + create table on thread | ~0.4 ms |
| Thread + sqlite RSS footprint | **+4 KB** |

**Conclusion:** the thread model's overhead is negligible — thread spawn is
sub-millisecond, `io.popen` ≈ `vim.system`, msgpack is sub-ms even for large
payloads, and the memory cost of a thread + sqlite is ~4KB. No performance
reason to avoid `uv.new_work`.

---

## 3. Three Options

### Option 1 — Subprocess (current)

Run `sync_review` inside a spawned `nvim --headless`.

| | |
|:--|:--|
| **Blocking handled by** | A separate OS process |
| **Cost** | High — boots a full second Neovim (~50–100ms+ just to start) |
| **IPC** | Clunky — results serialized to stdout, re-parsed; no direct Lua table passing |
| **State** | Re-resolves adapter, re-reads config, re-opens DB from scratch |
| **Crash isolation** | ✅ Full — a sync crash can't take down the editor |
| **DB contention** | ✅ None — own connection in own process |
| **Debugging** | ❌ Errors are strings over stdout, not real Lua errors |

### Option 2 — `uv.new_work` thread (like GC)

Run `sync_review` on a libuv thread with its own DB connection.

| | |
|:--|:--|
| **Blocking handled by** | A separate thread |
| **Cost** | Low — no process spawn, just a thread |
| **IPC** | Direct — pass Lua values in, get results via callback |
| **State** | Can share in-memory config/adapter resolution (careful: must not touch Neovim APIs on the thread) |
| **Crash isolation** | ⚠️ Partial — a hard thread crash can take down the process (rare; Lua errors are pcall-guarded) |
| **DB contention** | ✅ None — own connection (same as GC) |
| **Debugging** | ✅ Real Lua errors, pcall-able |

### Option 3 — Async refactor (no thread, no subprocess)

Refactor `sync_review` to use the **async** `base.run` callback path so nothing
blocks at all.

| | |
|:--|:--|
| **Blocking handled by** | Eliminated — `vim.system` with callback is non-blocking |
| **Cost** | Highest change — rewrite `sync_review` (a ~200-line synchronous monolith with inline DB writes) into callback/async form |
| **IPC** | N/A — same process, same thread |
| **State** | Full sharing |
| **Crash isolation** | N/A — same process |
| **DB contention** | ⚠️ Same connection as main process — must be careful with WAL/locking (busy_timeout already set) |
| **Debugging** | ✅ Best |

---

## 4. The Tradeoff, Summarized

The subprocess is **not required** by any hard constraint. The blocking
`:wait()` is the only reason work must leave the main thread, and both a thread
(Option 2) and a refactor (Option 3) solve that.

The subprocess is the **most expensive** of the three and buys only **crash
isolation** — which the plugin doesn't really need, because:
- The sync logic is already pcall-guarded (errors are caught, not fatal).
- A thread crash is rare in LuaJIT, and GC already accepts this risk.

| | Option 1 (subprocess) | Option 2 (thread) | Option 3 (async refactor) |
|:--|:--|:--|:--|
| **Change size** | None (current) | Small | Large |
| **Runtime cost** | High | Low | Lowest |
| **Crash isolation** | Full | Partial | N/A |
| **IPC simplicity** | Poor | Good | Best |
| **Consistency with GC** | ❌ | ✅ | ✅ |
| **Long-term cleanliness** | ❌ | Good | Best |

---

## 5. Recommendation

**Option 2 (`uv.new_work`) is the recommended choice** — minimal change, cheap,
proven by GC, and consistent with the existing codebase. It directly answers
"why not `uv.new_work`?": there is no good reason *not* to; the subprocess was
overkill. The thread keeps the sequential, readable `sync_review` logic intact
and runs it on its **own** SQLite connection (no UI contention).

**Option 3 (async refactor) is *not* recommended for this workload.** See §5.5:
it changes the control-flow shape of every network+DB function, and — the
deciding factor — it shares one SQLite connection with the UI, which can
reintroduce the main-thread blocking we're trying to eliminate. It's only worth
it if we want to eliminate the thread entirely for some other reason.

**Option 1 (subprocess) is the current state and is overkill.** Keep it only if
crash isolation is a hard requirement, which it is not for this plugin.

---

## 5.5 The Honest Tradeoff for Option 3 (Async Refactor)

Option 3 looks clean on paper ("no thread, no subprocess"), but it has real,
often-underestimated costs. The core issue: **it changes the control-flow shape
of every network+DB operation in the plugin**, not just `sync_review`.

### 5.5.1 The scope is bigger than `sync_review`

The plugin has **many** synchronous network+DB functions, not just `sync_review`:

| Function | What it does |
|:--|:--|
| `sync_review` (L406) | Pull threads + reconcile DB |
| `submit_review` (L228) | Push drafts/replies/edits/deletes + clear local state |
| `create_review` (L640) | Create MR |
| `update_review` (L707) | Update MR title/body + update cache |
| `close_review` (L658) / `approve_review` (L682) | Close/approve MR |
| `list_templates` (L627) | List MR templates |
| `fetch_users` / `fetch_pull_requests` | User/PR list fetch |

Each of these currently reads like a **sequential script** — resolve adapter,
call network, write DB, return. That's easy to read, test, and reason about.

### 5.5.2 The control-flow cost

To make these non-blocking on the main thread, each must become either:

- **Callback-nested** — the classic "callback pyramid". `submit_review` already
  has a 4-step sequential flow (new threads → replies → edits → deletes); nesting
  that in callbacks is painful and hard to follow.
- **Coroutine-based** (`vim.wait` + a scheduler, or a small async/await helper) —
  cleaner but requires building/maintaining a mini async runtime, which is
  non-trivial and easy to get subtly wrong (re-entrancy, cancellation, error
  propagation through `pcall`).

Neither is free. The current synchronous code is *simpler to read* than either
async form.

### 5.5.3 The DB-locking risk (the real hidden cost)

On the main thread, `sync_review` and the UI **share one SQLite connection**.
`busy_timeout` is 5000ms, but:
- A long sync (many threads/comments) holds the connection for a while.
- UI reads (decor refresh, summary redraw) that hit the DB during that window
  **block the main thread** — the exact thing we're trying to avoid.
- WAL helps concurrent *writers*, but a single connection is still serialized.

So Option 3 can *introduce* UI jank that Option 2 (separate thread + own
connection) avoids entirely. This is the strongest argument **against** Option 3
and **for** Option 2.

### 5.5.4 Summary of the Option 3 tradeoff

| Aspect | Cost |
|:--|:--|
| **Change size** | Large — every sync-path function, not just `sync_review` |
| **Control flow** | Becomes callback-nested or needs a mini async runtime |
| **Readability** | Worse than current sequential code (for the same logic) |
| **DB contention** | ⚠️ Shares one connection with UI → can reintroduce main-thread blocking |
| **No thread/process** | ✅ Simplest runtime model |
| **Pairs with doc 07** | ✅ `sync_review` decomposition is a natural place |

### 5.5.5 Revised recommendation

The DB-locking risk (5.5.3) is the deciding factor. **Option 2 (thread) is the
better choice** for the pull/sync path: it keeps the sequential, readable
`sync_review` logic intact, runs it on a thread with its **own** connection (no
UI contention), and only needs the two small changes from §2.5 (defer
`vim.notify`, resolve adapter on main first).

Option 3's async refactor is only worth it if we *also* want to eliminate the
thread entirely for some other reason — but given the shared-connection jank it
can introduce, it's the **weaker** of the two for this specific workload.

---

## 6. Open Questions

1. **Is crash isolation a real requirement?** If a sync bug could corrupt the
   editor session, the subprocess is justified. Otherwise it's not. (Current
   evidence: pcall-guarded, so no.)
2. **Does the async refactor (Option 3) belong with 07-submit-atomicity?**
   Given §5.5's DB-locking risk, Option 3 is **not recommended** for the
   pull/sync path. The `sync_review` decomposition in doc 07 should proceed
   independently of the async question — it's about *structure*, not *threading*.
3. **Adapter resolution on the thread (Option 2).** ✅ **Verified** (see §2.5):
   `adapter.resolve`/`adapter.ctx` use `vim.fn` (not thread-safe), so resolve on
   the main thread first and pass the resolved adapter/ctx into the thread.
   `sync_review`'s `vim.notify` conflict warnings must be collected into the
   result and replayed on the main thread via `vim.schedule`.
4. **WAL/locking with a shared connection (Option 3).** ⚠️ **This is the deciding
   factor against Option 3** (see §5.5.3). A long sync on the main thread shares
   one SQLite connection with the UI, so UI reads during the sync window block
   the main thread. Option 2 (thread + own connection) avoids this entirely —
   another reason Option 2 wins.

---

## 7. Implementation Sketch (Option 2 — `uv.new_work` thread)

This is the concrete shape of the change, matching the existing GC pattern in
`storage/init.lua` (L13-43). It replaces the subprocess in `pull_review_async`
with a thread.

### 7.1 The two required changes (from §2.5)

1. **Defer `vim.notify`** — `sync_review` emits conflict warnings, and
   `storage.execute` emits an error. Collect them into the result and replay on
   the main thread.
2. **Resolve the adapter on the main thread first** — `adapter.resolve`/`ctx`
   use `vim.fn` (not thread-safe). Pass the resolved plain-Lua values into the
   thread.

### 7.2 A thread-safe `sync_review` core

Refactor `sync_review` so the *pure* work (network + DB) is separable from the
`vim.notify` calls. The thread runs the pure core and returns notifications:

```lua
-- review.lua — new pure core (no vim.* UI calls)
-- Returns: { n = count, notifications = { {msg, level}, ... } }
function M.sync_review_core(cwd, detail, resolved)
  local ctx = adapter.ctx(resolved, detail.number)
  local notifications = {}
  local function warn(msg)
    notifications[#notifications + 1] = { msg, vim.log.levels.WARN }
  end

  -- ... existing sync_review body, but replace every `vim.notify(msg, WARN)`
  --     with `warn(msg)` ...
  -- ... storage.query / storage.execute / comments.* unchanged (thread-safe) ...

  return { n = n, notifications = notifications }
end
```

> **Note:** `vim.log.levels.WARN` is a plain constant (an integer), safe to read
> on the thread. `vim.mpack` / `vim.tbl_extend` / `vim.trim` / `vim.json` are
> pure data and safe. Only `vim.notify` (and `vim.fn`/`vim.api`) must be avoided.

### 7.3 The thread wrapper (mirrors GC)

```lua
-- review.lua — module-level, created once
local sync_work = vim.uv.new_work(function(cwd, detail_raw, resolved_raw, db_path, lazy_sqlite)
  -- 1. FIX: Bootstrap vim.g on thread so sqlite.lua defs.lua can load
  rawset(vim, "g", {})

  if lazy_sqlite and lazy_sqlite ~= "" then
    package.path = package.path .. ";" .. lazy_sqlite .. "/?.lua;" .. lazy_sqlite .. "/?/init.lua"
  end

  local ok, sqlite = pcall(require, "sqlite")
  if not ok then
    return vim.mpack.encode({ ok = false, err = "sqlite not available: " .. tostring(sqlite) })
  end

  -- 2. FIX: keep_open = true is mandatory (lazy-open fails on thread)
  local db = sqlite.new(db_path, { keep_open = true })
  if not db then
    return vim.mpack.encode({ ok = false, err = "failed to open sqlite db: " .. tostring(db_path) })
  end
  db:eval("PRAGMA journal_mode=WAL;")
  db:eval("PRAGMA busy_timeout=5000;")

  -- 3. FIX: Decode the MessagePack serialized arguments (tables cannot cross thread boundary)
  local detail = vim.mpack.decode(detail_raw)
  local resolved = vim.mpack.decode(resolved_raw)

  -- Run the pure sync core against THIS connection.
  local result = M.sync_review_core(cwd, detail, resolved)

  db:close()
  -- Return result as serialized MessagePack
  return vim.mpack.encode(result)
end, function(result_raw)
  -- 4. FIX: wrap callback in vim.schedule (thread returns in fast event context where vim.api/vim.notify fail)
  vim.schedule(function()
    local result = vim.mpack.decode(result_raw)
    -- Replay notifications on the main thread
    for _, notif in ipairs(result.notifications or {}) do
      vim.notify(notif[1], notif[2])
    end
    -- Refresh panels (same as current pull_review_async callback)
    if result.ok then
      local decor = require("lreview.ui.decor")
      for bufnr, _ in pairs(decor.enabled_buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then decor.refresh(bufnr) end
      end
      local tv = require("lreview.ui.thread_view")
      if tv.state and vim.api.nvim_buf_is_valid(tv.state.bufnr) then tv.redraw() end
      local summary = require("lreview.ui.summary")
      if summary.state and vim.api.nvim_buf_is_valid(summary.state.bufnr) then summary.redraw() end
    end
  end)
end)
```

### 7.4 The new `pull_review_async`

```lua
function M.pull_review_async(callback)
  if not M.current then
    if callback then callback(false) end
    return false, "no active review"
  end

  -- Resolve adapter on the MAIN thread (vim.fn is not thread-safe)
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    if callback then callback(false) end
    return false, "no git remote detected"
  end

  local detail = M.current.detail
  local db_path = config.get_defaults().db_path
  local lazy_sqlite = vim.fn.stdpath("data") .. "/lazy/sqlite.lua/lua"

  -- Serialize tables before passing to thread
  local detail_raw = vim.mpack.encode(detail)
  local resolved_raw = vim.mpack.encode(resolved)

  -- Queue the thread (fire-and-forget; callback fires on completion)
  sync_work:queue(M.current.cwd, detail_raw, resolved_raw, db_path, lazy_sqlite)
  return true, nil
end
```

### 7.5 What must change in the storage layer

The thread opens its **own** connection, so `storage.query`/`execute` must be
able to target a specific connection rather than the module-global `M.db`. Two
options:

- **A (minimal):** add an optional `db` parameter to `storage.query`/`execute`
  (defaults to `M.db`). The thread passes its own `db`.
- **B (cleaner):** extract a `storage.conn(db)` helper that returns a
  connection-scoped query/execute, so the thread gets its own bound functions.

Option A is the smaller diff and matches how GC already opens its own connection
inline. **Recommend A.**

### 7.6 What stays the same

- The panel-refresh logic in the callback (decor/thread_view/summary) is
  unchanged — it already runs on the main thread via `vim.schedule`.
- `sync_review`'s *logic* (the reconciliation algorithm) is unchanged — only the
  `vim.notify` calls are extracted into the returned `notifications` list.
- The `vim.g.lreview_pull_job` guard and the headless `init_session` bootstrap
  are **removed** — no longer needed.

### 7.7 Verification checklist

- [ ] `sync_review_core` contains **no** `vim.notify`, `vim.fn`, `vim.api`, or
      `vim.ui` calls (grep the function body).
- [ ] The thread opens its own connection and closes it (no leak).
- [ ] Conflict warnings still appear (replayed via `vim.schedule`).
- [ ] Panels refresh after sync completes.
- [ ] A long sync does **not** block the UI (thread + own connection).
- [ ] `storage.query`/`execute` accept the optional `db` param without breaking
      existing callers (default `M.db`).

---

## 8. Extending `uv.new_work` to Other Blocking I/O

Since we've decided on `uv.new_work` for the sync path, the natural question is:
**can we use it for the other blocking I/O in the plugin?** This section audits
every blocking I/O call site and assesses feasibility.

### 8.1 The full inventory of blocking I/O

| # | Call site | What it does | Latency | `vim.*` used |
|:--|:--|:--|:--|:--|
| 1 | `git.current_branch` / `head_sha` / `remotes` / `remote_branches` / `default_branch` | Local git subprocess | ~1–5ms | `vim.fn.fnamemodify`, `vim.trim`, `vim.fn.getcwd` |
| 2 | `git.changed_lines` | `git diff -U0` (heaviest git call) | 5–100ms+ on large diffs | `vim.trim` |
| 3 | `git.create_branch` | `git checkout -b` + `git push -u` | 100ms–1s (push = network) | none in the git helper |
| 4 | `adapter.fetch_threads` / `submit_*` / `create_mr` / `update_mr` / `close_mr` / `approve_mr` / `list_templates` | Network via `gh`/`glab` CLI | 100ms–10s | `vim.system`, `vim.trim`, `vim.json.decode` |
| 5 | `adapter.list_templates` file read (github/gitlab) | `io.popen`/`io.open` on template dir | ~1ms | `vim.fn.shellescape` |
| 6 | `vim.fn.input` / `vim.fn.confirm` | Interactive UI prompts | N/A (user) | `vim.fn` — **UI, not I/O** |

### 8.2 Feasibility rule (from §2.5)

A `uv.new_work` thread **cannot** touch `vim.api`, `vim.fn`, `vim.notify`,
`vim.ui`, or `vim.schedule`. It **can** do:
- Pure data (`vim.mpack`, `vim.tbl_extend`, `vim.trim`, `vim.json.decode`)
- Subprocess spawning (`vim.system(...):wait()`)
- File I/O (`io.open`, `io.popen`, `io.read`)

### 8.3 Per-category assessment

#### Category A — Fast local git calls (#1): **NOT worth it**

`current_branch`, `head_sha`, `remotes`, `remote_branches`, `default_branch`
are **~1–5ms** local git commands. Moving them to a thread adds async-callback
complexity for negligible benefit. They also use `vim.fn.fnamemodify` /
`vim.fn.getcwd` (not thread-safe), so they'd need refactoring first. **Keep
synchronous.**

#### Category B — `git.changed_lines` (#2): **WORTH IT — the biggest win**

This is the **core latency concern of doc 04 (sync-bus)**. It runs `git diff
-U0` on every decor refresh and can take 5–100ms+ on large diffs. It's the
single most impactful candidate. It uses only `vim.trim` (pure data, safe), so
it's **thread-ready as-is** — no `vim.fn` refactor needed.

**Recommendation:** run `git.changed_lines` on a `uv.new_work` thread, cache the
result (per doc 04's diff-cache), and refresh decor from the callback. This is
the natural companion to the sync-bus work.

#### Category C — Network adapter calls (#4): **WORTH IT — already covered by doc 09**

`fetch_threads`, `submit_*`, `create_mr`, etc. are the slowest (100ms–10s).
This is exactly the sync path already decided in §7. The only requirement (from
§2.5): resolve the adapter/ctx on the **main thread** first (they use `vim.fn`),
then pass the resolved plain-Lua values into the thread. The adapter functions
themselves are pure data + `base.run` (thread-safe).

**Recommendation:** covered by the §7 implementation. Extend the same pattern to
`submit_review` (push path) and the create/update/close/approve flows.

#### Category D — Template file reads (#5): **Marginal**

`io.popen`/`io.open` are thread-safe, but the reads are ~1ms and only happen
during the create flow (not a hot path). The only blocker is `vim.fn.shellescape`
(github.lua L489, gitlab.lua L323) — a one-line refactor to escape on the main
thread or use a pure-Lua escape. **Not worth a thread** unless the create flow
becomes slow; keep synchronous.

#### Category E — Interactive UI (#6): **NOT candidates**

`vim.fn.input` / `vim.fn.confirm` are **UI**, not I/O. They must stay on the
main thread. (Doc 03 already replaces `vim.fn.confirm` with a popup; doc 05
replaces `vim.fn.input` with the scratchpad.)

### 8.4 Summary matrix

| Call site | Move to thread? | Effort | Benefit | Blocker |
|:--|:--|:--|:--|:--|
| `git.current_branch`/`head_sha`/`remotes`/etc. | ❌ No | — | Negligible | `vim.fn` refactor |
| `git.changed_lines` | ✅ **Yes** | Low | **High** (doc 04 core) | none (thread-ready) |
| `git.create_branch` | ⚠️ Maybe | Low | Medium (push is network) | none |
| `adapter` network calls | ✅ **Yes** | Medium | **High** | resolve adapter on main first |
| `list_templates` file read | ❌ No | — | Marginal | `vim.fn.shellescape` |
| `vim.fn.input`/`confirm` | ❌ No (UI) | — | — | must stay on main |

### 8.5 Recommendation

1. **Do now (with §7):** the adapter network calls (sync + push + create flows)
   — already decided, extend the pattern.
2. **Do next (with doc 04):** `git.changed_lines` on a thread + diff cache. This
   is the single biggest UI-latency win and is thread-ready as-is.
3. **Consider:** `git.create_branch` (the `git push` part is network).
4. **Skip:** fast local git calls, template file reads, and all interactive UI.

### 8.6 Cross-doc impact

- **Doc 04 (sync-bus):** `git.changed_lines` on a thread + diff cache is the
  natural companion — the diff-cache miss during flush (doc 04 §4.2) is exactly
  what a threaded `changed_lines` + cache solves.
- **Doc 05 (MR lifecycle):** `create_mr`/`update_mr`/`close_mr`/`approve_mr` and
  the capability probe (§2.4) all run on the thread.
- **Doc 07 (submit atomicity):** `submit_review`'s push path runs on the thread;
  the `IN_FLIGHT` state + idempotent retry must be thread-aware (the state lives
  in the DB, which the thread writes via its own connection).
- **Doc 08 (capability system):** the **runtime probe** (doc 05 §2.4) is network
  I/O → it runs on the thread. The **probed capabilities** (`draft_mr`,
  `approve_mr`, `list_templates`) gate what the create flow offers — and that
  create flow is exactly what runs on the thread. So capabilities both *decide
  what work exists* and *run on the thread*. See doc 08 §3.1 for the full
  capability→action→event matrix.

---

## 9. Implementation Status (rediscovered — what's done vs remaining)

The thread model is **largely implemented**. This section records the actual
state so the remaining work is clear.

### 9.1 Implemented (verified in source)

| Piece | Location | Notes |
|:--|:--|:--|
| Generic thread worker | `lua/lreview/thread.lua` | `create_worker(mod, fn, cb)` — msgpack in/out, `rawset(vim,"g",{})` bootstrap, `vim.schedule` escape (solves problems 1,3,6) |
| Adapter io.popen fallback | `lua/lreview/adapter/base.lua` | `M.run` uses `vim.system` on main, `io.popen` on thread (solves problem 4) |
| Thread sync entry | `lua/lreview/review.lua` `sync_review_thread` | Opens own connection (`keep_open`), sets `M.current`, calls `sync_review` |
| Async pull | `lua/lreview/review.lua` `pull_review_async` | Uses `thread.create_worker`, refreshes panels in callback |
| GC thread fix | `lua/lreview/storage/init.lua` | `rawset(vim,"g",{})` + `keep_open = true` (solves problems 1,2) |
| Batched reconcile | `sync_review` | Single query + in-memory index (doc 10 ~11x win) |

### 9.2 Remaining work (in priority order)

1. **Move `submit_review` to a thread** (doc 07 §2.5). Currently synchronous on
   main thread — blocks UI during the push loop. Needs a `submit_review_thread`
   entry + `pull_review_async`-style wrapper. **Depends on** #2 (decomposition)
   so the pure core is separable from `vim.notify`.
2. **Decompose `sync_review` monolith** (doc 07 §2.2) into
   `_sync_threads` / `_reconcile_remote_comment_deletions` /
   `_reconcile_remote_thread_deletions`. Improves testability + enables #1.
3. **Replay `vim.notify` from thread callback.** Currently `sync_review` calls
   `vim.notify` on the worker thread where it's **nil → silently lost** (doc 12
   §3.2). Fix: collect `{msg, level}` into the result, replay in the callback
   (already wrapped in `vim.schedule`). This is the **one correctness bug** in
   the current implementation.
4. **Wire sync-bus diff-cache invalidation + bypass fix** (doc 04). `sync.lua`
   has `invalidate_diff_cache()` but it's never called; `pull_review_async`
   callback bypasses the bus (manually refreshes instead of `mark_dirty`+`flush`).
5. **`git.changed_lines` on a thread** (doc 09 §8.3/B). Biggest UI-latency win,
   thread-ready as-is. Companion to the diff cache.

### 9.3 Verification checklist (updated)

- [x] `thread.lua` msgpack in/out works (sanity_serialize.lua)
- [x] `base.lua` io.popen fallback works on thread (sanity_thread_network.lua)
- [x] `gc_work` opens with `keep_open` + `vim.g` (sanity_work.lua)
- [ ] `sync_review` emits **no** `vim.notify` on the thread (collect + replay)
- [ ] `submit_review` runs on a thread, UI stays responsive
- [ ] `invalidate_diff_cache` called on pull/branch change
- [ ] `pull_review_async` callback goes through `sync.mark_dirty`+`flush`
