---@meta

-- Neovim plugin entry point and user command registration.

local config = require("lreview.config")
local review = require("lreview.review")
local adapter = require("lreview.adapter")
local storage = require("lreview.storage")
local git = require("lreview.git")

local M = {}

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  M.register_commands()

  -- Automatically start review and enable highlights on buffer open
  local grp = vim.api.nvim_create_augroup("lreview_auto", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWritePost" }, {
    group = grp,
    callback = function(ev)
      local bufnr = ev.buf
      if vim.bo[bufnr].buftype ~= "" then return end
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if bufname == "" then return end
      local root = git.root(vim.fn.fnamemodify(bufname, ":h"))
      if not root then return end

      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        local detail = review.init_session(root)
        if detail then
          require("lreview.ui.decor").enable(bufnr)
        end
      end)
    end
  })
end

-- ---------------------------------------------------------------------------
-- Private Command Callbacks (Extracted to reduce cyclomatic complexity)
-- ---------------------------------------------------------------------------

local function cmd_query(args)
  local scope = args.args ~= "" and args.args or "mine"
  local resolved = adapter.resolve(vim.fn.getcwd())
  if not resolved then
    vim.notify("lreview: no git remote detected", vim.log.levels.WARN)
    return
  end
  local ctx = adapter.ctx(resolved)
  local prs, err = resolved.adapter.list_pull_requests(resolved.cfg, ctx, { scope = scope })
  if not prs then
    vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  -- Cache into storage for offline use.
  local ok = storage.open()
  if ok then
    for _, mr in ipairs(prs) do
      require("lreview.storage.pull_request").upsert(mr)
    end
  end
  vim.notify("lreview: " .. #prs .. " pull request(s) found", vim.log.levels.INFO)
end

local function resolve_detail_ref(cwd)
  if review.current then
    return tostring(review.current.detail.number)
  end
  local branch = git.current_branch(cwd)
  if branch == "master" or branch == "main" or branch == "develop" then
    return nil, "on default branch '" .. branch .. "'; please specify a PR/MR number or branch name"
  end
  return branch, nil
end

local function cmd_detail(args)
  local resolved = adapter.resolve(vim.fn.getcwd())
  if not resolved then
    vim.notify("lreview: no git remote detected", vim.log.levels.WARN)
    return
  end
  local ref = args.args ~= "" and args.args or nil
  local err
  if not ref then
    ref, err = resolve_detail_ref(resolved.cwd)
    if err then
      vim.notify("lreview: " .. err, vim.log.levels.WARN)
      return
    end
  end
  local ctx = adapter.ctx(resolved, ref)
  local detail, err_detail = resolved.adapter.get_mr_detail(resolved.cfg, ctx)
  if not detail then
    vim.notify("lreview: " .. tostring(err_detail), vim.log.levels.ERROR)
    return
  end
  local ok = storage.open()
  if ok then
    require("lreview.storage.pull_request").upsert(detail)
  end
  require("lreview.ui.detail_editor").open(detail)
end


local function resolve_target_branches(cwd)
  local default_branch = git.default_branch(cwd) or "main"
  local branches = git.remote_branches(cwd)
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
  return target_choices
end

local function execute_create_mr(cwd, choice, title, target)
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
  vim.notify("lreview: created MR: " .. url, vim.log.levels.INFO)
end

-- Template -> target branch -> title -> create. Shared by both the
-- current-branch and new-branch create flows.
local function pick_template_and_create(cwd, choices, target_choices)
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
      execute_create_mr(cwd, choice, title, target)
    end)
  end)
end

-- Source branch picker: use the current branch, or create a brand-new branch
-- (checked out and pushed) and open the MR/PR from it.
local function pick_source_branch(cwd, choices, target_choices)
  local current = git.current_branch(cwd)
  local source_choices = {}
  if current then
    source_choices[#source_choices + 1] = { name = "(current) " .. current, kind = "current" }
  end
  source_choices[#source_choices + 1] = { name = "(new) Create new branch...", kind = "new" }

  vim.ui.select(source_choices, {
    prompt = "Select source branch:",
    format_item = function(c) return c.name end,
  }, function(src)
    if not src then
      return
    end
    if src.kind == "new" then
      local name = vim.fn.input("New branch name: ")
      if name == "" then
        return
      end
      local ok, err = git.create_branch(cwd, name)
      if not ok then
        vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify("lreview: created branch '" .. name .. "'", vim.log.levels.INFO)
    end
    pick_template_and_create(cwd, choices, target_choices)
  end)
end

local function cmd_create()
  local cwd = vim.fn.getcwd()
  local resolved = adapter.resolve(cwd)
  if not resolved then
    vim.notify("lreview: no git remote detected", vim.log.levels.WARN)
    return
  end
  local ctx = adapter.ctx(resolved)
  local templates, terr = resolved.adapter.list_templates(resolved.cfg, ctx)
  if terr then
    vim.notify("lreview: " .. tostring(terr), vim.log.levels.ERROR)
    return
  end

  local target_choices = resolve_target_branches(cwd)
  local choices = { { name = "(blank)", path = nil, content = "" } }
  for _, t in ipairs(templates or {}) do
    choices[#choices + 1] = t
  end

  pick_source_branch(cwd, choices, target_choices)
end

local function ensure_review_started()
  if not review.current then
    local detail, err = review.init_session()
    if not detail then
      vim.notify("lreview: failed to start review session: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
  end
  return true
end

local function cmd_comment()
  if not ensure_review_started() then return end
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
end

local function cmd_submit()
  if not ensure_review_started() then return end
  local pushed, err = review.submit_review()
  if err then
    vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify("lreview: submitted " .. pushed .. " inline comment(s)", vim.log.levels.INFO)
end

local function cmd_pull()
  if not ensure_review_started() then return end
  vim.notify("lreview: pulling remote updates...", vim.log.levels.INFO)
  review.pull_review_async(function(success)
    if success then
      vim.notify("lreview: remote updates pulled successfully", vim.log.levels.INFO)
    else
      vim.notify("lreview: failed to pull remote updates", vim.log.levels.ERROR)
    end
  end)
end

local function cmd_pull_users()
  vim.notify("lreview: fetching repo users...", vim.log.levels.INFO)
  require("lreview.users").pull_users_async(function(success, count, err)
    if success then
      vim.notify("lreview: cached " .. count .. " repo user(s)", vim.log.levels.INFO)
    else
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

local function cmd_pull_requests()
  vim.notify("lreview: fetching pull request list...", vim.log.levels.INFO)
  require("lreview.pull_request").pull_async(function(success, count, err)
    if success then
      vim.notify("lreview: cached " .. count .. " pull request(s)", vim.log.INFO)
    else
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

local function cmd_close(args)
  if not ensure_review_started() then return end
  local number = args.args ~= "" and tonumber(args.args) or nil
  local ok, err = review.close_review(number)
  if not ok then
    vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify("lreview: closed MR #" .. (number or (review.current and review.current.detail.number)), vim.log.levels.INFO)
end

local function cmd_approve(args)
  if not ensure_review_started() then return end
  local number = args.args ~= "" and tonumber(args.args) or nil
  local ok, err = review.approve_review(number)
  if not ok then
    vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify("lreview: approved MR #" .. (number or (review.current and review.current.detail.number)), vim.log.levels.INFO)
end

local function cmd_toggle()
  if not ensure_review_started() then return end
  require("lreview.ui.decor").toggle()
end

local function cmd_open()
  if not ensure_review_started() then return end
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
end

local function cmd_summary()
  if not ensure_review_started() then return end
  require("lreview.ui.summary").open()
end

local function cmd_next()
  if not ensure_review_started() then return end
  require("lreview.ui.decor").next_thread()
end

local function cmd_prev()
  if not ensure_review_started() then return end
  require("lreview.ui.decor").prev_thread()
end

-- ---------------------------------------------------------------------------
-- Public Commands Registration (Complexity = 1)
-- ---------------------------------------------------------------------------

function M.register_commands()
  local api = vim.api

  api.nvim_create_user_command("LocalReviewQuery", cmd_query, {
    nargs = "?",
    complete = function() return { "mine", "all" } end
  })

  api.nvim_create_user_command("LocalReviewDetail", cmd_detail, { nargs = "?" })
  api.nvim_create_user_command("LocalReviewCreate", cmd_create, {})
  api.nvim_create_user_command("LocalReviewComment", cmd_comment, { range = true })
  api.nvim_create_user_command("LocalReviewSubmit", cmd_submit, {})
  api.nvim_create_user_command("LocalReviewPull", cmd_pull, {})
  api.nvim_create_user_command("LocalReviewPullUser", cmd_pull_users, {})
  api.nvim_create_user_command("LocalReviewPullRequest", cmd_pull_requests, {})
  api.nvim_create_user_command("LocalReviewClose", cmd_close, { nargs = "?" })
  api.nvim_create_user_command("LocalReviewApprove", cmd_approve, { nargs = "?" })
  api.nvim_create_user_command("LocalReviewToggle", cmd_toggle, {})
  api.nvim_create_user_command("LocalReviewHover", cmd_open, {})
  api.nvim_create_user_command("LocalReviewOpen", cmd_open, {})
  api.nvim_create_user_command("LocalReviewSummary", cmd_summary, {})
  api.nvim_create_user_command("LocalReviewNext", cmd_next, {})
  api.nvim_create_user_command("LocalReviewPrev", cmd_prev, {})
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
  detail_editor = require("lreview.ui.detail_editor"),
  summary = require("lreview.ui.summary"),
  init_session = review.init_session,
  add_comment = review.add_comment,
  submit_review = review.submit_review,
  sync_review = review.sync_review,
  pull_review_async = review.pull_review_async,
  close_review = review.close_review,
  approve_review = review.approve_review,
  resolve_thread = review.resolve_thread,
  resolve = adapter.resolve,
  users = require("lreview.users"),
  fetch_users = require("lreview.users").fetch_users,
  pull_request = require("lreview.pull_request"),
  fetch_pull_requests = require("lreview.pull_request").fetch,
  next_thread = require("lreview.ui.decor").next_thread,
  prev_thread = require("lreview.ui.decor").prev_thread,
}

return M
