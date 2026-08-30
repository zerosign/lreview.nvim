local git = require("lreview.git")

local M = {}

--- Resolve the materialization mode ("checkout" vs "worktree") based on config and scope.
---@param cfg table|nil
---@param file_count integer|nil
---@return "checkout"|"worktree"
function M.resolve_mode(cfg, file_count)
  cfg = cfg or {}
  local topology = cfg.topology or "simple"

  if topology == "monorepo-multi" then
    return "worktree"
  elseif topology == "monorepo-single" then
    if cfg.open and cfg.open.prefer then
      return cfg.open.prefer
    end
    if file_count and file_count > 20 then
      return "worktree"
    end
  end

  return "checkout"
end

--- Materialize a remote or local branch into the workspace or worktree.
---@param source_branch string
---@param cwd string|nil
---@param opts table|nil -- { mode = "checkout"|"worktree", target_dir = "..." }
---@return boolean ok, string|nil target_path_or_err
function M.materialize_branch(source_branch, cwd, opts)
  opts = opts or {}
  cwd = cwd or vim.fn.getcwd()
  local mode = opts.mode or "checkout"

  if mode == "worktree" then
    local base_dir = opts.target_dir or (cwd .. "/.worktrees/" .. source_branch)
    vim.fn.mkdir(vim.fn.fnamemodify(base_dir, ":h"), "p")
    local ok, err = git.create_worktree(base_dir, source_branch, cwd)
    if not ok then
      return false, err
    end
    return true, base_dir
  else
    local ok, err = git.checkout_branch(source_branch, cwd)
    if not ok then
      return false, err
    end
    return true, cwd
  end
end

return M
