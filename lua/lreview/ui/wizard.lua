---@meta

-- Interactive wizard for creating new Pull Requests / Merge Requests.
-- Guides the user through:
--   1. Source branch selection (current or create new)
--   2. Template selection (if templates exist on remote or blank)
--   3. Target branch selection
--   4. Title & description editor
--   5. Asynchronous creation via adapter

local git = require("lreview.git")
local review = require("lreview.review")
local adapter = require("lreview.adapter")

local M = {}

--- Resolve candidate target branches for the given repository.
---@param cwd string|nil
---@return string[]
function M.resolve_target_branches(cwd)
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

--- Template -> target branch -> title -> create.
--- Shared by both the current-branch and new-branch create flows.
---@param cwd string
---@param choices table[]
---@param target_choices string[]
function M.pick_template_and_create(cwd, choices, target_choices)
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
      require("lreview.ui.editor").open_mr_editor(choice.content, function(title, body)
        local source_branch = git.current_branch(cwd)
        local opts = {
          title = title,
          body = body,
          source_branch = source_branch,
          target_branch = target,
          template = choice.path,
        }
        review.create_review_async(opts, cwd, function(url, err)
          if not url then
            vim.notify("lreview: failed to create MR: " .. tostring(err), vim.log.levels.ERROR)
          else
            vim.notify("lreview: created MR: " .. url, vim.log.levels.INFO)
            require("lreview.sync").schedule()
          end
        end)
      end)
    end)
  end)
end

--- Source branch picker: use the current branch, or create a brand-new branch
--- (checked out and pushed) and open the MR/PR from it.
---@param cwd string
---@param choices table[]
---@param target_choices string[]
function M.pick_source_branch(cwd, choices, target_choices)
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
    M.pick_template_and_create(cwd, choices, target_choices)
  end)
end

--- Launch the interactive PR/MR creation wizard.
---@param cwd string|nil
function M.start(cwd)
  cwd = cwd or vim.fn.getcwd()
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

  local target_choices = M.resolve_target_branches(cwd)
  local choices = { { name = "(blank)", path = nil, content = "" } }
  for _, t in ipairs(templates or {}) do
    choices[#choices + 1] = t
  end

  M.pick_source_branch(cwd, choices, target_choices)
end

return M
