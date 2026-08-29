# lreview.nvim 💬

A unified, offline-first, non-invasive Merge/Pull Request code review plugin for Neovim. Review changes locally across GitHub and GitLab using a local SQLite cache.

```mermaid
graph TD
    User([User]) -->|LocalReviewComment| UI[Local Review Buffer]
    UI -->|Saves instantly| LocalDB[(SQLite Local Cache)]
    LocalDB -->|LocalReviewSubmit| Sync[Sync Engine]
    Sync -->|Adapters| CLI[gh / glab CLI]
    CLI -->|Push API| Remotes[GitHub / GitLab]
```

## Features

- **Offline-First Workflow:** Save draft comments locally instantly; publish them all in a single batch once you finish the review.
- **Asynchronous Engine:** Background pulling and pushing prevent Neovim from freezing during network requests.
- **Unified Adapter Structure:** Handles both GitLab Merge Requests and GitHub Pull Requests with a single unified set of commands and UI.
- **Auto-Garbage Collection:** Keeps the SQLite cache clean by purging old closed/merged reviews after 30 days while safeguarding your local drafts.
- **Dynamic Context Resolution:** Handles forks, nested subgroups (GitLab), and multiple concurrent repositories seamlessly in a single database.

---

## Requirements

- Neovim `0.10+`
- `sqlite3` installed on your system
- [sqlite.lua](https://github.com/kkharji/sqlite.lua) dependency
- Platform CLIs configured and authenticated:
  - `gh` CLI (for GitHub)
  - `glab` CLI (for GitLab)

---

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "zerosign/lreview.nvim",
  dependencies = {
    "kkharji/sqlite.lua",
  },
  rocks = { "lsqlite3" },
  opts = {
    defaults = {
      db_path = vim.fn.stdpath("data") .. "/lreview/lreview.db",
      ui = {
        decor = "both", -- "both" | "sign" | "virtual_text" | "none"
        layout = "float", -- "float" | "split" | "vsplit" | "buffer"
      },
    },
    ["github\\.com"] = {
      adapter = "github",
      provider = "gh",
      host = "github.com",
    },
    ["gitlab\\.com|gitlab\\..*"] = {
      adapter = "gitlab",
      provider = "glab",
      host = "gitlab.com",
    },
  },
  config = function(_, opts)
    require("lreview").setup(opts)
  end,
  keys = {
    { "<leader>oq",  "<cmd>LocalReviewQuery<cr>",   desc = "List PRs/MRs" },
    { "<leader>ot", "<cmd>LocalReviewToggle<cr>",   desc = "Toggle Review" },
    { "<leader>op", "<cmd>LocalReviewPull<cr>",    desc = "Pull/Sync Review Comments" },
    { "<leader>os", "<cmd>LocalReviewSubmit<cr>",  desc = "Submit PR Review" },
    { "<leader>od", "<cmd>LocalReviewSummary<cr>", desc = "View Review Summary Panel" },
    { "<leader>oA", "<cmd>LocalReviewApprove<cr>", desc = "Approve MR/PR" },
    { "<leader>oC", "<cmd>LocalReviewClose<cr>",   desc = "Close MR/PR" },
    { "<leader>on", "<cmd>LocalReviewCreate<cr>",  desc = "Create MR/PR" },
    { "<leader>oc",  ":LocalReviewComment<cr>",     mode = "x", desc = "Add inline review comment" },
  },
}
```

---

## Usage Workflow

### 1. Enable Review Highlights
Run `:LocalReviewToggle` (or press `<leader>ot`) in a repository. The plugin automatically and lazily resolves the git branch target MR/PR, queries the API, opens the SQLite database, and syncs all remote discussions to SQLite under the hood.

### 2. Browse & Annotate code
* **View Comments:** Hover your cursor over a line marked with comments. The comments panel will open automatically showing the discussion thread.
* **Add a Comment:** Make a visual selection of code lines and run `:LocalReviewComment` (or press `<leader>oc`). Write your comment and save with `:w` or `<leader>s` (automatically closes and caches it as a draft).

### 3. Manage Conversations (Floating Panel)
Press `K` or hover to focus the thread panel. Use these buffer-local keys:
* `r`: Reply to the thread (opens a scratchpad).
* `e`: Edit your local draft comment.
* `d`: Delete your local draft comment.
* `s`: Toggle Resolved/Reopened thread state.
* `q` / `<esc>`: Close the thread view.

### 4. Submit Staged Drafts
Once you finish your review, run `:LocalReviewSubmit` (or `<leader>os`) to batch push all local drafts to the remote platform.

---

## User Commands

| Command | Description |
| :--- | :--- |
| `:LocalReviewQuery [scope]` | Query and list active MRs for this repository (`mine` or `all`). |
| `:LocalReviewDetail [number]` | Print metadata details for a specific MR/PR. |
| `:LocalReviewPull` | Query and sync the latest updates from the remote host. |
| `:LocalReviewSubmit` | Batch submit all local review comments. |
| `:LocalReviewApprove` | Approve the active MR/PR. |
| `:LocalReviewClose` | Close the active MR/PR. |
| `:LocalReviewCreate` | Create a new MR/PR using template and branch pickers. |
| `:LocalReviewToggle` | Toggle buffer review signs and virtual text annotations. |
| `:LocalReviewSummary` | Open the interactive review summary panel. |
| `:LocalReviewNext` | Jump to the next comment thread in the current buffer. |
| `:LocalReviewPrev` | Jump to the previous comment thread in the current buffer. |

---

## Configuration Options

Pass these options inside the `setup()` block to customize behaviors:

```lua
require("lreview").setup({
  defaults = {
    db_path = vim.fn.stdpath("data") .. "/lreview/lreview.db",
    db = {
      busy_timeout_ms = 5000,
      keep_days = 30, -- Garbage collect reviews older than 30 days
    },
    ui = {
      decor = "both", -- Annotation style: "sign" | "virtual_text" | "both" | "none"
      layout = "float", -- Float style: "float" | "split" | "vsplit" | "buffer"
      float = {
        border = "rounded",
        width = 0.5, -- Floating window width (percentage of editor)
        height = 0.6, -- Floating window height (percentage of editor)
      },
      split = {
        position = "botright",
        size = 15,
      }
    },
    open = { method = "checkout" },
  }
})
```

---

## Gutter Line Highlights & Customization

The plugin highlights gutter line numbers and signs to represent review statuses and code changes. These are linked to standard Vim groups by default so they match your theme automatically, but you can override them in your configuration:

* `LReviewSignDraft` (Default: `WarningMsg` link) - Sign column indicator for draft comment threads.
* `LReviewSignSynced` (Default: `Comment` link) - Sign column indicator for active remote threads.
* `LReviewNumDraft` (Default: `DiffChange` link) - Gutter line number background highlight for drafts.
* `LReviewNumSynced` (Default: `DiffAdd` link) - Gutter line number background highlight for active threads.
* `LReviewNumResolved` (Default: `Comment` link) - Gutter line number background highlight for resolved threads.
* `LReviewDiffAdd` (Default: `DiffAdd` link) - Gutter line number background highlight for git diff changes.

---

## Performance & Caching Details

- **WAL Mode:** SQLite is initialized with Write-Ahead Logging (`journal_mode=WAL`) and `synchronous=NORMAL` to handle parallel disk commits instantly without freezing Neovim's main render loop.
- **Safety Gate Keepers:** Automatic garbage collection runs on startup. Old closed reviews are deleted to keep the database size minimal. **Local drafts and threads with draft comments are strictly preserved and skipped by the garbage collector.**

---

## Development

Tests, coverage, and benchmarks run through the sandbox Neovim (`scripts/sandbox-nvim.fish`) so they never touch your real `~/.config/nvim`. All recipes are defined in the `justfile`:

```sh
just test              # unit tests (offline, mock-based)
just test-one test_git # run a single test by name
just test-integration  # integration tests (hit live GitHub/GitLab APIs)
just test-all          # unit + integration
just coverage          # unit tests under luacov -> luacov.report.out
just coverage-summary  # compact coverage summary
just bench             # SQL query latency benchmark (1000 iterations)
```

Coverage is scoped to `lua/lreview/` via `.luacov`. The integration tests require authenticated `gh`/`glab` CLIs and the seeded sample repos in `tmp/`.

---

License: MIT
