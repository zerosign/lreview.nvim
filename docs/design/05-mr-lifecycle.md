# 05 — MR Lifecycle Contract & Body Editor

**Journey:** B 2 (Create the MR/PR)
**Domain:** 3 — Requesting Review UX

---

## 1. Problem

Two issues with the current create/update/close flow:

1. **No body editor.** `pick_template_and_create` uses
   `vim.fn.input("Title: ")` (a single-line prompt) and the template body
   verbatim. There is no way to write a meaningful multi-line description or
   edit the template before submitting.

2. **The MR-lifecycle adapter contract is informal.** The adapter already has
   `create_mr`, `update_mr`, `close_mr`, `approve_mr` (verified in both
   `github.lua` and `gitlab.lua`), but the contract is not documented or typed.
   The README documents the *comment* contract but not the *MR lifecycle*
   contract. This makes it hard to add new platforms correctly.

---

## 2. Proposed Solution

### 2.1 Formalize the MR-Lifecycle Adapter Contract

> **Cross-cutting:** which lifecycle operations are available is gated by the
> capability system in [08-capability-system.md](08-capability-system.md)
> (`update_mr`, `close_mr`, `approve_mr`, `draft_mr`, `list_templates`).

Document and type the contract so new platforms implement it correctly:

```lua
-- adapter contract (MR lifecycle)
M.create_mr(cfg, ctx, opts) -> url, err
  -- opts: { title, body, source_branch, target_branch, template, draft?, reviewers? }
M.update_mr(cfg, ctx, number, title, body) -> ok, err
M.close_mr(cfg, ctx, number) -> ok, err
M.approve_mr(cfg, ctx, number) -> ok, err
M.list_templates(cfg, ctx) -> { name, content }[], err
```

The generic `review.create_review` / `review.update_review` / `review.close_review`
stay platform-agnostic; each adapter maps the uniform contract to its CLI
(e.g. `glab` uses `--description`/`--template` mutually exclusive, `gh` uses
`--body`).

### 2.2 Body Editor via the Existing Scratchpad

After picking a template, open the body in the existing `ui/editor.lua`
scratchpad **pre-filled with the template content**. On `:w`, create the MR.

This:
- **Reuses the plugin's own editor** (no new UI).
- Gives a proper **multi-line description**.
- Lets the user **edit the template** before submitting.

### 2.3 Create Flow Sequence

```
LocalReviewCreate
        │
        ▼
  list_templates() → pick template (or blank)
        │
        ▼
  pick source branch (current / new)
        │
        ▼
  pick target branch
        │
        ▼
  open scratchpad pre-filled with template body
        │  user edits title + body
        ▼
  :w → create_mr({ title, body, source_branch, target_branch, template })
        │
        ▼
  vim.notify("created MR: <url>")
```

### 2.4 Probing Platform Capabilities at Runtime

> **Cross-cutting:** this extends the declarative capability system in
> [08-capability-system.md](08-capability-system.md). Doc 08's `capabilities`
> table answers *"does this adapter implement X?"* (static, per-adapter). This
> section adds a *runtime probe* that answers *"does X actually work in this
> specific repo/org/environment?"* (dynamic, per-repo).

The MR lifecycle is where the **static table is insufficient**. Two capabilities
are genuinely environmental and can't be known from the adapter code alone:

| Capability | Static table can't know | Why it varies |
|:--|:--|:--|
| `draft_mr` | Whether the **org/repo** allows draft MRs | GitHub Enterprise / GitLab self-hosted may disable drafts; org settings vary |
| `approve_mr` | Whether the **current user** has permission to approve | Permission is per-user/per-role, not per-adapter |
| `list_templates` | Whether the repo has templates configured | Repos without a `.github/PULL_REQUEST_TEMPLATE` or GitLab template dir return none |

### 2.5 Local Database State Persistence (`pull_requests.state`)

When an MR lifecycle state transition completes successfully on the remote platform (`approve_mr`, `close_mr`, or `create_mr`), the plugin immediately persists the state change to the local SQLite database:

```lua
-- storage/pull_request.lua
function M.update_state(mo_id, new_state)
  storage.execute("UPDATE pull_requests SET state = ? WHERE mo_id = ?", new_state, mo_id)
end
```

- **On Approval (`approve_review`)**: Updates `pull_requests.state = "approved"` in SQLite.
- **On Close (`close_review`)**: Updates `pull_requests.state = "closed"` in SQLite.
- **UI Propagation**: Triggers `sync.schedule()` to flush the debounced Sync Bus and redraw all open UI panels (`summary.lua`, `decor.lua`) with the updated state.

---

A static `capabilities.draft_mr = true` on the GitHub adapter is *wrong* for a
repo that has drafts disabled. Only a probe of that specific repo can tell.

#### 2.4.1 Probe design — offline-first, cached, best-effort

To respect the offline-first principle (doc 08 rejected naive runtime probing
because it's slow and network-bound), the probe must be:

- **Cached** — probe once per repo, store the result in SQLite, reuse on
  subsequent sessions. Invalidate on a manual refresh or when the repo's remote
  changes.
- **Best-effort** — if the probe fails (offline, CLI error), **fall back to the
  static `capabilities` table**. Never block the create flow on a probe.
- **Non-blocking** — run the probe in the background (via the `uv.new_work`
  thread from [09-async-model.md](09-async-model.md)), not synchronously in the
  create flow.

```lua
-- adapter contract addition (optional, per-adapter)
M.probe_capabilities(cfg, ctx) -> { draft_mr = bool, approve_mr = bool, ... }, err
  -- returns the ENVIRONMENTAL subset; nil fields mean "unknown, use static default"
```

```lua
-- review.lua (create flow) — merge static + probed
local caps = vim.tbl_extend("force", resolved.adapter.capabilities, probed or {})
if caps.draft_mr then
  -- offer "create as draft"
end
```

#### 2.4.2 What the probe actually does

The probe is a **cheap, read-only** CLI call per capability, e.g.:

- `draft_mr`: `gh pr create --help` / `glab mr create --help` and check for a
  `--draft` flag, **or** a lightweight API call that reflects org settings.
- `approve_mr`: `gh api` / `glab api` to check the current user's role on the
  repo (or just attempt a dry-run permission check).
- `list_templates`: already known from `list_templates()` returning non-empty.

The probe should be **one batched call** where possible (a single GraphQL/REST
query returning all the environmental facts), not N separate calls.

#### 2.4.3 Cache shape

```
repo_capabilities (
  repo_key   TEXT PRIMARY KEY,   -- provider:owner/repo
  caps       TEXT,               -- JSON { draft_mr, approve_mr, ... }
  probed_at  TEXT                -- timestamp; stale after N days
)
```

#### 2.4.4 Why this is the right place for it

The MR lifecycle is the **only** flow where the user is *creating* something on
the platform, so the environmental facts (drafts allowed, permission to approve)
matter most here. The reviewing flow (doc 03) and reviewer assignment (doc 06)
are more uniformly supported, so they can rely on the static table alone — but
they can reuse the same probe mechanism if a platform needs it.

---

## 3. Before / After

### Before

```
LocalReviewCreate
  → pick template
  → pick source branch
  → pick target branch
  → vim.fn.input("Title: ")          ← single line, no body editing
  → create_mr({ title, body = template verbatim })
```

**Problems:** No way to write a description or edit the template. Single-line
title prompt is limiting.

### After

```
LocalReviewCreate
  → pick template
  → pick source branch
  → pick target branch
  → scratchpad pre-filled with template body   ← multi-line editor
  → user edits title + body
  → :w → create_mr(...)
```

**Improvements:** Proper multi-line description. Template editable before
submit. Reuses the existing scratchpad (no new UI).

---

## 4. Pros & Cons

### Pros

- **Better DX** — real editor for the description, not a single-line prompt.
- **Reuses existing UI** — the scratchpad, no new window.
- **Formalized contract** — easier to add new platforms correctly.
- **Multiplatform** — uniform contract, adapter maps to CLI.

### Cons

- **Scratchpad reuse needs a "create MR" mode** — the current scratchpad is
  comment-focused; needs a variant that calls `create_mr` on `:w`.
- **Contract documentation** — must be written and kept in sync with the code.
- **Template + body interaction** — `glab` treats `--template` and
  `--description` as mutually exclusive; the flow must handle "edited template"
  as a body, not a template reference.
- **Probing adds a cache + background job** — the runtime probe (§2.4) needs a
  `repo_capabilities` cache table and a background probe (via the `uv.new_work`
  thread). Must be best-effort so it never blocks the create flow.

---

## 5. Alternatives

### Alt A — Keep `vim.fn.input` for title, add a separate body prompt
- **Pros:** Minimal change.
- **Cons:** Still no proper multi-line editor; poor DX. **Rejected.**

### Alt B — Open a real file buffer for the description (temp file)
- **Pros:** Full editor features.
- **Cons:** Creates a temp file; more state to manage; less integrated.
  **Rejected** — the scratchpad is cleaner.

### Alt C — Recommended: scratchpad reuse + formalized contract (this doc)
- **Pros:** Reuses existing UI, proper editor, formalized contract.
- **Cons:** Needs a scratchpad mode variant. **Accepted.**

### Alt D — Static capabilities only, no runtime probe
- **Pros:** Simpler — no cache, no background job, no probe contract.
- **Cons:** Wrong for environmental facts (drafts disabled, no permission to
  approve). A static `draft_mr = true` on GitHub is *false* for a repo with
  drafts disabled. **Rejected** — the probe is cheap and cached.

### Alt E — Recommended: static table + best-effort runtime probe (this doc)
- **Pros:** Static table covers "does the adapter implement X"; the probe
  refines it to "does X work in this repo/org". Offline-first (cached,
  best-effort, non-blocking). Falls back to static on probe failure.
- **Cons:** Adds a cache table + background probe. **Accepted.**

---

## 6. Open Questions

1. Should the scratchpad support a "draft MR" flag (create as draft)?
2. Should reviewers be assignable during create (ties into Doc 06)?
3. Should the title also be editable in the scratchpad (single buffer with
   title + body), or kept as a separate prompt?
4. Should the probe be **one batched call** (single GraphQL/REST query returning
   all environmental facts) or **per-capability calls**? (Recommended: batched.)
5. How stale is too stale for the `repo_capabilities` cache — should it
   auto-refresh on a manual pull, or expire after N days?
