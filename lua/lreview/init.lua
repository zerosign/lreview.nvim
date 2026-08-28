---@meta

-- lreview.nvim: unified MR/PR review across GitHub, GitLab, Sourcehut.
--
-- Entry point loaded by lazy.nvim. Calls config.setup(opts), registers
-- commands, and exposes the public API.

local config = require("lreview.config")
local review = require("lreview.review")
local adapter = require("lreview.adapter")
local storage = require("lreview.storage")
local git = require("lreview.git")

local M = {}

--- Plugin setup. Called by lazy.nvim with `opts`.
---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  M.register_commands()
end

--- Register user commands.
function M.register_commands()
  local api = vim.api

  -- LocalReviewQuery [scope] [query]: list MRs for the current repo.
  --   scope: "mine" (default) | "all"
  api.nvim_create_user_command("LocalReviewQuery", function(args)
    local scope = args.args ~= "" and args.args or "mine"
    local resolved = adapter.resolve(vim.fn.getcwd())
    if not resolved then
      vim.notify("lreview: no forge remote detected", vim.log.levels.WARN)
      return
    end
    local ctx = adapter.ctx(resolved)
    local mrs, err = resolved.adapter.list_mrs(resolved.cfg, ctx, { scope = scope })
    if not mrs then
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    -- Cache into storage for offline use.
    local ok = storage.open()
    if ok then
      for _, mr in ipairs(mrs) do
        require("lreview.storage.pull_request").upsert(mr)
      end
    end
    -- TODO: render into a list buffer (UI layer).
    vim.notify(string.format("lreview: %d MR(s) found", #mrs), vim.log.levels.INFO)
  end, { nargs = "?", complete = function()
    return { "mine", "all" }
  end })

  -- LocalReviewDetail [ref]: show detail for an MR (default: current branch).
  api.nvim_create_user_command("LocalReviewDetail", function(args)
    local resolved = adapter.resolve(vim.fn.getcwd())
    if not resolved then
      vim.notify("lreview: no forge remote detected", vim.log.levels.WARN)
      return
    end
    local ref = args.args ~= "" and args.args or nil
    local ctx = adapter.ctx(resolved, ref)
    local detail, err = resolved.adapter.get_mr_detail(resolved.cfg, ctx)
    if not detail then
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    local ok = storage.open()
    if ok then
      require("lreview.storage.pull_request").upsert(detail)
    end
    -- TODO: render detail into a buffer (UI layer).
    vim.notify(string.format("lreview: %s #%d %s", detail.provider, detail.number, detail.title), vim.log.levels.INFO)
  end, { nargs = "?" })

  -- LocalReviewStart: begin a local review of the current branch's MR.
  api.nvim_create_user_command("LocalReviewStart", function()
    local detail, err = review.start_review(vim.fn.getcwd())
    if not detail then
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("lreview: reviewing %s #%d (%s)", detail.provider, detail.number, detail.title), vim.log.levels.INFO)
  end, {})

  -- LocalReviewCreate: create a new MR/PR from the current branch, with
  -- optional template selection and target-branch selection (for stacked
  -- branches the target may not be the repo default branch).
  api.nvim_create_user_command("LocalReviewCreate", function()
    local cwd = vim.fn.getcwd()
    local resolved = adapter.resolve(cwd)
    if not resolved then
      vim.notify("lreview: no forge remote detected", vim.log.levels.WARN)
      return
    end
    local ctx = adapter.ctx(resolved)
    local templates, terr = resolved.adapter.list_templates(resolved.cfg, ctx)
    if terr then
      vim.notify("lreview: " .. tostring(terr), vim.log.levels.ERROR)
      return
    end
    -- Determine the default branch and the candidate target branches.
    local default_branch = git.default_branch(cwd) or "main"
    local branches = git.remote_branches(cwd)
    -- Ensure the default branch is in the candidate list (first choice).
    local target_choices = {}
    local seen = {}
    local function add_target(b)
      if b and b ~= "" and not seen[b] then
        seen[b] = true
        target_choices[#target_choices + 1] = b
      end
    end
    add_target(default_branch)
    for _, b in ipairs(branches) do
      add_target(b)
    end
    -- Build the template picker choices: blank + each template.
    local choices = { { name = "(blank)", path = nil, content = "" } }
    for _, t in ipairs(templates or {}) do
      choices[#choices + 1] = t
    end
    local function do_create(choice, title, target)
      local body = choice and choice.content or ""
      local source_branch = git.current_branch(cwd)
      local url, err = review.create_review({
        title = title,
        body = body,
        source_branch = source_branch,
        target_branch = target,
        template = (choice and choice.name ~= "(blank)") and choice.name or nil,
      }, cwd)
      if not url then
        vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify(string.format("lreview: created MR: %s", url), vim.log.levels.INFO)
    end
    -- Pick a template, then a target branch, then prompt for the title.
    vim.ui.select(choices, {
      prompt = "Select MR/PR template:",
      format_item = function(c) return c.name end,
    }, function(choice)
      if not choice then
        return
      end
      vim.ui.select(target_choices, {
        prompt = "Select target branch:",
        format_item = function(b) return b end,
      }, function(target)
        if not target then
          return
        end
        local title = vim.fn.input("Title: ")
        if title == "" then
          return
        end
        do_create(choice, title, target)
      end)
    end)
  end, {})

  -- LocalReviewComment: add a draft comment on the visual selection.
  api.nvim_create_user_command("LocalReviewComment", function()
    local start_line = vim.fn.line("'<")
    local end_line = vim.fn.line("'>")
    if start_line == 0 or end_line == 0 then
      vim.notify("lreview: LocalReviewComment requires a visual selection", vim.log.levels.WARN)
      return
    end
    local abs = vim.fn.expand("%:p")
    local root = git.root(vim.fn.getcwd())
    local path = abs
    if root then
      if vim.startswith(abs, root .. "/") then
        path = abs:sub(#root + 2)
      end
    end
    require("lreview.ui.editor").open_new_comment(path, start_line, end_line)
  end, { range = true })

  -- LocalReviewSubmit: push all draft inline comments (no review-state change).
  api.nvim_create_user_command("LocalReviewSubmit", function()
    local pushed, err = review.submit_review()
    if err then
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("lreview: submitted %d inline comment(s)", pushed), vim.log.levels.INFO)
  end, {})

  -- LocalReviewPull: fetch remote MR threads/comments into local storage.
  api.nvim_create_user_command("LocalReviewPull", function()
    local synced, err = review.sync_review()
    if err then
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("lreview: pulled %d remote thread(s)", synced), vim.log.levels.INFO)
  end, {})

  -- LocalReviewClose [number]: close the MR on the platform.
  --   number: optional remote MR/PR number; defaults to the active review's MR.
  api.nvim_create_user_command("LocalReviewClose", function(args)
    local number = args.args ~= "" and tonumber(args.args) or nil
    local ok, err = review.close_review(number)
    if not ok then
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("lreview: closed MR #%d", number or (review.current and review.current.detail.number)), vim.log.levels.INFO)
  end, { nargs = "?" })

  -- LocalReviewApprove [number]: approve the MR on the platform.
  --   number: optional remote MR/PR number; defaults to the active review's MR.
  api.nvim_create_user_command("LocalReviewApprove", function(args)
    local number = args.args ~= "" and tonumber(args.args) or nil
    local ok, err = review.approve_review(number)
    if not ok then
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("lreview: approved MR #%d", number or (review.current and review.current.detail.number)), vim.log.levels.INFO)
  end, { nargs = "?" })

  -- LocalReviewToggle: toggle review highlights in the current buffer.
  api.nvim_create_user_command("LocalReviewToggle", function()
    require("lreview.ui.decor").toggle()
  end, {})

  -- LocalReviewHover: show hover/split thread window for the current line.
  api.nvim_create_user_command("LocalReviewHover", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local abs = vim.fn.expand("%:p")
    local root = git.root(vim.fn.getcwd())
    local path = abs
    if root then
      if vim.startswith(abs, root .. "/") then
        path = abs:sub(#root + 2)
      end
    end
    require("lreview.ui.thread_view").show(vim.api.nvim_get_current_buf(), path, line)
  end, {})

  -- LocalReviewList: list all MR comments in a quickfix buffer.
  api.nvim_create_user_command("LocalReviewList", function()
    require("lreview.ui.list").open_quickfix()
  end, {})
end

--- Public API surface.
M.api = {
  config = config,
  review = review,
  adapter = adapter,
  storage = storage,
  decor = require("lreview.ui.decor"),
  thread_view = require("lreview.ui.thread_view"),
  editor = require("lreview.ui.editor"),
  list = require("lreview.ui.list"),
  start_review = review.start_review,
  add_comment = review.add_comment,
  submit_review = review.submit_review,
  sync_review = review.sync_review,
  close_review = review.close_review,
  approve_review = review.approve_review,
  resolve_thread = review.resolve_thread,
  resolve = adapter.resolve,
}

return M
