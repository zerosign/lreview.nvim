# lreview.nvim — Design Documents

This directory contains detailed design documents for improving `lreview.nvim`.
Each document covers one problem domain: the problem, the proposed solution,
pros/cons, alternatives, before/after changes, and the flow/layout.

## Problem Categorization

All issues discussed are grouped into **four problem domains**:

### Domain 1 — Repo Topology & Branch Materialization
*How the plugin materializes code locally (checkout / worktree / sparse-checkout).*

| Doc | Issue | Journey |
|:----|:------|:--------|
| [01-repo-topology.md](01-repo-topology.md) | Query → Open an MR is a strategy decision, not a single command | A 0→1 |
| [01-repo-topology.md](01-repo-topology.md) | Branch creation for new work is the same strategy problem | B 0 |

### Domain 2 — Reviewing UX (Journey A)
*The reviewer's per-step experience.*

| Doc | Issue | Journey |
|:----|:------|:--------|
| [02-file-overview.md](02-file-overview.md) | File-list overview, minimal & non-invasive | A 2 |
| [03-review-verdict.md](03-review-verdict.md) | Review verdict (approve/request-changes) + popup confirmation, multiplatform | A 6 |
| [04-sync-bus.md](04-sync-bus.md) | Centralized panel/status sync, efficient propagation, keymap conflict | A 7 |

### Domain 3 — Requesting Review UX (Journey B)
*The author's per-step experience.*

| Doc | Issue | Journey |
|:----|:------|:--------|
| [05-mr-lifecycle.md](05-mr-lifecycle.md) | Formalize MR lifecycle contract + body editor | B 2 |
| [06-reviewer-assignment.md](06-reviewer-assignment.md) | Offline-first reviewer assignment via local user index — **deprioritized (enhancement/feature)** | B 3 |

### Domain 4 — Correctness & Maintainability
*Core engine robustness (from the initial architecture review).*

| Doc | Issue | Area |
|:----|:------|:-----|
| [07-submit-atomicity.md](07-submit-atomicity.md) | Non-atomic submit → partial-failure inconsistency; change-diff model + user feedback + `uv.new_work` + state-machine graph + SQLite txn strategy + large-MR scaling | `review.lua` |
| [07-submit-atomicity.md](07-submit-atomicity.md) | `sync_review` 40-complexity monolith decomposition | `review.lua` |

### Domain 5 — Cross-Cutting (Multiplatform Safety)
*Mechanisms that span multiple domains.*

| Doc | Issue | Used by |
|:----|:------|:--------|
| [08-capability-system.md](08-capability-system.md) | Adapter capability flags for multiplatform-safe features | Docs 03, 05, 06, 07 |
| [09-async-model.md](09-async-model.md) | Async execution model: subprocess vs. thread vs. async refactor — **decided: `uv.new_work` thread**; §8 extends it to all blocking I/O (`git.changed_lines`, network calls) | 04-sync-bus.md |
| [10-benchmark.md](10-benchmark.md) | SQLite query benchmark across files/threads-per-file/pending-changes; confirms N+1 reconcile is the lag source, batching is ~11x, transactions are negligible, bitmap rejected | 07-submit-atomicity.md |
| [11-plan-verification.md](11-plan-verification.md) | Per-plan test strategy (scenarios, checkpoints, risks, regressions, edge cases) + cross-plan conflict map (C1–C6) + implementation order | all plans |
| [12-async-audit.md](12-async-audit.md) | **Empirical audit** of `uv.new_work` threads vs `vim._async` coroutines in headless nvim: thread `vim` proxy limits, sqlite.lua workarounds, no object sharing (isolated/safe), JSON serialization, `vim._async` internal-API risk, hybrid option | 09-async-model.md |

## Recommended Implementation Order

The domains are largely independent, but there are dependencies *within* each:

1. **Domain 4 (correctness)** first — it's the foundation and lowest risk.
   - `07-submit-atomicity.md` (partial-failure data integrity)
2. **Domain 5 (capability system)** — a small, high-leverage cross-cutting
   foundation that Docs 03/05/06 depend on.
   - `08-capability-system.md` (adapter capability flags)
   - `09-async-model.md` (async execution model — decide before 04-sync-bus.md)
3. **Domain 1 (topology)** — unblocks the core reviewing journey.
   - `01-repo-topology.md` (shared materialize strategy)
4. **Domain 2 (reviewing UX)** — builds on the sync bus.
   - `04-sync-bus.md` first (foundation for 02 and 03)
   - then `02-file-overview.md`, `03-review-verdict.md`
5. **Domain 3 (requesting UX)** — independent, can be parallel.
   - `05-mr-lifecycle.md` first (core create/update/close flow)
   - `06-reviewer-assignment.md` **deprioritized** — it's an enhancement/feature,
     not a core fix. Design stays valid (offline-first via local user index +
     `uv.new_work`), but implement only after the higher-priority plans above.

## Cross-Cutting Principles

These principles recur across all documents:

- **Offline-first:** read from SQLite, push to network in batches.
- **Minimal & non-invasive:** reuse existing surfaces (panels, scratchpad, statusline); don't add competing windows.
- **Configurable, not hardcoded:** company tooling and repo topology vary; provide defaults + per-repo overrides.
- **Multiplatform via adapter capability flags:** generic code stays platform-agnostic; the adapter declares what it supports (see [08-capability-system.md](08-capability-system.md)).
- **Efficient propagation:** debounce, cache, and only touch dirty state.
