# 02 — File-List Overview in the Summary Panel

**Journey:** A 2 (Browse the diff / understand changes)
**Domain:** 2 — Reviewing UX

---

## 1. Problem

A reviewer needs an **overview of the files changed in an MR** to understand
scope and navigate. Today the plugin has:

- Gutter diff highlights (changed lines) — good for *within-file* context.
- A summary panel listing **threads** — good for *discussion* overview.
- **No file-list overview** — no way to see "what files changed, how much, and
  where the comments are."

The naive fix — a separate file-explorer panel — is **invasive**: it competes
with the user's own file explorer (NvimTree/Oil/etc.) and adds screen clutter.
The user explicitly wants a **minimal, non-invasive** solution.

---

## 2. Proposed Solution — A File-List *View Mode* in the Existing Summary Panel

**Principle: one panel, two views — not two panels.**

The summary panel already exists and is opt-in. Add a **file-list view mode**
toggled with a key. The *same* panel switches between "threads" and "files"
views. No new window is created.

### 2.1 Data Sources (all already available)

| Data | Source | Cost |
|:-----|:-------|:-----|
| `path`, `+adds -dels` | `detail.files` (fetched in `get_mr_detail`) | free (already fetched) |
| thread/comment counts per file | `comments.comments_for_buffer(mo_id, path)` | SQLite read |
| changed-line count | `git.changed_lines()` (already computed for decor) | cached (see Doc 04) |

### 2.2 Layout — a Wide Table, Not a Narrow Split

The current summary panel opens as a **narrow split** (default `size = 15`),
which makes any table layout cramped and awkward. For a file overview we want a
**wide table that spans the buffer width** — much closer to a spreadsheet than
the current packed panel.

**Two changes to achieve this:**

1. **Widen the panel.** When the file view is active (or when the summary panel
   opens), use a much wider layout — ideally a **full-width split** (e.g.
   `botright vsplit` at ~50–60% width, or a full-width horizontal split), rather
   than the current narrow `size = 15` split. The exact width should be
   configurable (`ui.summary.width`), defaulting to something wide.

2. **Column-aligned table.** Use fixed-width columns so rows line up cleanly
   across the full width, with the path column taking the remaining space.

```
=== Local Review Summary [Files] ============================================
  Filter: [Active & Drafts Only]   (f: filter, g: files/threads, s: sort)
  ┌──────────┬──────────┬──────────┬──────────────────────────────────────┐
  │ Status   │  +adds   │  -dels   │  Path                                │
  ├──────────┼──────────┼──────────┼──────────────────────────────────────┤
  │ ● 💬2    │    +12   │    -3    │  src/features/checkout/controller.lua │
  │ ● 💬1    │     +4   │    -0    │  libs/shared/util.lua                 │
  │ ✔        │     +0   │    -8    │  src/legacy/deprecated/old_thing.lua  │
  │ ⚠ 💬1    │     +2   │    -1    │  src/api/routes.lua                   │
  └──────────┴──────────┴──────────┴──────────────────────────────────────┘
  [o/<CR>] Jump to File | [q] Close
```

- **Status column** reuses the same semantics as the threads view:
  `●` active, `💬` draft, `✔` resolved, `⚠` conflict — plus the comment count
  so you can see at a glance which files have the most discussion.
- **`+adds` / `-dels`** columns are right-aligned numeric columns (from
  `detail.files`), so the diff magnitude is scannable.
- **Path column** takes the remaining width and is left-aligned. Long paths
  truncate at the right edge with `…` (the full path is available on hover /
  in the statusline).
- **Sorting:** by path, by additions, by deletions, or by "most comments first"
  (toggle with `s`).
- **Jump:** selecting a file opens it and positions the cursor (reuse
  `handle_action("open")` logic).

**Why wide:** a file overview is fundamentally a *table* — it needs horizontal
room for path + stats + status. The current narrow split forces truncation and
wrapping, which is exactly the "packed and weird" feel you're describing. A
wide, column-aligned table makes the diff scope legible at a glance.

### 2.3 Keymap

- `g` (or a configurable key) toggles between **threads** and **files** views.
- `f` keeps its current meaning (toggle resolved-filter) — applies to both views.
- `s` cycles the sort order in the files view.

---

## 3. Flow / Sequence

```
LocalReviewSummary
        │
        ▼
  summary panel opens (threads view, as today)
        │  press g
        ▼
  files view: list files from detail.files + comment counts
        │  select a file / press <CR>
        ▼
  open file at cursor, show thread view for that line
```

---

## 4. Before / After

### Before

```
LocalReviewSummary → threads-only panel
  - No way to see which files changed or how much
  - No file-level navigation
```

### After

```
LocalReviewSummary → threads panel
  press g → files panel (wide table: status, +adds, -dels, path)
  select → jump to file
```

**Improvements:** File-scope overview without a new window. Reuses existing
data. Opt-in (only appears when the user opens summary). **Wide, column-aligned
table** spans the buffer width so the diff scope is legible at a glance.

---

## 5. Pros & Cons

### Pros

- **Minimal** — no new window, reuses the existing panel.
- **Non-invasive** — only appears when the user opens summary.
- **Cheap** — reads already-fetched `detail.files` + SQLite.
- **Consistent** — same status semantics as the threads view.
- **Legible** — wide, column-aligned table makes path + stats + status scannable
  without truncation/wrapping.

### Cons

- **Not a persistent file explorer** — it's a snapshot view, not a live tree.
  Users who want a real file tree should use their own explorer.
- **Requires `detail.files` to be populated** — if the adapter doesn't return
  file stats, the `+adds -dels` column is blank (fallback: show path + counts).
- **Wider panel takes more screen space** — the wide layout is intentional, but
  it does occupy more of the buffer than the current narrow split. Configurable
  width (`ui.summary.width`) lets the user tune this.

---

## 6. Alternatives

### Alt A — Separate file-explorer panel
- **Pros:** Full-featured, familiar.
- **Cons:** **Invasive** — competes with the user's own explorer, adds clutter.
  **Rejected** — violates the minimal/non-invasive requirement.

### Alt B — Statusline component only
- **Pros:** Zero invasion (lives in user's statusline).
- **Cons:** No overview; only per-file context as you navigate.
- **Verdict:** A nice *complement* (show `+12 -3 💬2` for the current file), but
  not a substitute for the overview.

### Alt C — Diff-hunk navigation in the current buffer (no file list)
- **Pros:** No new surface at all.
- **Cons:** Doesn't give the file-scope overview the user asked for.
- **Verdict:** Complementary to the file view — make `LocalReviewNext/Prev`
  smarter (thread → hunk → thread). Worth doing alongside.

### Alt D — Recommended combination
- **File view** in the summary panel (this doc) **+** statusline per-file stats
  **+** smarter Next/Prev. This gives overview + context + navigation with
  minimal new surface.

---

## 7. Open Questions

1. Should the file view be sortable (path / comments / additions)?
2. Should selecting a file with multiple threads show a sub-list first?
3. Should the statusline component be opt-in via config?
4. What should the default `ui.summary.width` be, and should the wide layout
   apply to the *threads* view too, or only the *files* view? (The threads view
   may stay narrow; the files view wants wide.)
