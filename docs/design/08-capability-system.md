# 08 — Adapter Capability System (Cross-Cutting)

**Applies to:** Docs 03, 05, 06, 07 (and the core adapter contract)
**Domain:** Cross-Cutting — Multiplatform Safety

---

## 1. Problem

`lreview.nvim` supports multiple platforms (GitHub, GitLab, and custom
adapters). Not every platform supports every feature:

- GitHub/GitLab support a **review verdict** (approve / request-changes);
  some platforms don't.
- Some platforms support **assigning reviewers**; others don't.
- Some support **draft MRs**, **thread resolution**, **batch submission**, etc.

If the generic code assumes a feature exists, it breaks (or silently misbehaves)
on platforms that lack it. The naive fix — checking `if provider == "github"`
scattered through the code — is fragile and doesn't scale to custom adapters.

**The solution is a capability system:** each adapter *declares* what it
supports, and the generic code checks the declaration before offering a feature.
This keeps the generic code platform-agnostic and makes new platforms safe to
add.

---

## 2. Proposed Solution — A `capabilities` Table on Each Adapter

Each adapter exposes a `capabilities` table. The generic code reads it to decide
whether to offer a feature.

```lua
-- adapter contract addition
M.capabilities = {
  -- Review lifecycle
  review_verdict   = true,   -- approve / request-changes on submit   (Doc 03)
  draft_mr         = true,   -- create MR as draft                    (Doc 05)
  update_mr        = true,   -- edit title/body after create          (Doc 05)
  close_mr         = true,   -- close an MR                           (Doc 05)
  approve_mr       = true,   -- approve an MR                         (Doc 05)
  list_templates   = true,   -- MR/PR templates                       (Doc 05)

  -- Comments & threads
  inline_comments  = true,   -- line-level comments (vs. general only)
  resolve_threads  = true,   -- resolve/reopen threads
  batch_submit     = true,   -- submit new threads in one batch        (Doc 07)

  -- Reviewers
  assign_reviewers = true,   -- assign reviewers                       (Doc 06)
  offline_staging  = true,   -- stage reviewer selection offline       (Doc 06)
}
```

### 2.1 How the Generic Code Uses It

```lua
-- review.lua (submit_review)
if resolved.adapter.capabilities.review_verdict then
  verdict = confirm_popup.ask_verdict(summary)
end
```

```lua
-- init.lua (cmd_create)
if resolved.adapter.capabilities.list_templates then
  templates = resolved.adapter.list_templates(cfg, ctx)
end
```

The pattern is always the same: **check the capability before offering the
feature; fall back gracefully if absent.**

### 2.2 Defaults & Fallbacks

To keep custom adapters simple, `capabilities` should have **sensible defaults**
when not specified. Two options:

- **Optimistic (default true):** assume a feature works unless the adapter says
  otherwise. Simpler for adapters, but risks silent breakage.
- **Pessimistic (default false):** assume nothing works unless declared. Safer,
  but more boilerplate for adapters.

**Recommendation:** a hybrid — a shared `base.lua` provides a default
`capabilities` table (the common subset), and each adapter overrides only what
differs. New/custom adapters inherit the base defaults and opt out explicitly.

```lua
-- adapter/base.lua
M.default_capabilities = {
  review_verdict   = false,  -- conservative: opt-in
  draft_mr         = false,
  update_mr        = true,   -- most platforms support this
  close_mr         = true,
  approve_mr       = false,  -- conservative: opt-in
  list_templates   = false,
  inline_comments  = true,
  resolve_threads  = true,
  batch_submit     = true,
  assign_reviewers = false,  -- conservative: opt-in
  offline_staging  = false,
}
```

```lua
-- adapter/github.lua
M.capabilities = vim.tbl_extend("force", base.default_capabilities, {
  review_verdict   = true,
  draft_mr         = true,
  approve_mr       = true,
  list_templates   = true,
  assign_reviewers = true,
  offline_staging  = true,
})
```

---

## 3. Where Each Capability Is Used (Cross-Reference)

| Capability | Doc | Feature gated |
|:-----------|:----|:--------------|
| `review_verdict` | [03-review-verdict.md](03-review-verdict.md) | Comment/Approve/Request-changes on submit |
| `assign_reviewers` | [06-reviewer-assignment.md](06-reviewer-assignment.md) | Reviewer-assignment picker |
| `offline_staging` | [06-reviewer-assignment.md](06-reviewer-assignment.md) | Stage reviewer selection offline, push later |
| `list_templates` | [05-mr-lifecycle.md](05-mr-lifecycle.md) | Template picker in create flow |
| `draft_mr` | [05-mr-lifecycle.md](05-mr-lifecycle.md) | "Create as draft" option |
| `update_mr` / `close_mr` / `approve_mr` | [05-mr-lifecycle.md](05-mr-lifecycle.md) | Enable those commands |
| `inline_comments` | (core) | Line-level comments vs. general-only |
| `resolve_threads` | (core) | Thread resolve/reopen |
| `batch_submit` | [07-submit-atomicity.md](07-submit-atomicity.md) | Batch new-thread submission |

### 3.1 Full Inventory — Capability → Feature → Actions → Events

A capability is a **gate** ("does the platform support X?"). The feature it
gates is then **driven by user actions** and **affected by events** (sync,
remote changes, probe invalidation). This is the complete matrix.

**Static capabilities (per-adapter):**

| Capability | Feature | Doc | Adapter method (exists?) | Actions that trigger it | Events that affect it |
|:--|:--|:--|:--|:--|:--|
| `review_verdict` | approve / request-changes on submit | 03 | `approve_mr` ✅ | `:LocalReviewSubmit` → verdict popup → confirm | sync reconcile; remote approval by others |
| `draft_mr` | create MR as draft | 05 | `create_mr` ✅ | `:LocalReviewCreate` → "as draft" toggle | **probe** (org allows drafts?) |
| `update_mr` | edit title/body | 05 | `update_mr` ✅ | `:LocalReviewUpdate` | — |
| `close_mr` | close MR | 05 | `close_mr` ✅ | `:LocalReviewClose` | — |
| `approve_mr` | approve MR | 05 | `approve_mr` ✅ | `:LocalReviewApprove` | **probe** (user permission) |
| `list_templates` | template picker | 05 | `list_templates` ✅ | `:LocalReviewCreate` → template picker | **probe** (repo has templates?) |
| `inline_comments` | line-level comments | core | `submit_inline_review` ✅ | `add_comment` (visual select) | sync reconcile |
| `resolve_threads` | resolve / reopen | core | `resolve_thread` ✅ | `:LocalReviewResolve` / toggle | sync reconcile (remote resolve) |
| `batch_submit` | batch new-thread submit | 07 | `submit_inline_review` ✅ | `submit_review` (batch path) | partial-failure retry; `IN_FLIGHT` state |
| `assign_reviewers` | assign reviewers | 06 | `list_users` ✅ | reviewer picker → assign | — |
| `offline_staging` | stage reviewer selection offline | 06 | TBD | stage → push later | submit push |

**Runtime-probed capabilities (per-repo/org, from doc 05 §2.4):**

| Capability | Answers | Probe trigger | Events that invalidate / affect |
|:--|:--|:--|:--|
| `draft_mr` | org allows drafts? | create flow (background) | repo remote change; manual refresh; cache stale (>N days) |
| `approve_mr` | current user can approve? | create flow (background) | user role change; cache stale |
| `list_templates` | repo has templates? | create flow (background) | template files added/removed; cache stale |

**Key takeaway:** the capability is checked once (static, refined by probe);
the feature's *behavior* is then driven by the actions in the middle column and
perturbed by the events in the right column. The dominant event class is the
**sync/reconcile** (doc 07 §2.2) — a remote change can flip a comment to
`CONFLICT`, which blocks the submit feature until resolved.

### 3.2 Cross-Cutting Impact on Other Plans

The capability system is **Domain 5 — Cross-Cutting**: it is not a standalone
feature but a mechanism other plans depend on. The impact differs by plan:

| Plan | How capabilities affect it | Reference |
|:--|:--|:--|
| **Doc 07 (submit atomicity)** | `batch_submit` **gates the code path** (batch vs one-by-one) → changes the atomicity requirements. One-by-one path needs the `IN_FLIGHT` + idempotent-retry machinery to be rock-solid. `review_verdict` gates the verdict popup on submit. | doc 07 §2.1, §2.5 |
| **Doc 09 (async model)** | The **runtime probe** (doc 05 §2.4) is network I/O → runs on the `uv.new_work` thread. Probed capabilities (`draft_mr`, `approve_mr`, `list_templates`) gate the create-flow options — and that create flow runs on the thread. Capabilities both *decide what work exists* and *run on the thread*. | doc 09 §8.6 |
| **Doc 03 (review verdict)** | `review_verdict` gates whether the verdict popup is offered on submit. | doc 03 §2 |
| **Doc 05 (MR lifecycle)** | `draft_mr`/`update_mr`/`close_mr`/`approve_mr`/`list_templates` gate the create/update/close commands; the runtime probe refines them per-repo. | doc 05 §2.4 |
| **Doc 06 (reviewer assignment)** | `assign_reviewers`/`offline_staging` gate the reviewer picker and offline staging. | doc 06 §2 |

**The two distinct ways capabilities affect a plan:**
1. **Code-path selection** (doc 07): the capability picks *which* implementation
   runs (batch vs one-by-one), which changes correctness requirements.
2. **Execution-location** (doc 09): the capability's *probe* and the *gated
   network calls* determine what work runs on the thread.

Both must be kept in mind when implementing any of the dependent plans.

---

## 4. Flow / Sequence

```
adapter.resolve(cwd)
        │
        ▼
  resolved = { adapter, provider, cfg, ... }
        │
        ▼
  [feature offered?]
        │
        ├── resolved.adapter.capabilities.<feature> == true
        │     → offer the feature (popup, picker, command)
        │
        └── false / nil
              → fall back to the non-feature path (or hide the option)
```

---

## 5. Before / After

### Before

```
if provider == "github" or provider == "gh" then
  -- github-specific reply targeting
end
if provider == "gitlab" then
  -- gitlab-specific behavior
end
```

**Problems:** Provider checks scattered through generic code. Doesn't scale to
custom adapters. Easy to miss a platform.

### After

```
if resolved.adapter.capabilities.review_verdict then
  -- offer verdict
end
```

**Improvements:** Generic code is platform-agnostic. New platforms declare
capabilities once. Features degrade gracefully.

---

## 6. Pros & Cons

### Pros

- **Multiplatform-safe** — generic code never assumes a feature exists.
- **Extensible** — new platforms declare capabilities once; no generic-code
  changes.
- **Graceful degradation** — unsupported features fall back or hide.
- **Single source of truth** — capability lives in the adapter, not scattered
  `if provider` checks.
- **Reusable across the whole plan** — verdict, reviewers, templates, drafts,
  batch submit all use the same mechanism.

### Cons

- **New contract surface** — adapters must declare capabilities (mitigated by
  `base.lua` defaults).
- **Default policy decision** — optimistic vs pessimistic defaults need care
  (recommended: conservative base + explicit opt-in).
- **Discovery** — a feature might be offered but the capability not declared
  (or vice versa); needs a test that every capability is checked consistently.

---

## 7. Alternatives

### Alt A — Scattered `if provider == "github"` checks (status quo)
- **Pros:** No new abstraction.
- **Cons:** Fragile, doesn't scale to custom adapters, easy to miss a platform.
  **Rejected.**

### Alt B — Feature detection at runtime (probe the API)
- **Pros:** No manual declaration; always accurate.
- **Cons:** Requires a network call per feature; slow; can't detect offline.
  **Rejected** — violates the offline-first principle.

### Alt C — Recommended: declarative `capabilities` table (this doc)
- **Pros:** Offline, fast, explicit, extensible.
- **Cons:** Requires manual declaration (mitigated by base defaults).
  **Accepted.**

---

## 8. Open Questions

1. Should capabilities be **static** (declared at module load) or **dynamic**
   (some depend on the specific repo/org, e.g. whether the org allows
   draft MRs)? **→ Partially resolved by [05-mr-lifecycle.md](05-mr-lifecycle.md)
   §2.4:** the static table answers "does the adapter implement X"; a
   best-effort, cached **runtime probe** refines it to "does X work in this
   repo/org" for environmental facts (draft_mr, approve_mr, list_templates).
2. Should there be a **capability check helper** (e.g.
   `adapter.has(resolved, "review_verdict")`) to centralize the nil-safe check?
3. Should the README document the full capability matrix per platform?
4. Should unsupported features be **hidden** or **shown-but-disabled** (with a
   tooltip explaining why)?
