# 12 — Async API Audit: `uv.new_work` vs `vim._async` (Empirical Findings)

**Status:** ✅ **Audit complete — findings resolved; `uv.new_work` confirmed + implemented**
**Domain:** Cross-Cutting (foundation for 04-sync-bus.md, 07-submit-atomicity.md)
**Depends on:** 09-async-model.md (the decision being audited)
**Related:** 04-sync-bus.md, 07-submit-atomicity.md, 11-plan-verification.md

> **✅ Resolution:** every restriction found here has a **verified solution**
> (see §3.8). The thread model is **implemented** in `thread.lua` +
> `adapter/base.lua` + `sync_review_thread`. Overheads measured negligible
> (§9). `vim._async` remains **not recommended** (internal API + biggest
> rewrite + no true parallelism).

---

## 1. Why This Audit Exists

Doc 09 **decided** on `uv.new_work` threads (Option 2). Before implementing,
we sanity-checked every `vim.*`/`vim.uv.*` API our plans reference in
**headless Neovim** (`nvim --headless -u NONE -l script.lua`).

**Result: every API exists** — but the *behavior* of `uv.new_work` threads
revealed **previously-unknown restrictions** that directly affect the design.
This doc records what we found, empirically, so the decision can be re-made
with facts.

**Environment:** Neovim v0.13.0-dev-1917, LuaJIT 2.1, luv 1.52.1.

---

## 2. API Availability (all exist — no surprises)

Every `vim.*` call referenced in our plans + source exists in this build:

| Group | APIs | Status |
|:--|:--|:--|
| `vim.uv` | `new_work`, `new_timer`, `new_thread`, `thread_create`, `queue_work`, `spawn`, `sleep`, `run`, `now` | ✅ all exist |
| `vim.system` | sync `:wait()`, async callback | ✅ works headless |
| `vim.mpack` / `vim.json` | `decode`, `encode` | ✅ |
| `vim.fn` | `confirm`, `fnamemodify`, `getcwd`, `input`, `shellescape`, `stdpath`, `bufnr`, `complete`, `escape`, `expand`, `hlexists`, `isdirectory`, `line`, `strdisplaywidth`, `system`, `win_findbuf` | ✅ all exist |
| `vim.api` | all 26 referenced | ✅ all exist |
| `vim.ui` / `vim.keymap` / `vim.log` | `select`, `set`, `levels` | ✅ |
| `vim.v` / `vim.g` / `vim.o` | `progpath`, settable, `columns`, `lines` | ✅ |

**No missing APIs.** The restrictions are about *where* they can run, not
whether they exist.

---

## 3. `uv.new_work` Threads — What We Found

### 3.1 Threads Work (with `vim.wait` to pump the loop)

`uv.new_work` works, but **`vim.uv.run("nowait")` does NOT pump the work
queue** in a `-l` script. You must use `vim.wait(ms, cond, interval)` to drive
the event loop. (In a real plugin, the normal event loop handles this.)

```lua
local work = vim.uv.new_work(function(x) return "got:" .. tostring(x * 2) end,
  function(r) res = r; done = true end)
work:queue(21)
vim.wait(3000, function() return done end, 10)  -- ✅ works
```

### 3.2 The Thread's `vim` Is a Limited Proxy

On a worker thread, `vim` **exists** but is a **separate, limited table**:

| `vim.*` field | On thread | Notes |
|:--|:--|:--|
| `vim.api` | ✅ table | but doc 09 says don't use it |
| `vim.uv` | ✅ table | |
| `vim.json` | ✅ table | |
| `vim.mpack` | ✅ table | |
| `vim.inspect` | ✅ table | |
| `vim.deepcopy`, `tbl_extend`, `split`, `trim`, `validate` | ✅ functions | |
| `vim.list`, `vim.text`, `vim.loop` | ✅ tables | |
| **`vim.g`** | ❌ **nil** | **breaks sqlite.lua** |
| `vim.fn` | ❌ nil | as doc 09 expected |
| `vim.schedule` | ❌ nil | as doc 09 expected |
| `vim.notify` | ❌ nil | as doc 09 expected |
| `vim.system` | ❌ **nil** | **breaks adapter network calls** |
| `vim.wait` | ❌ nil | |
| `vim.keymap`, `vim.log`, `vim.ui`, `vim.o`, `vim.v` | ❌ nil | |

**Critical:** `vim.g` is nil AND **cannot be set** (`vim.g = {}` errors). The
only way to create it is `rawset(vim, "g", {})`.

### 3.3 sqlite.lua Needs Two Workarounds on a Thread

`kkharji/sqlite.lua` (FFI-based) **cannot load on a thread** out of the box:

1. **`defs.lua` reads `vim.g.sqlite_clib_path` at module-load time** → crashes
   with `attempt to index field 'g' (a nil value)`.
   **Fix:** `rawset(vim, "g", {})` on the thread before `require("sqlite")`.
2. **`sqlite.new(db)` without `keep_open` uses lazy-open which fails** with
   "out of memory" / "Invalid connection passed to sqlstmt:parse".
   **Fix:** use `sqlite.new(db_path, { keep_open = true })`.

With both fixes, **sqlite works fully in a thread** (CREATE/INSERT/SELECT all
verified). WAL concurrent access works: thread writes 100 rows while main
thread reads — all 100 intact, no lock errors.

> ⚠️ **The plugin's existing `gc_work` thread (storage/init.lua L13-43) is
> actually broken** — it uses `sqlite.new(db_path)` without `keep_open` and
> without the `vim.g` workaround. It would fail with "out of memory" on the
> lazy-open. This is a latent bug the audit surfaced.

### 3.4 No Tables, No Functions, No cdata Across the Boundary

`uv.new_work` **only passes primitive types** (number/string/boolean/nil):

```
number   ✅  string   ✅  boolean  ✅  nil  ✅
table    ❌ "thread arg not support type 'table'"
function ❌ "thread arg not support type 'function'"
cdata    ❌ "thread arg not support type 'cdata'"
```

**Workaround:** serialize with **`vim.mpack`** (msgpack — preferred over JSON:
more compact, faster, binary-safe; both `vim.mpack.encode`/`decode` are
available on the thread). Verified: pass msgpack string in, get msgpack string
out, all values intact.

### 3.5 Object Sharing — Threads Are Fully Isolated (Safety Analysis)

The user asked: **can threads share object references, and how to protect
against buffer overrun?**

**Answer: NO shared references are possible.** Verified empirically:

| Attempt | Result |
|:--|:--|
| Pass a table ref | ❌ rejected at `queue()` |
| Pass an FFI cdata ref | ❌ rejected at `queue()` |
| Read a main-thread global (`_G.shared_table`) | ❌ nil on thread (separate Lua state) |

This is a **safety feature**, not a limitation:
- **No shared mutable state** → no data races, no use-after-free, no buffer
  overruns, no memory corruption. The thread physically cannot touch
  main-thread objects.
- **The only communication channel is primitive values** (args in, return out).
- **The thread's `vim` proxy is a separate table** — it does not reference the
  main thread's `vim` internals.

**Implication for the design:** all data crossing the boundary must be
**serialized** (msgpack strings — see §3.4). The thread is a "pure worker" —
it gets primitives, does work, returns primitives. This is actually *cleaner*
than shared-memory threading (no locks needed), at the cost of serialization.

### 3.6 Subprocess on a Thread — `vim.system` Is Nil, But Alternatives Work

`vim.system` is **nil on the thread**. But subprocess execution works via:

| Mechanism | On thread | Verified |
|:--|:--|:--|
| `io.popen(cmd)` | ✅ | captures stdout |
| `os.execute(cmd)` | ✅ | returns status |
| `vim.uv.spawn` | ✅ | available as function |

Verified a **realistic network flow**: thread runs `cat fake_gh.json` via
`io.popen`, parses with `vim.json.decode`, processes, returns JSON. Works.

**Implication:** adapters (`gh`/`glab`) must use `io.popen`/`uv.spawn` on the
thread, NOT `vim.system`. This is a real refactor of `adapter/base.lua`.

### 3.7 Summary: What `uv.new_work` Enables vs. Costs

| | |
|:--|:--|
| **Enables** | True parallelism — blocking network I/O off the main thread; UI stays responsive during 100ms–10s `gh` calls; WAL concurrent DB access |
| **Costs** | Thread `vim` is a limited proxy (no `vim.g`/`vim.fn`/`vim.system`/`vim.schedule`/`vim.notify`); no tables/functions/cdata across boundary (must JSON-serialize); sqlite.lua needs 2 workarounds; adapters must use `io.popen`/`uv.spawn` not `vim.system`; `vim.notify` must be deferred via callback + `vim.schedule` |

### 3.8 Every Restriction Has a Verified Solution

| # | Restriction | Solution | Where implemented |
|:--|:--|:--|:--|
| 1 | `vim.g` nil on thread | `rawset(vim, "g", {})` bootstrap | `thread.lua` L31, `storage/init.lua` L14 |
| 2 | sqlite lazy-open fails | `sqlite.new(db, { keep_open = true })` | `thread.lua` (via target fn), `storage/init.lua` L22 |
| 3 | No table/function/cdata args | **msgpack** serialize (`vim.mpack`) | `thread.lua` L43/L71/L81 |
| 4 | `vim.system` nil on thread | `io.popen`/`uv.spawn` fallback | `adapter/base.lua` L129-154 |
| 5 | `vim.notify` nil on thread | Collect into result, replay via `vim.schedule` | callback in `thread.lua` L78 |
| 6 | **Callback runs in fast event context** (new finding) | Wrap callback body in `vim.schedule` | `thread.lua` L77 |
| 7 | `vim.fn` not thread-safe | Resolve adapter/ctx on main first | `pull_review_async` |
| 8 | WAL concurrent access | Own connection + `busy_timeout` | `sync_review_thread` L920-921 |

> **New finding (§3.8 #6):** the `uv.new_work` completion callback runs in
> **fast event context** — `vim.api`/`vim.notify` fail inside it (E5560), but
> `vim.schedule` works. Verified in `sanity_callback_ctx.lua` /
> `sanity_callback_ctx2.lua`. This is why `thread.lua` wraps the callback body
> in `vim.schedule`.

---

## 4. `vim._async` (Coroutine Async/Await) — What We Found

### 4.1 What It Is

`vim._async` (`runtime/lua/vim/_async.lua`) is a **coroutine-based async/await
framework**. It is **NOT threads** — it's cooperative coroutines on the **main
thread**. It provides:

- `M.run(func, on_finish)` — run an async function (coroutine)
- `M.await(argc, fun, ...)` — inside an async function, await a callback-based
  function (e.g. `vim.system` with callback, `vim.schedule`)
- `M.join(max_jobs, funs)` — run multiple async functions with a concurrency
  limit

### 4.2 It Works (verified)

```lua
local async = require("vim._async")
async.run(function()
  local completed = async.await(3, vim.system, { "echo", "hi" }, { text = true })
  async.await(1, vim.schedule)
  return completed.stdout
end, function(err, stdout) ... end)
```

Verified:
- `async.await` with `vim.system` (async subprocess) ✅
- `async.await` with `vim.schedule` ✅
- `async.join(2, tasks)` — 3 tasks, max 2 concurrent ✅
- `async.await` with a 3-arg callback (like `vim.ui.select(items, opts, cb)`) ✅
- **Full `vim` access** — it's on the main thread, so `vim.api`, `vim.notify`,
  `vim.ui`, sqlite.lua (no hacks), tables, functions — **everything works** ✅

### 4.3 The Fast-Event-Context Gotcha

When you `await` a `uv.new_work` callback, the coroutine resumes **inside the
libuv callback (fast event context)**, where `vim.api` calls are restricted:

```
async.await(uv.new_work cb) → resume in fast event ctx → vim.api FAILS (E5560)
```

**Fix:** `async.await(1, vim.schedule)` after the thread await, before touching
`vim.api`. Verified: with the schedule, `vim.api.nvim_get_current_buf()` works.

### 4.4 It's an INTERNAL API (⚠️ Risk)

`vim._async` has an **underscore prefix** = internal. It is:
- **Not documented** in `:help lua.txt` (no `vim.async` tag)
- Only referenced in `vim/pack.lua` (internal usage)
- **Subject to change or removal** without notice

This is a **stability risk** for a plugin. If Neovim changes/removes
`vim._async`, the plugin breaks. (Though it's been stable across recent
versions and is used internally by `vim.pack`.)

### 4.5 The Real Cost: Rewriting Blocking Calls to Async Form

The adapters use `vim.system(args, o):wait()` (blocking). With `vim._async`,
you must rewrite these to the **async callback form**:

```lua
-- BEFORE (blocking):
local res = vim.system(args, o):wait()

-- AFTER (async):
local res = async.await(3, vim.system, args, o)
```

This is the "async refactor" (Option 3 in doc 09) — it requires rewriting
`sync_review` (a ~200-line monolith) and every adapter call into async form.
Doc 09 rejected this as "highest change cost." But it avoids ALL the thread
restrictions.

### 4.6 Summary: What `vim._async` Enables vs. Costs

| | |
|:--|:--|
| **Enables** | Full `vim` API access (no restrictions); sqlite.lua works normally (no hacks); tables/functions pass freely; `vim.notify`/`vim.ui` work directly; no serialization needed; `join` gives concurrency control |
| **Costs** | Must rewrite all blocking calls (`vim.system(...):wait()`) to async callback form + `await`; it's an **internal API** (stability risk); no true parallelism (cooperative — a CPU-bound task still blocks the main thread); `sync_review` rewrite is the biggest single change |

---

## 5. Side-by-Side Comparison

| | **`uv.new_work` (threads)** | **`vim._async` (coroutines)** |
|:--|:--|:--|
| **Execution** | True parallel thread | Cooperative on main thread |
| **`vim` access** | Limited proxy (no `g`/`fn`/`system`/`schedule`/`notify`) | **Full** |
| **sqlite.lua** | Needs 2 workarounds (`rawset(vim,"g",{})` + `keep_open`) | Works normally |
| **Passing data** | Primitives only → msgpack-serialize | Tables/functions freely |
| **Object sharing** | **None** (isolated — safe, no buffer overrun) | Same thread (shared) |
| **Subprocess** | `io.popen`/`uv.spawn` (not `vim.system`) | `vim.system` async |
| **Blocking calls** | Run on thread (off main) | Must rewrite to async form |
| **UI responsiveness** | ✅ blocking I/O off main thread | ⚠️ cooperative — CPU-bound still blocks |
| **`vim.notify`** | Must defer via callback + `vim.schedule` | Works directly |
| **API stability** | `vim.uv` is stable/public | `vim._async` is **internal** (risk) |
| **Rewrite cost** | Moderate (adapters → `io.popen`; sqlite workarounds) | High (`sync_review` + all adapters → async) |
| **Crash isolation** | ⚠️ Partial (hard thread crash can take down process) | N/A (same thread) |

---

## 6. Hybrid Option: `vim._async` + `uv.new_work` (Best of Both?)

We verified this works:

```lua
async.run(function()
  local tr = async.await(1, function(cb)
    local w = vim.uv.new_work(function(x) return "thread:" .. tostring(x * 2) end,
      function(r) cb(r) end)
    w:queue(21)
  end)
  async.await(1, vim.schedule)  -- back to main thread context
  return tr, vim.api.nvim_get_current_buf()  -- full vim access
end, ...)
```

**Pattern:** use `uv.new_work` for the *blocking* work (network, DB), and
`vim._async` for the *orchestration* (await, join, then touch `vim` freely on
the main thread). This gets:
- ✅ True parallelism for blocking I/O (thread)
- ✅ Full `vim` access for orchestration (async on main thread)
- ✅ `vim.notify`/`vim.ui` work directly
- ✅ Tables/functions in the async flow (only the thread boundary needs JSON)

**Costs:** still need the thread workarounds (sqlite, `io.popen`), plus the
async rewrite of blocking calls, plus the `vim.schedule` after thread awaits.
And it depends on the internal `vim._async`. Data crossing the thread boundary
is msgpack-serialized.

---

## 7. Open Questions / Recommendations

1. **Is `vim._async` stable enough to depend on?** It's internal. Options:
   - Vendor a copy of `_async.lua` into the plugin (it's ~110 lines, MIT).
   - Wait for it to become public (it's actively developed in Neovim).
   - Use plain coroutines + `vim.schedule` (reimplement the ~30 lines we need).
2. **Does the thread model's sqlite workarounds hold in the real plugin?**
   The `gc_work` thread is currently broken (lazy-open). Fix it with
   `keep_open` + `rawset(vim, "g", {})` and re-verify.
3. **Adapter refactor:** if threads, adapters must switch `vim.system` →
   `io.popen`/`uv.spawn`. If async, adapters must switch to callback form.
   Either way, `adapter/base.lua` changes.
4. **Recommendation:** the **hybrid** (async orchestration + thread for
   blocking I/O) gives the best UX, but depends on internal `vim._async`.
   The **pure thread** model is stable but has the most workarounds.
   The **pure async** model is cleanest but requires the biggest rewrite and
   has no true parallelism.

---

## 8. Test Scripts (reproducible)

All findings verified with scripts in `tmp/` (**kept for reproducibility** —
run from the project root: `nvim --headless -u NONE -l tmp/<script>.lua`):
- `sanity_work.lua` — thread + sqlite end-to-end (with workarounds)
- `sanity_thread_env.lua` — thread `vim` proxy contents
- `sanity_thread_args.lua` — arg type restrictions
- `sanity_share.lua` — object sharing (isolation)
- `sanity_serialize.lua` — **msgpack** across boundary
- `sanity_wal.lua` — WAL concurrent access
- `sanity_thread_subprocess.lua` — `io.popen`/`uv.spawn` on thread
- `sanity_thread_network.lua` — realistic thread network flow (gh-style)
- `sanity_async.lua` — `vim._async` basics
- `sanity_async_sqlite.lua` — sqlite in async flow (no hacks)
- `sanity_async_join.lua` — `async.join` concurrency limit
- `sanity_async_work2.lua` — hybrid + fast-event-context fix
- `sanity_callback_ctx.lua` / `sanity_callback_ctx2.lua` — **fast-event-context** finding + `vim.schedule` fix
- `sanity_popen_adapter.lua` — io.popen as real adapter `base.run` replacement (stdout/stderr/exit)
- `bench_thread_overhead.lua` / `bench_precise.lua` — overhead measurements

---

## 9. Overhead Measurements (mem / latency / CPU)

The user asked whether the thread model has meaningful overhead. Measured in
headless nvim (`bench_thread_overhead.lua` + `bench_precise.lua`, using
`vim.uv.hrtime()` for ns precision):

### 9.1 Latency

| Operation | Latency |
|:--|:--|
| `uv.new_work` queue+run+callback (reused worker) | **~0.1 ms** |
| `uv.new_work` create+queue+run+callback (fresh) | ~0.2 ms |
| `io.popen` echo (thread-style subprocess) | ~1.8 ms |
| `vim.system` echo `:wait()` (main thread) | ~1.5 ms |
| `vim.system` echo async callback | ~1.4 ms |
| `vim.mpack.encode` (90KB payload: 50 threads × 8 comments) | ~0.8 ms |
| `vim.mpack.decode` (90KB payload) | ~0.6 ms |
| `vim.json.encode` (93KB, for comparison) | ~0.4 ms |
| `vim.json.decode` (93KB) | ~0.4 ms |
| sqlite open + create table on thread | ~0.4 ms |
| sqlite open + 100 inserts on thread (incl. open) | ~76 ms |

### 9.2 Memory

| Measurement | RSS |
|:--|:--|
| Baseline (headless nvim) | 18,604 KB |
| After `uv.new_work` create | 18,604 KB (**+0 KB**) |
| After thread + sqlite run | 18,608 KB (**+4 KB**) |

A worker thread + its sqlite connection costs **~4 KB** of RSS. Negligible.

### 9.3 CPU

- Thread spawn is sub-millisecond and one-shot (not a busy loop).
- msgpack encode/decode is sub-ms even for 90KB payloads.
- The only real CPU cost is the actual work (network I/O, DB writes), which is
  the same whether on main or worker thread — but on the worker it does **not**
  block the UI.

### 9.4 Conclusion

The thread model's overhead is **negligible**:
- Thread spawn ~0.1ms (vs ~1.5ms for a subprocess — 15× cheaper).
- `io.popen` ≈ `vim.system` (~1.8ms vs ~1.5ms — no meaningful penalty).
- msgpack sub-ms for realistic payloads.
- +4KB memory per thread.
- No busy-wait CPU cost.

There is **no performance reason** to avoid `uv.new_work`. The only real costs
are the code-level workarounds (§3.8), all of which are implemented.

---

## 9. Solutions & Precise Overheads (Reframed)

Following the audit, the final architecture relies on **Option 2 (pure `uv.new_work` threads)**. All design plans have been reframed to incorporate the following verified solutions and latency profiles:

### 9.1 Verified Solutions
1. **Thread Bootstrap:** Call `rawset(vim, "g", {})` and extend `package.path` immediately inside the thread function before requiring `sqlite`.
2. **Database Connection:** Always open using `sqlite.new(db_path, { keep_open = true })` to prevent lazy-open failures on threads.
3. **Data Serialization:** Encode tables using MessagePack (`vim.mpack.encode/decode`) to safely pass arguments and return structures across the isolated thread boundary.
4. **Subprocess Calls:** Execute subprocesses using `io.popen(cmd .. " 2>&1")` or `vim.uv.spawn` inside the thread (as `vim.system` is `nil`).
5. **Fast Event Escape:** Wrap completion callbacks in `vim.schedule` to prevent `E5560` errors when touching Neovim APIs or notifications.

### 9.2 Precise Latency Benchmarks
* **Thread Spawn (reused):** **0.118 ms** (negligible overhead).
* **Subprocess Echo (`io.popen`):** **1.806 ms** (comparable to `vim.system`'s 1.462 ms).
* **msgpack vs JSON (90KB payload):** msgpack is sub-ms (~0.6–0.8 ms) and ~4% more compact.
* **SQLite Open + Table Creation on Thread:** **0.361 ms**.
* **Memory Footprint:** **+4 KB RSS** after thread + sqlite runs.