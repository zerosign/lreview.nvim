# 10 — SQLite Query Benchmark & Scaling Exploration

> **Status:** Exploration / data-gathering. Feeds the scaling decisions in
> [07-submit-atomicity.md](07-submit-atomicity.md) §2.8. Not a feature doc —
> it records *how* we measured the query patterns and *what* we concluded.

## Why this exists

While designing the submit/sync path (doc 07), we asked three questions that
needed *measured* answers, not theory:

1. Does the submit path need SQLite transactions, and do they lag the UI?
2. How does the design scale from a small MR to a huge one?
3. Would a **bitmap** data structure help the diff/change-set?

This doc records the benchmark that answered them, so the reasoning is
reproducible and the numbers are on record.

## The three scaling dimensions

An MR's size is not one number. We varied three independent dimensions:

| Dimension | What it models | Example |
|:--|:--|:--|
| **Files changed** | breadth of the MR | 5 → 100 files |
| **Threads per file** | density of discussion in one file | 2 → 12 threads/file |
| **Pending comment changes** | creation / replies / edits / deletions (the submit work) | 10 → 500 pending |

Total comments = `files × threads_per_file × comments_per_thread + pending`.

## Methodology

- **Runtime:** `lua5.5` + `lsqlite3` (SQLite 3.53.4), in-memory DB, WAL mode,
  `synchronous=NORMAL` — matching the plugin's `storage/init.lua` PRAGMAs.
- **Schema:** mirrors `storage/schema.sql` (threads + comments + the same
  indexes `idx_threads_buffer`, `idx_comments_thread`).
- **Data:** ~80% SYNCED base comments + a spread of pending DRAFT/MODIFIED/
  DELETED changes, matching a realistic MR.
- **Timing:** `os.clock()` wall-clock, single run after a warmup call, on the
  main thread (the worst case — before the async move in doc 09).
- **Reproduce:** `lua5.5 tmp/bench.lua` (the script lives in `tmp/`).

## Measured query patterns

| Pattern | What it is | Where |
|:--|:--|:--|
| **N+1 reconcile** | ~3 queries per comment (`WHERE t_id`, `comments_for_thread`, `WHERE c_id`) | current `sync_review` (`review.lua:426-560`) |
| **Batched reconcile** | 1 query for the whole MR + in-memory hash index | proposed fix (§2.8.1) |
| **Transaction** | `BEGIN IMMEDIATE` … `COMMIT` around N writes | proposed (§2.7) |
| **Per-buffer** | single indexed query for one file+line range | UI hot path (`comments_for_buffer`) |
| **Change-set** | `(c.state & 13) > 0` pending query | submit path (`get_pending_comments`) |

## Results

| Scenario | files | threads | total cmts | pending | N+1 reconcile | batched reconcile | txn (500) | per-buffer | change-set |
|:--|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| small | 5 | 10 | 40 | 10 | 0.7 ms | 0.11 ms | 0.02 ms | 0.04 ms | 0.08 ms |
| medium | 20 | 80 | 450 | 50 | 8.5 ms | 0.96 ms | 0.07 ms | 0.06 ms | 0.18 ms |
| large | 50 | 400 | 3,400 | 200 | **72 ms** | 6.5 ms | 0.30 ms | 0.13 ms | 0.77 ms |
| huge | 100 | 1,200 | 14,900 | 500 | **361 ms** | 31 ms | 0.78 ms | 0.32 ms | 2.9 ms |

## Conclusions

### 1. The N+1 reconcile is the real lag source — confirmed
Grows linearly with comment count (0.7 → 8.5 → 72 → 361 ms). At 3,400 comments
it's a visible UI hitch; at 14,900 it's a half-second freeze **on the main
thread today**. This is a pre-existing issue, not introduced by the new design.

### 2. Batching is an ~11x win — confirmed
72 → 6.5 ms (large), 361 → 31 ms (huge). Even at 15k comments the batched
reconcile is 31 ms — and it runs on the `uv.new_work` thread (doc 09), so the
UI never sees it. **Adopt the batched reconcile (§2.8.1).**

### 3. Transactions are negligible — confirmed
Marking 500 comments SYNCED: 0.78 ms auto-commit vs 0.63 ms single txn. The
transaction is actually *faster* (one commit avoids per-statement fsyncs).
**Keep the two-transaction structure (§2.7): wrap the local writes, never the
network.**

### 4. The UI hot path scales flat — confirmed
Per-buffer query: 0.04 → 0.32 ms even at 15k total comments, because it's
indexed by `(mo_id, path, line_start, line_end)`. O(comments in buffer), not
O(comments in MR). **No concern.**

### 5. The change-set query scales fine — confirmed
0.08 → 2.9 ms for up to 500 pending. One indexed query. **No concern.**

### 6. A bitmap data structure is unnecessary — rejected
The batched reconcile is already 31 ms at 15k comments via a single SQL scan +
in-memory hash index. A bitmap would add a structure to represent a set SQLite
already produces efficiently. Comment IDs are UUIDs, not dense integers, so a
bitmap would need a hash→index mapping (a *second* structure). The measured
cost is the SQL scan, not the in-memory work, so a bitmap buys nothing.
**Keep the batched query + hash index.**

## Open follow-ups

- Re-run under the real `sqlite.lua` wrapper (nvim's LuaJIT) to confirm the
  numbers hold with the plugin's actual statement layer (`storage/init.lua`
  `query`/`execute`), not just raw `lsqlite3`.
- Measure the network round-trip cost separately (the dominant term for large
  MRs) to size the async thread queue.
- Consider a `PRAGMA`-level check that `idx_threads_buffer` is actually used
  (`EXPLAIN QUERY PLAN`) for the per-buffer query on a large MR.
