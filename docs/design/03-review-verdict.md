# 03 — Review Verdict + Popup Confirmation (Multiplatform)

**Journey:** A 6 (Submit the review)
**Domain:** 2 — Reviewing UX
**Status:** ✅ **Implemented** — `ui/confirm.lua` (floating confirmation popup) + verdict picker (APPROVE/COMMENT/REQUEST_CHANGES), capability-gated

---

## 1. Problem

Two issues with the current submit flow:

1. **No review verdict.** `LocalReviewSubmit` pushes comments but has no
   approve / request-changes / comment verdict. `LocalReviewApprove` is a
   separate bare action. On GitHub/GitLab, a review is a *verdict + comments*.
   The two should be unified.

2. **Poor confirmation UX.** `submit_review` uses
   `vim.fn.confirm(msg, "&Yes\n&No", 2)` — a **command-bar/status-bar prompt**.
   This is poor DX: it's modal, hard to read long summaries, and feels
   disconnected from the review context.

Additionally, the verdict must be **multiplatform-safe**: not every platform
supports a review verdict, and the generic code must not assume it does.

---

## 2. Proposed Solution

### 2.1 Adapter Capability Declaration

> **Cross-cutting:** the capability-flag pattern is generalized in
> [08-capability-system.md](08-capability-system.md). This doc uses
> `review_verdict`; the same mechanism gates reviewers, templates, drafts, and
> batch submit.

Add a capability flag to each adapter. The generic code checks it before
offering the verdict — the *capability* lives in the adapter, not in
`submit_review`.

```lua
-- adapter contract addition
M.capabilities = {
  review_verdict = true,    -- github: true, gitlab: true, others: false
  assign_reviewers = true,  -- for Doc 06 (request review)
}
```

`submit_review` checks `resolved.adapter.capabilities.review_verdict`:
- `true` → offer Comment / Approve / Request changes.
- `false` → fall back to current "push comments only" behavior.

### 2.2 Verdict Flow

The chosen verdict is passed to `submit_inline_review` as an extra param.
Adapters that don't support it ignore it.

```lua
-- review.lua
local verdict = nil
if resolved.adapter.capabilities.review_verdict then
  verdict = confirm_popup.ask_verdict(summary)   -- "comment" | "approve" | "request_changes" | nil
end
-- pass verdict into the batch submit
resolved.adapter.submit_inline_review(cfg, ctx, number, batch, { verdict = verdict })
```

### 2.3 Popup Confirmation (replacing `vim.fn.confirm`)

New self-contained module `lua/lreview/ui/confirm.lua`:

- **Floating popup** showing the pending-changes summary (same content as today,
  but in a popup with proper layout).
- **Verdict buttons** (Comment / Approve / Request changes) when supported.
- **Cancel** button.

```
┌──────────────────────────────────────────────────────────┐
│  Pending Review Changes                                  │
│  ──────────────────────────────────────────────────────  │
│  [New Thread]  src/a.lua:12: This logic is duplicated... │
│  [New Reply]   Agreed, let me fix that.                  │
│  [Edit Note]   Updated the error message.                │
│                                                          │
│  Push these 3 change(s) to github?                       │
│                                                          │
│   [Comment]  [Approve]  [Request changes]  [Cancel]      │
└──────────────────────────────────────────────────────────┘
```

The popup is **non-invasive** — it only appears at submit time.

### 2.4 Summary Panel Short-Circuits (`A` / `R`)

For rapid review workflows, the **Local Review Summary panel** exposes direct keybindings to trigger verdicts without leaving the summary window:

- **`A` (Approve MR)**: Prompts confirmation and triggers an immediate MR approval call (checking `approve_mr` capability).
- **`R` (Reject / Request Changes)**: Prompts confirmation and submits a `REQUEST_CHANGES` verdict (checking `review_verdict` capability).

---

## 3. Flow / Sequence

```
LocalReviewSubmit
        │
        ▼
  submit_review() gathers pending changes
        │
        ▼
  confirm_popup.show(summary)
        │
        ├── Cancel → abort (no API call)
        ├── Comment → verdict="comment"
        ├── Approve → verdict="approve"
        └── Request changes → verdict="request_changes"
        │
        ▼
  adapter.submit_inline_review(..., { verdict })
        │
        ▼
  sync_review() → reconcile local state
```

---

## 4. Before / After

### Before

```
LocalReviewSubmit
  → vim.fn.confirm("Push these N change(s)?", "&Yes\n&No", 2)  ← command bar
  → adapter.submit_inline_review(...)   (no verdict)
LocalReviewApprove (separate, bare approve)
```

**Problems:** Command-bar prompt (poor DX). No verdict attached to the review.
Approve is disconnected from the comment batch.

### After

```
LocalReviewSubmit
  → confirm_popup.show(summary)   ← floating popup
  → pick verdict (Comment/Approve/Request changes) if supported
  → adapter.submit_inline_review(..., { verdict })
```

**Improvements:** Popup confirmation (better DX). Verdict unified with the
comment batch. Multiplatform-safe via capability flag.

---

## 5. Pros & Cons

### Pros

- **Better DX** — popup instead of command-bar prompt.
- **Unified review** — verdict + comments in one action.
- **Multiplatform-safe** — capability flag; unsupported platforms fall back
  gracefully.
- **Non-invasive** — popup only at submit time.

### Cons

- **New UI module** (`ui/confirm.lua`) to build and maintain.
- **Adapter contract change** — `submit_inline_review` gains an optional param;
  existing adapters must be updated (backward-compatible if param is optional).
- **Verdict semantics differ per platform** — "request changes" maps differently
  on GitHub vs GitLab; the adapter must translate.

---

## 6. Alternatives

### Alt A — Keep `vim.fn.confirm`, just add verdict
- **Pros:** Minimal change.
- **Cons:** Keeps the poor command-bar DX. **Rejected** — the user explicitly
  flagged the command-bar confirmation as bad UX.

### Alt B — Verdict as a separate command (`LocalReviewApprove` with comments)
- **Pros:** No change to submit flow.
- **Cons:** Still disconnected; user must remember to approve separately.
  **Rejected** — doesn't unify the review.

### Alt C — Always ask for verdict (no capability check)
- **Pros:** Simpler generic code.
- **Cons:** Breaks for platforms without verdict support. **Rejected** —
  violates the multiplatform requirement.

### Alt D — Recommended: capability flag + popup (this doc)
- **Pros:** Correct multiplatform behavior + good DX.
- **Cons:** Slightly more code. **Accepted.**

---

## 7. Open Questions

1. Should "Request changes" require a comment body (some platforms do)?
2. Should the verdict default to "Comment" (pre-selected) to reduce friction?
3. Should `LocalReviewApprove` be kept as a fast-path (approve without opening
   the popup) or removed in favor of the unified flow?
