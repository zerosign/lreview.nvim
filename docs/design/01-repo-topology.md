# 01 — Repo Topology & Branch Materialization

**Journey:** A 0→1 (Query → Open an MR) and B 0 (create a branch for new work)
**Domain:** 1 — Repo Topology & Branch Materialization

---

## 1. Problem

"Open an MR and start reviewing" (A 0→1) and "start new work on a branch" (B 0)
are **not single actions**. They are decisions about *how to materialize a branch
locally*, and the right answer depends on:

1. **Repo topology** — is this a large monorepo, a single-project monorepo, or a
   small non-monorepo?
2. **User working style** — do they use worktrees for parallel context switching?
   Do they maintain a manual sparse-checkout?
3. **Company tooling** — branch naming conventions, ticket-based branches,
   mandated worktree layouts, CI expectations.

The plugin currently **cannot guess** this correctly, and guessing wrong is worse
than asking. Today the flow is broken: `LocalReviewQuery` only prints a count via
`vim.notify`, and there is no way to select an MR and materialize it.

---

## 2. The Three Repo Topologies

### Type 1 — Large Monorepo (many projects, sparse-checkout)

- **Reality:** User maintains a manual sparse-checkout (cone) with only relevant
  subfolders. An MR's changes may span multiple projects (e.g. one project + a
  shared library).
- **Challenge:** Auto-resolving "which subfolders does this MR touch, and how do
  they map to my sparse-checkout cone?" is genuinely hard. Project depth varies
  (2nd vs 3rd level), and changes can span multiple projects.
- **Strategy:** **worktree + sparse-checkout**, driven by **user-maintained
  heuristics** (path-prefix → cone patterns). The plugin should offer a *guided
  setup*, not auto-guess.

### Type 2 — Monorepo, Single Project (UI + client + service + libs, all related)

- **Reality:** Everything is related; you *can* explore the whole thing. But for
  a small change (backend-only or UI-only), a full checkout is wasteful.
- **Challenge:** The "right" choice depends on change size and user mood.
- **Strategy:** **Configurable, resolvable via config.** Default + an override
  prompt. The plugin can *suggest* based on the MR's changed-file scope.

### Type 3 — Non-Monorepo (single small project)

- **Reality:** Smallest unit. Cost of checkout/worktree is trivial.
- **Strategy:** **Plain checkout.** Zero-friction default, no prompt.

---

## 3. Proposed Solution — A Shared `materialize` Strategy Resolver

Both A 0→1 and B 0 are the same operation in opposite directions:

- **A 0→1:** materialize an *existing remote* branch (the MR's source branch).
- **B 0:** materialize a *new local* branch.

So they share **one strategy resolver** (`materialize`), not two.

### 3.1 Config Shape (per-repo, persisted)

```lua
-- in opts, keyed by repo/domain
["github\\.com/org/big-monorepo"] = {
  topology = "monorepo-multi",          -- Type 1
  worktree = {
    base_dir = "~/worktrees",           -- where worktrees live
    sparse = {
      cone = { "services/", "libs/shared/" },  -- user-maintained heuristics
      auto_map = false,                 -- don't auto-resolve project depth
    },
  },
  branch = {
    create = "worktree",                -- B 0: new work → new worktree
    naming = "feature/{ticket}-{name}", -- company convention
  },
},
["github\\.com/org/single-app"] = {
  topology = "monorepo-single",         -- Type 2
  open = {
    method = "auto",                    -- suggest based on change scope
    prefer = "worktree",
  },
},
["github\\.com/org/small-tool"] = {
  topology = "simple",                  -- Type 3
  open = { method = "checkout" },       -- default, no prompt
},
```

### 3.2 The `materialize` Module

```lua
-- lua/lreview/materialize.lua (new)
local M = {}

--- Materialize a branch locally.
---@param repo_cfg table   -- resolved per-repo config
---@param spec table       -- { ref = "feature/x", create = false, ticket = "JIRA-123" }
---@return string|nil worktree_dir, string|nil err
function M.open_branch(repo_cfg, spec)
  local topology = repo_cfg.topology or "simple"

  if topology == "simple" then
    return M._checkout(repo_cfg, spec)          -- plain checkout
  elseif topology == "monorepo-single" then
    return M._auto(repo_cfg, spec)              -- suggest worktree vs checkout
  elseif topology == "monorepo-multi" then
    return M._worktree_sparse(repo_cfg, spec)   -- worktree + sparse cone
  end
end
```

### 3.3 The Change-Scope Suggestion (Type 2)

The plugin already has `detail.files` from `get_mr_detail`. Compute:

- Which top-level dirs are touched.
- Whether the change is "narrow" (one dir) or "broad" (many dirs).

Then suggest: *"This MR only touches `backend/` — use a sparse worktree? [y/N]"*
— but only when `topology = "monorepo-single"` and `open.method = "auto"`.

### 3.4 Dirty Working-Tree Guardrail (all topologies)

**Critical safety check.** Before any materialization that would change the
current checkout (plain `git checkout`, or switching to a worktree that shares
the repo), the plugin **must** check whether the current working tree is dirty:

- **Unstaged changes** (modified/untracked files), or
- **Staged but uncommitted changes** (in the index).

**Policy: stop and inform, never auto-resolve.** The plugin should **not**
attempt to stash, commit, or discard the user's changes automatically. Instead
it should:

1. Detect the dirty state (`git status --porcelain`).
2. **Stop** the materialization flow.
3. **Inform the user** clearly what is blocking the review (list the dirty
   files / staged changes).
4. Let the user resolve it **manually, outside the flow** (commit, stash, or
   clean), then retry.

This applies to **all three topologies**, but is most critical for Type 3
(plain checkout) where a checkout would directly overwrite the working tree.

```lua
-- materialize.lua — dirty check before any checkout
local function check_clean(cwd)
  local res = git.status_porcelain(cwd)   -- new helper: git status --porcelain
  if res and #res > 0 then
    return false, {
      unstaged = res.unstaged,   -- modified / untracked
      staged   = res.staged,     -- staged but uncommitted
    }
  end
  return true, nil
end
```

**Why not auto-resolve?**
- **Stashing** is surprising and can be lost/confusing; the user may not expect
  their work to be moved.
- **Committing** on the user's behalf is dangerous (wrong message, wrong branch,
  partial work).
- **Discarding** is destructive and irreversible.

The plugin's job is to be a *safe reviewer*, not to manage the user's WIP. The
user knows their working state best; the plugin should surface the blocker and
step aside.

**Worktree exception:** For Type 1/2 worktree-based materialization, a dirty
*main* checkout does **not** block creating a *new* worktree (the worktree is a
separate directory). The dirty check only applies when the materialization
would touch the current checkout (e.g. plain checkout, or switching the current
worktree's branch). This is a key advantage of worktrees — they sidestep the
dirty-tree problem entirely.

---

## 4. Flow / Sequence

### A 0→1 — Query → Open an MR

```
LocalReviewQuery (list MRs)
        │
        ▼
  [interactive picker: title, author, state]
        │  select MR
        ▼
  materialize.open_branch(repo_cfg, { ref = mr.source_branch })
        │
        ├── [dirty check: git status --porcelain]
        │     ├── CLEAN → continue
        │     └── DIRTY → STOP, inform user (list files), let them resolve
        │                manually, then retry
        │
        ├── Type 3: git checkout <branch>          (no prompt)
        ├── Type 2: suggest sparse vs full          (confirm/override)
        └── Type 1: worktree + sparse cone          (guided setup)
        │
        ▼
  review.init_session(cwd)   → start review session
```

### B 0 — Create a branch for new work

```
LocalReviewBranch (new command)
        │
        ▼
  [prompt: branch name / ticket]
        │
        ▼
  materialize.open_branch(repo_cfg, { ref = name, create = true })
        │
        ├── [dirty check: git status --porcelain]
        │     ├── CLEAN → continue
        │     └── DIRTY → STOP, inform user, let them resolve manually
        │                (worktree path may proceed if it doesn't touch
        │                 the current checkout)
        │
        ├── Type 3: git checkout -b <name>
        ├── Type 2: worktree or checkout (per config)
        └── Type 1: new worktree + sparse cone
```

---

## 5. Before / After

### Before (A 0→1)

```
LocalReviewQuery  → vim.notify("N pull request(s) found")   ← just a count
git checkout <branch> (manual, user must know the branch)
LocalReviewToggle → resolves current branch's MR, starts session
```

**Problems:** No picker. No way to select an MR and materialize it. User must
manually checkout, and the plugin can't help with monorepo sparse-checkout.

### After (A 0→1)

```
LocalReviewQuery → interactive picker of MRs
  → select MR → dirty check → materialize.open_branch() → session starts
```

**Improvements:** One command to go from "what needs review" to "reviewing".
Topology-aware materialization. Configurable for company tooling. **Dirty-tree
guardrail** — never auto-checkout over uncommitted work; stop and inform instead.

### Before (B 0)

```
git checkout -b <name> (manual, no topology awareness)
```

### After (B 0)

```
LocalReviewBranch → dirty check → creates branch via the same materialize strategy
```

**Improvements:** Same topology-aware materialization + dirty-tree guardrail as
A 0→1.

---

## 6. Pros & Cons

### Pros

- **Unifies two journeys** (A 0→1 and B 0) behind one strategy resolver.
- **Configurable for company tooling** — branch naming, worktree layout, sparse
  cones are all per-repo overrides.
- **Zero-friction default** for the common case (Type 3, no prompt).
- **Reuses existing data** (`detail.files`) for the Type 2 suggestion.
- **Offline-friendly** — materialization is pure git, no network.
- **Safe** — dirty-tree guardrail prevents silently overwriting uncommitted work.

### Cons

- **Type 1 (monorepo-multi) is genuinely hard** — auto-resolving project
  boundaries is a rabbit hole. We deliberately punt to user-maintained heuristics.
- **Config surface grows** — per-repo topology config adds complexity for users
  who don't need it (mitigated by sensible defaults).
- **Worktree management** — creating/cleaning worktrees adds state the plugin
  must track (base_dir, cleanup, naming collisions).
- **Guardrail friction** — a dirty tree blocks the flow and requires manual
  resolution. This is intentional (safety over convenience), but it does
  interrupt the user. Mitigated by the worktree path, which sidesteps the dirty
  check entirely.

---

## 7. Alternatives

### Alt A — Always plain checkout (no topology awareness)
- **Pros:** Simplest. Zero new config.
- **Cons:** Breaks for monorepos with sparse-checkout; no parallel context
  switching; no company-tooling support. **Rejected** — doesn't solve the problem.

### Alt B — Always ask the user (prompt every time)
- **Pros:** Never guesses wrong.
- **Cons:** Friction on every open; annoying for the common Type 3 case.
  **Rejected** — violates the "zero-friction default" principle.

### Alt C — Auto-detect topology from repo structure
- **Pros:** No config needed for Type 1/2.
- **Cons:** Heuristics for "is this a monorepo" are unreliable; can't know the
  user's sparse-checkout intent or company conventions. **Rejected** — guessing
  wrong is worse than asking.

### Alt D — Hybrid: auto-detect + config override (recommended refinement)
- **Pros:** Best of both — detect obvious cases, let user override.
- **Cons:** More code paths to test.
- **Verdict:** Worth doing *after* the config-driven baseline works. The
  config-driven approach is the foundation; auto-detect is a later enhancement.

### Alt E — Auto-resolve the dirty tree (stash / commit / discard)
- **Pros:** No interruption; the flow just works.
- **Cons:** **Dangerous.** Stashing is surprising and can be lost; committing on
  the user's behalf is risky (wrong message/branch); discarding is destructive
  and irreversible. **Rejected** — the plugin must never touch the user's WIP
  without explicit consent.

### Alt F — Stop-and-inform, offer optional stash (recommended refinement)
- **Pros:** Safe by default; still offers a convenience path.
- **Cons:** The stash option adds a code path and a "restore" responsibility.
- **Verdict:** The **stop-and-inform** baseline (this doc) is the safe default.
  An *optional, explicit* "stash and restore on close" could be added later as a
  config-gated convenience, but only with a clear restore mechanism.

---

## 8. Open Questions

1. Should worktree cleanup be automatic (delete on MR close) or manual?
2. ~~How to handle the "dirty working tree" case — always prefer worktree, or
   ask?~~ **Resolved:** stop-and-inform (never auto-resolve). Remaining
   sub-question: should an *optional* "stash and restore on close" convenience
   be offered behind a config flag (Alt F)?
3. Should the Type 2 suggestion be a one-time prompt or persist the choice?
4. How does `materialize` interact with the existing `open.method = "checkout"`
   config option (currently in README but unused)?
5. Should the dirty check distinguish *untracked* files from *modified* files?
   (Untracked files don't block a checkout the same way modified files do —
   git allows checkout with untracked files present, but refuses with modified
   tracked files. The guardrail should reflect this nuance.)
