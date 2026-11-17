---@meta

-- User commands and Neovim command dispatch.

local adapter = require("lreview.adapter")
local storage = require("lreview.storage")
local git = require("lreview.git")
local review = require("lreview.review")
local config = require("lreview.config")
local materialize = require("lreview.materialize")

local M = {}

--- Ensure that an active review session exists, initializing asynchronously if needed.
---@param callback fun(ok: boolean)
function M.ensure_review_started(callback)
  if review.current then
    callback(true)
    return
  end
  review.init_session_async(vim.fn.getcwd(), function(detail, err)
    if not detail and not review.current then
      vim.notify("lreview: failed to start review session: " .. tostring(err), vim.log.levels.ERROR)
      callback(false)
      return
    end
    callback(true)
  end)
end

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

local function cmd_create()
  require("lreview.ui.wizard").start()
end

local function cmd_comment()
  M.ensure_review_started(function(ok)
    if not ok then return end
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
  end)
end

local function cmd_submit()
  M.ensure_review_started(function(ok)
    if not ok then return end
    review.submit_review(nil, function(success, count, err, remaining)
      if err then
        vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      end
      if count and count > 0 then
        vim.notify("lreview: submitted " .. count .. " inline comment(s)", vim.log.levels.INFO)
      elseif not err then
        vim.notify("lreview: nothing to submit", vim.log.levels.INFO)
      end
      if remaining and remaining > 0 then
        vim.notify("lreview: " .. remaining .. " change(s) still queued (:LocalReviewSubmit retries them)",
          vim.log.levels.WARN)
      end
    end)
  end)
end

local function cmd_pull()
  M.ensure_review_started(function(ok)
    if not ok then return end
    vim.notify("lreview: pulling remote updates...", vim.log.levels.INFO)
    review.pull_review_async(function(success)
      if success then
        vim.notify("lreview: remote updates pulled successfully", vim.log.levels.INFO)
      else
        vim.notify("lreview: failed to pull remote updates", vim.log.levels.ERROR)
      end
    end)
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
      vim.notify("lreview: cached " .. count .. " pull request(s)", vim.log.levels.INFO)
    else
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

local function cmd_close(args)
  M.ensure_review_started(function(ok)
    if not ok then return end
    local number = args.args ~= "" and tonumber(args.args) or nil
    vim.notify("lreview: closing MR...", vim.log.levels.INFO)
    review.close_review_async(number, function(close_ok, err)
      if not close_ok then
        vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify("lreview: closed MR #" .. (number or (review.current and review.current.detail.number)), vim.log.levels.INFO)
    end)
  end)
end

local function cmd_approve(args)
  M.ensure_review_started(function(ok)
    if not ok then return end
    local number = args.args ~= "" and tonumber(args.args) or nil
    vim.notify("lreview: approving MR...", vim.log.levels.INFO)
    review.approve_review_async(number, function(approve_ok, err)
      if not approve_ok then
        vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify("lreview: approved MR #" .. (number or (review.current and review.current.detail.number)), vim.log.levels.INFO)
    end)
  end)
end

local function cmd_toggle()
  M.ensure_review_started(function(ok)
    if not ok then return end
    require("lreview.ui.decor").toggle()
  end)
end

local function cmd_open()
  M.ensure_review_started(function(ok)
    if not ok then return end
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
  end)
end

local function cmd_summary()
  require("lreview.ui.summary").open()
end

local function cmd_next()
  M.ensure_review_started(function(ok)
    if not ok then return end
    require("lreview.ui.decor").next_thread()
  end)
end

local function cmd_prev()
  M.ensure_review_started(function(ok)
    if not ok then return end
    require("lreview.ui.decor").prev_thread()
  end)
end

local function cmd_quickfix()
  M.ensure_review_started(function(ok)
    if not ok then return end
    require("lreview.ui.decor").populate_quickfix()
  end)
end

local function cmd_request_review(args)
  M.ensure_review_started(function(started)
    if not started then return end
    local cwd = vim.fn.getcwd()
    local users = require("lreview.users").search_users(cwd, "")
    if #users == 0 then
      vim.notify("lreview: no repo users cached; fetching users...", vim.log.levels.INFO)
      require("lreview.users").pull_users_async(function(success)
        if success then
          cmd_request_review(args)
        end
      end)
      return
    end
    local choices = {}
    for _, u in ipairs(users) do
      choices[#choices + 1] = u.username
    end
    vim.ui.select(choices, {
      prompt = "Select reviewer to request:",
      format_item = function(u) return "@" .. u end,
    }, function(selected)
      if not selected then return end
      review.request_reviewers_async({ selected }, nil, nil, function(ok, err)
        if not ok then
          vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
        else
          vim.notify("lreview: requested review from @" .. selected, vim.log.levels.INFO)
        end
      end)
    end)
  end)
end

local function cmd_branch(args)
  local cwd = vim.fn.getcwd()
  local branch_name = args.args ~= "" and args.args or vim.fn.input("Branch name: ")
  if branch_name == "" then return end

  local cfg = config.get_defaults()
  local res_branch, err = materialize.materialize_branch(cfg, cwd, branch_name)
  if not res_branch then
    vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
  else
    vim.notify("lreview: materialized branch '" .. res_branch .. "'", vim.log.levels.INFO)
  end
end

local function cmd_conflicts()
  require("lreview.ui.conflicts").open()
end

local function cmd_issues(args)
  local state = args.args ~= "" and args.args or "open"
  require("lreview.ui.issues").pick({ state = state })
end

local function cmd_issue(args)
  if args.args == "" then
    vim.notify("lreview: usage :LocalReviewIssue <number>", vim.log.levels.WARN)
    return
  end
  require("lreview.ui.issues").show(args.args)
end

local function cmd_issue_pull(args)
  local state = args.args ~= "" and args.args or "open"
  local ok, err = require("lreview.issues").pull_async({ state = state })
  if not ok then
    vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function cmd_start()
  local cwd = vim.fn.getcwd()
  vim.notify("lreview: resolving MR for review...", vim.log.levels.INFO)
  local fallback = review.init_session_async(cwd, function(detail, err)
    if not detail then
      if review.current and review.current.detail and review.current.detail.unlinked then
        vim.notify("lreview: draft review session ready (no linked MR yet)", vim.log.levels.INFO)
      else
        vim.notify("lreview: " .. tostring(err), vim.log.levels.WARN)
      end
      return
    end
    if detail.unlinked then
      vim.notify("lreview: draft review session ready (no linked MR yet)", vim.log.levels.INFO)
    else
      vim.notify("lreview: review started for MR #" .. detail.number .. " (" .. detail.title .. ")", vim.log.levels.INFO)
    end
  end)
  if fallback and fallback.unlinked then
    vim.notify("lreview: draft review session ready (no linked MR yet)", vim.log.levels.INFO)
  end
end

--- Register all user commands in Neovim.
function M.register()
  local api = vim.api

  api.nvim_create_user_command("LocalReviewQuery", cmd_query, {
    nargs = "?",
    complete = function() return { "mine", "all" } end,
  })

  api.nvim_create_user_command("LocalReviewDetail", cmd_detail, { nargs = "?" })
  api.nvim_create_user_command("LocalReviewStart", cmd_start, {})
  api.nvim_create_user_command("LocalReviewCreate", cmd_create, {})
  api.nvim_create_user_command("LocalReviewBranch", cmd_branch, { nargs = "?" })
  api.nvim_create_user_command("LocalReviewComment", cmd_comment, { range = true })
  api.nvim_create_user_command("LocalReviewSubmit", cmd_submit, {})
  api.nvim_create_user_command("LocalReviewPull", cmd_pull, {})
  api.nvim_create_user_command("LocalReviewPullUser", cmd_pull_users, {})
  api.nvim_create_user_command("LocalReviewPullRequest", cmd_pull_requests, {})
  api.nvim_create_user_command("LocalReviewClose", cmd_close, { nargs = "?" })
  api.nvim_create_user_command("LocalReviewApprove", cmd_approve, { nargs = "?" })
  api.nvim_create_user_command("LocalReviewRequestReview", cmd_request_review, { nargs = "?" })
  api.nvim_create_user_command("LocalReviewToggle", cmd_toggle, {})
  api.nvim_create_user_command("LocalReviewHover", cmd_open, {})
  api.nvim_create_user_command("LocalReviewOpen", cmd_open, {})
  api.nvim_create_user_command("LocalReviewSummary", cmd_summary, {})
  api.nvim_create_user_command("LocalReviewNext", cmd_next, {})
  api.nvim_create_user_command("LocalReviewPrev", cmd_prev, {})
  api.nvim_create_user_command("LocalReviewQuickfix", cmd_quickfix, {})
  api.nvim_create_user_command("LocalReviewQf", cmd_quickfix, {})
  api.nvim_create_user_command("LocalReviewConflicts", cmd_conflicts, {})
  api.nvim_create_user_command("LocalReviewIssues", cmd_issues, {
    nargs = "?",
    complete = function() return { "open", "closed", "all" } end,
  })
  api.nvim_create_user_command("LocalReviewIssue", cmd_issue, { nargs = "?" })
  api.nvim_create_user_command("LocalReviewIssuePull", cmd_issue_pull, {
    nargs = "?",
    complete = function() return { "open", "closed", "all" } end,
  })
end

return M
