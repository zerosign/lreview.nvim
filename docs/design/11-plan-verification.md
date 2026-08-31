# 11 — Plan Verification, Test Strategy & Cross-Plan Risk

> **Status:** Verification / pre-implementation checklist. For each design doc,
> this records: what to test, the scenarios, the checkpoints (definition of
> done before commit), the risks, likely regressions, and edge cases. It also
> flags **cross-plan conflicts** — places where two plans disagree or depend on
> each other in ways that could break if implemented independently.

> **✅ Implementation status (rediscovered):** docs 01, 02, 03, 05, 06, 08 are
> **implemented**; doc 04 (sync-bus) and doc 07 (submit atomicity) are
> **partially implemented** (see their status headers); doc 09's thread model is
> **largely implemented** (`thread.lua`, `base.lua` io.popen, `sync_review_thread`).
> The **remaining work** is concentrated in: submit-on-thread (07), `sync_review`
> decomposition (07), notification replay (09), diff-cache invalidation + bus
> bypass (04), and `IN_FLIGHT` crash recovery (07). See §14.

---

## 0. Cross-Plan Dependency Map

Before testing any single plan, understand how the plans interlock. The
capability system (08) and async model (09) are the two **cross-cutting
foundations**; most other plans depend on them.

```
        ┌─────────────────────────────────────────────────────────┐
        │  08 Capability System (cross-cutting foundation)        │
        │  gates: 03 verdict, 05 lifecycle, 06 reviewers, 07 batch │
        └───────────────┬─────────────────────────────────────────┘
                        │
        ┌───────────────▼─────────────────────────────────────────┐
        │  09 Async Model (uv.new_work thread) — DECIDED          │
        │  runs: 04 sync-bus diff, 05 create/probe, 07 submit     │
        └───────────────┬─────────────────────────────────────────┘
                        │
   ┌────────────┬───────┴───────┬────────────┬──────────────┐
   ▼            ▼               ▼            ▼              ▼
 01 topology  02 file-overview 03 verdict  04 sync-bus    05 lifecycle
  (git)       (needs 04 cache) (needs 08)  (needs 09)     (needs 08,09)
   │            │                            │              │
   │            │                            │              ▼
   │            │                            │            06 reviewers
   │            │                            │            (needs 08,09)
   │            │                            │
   │            └───────────────┬────────────┘
   │                            ▼
   │                          07 submit-atomicity
   │                          (needs 08 batch_submit, 09 thread)
   ▼
 10 benchmark (informs 07 scaling)
```

### ⚠️ Cross-Plan Conflicts Found (must resolve before implementation)

| # | Conflict | Severity | Status |
|:--|:--|:--|:--|
| **C1** | **Doc 04 vs Doc 09 — async mechanism contradicts** | **HIGH** | **RESOLVED** — migrate everything to `uv.new_work` threads. Doc 04's subprocess model is replaced by the thread model. |
| **C2** | **Doc 04 §5.3 rationale invalidated** | **HIGH** | **RESOLVED** — the "SQLite isn't thread-safe → use subprocess" rationale is wrong. Threads use per-thread connections (WAL); no shared connection. |
| **C3** | **Doc 06 §2 references subprocess** | **MED** | **RESOLVED** — `pull_users_async` migrates to `uv.new_work` thread. |
| **C4** | **Doc 02 depends on Doc 04's diff cache** | **MED** | **Confirmed** — 04 before 02. |
| **C5** | **Doc 07 depends on Doc 09's thread + Doc 08's batch_submit** | **MED** | **Confirmed** — 07 after 08+09. |
| **C6** | **Doc 03/05/06 depend on Doc 08 capabilities** | **MED** | **Confirmed** — 08 first. |

**Resolution:** all async work migrates to the `uv.new_work` thread model
(doc 09). Doc 04 and Doc 06 are rewritten to remove subprocess references.
Implement **08 → 09 → 04 → 07** first (the foundations), then the rest.

---

## 1. Doc 01 — Repo Topology & Materialization

### What to test
The `materialize` strategy resolver: correct topology dispatch, dirty-tree
guardrail, worktree/sparse handling.

### Scenarios
| Scenario | Setup | Expected |
|:--|:--|:--|
| S1.1 Type 3 plain checkout | `topology = "simple"`, clean tree | `git checkout <branch>`, no prompt |
| S1.2 Type 3 dirty tree | `topology = "simple"`, modified tracked file | **STOP**, list dirty files, no checkout |
| S1.3 Type 3 untracked only | `topology = "simple"`, only untracked files | checkout proceeds (untracked don't block) — see open Q5 |
| S1.4 Type 2 auto suggest | `topology = "monorepo-single"`, `open.method = "auto"` | suggest sparse vs full, confirm/override |
| S1.5 Type 1 worktree+sparse | `topology = "monorepo-multi"` | worktree + cone patterns applied |
| S1.6 Dirty main + new worktree | dirty main checkout, Type 1/2 worktree | worktree creation proceeds (doesn't touch main) |
| S1.7 B 0 branch create | `LocalReviewBranch` | branch created via same resolver, naming convention applied |

### Checkpoints (before commit)
- [ ] Dirty tree **never** auto-resolves (no stash/commit/discard).
- [ ] Untracked vs modified distinction handled per open Q5.
- [ ] Worktree creation doesn't touch a dirty main checkout.
- [ ] Type 2 suggestion only fires when `open.method = "auto"`.

### Risks / Regressions
- **Risk:** worktree cleanup (open Q1) — orphaned worktrees accumulate.
- **Regression:** existing `open.method = "checkout"` config (open Q4) — currently unused; must not break existing users.
- **Edge:** branch naming collisions in worktrees; sparse cone patterns that don't match the MR's changed paths.

---

## 2. Doc 02 — File-List Overview

### What to test
The file view mode in the summary panel: wide table layout, sorting, jump-to-file, comment counts.

### Scenarios
| Scenario | Setup | Expected |
|:--|:--|:--|
| S2.1 Toggle views | open summary, press `g` | threads ↔ files view |
| S2.2 Wide table | files view | column-aligned, path truncates with `…` |
| S2.3 Sort | press `s` | cycles path/adds/dels/comments |
| S2.4 Jump | select file, `<CR>` | opens file at cursor, thread view for line |
| S2.5 No file stats | adapter returns no `+adds -dels` | fallback: path + counts only |
| S2.6 Comment counts | file with threads | `💬N` shown from `comments_for_buffer` |

### Checkpoints (before commit)
- [ ] No new window created (reuses summary panel).
- [ ] `detail.files` populated; graceful fallback if not.
- [ ] Comment counts come from the indexed per-buffer query (not N+1).

### Risks / Regressions
- **Risk (C4):** depends on Doc 04's diff cache for changed-line counts — if 04 isn't done, this column is blank.
- **Regression:** the summary panel's existing threads view must be unchanged.
- **Edge:** very long paths; files with many threads (sub-list? open Q2).

---

## 3. Doc 03 — Review Verdict + Popup

### What to test
The verdict popup, capability gating, verdict passed to submit.

### Scenarios
| Scenario | Setup | Expected |
|:--|:--|:--|
| S3.1 Verdict supported | `review_verdict = true` | popup shows Comment/Approve/Request changes |
| S3.2 Verdict unsupported | `review_verdict = false` | falls back to "push comments only" |
| S3.3 Cancel | click Cancel | no API call |
| S3.4 Verdict passed | choose Approve | `submit_inline_review(..., { verdict = "approve" })` |
| S3.5 Request changes w/o body | platform requires body | prompt for body (open Q1) |

### Checkpoints (before commit)
- [ ] Capability check before offering verdict (C6 — needs Doc 08).
- [ ] Adapter ignores verdict if unsupported (backward-compatible param).
- [ ] Popup replaces `vim.fn.confirm` entirely.

### Risks / Regressions
- **Risk (C6):** no capability table if 08 not implemented.
- **Regression:** `LocalReviewApprove` fast-path (open Q3) — keep or remove.
- **Edge:** verdict semantics differ per platform (GitHub vs GitLab "request changes").

---

## 4. Doc 04 — Sync Bus

### What to test
Debounced propagation, diff cache, dirty-only refresh, keymap resolution.

### ⚠️ Conflict C1/C2 — RESOLVED: migrated to the thread model
Doc 04's subprocess model (§3.1/§5.3) is **replaced** by the `uv.new_work`
thread model (doc 09). The sync-bus *concept* (debounce, dirty-only, diff
cache) is unchanged; only the async mechanism differs. All async work
(`pull_review_async`, `pull_users_async`, `git.changed_lines`) runs on threads
with per-thread SQLite connections (WAL).

### Scenarios
| Scenario | Setup | Expected |
|:--|:--|:--|
| S4.1 Debounce coalesces | rapid add/reply/edit | one flush, not three |
| S4.2 Dirty-only refresh | one buffer dirty | only that buffer's decor refreshed |
| S4.3 Diff cache hit | same (branch, path) | no `git.changed_lines()` recompute |
| S4.4 Diff cache invalidate | branch change / pull | cache cleared, recompute once |
| S4.5 Pull completion | thread pull done | immediate flush (skip debounce) |
| S4.6 DB write not gated | action | DB write instant, flush deferred |
| S4.7 Keymap | `<leader>od` | Summary (README intent), thread view via hover |

### Checkpoints (before commit)
- [ ] `mark_dirty` is fire-and-forget; DB write never gated on flush.
- [ ] `vim.uv` timer callback wrapped in `vim.schedule` (LuaJIT quirk §5.1).
- [ ] Diff cache invalidated on branch change / pull.
- [ ] `flush_now()` on pull completion.

### Risks / Regressions
- **Risk:** cache invalidation bugs → stale highlights.
- **Regression:** every action handler in `summary.lua`/`thread_view.lua`/`editor.lua`/`decor.lua` touched — high blast radius.
- **Edge:** flush pending while a pull completes (open Q4); GC pauses during flush (§5.4).

---

## 5. Doc 05 — MR Lifecycle + Runtime Probe

### What to test
Create/update/close/approve flows, body editor, and the **runtime capability probe**.

### Scenarios
| Scenario | Setup | Expected |
|:--|:--|:--|
| S5.1 Create MR | `LocalReviewCreate` | create via adapter, template picker if supported |
| S5.2 Draft MR | `draft_mr` probed true | "create as draft" offered |
| S5.3 Draft MR disabled | org disallows drafts | option hidden (probe false) |
| S5.4 Probe offline | probe fails (offline) | fall back to static table, never block |
| S5.5 Probe cached | probe ran before | reuse SQLite cache, no re-probe |
| S5.6 Probe stale | cache > N days | re-probe in background |
| S5.7 Update/Close/Approve | commands | adapter calls, capability-gated |

### Checkpoints (before commit)
- [ ] Probe is **offline-first, cached, best-effort, non-blocking** (§2.4.1).
- [ ] Probe runs on the `uv.new_work` thread (C5 — needs Doc 09).
- [ ] Static + probed merged: `vim.tbl_extend("force", static, probed)`.
- [ ] Never block the create flow on a probe.

### Risks / Regressions
- **Risk (C6):** capability table needed (08).
- **Risk (C5):** probe on thread (09).
- **Regression:** existing `create_mr`/`update_mr`/`close_mr`/`approve_mr` behavior.
- **Edge:** probe cache staleness (open Q5); batched vs per-capability probe (open Q4).

---

## 6. Doc 06 — Reviewer Assignment (deprioritized)

### What to test
Offline multi-select picker, single API call, reviewer history.

### Scenarios
| Scenario | Setup | Expected |
|:--|:--|:--|
| S6.1 Picker offline | user index populated | instant multi-select, search-as-you-type |
| S6.2 Empty index | no users cached | auto-fetch on first use |
| S6.3 Assign | select reviewers | single `assign_reviewers` call |
| S6.4 Offline staging | offline | stage locally, push later |
| S6.5 Large org | 500 users | FTS5 search, recent reviewers first |

### Checkpoints (before commit)
- [ ] Picker reads from SQLite only (no per-keystroke network).
- [ ] Single API call on submit, not per-user.
- [ ] Network submit via `uv.new_work` (C3 — RESOLVED: `pull_users_async` migrated to thread).

### Risks / Regressions
- **Risk (C3):** RESOLVED — §2 migrated to thread model.
- **Risk (C6):** `assign_reviewers` capability (08).
- **Edge:** reviewer history definition (open Q2); staging persistence (open Q4).

---

## 7. Doc 07 — Submit Atomicity

### What to test
Change-set computation, `IN_FLIGHT` state, idempotent retry, transactions, scaling.

### Scenarios
| Scenario | Setup | Expected |
|:--|:--|:--|
| S7.1 Full success | all pushes ok | all → SYNCED, `"Pushed N"` |
| S7.2 Partial failure | 2nd of 5 fails | pushed → SYNCED, failed → revert, `"Pushed 1 of 5"` |
| S7.3 Retry idempotent | re-run after partial | only failed items pushed (no double-push) |
| S7.4 Crash mid-push | `IN_FLIGHT` left in DB | on startup, revert `IN_FLIGHT` to prior state |
| S7.5 Conflict blocks | any CONFLICT | submit blocked until resolved |
| S7.6 Batch vs one-by-one | `batch_submit` true/false | correct path per capability |
| S7.7 Transaction atomicity | txn 1 / txn 2 | all-or-nothing per phase |
| S7.8 Large MR | 3,400+ comments | batched reconcile (not N+1) — see Doc 10 |

### Checkpoints (before commit)
- [ ] `IN_FLIGHT` is transient — never persists across crash (revert on startup).
- [ ] Idempotency from state transitions, not a parallel "already pushed" list.
- [ ] Transactions wrap local writes only; **never** the network call.
- [ ] Batched reconcile (one query + in-memory index), not N+1.
- [ ] `batch_submit` capability gates the path (C5 — needs 08).

### Risks / Regressions
- **Risk (C5):** needs 08 (`batch_submit`) + 09 (thread).
- **Regression:** `submit_review`/`sync_review` are core — high blast radius.
- **Edge:** crash during push (open Q2); `IN_FLIGHT` persisted vs in-memory (open Q1); one-by-one path correctness even when batch is common.

---

## 8. Doc 08 — Capability System

### What to test
Capability declaration, defaults, gating, cross-plan consistency.

### Scenarios
| Scenario | Setup | Expected |
|:--|:--|:--|
| S8.1 Defaults | adapter declares nothing | inherits `base.default_capabilities` |
| S8.2 Override | adapter overrides | `vim.tbl_extend("force", ...)` wins |
| S8.3 Gate | `review_verdict = false` | feature hidden/fallback |
| S8.4 Static + probe | probe refines | merged, probe wins on environmental facts |
| S8.5 Consistency | every feature gated | no feature offered without a capability check |

### Checkpoints (before commit)
- [ ] Every capability used by 03/05/06/07 is declared in 08.
- [ ] `base.lua` provides conservative defaults; adapters opt in.
- [ ] A test ensures every capability is checked consistently (doc 08 §6 "Discovery" con).

### Risks / Regressions
- **Risk:** a feature offered but capability not declared (or vice versa).
- **Regression:** existing adapter contract — adding `capabilities` must not break custom adapters.
- **Edge:** nil-safe capability check (open Q2 — `adapter.has()` helper).

---

## 9. Doc 09 — Async Model (`uv.new_work` thread)

### What to test
Thread safety, notification deferral, adapter resolution on main thread, DB connection isolation.

### Scenarios
| Scenario | Setup | Expected |
|:--|:--|:--|
| S9.1 Thread no vim.api | thread runs network+DB | no `vim.api`/`vim.fn`/`vim.notify` in thread |
| S9.2 Notification deferral | thread produces notify | collected, replayed on main via `vim.schedule` |
| S9.3 Adapter on main | `vim.fn` needed | resolved on main before queueing |
| S9.4 Own DB connection | thread writes | separate connection (WAL), no UI contention |
| S9.5 GC precedent | existing `gc_work` | same pattern, proven |
| S9.6 `git.changed_lines` | threaded | biggest win, thread-ready as-is |

### Checkpoints (before commit)
- [ ] Thread rule (§2.5): no `vim.api`/`vim.fn`/`vim.notify`/`vim.ui`/`vim.schedule` in thread.
- [ ] Notifications collected + replayed on main.
- [ ] Adapter/ctx resolved on main thread first.
- [ ] Thread uses its own SQLite connection.

### Risks / Regressions
- **Risk (C1/C2):** RESOLVED — Doc 04 migrated to the thread model.
- **✅ Risk (12-async-audit):** RESOLVED — every `uv.new_work` restriction has a
  verified solution (doc 12 §3.8): `rawset(vim,"g",{})` + `keep_open` for
  sqlite, msgpack for data, `io.popen` for subprocess, `vim.schedule` for the
  fast-event-context callback. The `gc_work` thread is **fixed**. The thread
  decision is **confirmed**. See [12-async-audit.md](12-async-audit.md).
- **Regression:** any code that assumed subprocess (`pull_review_async`, `pull_users_async`) — all migrate to threads.
- **Edge:** thread crash isolation (pcall-guarded); GC thread + submit thread both writing (WAL handles).

---

## 10. Doc 10 — Benchmark (informs 07)

### What to test
The measured query patterns; the N+1 → batched fix.

### Scenarios
| Scenario | Setup | Expected |
|:--|:--|:--|
| S10.1 Reproduce | `lua5.5 tmp/bench.lua` | matches recorded numbers |
| S10.2 N+1 vs batched | large MR | batched ~11x faster |
| S10.3 Transaction | 500 writes | txn ≈ auto-commit (or faster) |
| S10.4 Per-buffer | huge MR | flat (indexed) |

### Checkpoints (before commit)
- [ ] Batched reconcile adopted in 07 (not N+1).
- [ ] Re-run under real `sqlite.lua` wrapper (open follow-up).

### Risks / Regressions
- **Risk:** benchmark used raw `lsqlite3`, not the plugin's `sqlite.lua` wrapper — numbers may differ slightly.
- **Edge:** WAL vs in-memory differences; real disk I/O.

---

## 11. Cross-Plan Regression Matrix

When implementing plan X, which other plans could break?

| Implementing | Could regress | Why |
|:--|:--|:--|
| 08 (capabilities) | 03, 05, 06, 07 | they read `adapter.capabilities` |
| 09 (async thread) | 04, 06, 07 | they assumed subprocess / need thread — **all migrate to thread** |
| 04 (sync bus) | 02 | 02 uses the diff cache |
| 07 (submit atomicity) | 03 | verdict popup is part of submit |
| 05 (lifecycle) | 06 | reviewer assignment may hook create flow |

---

## 12. Recommended Implementation & Test Order

1. **08 (capabilities)** — foundation; test S8.1–S8.5.
2. **09 (async thread)** — foundation; test S9.1–S9.6. **Doc 04 already rewritten to match.**
3. **04 (sync bus)** — after 09; test S4.1–S4.7.
4. **07 (submit atomicity)** — after 08+09; test S7.1–S7.8 (uses Doc 10 data).
5. **01 (topology)** — independent; test S1.1–S1.7.
6. **02 (file overview)** — after 04; test S2.1–S2.6.
7. **03 (verdict)** — after 08; test S3.1–S3.5.
8. **05 (lifecycle)** — after 08+09; test S5.1–S5.7.
9. **06 (reviewers)** — deprioritized; after 08+09; test S6.1–S6.5.

---

## 13. Open Cross-Plan Questions to Resolve

1. ~~**C1/C2:** Should Doc 04 be rewritten to the thread model now, or is the
   subprocess model still intended for *some* paths?~~ **RESOLVED** — migrate
   everything to `uv.new_work` threads. Doc 04 and Doc 06 rewritten.
2. **C4:** Is the diff cache (04) a hard prerequisite for 02, or can 02 fall
   back to no changed-line count?
3. **C6:** Should the capability system (08) ship with a `has()` helper to
   centralize nil-safe checks, so all dependent plans use the same pattern?
4. **Doc 07 open Q1:** Is `IN_FLIGHT` persisted or in-memory? Affects crash
   recovery testing (S7.4).
5. **Doc 04 open Q4:** Flush pending while pull completes — `flush_now()`
   semantics need a defined behavior.

---

## 14. Implementation Status (rediscovered — what's done vs remaining)

### 14.1 Fully implemented

| Doc | Module(s) | Notes |
|:--|:--|:--|
| 01 | `materialize.lua` | `resolve_mode` (checkout/worktree), `materialize_branch` |
| 02 | `ui/summary.lua` | Dual threads/files view, sort cycle, `win_w`-dynamic columns |
| 03 | `ui/confirm.lua`, `review.lua` | Floating confirm popup, verdict picker, capability-gated |
| 05 | `ui/detail_editor.lua`, `init.lua` | Scratchpad body editor, `LocalReviewCreate` |
| 06 | `review.lua`, adapters | `assign_reviewers`, `LocalReviewRequestReview`, offline cache |
| 08 | `adapter/init.lua`, `adapter/base.lua` | `default_capabilities`, `M.supports()`, overrides |

### 14.2 Partially implemented

| Doc | Done | Remaining |
|:--|:--|:--|
| 04 (sync-bus) | `sync.lua` core (mark_dirty, debounce, flush, subscribe, diff cache) | Diff-cache invalidation never wired; `pull_review_async` bypasses bus |
| 07 (submit) | `IN_FLIGHT`, `with_transaction`, `compute_change_set`, batched reconcile | Submit-on-thread; `sync_review` decomposition; `IN_FLIGHT` crash recovery |
| 09 (async) | `thread.lua`, `base.lua` io.popen, `sync_review_thread`, `pull_review_async`, `gc_work` fix | `vim.notify` replay from thread; `git.changed_lines` on thread |

### 14.3 The consolidated remaining-work list (all plans)

1. **`vim.notify` replay from thread callback** (09/12) — currently silently
   lost on the worker thread. **Correctness bug.**
2. **`sync_review` decomposition** (07 §2.2) — enables submit-on-thread.
3. **Submit-on-thread** (07 §2.5) — `submit_review_thread` + wrapper.
4. **`IN_FLIGHT` crash recovery on startup** (07 §2.6.1).
5. **Diff-cache invalidation wiring** (04) — on pull + branch change.
6. **Sync-bus bypass fix** (04) — `pull_review_async` → `mark_dirty`+`flush_now`.
7. **`git.changed_lines` on thread** (09 §8.3/B) — biggest UI-latency win.

### 14.4 Recommended next implementation order

1. **#1 + #2** (notification replay + decomposition) — one coherent unit in
   `sync_review`, unblocks submit-on-thread.
2. **#3** (submit-on-thread) — depends on #1/#2.
3. **#4** (IN_FLIGHT recovery) — small, independent.
4. **#5 + #6** (sync-bus wiring) — doc 04 completion.
5. **#7** (`git.changed_lines` threaded) — biggest perf win, independent.
