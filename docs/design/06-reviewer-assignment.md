# 06 — Offline-First Reviewer Assignment

**Journey:** B 3 (Request review / assign reviewers)
**Domain:** 3 — Requesting Review UX
**Status:** ⏸️ **Deprioritized — enhancement/feature, not a core fix.** Design
stays valid; implement only after the higher-priority plans (docs 01–05, 07–09).
**Constraint:** must resolve **offline-first** (local user index) and run the
network submit via **`uv.new_work`** (see [09-async-model.md](09-async-model.md)).

---

## 1. Problem

After creating an MR, there is no way to **request review / assign reviewers**.
For a plugin whose whole purpose is review, this is a notable hole.

This is harder than it looks because of **scale**:

- **Non-monorepo:** 1–20 people.
- **Big monorepo:** 100–500 people.

Calling the backend per keystroke for a 500-person org is slow and wasteful. The
right approach is **offline-first**: use the **local user index** (already built
for `@mention`) to make the picker instant and responsive, and only hit the
network once on submit.

---

## 2. Existing Infrastructure (already built)

The plugin already has everything needed for the *picker*:

| Piece | Location | Purpose |
|:------|:---------|:--------|
| User fetch (async) | `users.pull_users_async()` | `uv.new_work` thread, non-blocking |
| User cache | `storage/users.lua` → `repo_users` table | SQLite |
| FTS5 trigram search | `repo_users_fts` | fast substring search |
| Search API | `users.search_users(cwd, prefix)` | ranking: username prefix > substring > name |
| `@mention` completion | scratchpad | already uses the index |

What's **missing**:
- An adapter method to **assign reviewers** (`assign_reviewers`).
- A **multi-select reviewer picker** UI.
- (optional) **reviewer history** — who usually reviews this repo/area.

---

## 3. Proposed Solution

### 3.1 Adapter Capability + Method

> **Cross-cutting:** the capability-flag pattern is generalized in
> [08-capability-system.md](08-capability-system.md). This doc uses
> `assign_reviewers` and `offline_staging`.

```lua
M.capabilities = { assign_reviewers = true }   -- github: true, gitlab: true
M.assign_reviewers(cfg, ctx, number, reviewers) -> ok, err
```

### 3.2 The Reviewer Picker (offline, multi-select)

New command `LocalReviewRequestReview` (or a post-create step):

- Open a **multi-select picker** (`vim.ui.select` with `multiple = true`)
  populated from the **local user index** (`users.list_users` / `search_users`).
- The picker is **offline and instant** — no backend call per keystroke.
- **Search-as-you-type** via `search_users` (FTS5 trigram handles thousands of
  rows).
- On selection, call `adapter.assign_reviewers` **once** (single API call, not
  per-user).

### 3.3 Scale Handling (the 100–500 person case)

- The local index makes the *picker* fast regardless of size.
- **Reviewer history:** track who has reviewed this repo's MRs before (from
  `repo_users.fetched_at` or a new `reviewer_history` table) and surface them
  first. This is the real UX win for big orgs — you want "the 5 people who
  usually review this area," not a scroll through 500 names.

### 3.4 Offline-First Principle

- The picker reads from SQLite (instant).
- Only the final `assign_reviewers` call hits the network (one call).
- If offline, you can still **stage** the reviewer selection locally and push
  later — consistent with the plugin's whole offline-first philosophy.

---

## 4. Flow / Sequence

```
LocalReviewRequestReview
        │
        ▼
  ensure users cached (pull_users_async if empty)
        │
        ▼
  multi-select picker from local index (offline, instant)
        │  search-as-you-type (FTS5)
        │  recent reviewers surfaced first
        ▼
  confirm selection
        │
        ▼
  adapter.assign_reviewers(number, reviewers)   ← single API call
        │
        ▼
  vim.notify("review requested from N people")
```

---

## 5. Before / After

### Before

```
(no reviewer assignment exists)
```

### After

```
LocalReviewRequestReview
  → offline multi-select picker from local user index
  → single API call to assign reviewers
```

**Improvements:** Reviewer assignment exists. Offline-first (responsive even for
500-person orgs). Reuses the existing user index.

---

## 6. Pros & Cons

### Pros

- **Offline-first** — picker is instant, no per-keystroke network calls.
- **Scales** — works identically for 20 or 500 users (FTS5).
- **Consistent** — reuses the same index as `@mention`.
- **Single API call** on submit, not per-user.

### Cons

- **User index must be populated** — requires `pull_users_async` to have run;
  if empty, the picker is empty (mitigated by auto-fetch on first use).
- **Reviewer history** is a new table + tracking logic.
- **Adapter contract change** — new `assign_reviewers` method + capability flag.

---

## 7. Alternatives

### Alt A — Call the backend directly for the picker
- **Pros:** Always fresh user list.
- **Cons:** Slow for large orgs; per-keystroke network calls; not offline.
  **Rejected** — violates the offline-first principle.

### Alt B — Free-text reviewer input (comma-separated usernames)
- **Pros:** Simplest.
- **Cons:** No discovery; error-prone for large orgs. **Rejected.**

### Alt C — Recommended: offline picker from local index (this doc)
- **Pros:** Fast, scalable, offline, consistent with `@mention`.
- **Cons:** Needs user index populated + reviewer history. **Accepted.**

---

## 8. Open Questions

1. Should reviewer assignment be part of the create flow (Doc 05) or a separate
   command?
2. How to define "recent reviewers" — by count, by recency, or by code-area
   (path prefix)?
3. Should the picker support grouping by team/area for large orgs?
4. Should staged reviewer selections be persisted for offline push (like draft
   comments)?
