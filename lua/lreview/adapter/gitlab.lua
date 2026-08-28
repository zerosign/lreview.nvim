---@meta

-- GitLab adapter: wraps the `glab` CLI.
--
-- Ops are named defaults that can be overridden per-domain in config with a
-- string CLI template or a Lua function hook. Each op returns a lreview.CliResult
-- (see adapter/base.lua).

local base = require("lreview.adapter.base")
local mappers = require("lreview.mappers")
local model = require("lreview.model")

local M = {}

M.name = "gitlab"
M.provider = "glab"

--- Build the base argv with optional --repo.
---@param cfg table
---@param ctx table
---@return string[]
local function base_argv(cfg, ctx)
  local argv = { cfg.provider or "glab" }
  if ctx.repo then
    argv[#argv + 1] = "--repo"
    argv[#argv + 1] = ctx.repo
  end
  return argv
end

--- List MRs (query). scope: "mine" | "all"; query: optional search string.
---@param cfg table
---@param ctx table
---@param opts table  -- { scope, query }
---@return lreview.MR[]|nil, string|nil
function M.list_mrs(cfg, ctx, opts)
  opts = opts or {}
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "list"
  if opts.scope == "mine" then
    -- glab has no --author @me; use --assignee=@me as the "mine" proxy.
    argv[#argv + 1] = "--assignee"
    argv[#argv + 1] = "@me"
  end
  if opts.query and opts.query ~= "" then
    argv[#argv + 1] = "--search"
    argv[#argv + 1] = opts.query
  end
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "json"
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  return mappers.glab_mrs_to_mrs(data, ctx.repo), nil
end

--- Get MR detail by ref (iid, branch, or current branch if ref is nil).
---@param cfg table
---@param ctx table
---@return lreview.MRDetail|nil, string|nil
function M.get_mr_detail(cfg, ctx)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "view"
  if ctx.ref then
    argv[#argv + 1] = ctx.ref
  end
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "json"
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok and ctx.repo then
    local new_argv = {}
    local skip = false
    for _, arg in ipairs(argv) do
      if skip then
        skip = false
      elseif arg == "--repo" then
        skip = true
      else
        new_argv[#new_argv + 1] = arg
      end
    end
    local fallback_res = base.run(new_argv, { cwd = ctx.cwd })
    if fallback_res.ok then
      res = fallback_res
    end
  end

  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  return mappers.glab_mr_view_to_mrdetail(data, ctx.repo), nil
end

--- Resolve an MR by branch name.
---@param cfg table
---@param ctx table
---@param branch string
---@return lreview.MR|nil, string|nil
function M.get_mr_by_branch(cfg, ctx, branch)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "list"
  argv[#argv + 1] = "--source-branch"
  argv[#argv + 1] = branch
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "json"
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  local mrs = mappers.glab_mrs_to_mrs(data, ctx.repo)
  if #mrs == 0 then
    return nil, "no merge request found for branch '" .. branch .. "'"
  end
  return mrs[1], nil
end

--- Fetch remote discussions (threads) for an MR via the stable glab api.
---@param cfg table
---@param ctx table
---@param number integer  -- iid
---@return lreview.Thread[]|nil, string|nil
function M.fetch_discussions(cfg, ctx, number)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "api"
  argv[#argv + 1] = string.format("projects/:fullpath/merge_requests/%d/discussions", number)
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  local mo_id = model.mo_id("gitlab", ctx.repo, number)
  return mappers.glab_discussions_to_threads(data, mo_id), nil
end

--- Fetch remote discussions (threads) for an MR. Alias of fetch_discussions
--- so both adapters expose a uniform `fetch_threads(cfg, ctx, number, mo_id)`.
---@param cfg table
---@param ctx table
---@param number integer  -- iid
---@param mo_id string
---@return lreview.Thread[]|nil, string|nil
function M.fetch_threads(cfg, ctx, number, mo_id)
  return M.fetch_discussions(cfg, ctx, number)
end

--- Submit a batch of inline comments as new discussion threads.
--- Uses `glab mr note create --file --line` (experimental but the only working
--- inline write path; raw glab api does not attach position).
---@param cfg table
---@param ctx table
---@param number integer  -- iid
---@param comments table[]  -- { path, line, body }
---@return boolean, string|nil
function M.submit_inline_review(cfg, ctx, number, comments, body)
  for _, c in ipairs(comments) do
    local argv = base_argv(cfg, ctx)
    argv[#argv + 1] = "mr"
    argv[#argv + 1] = "note"
    argv[#argv + 1] = "create"
    argv[#argv + 1] = tostring(number)
    argv[#argv + 1] = "--file"
    argv[#argv + 1] = c.path
    argv[#argv + 1] = "--line"
    argv[#argv + 1] = tostring(c.line)
    argv[#argv + 1] = "-m"
    argv[#argv + 1] = c.body
    local res = base.run(argv, { cwd = ctx.cwd })
    if not res.ok then
      return false, res.error
    end
  end
  return true, nil
end

--- Close a merge request.
---@param cfg table
---@param ctx table
---@param number integer  -- iid
---@return boolean, string|nil
function M.close_mr(cfg, ctx, number)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "close"
  argv[#argv + 1] = tostring(number)
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Approve a merge request.
---@param cfg table
---@param ctx table
---@param number integer  -- iid
---@return boolean, string|nil
function M.approve_mr(cfg, ctx, number)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "approve"
  argv[#argv + 1] = tostring(number)
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Discover merge request templates in the repo.
--- GitLab looks in .gitlab/merge_request_templates/*.md.
---@param cfg table
---@param ctx table
---@return table[]|nil, string|nil  -- { name, path, content }[]
function M.list_templates(cfg, ctx)
  local dir = ctx.cwd .. "/.gitlab/merge_request_templates"
  local out = {}
  local p = io.popen("ls " .. vim.fn.shellescape(dir) .. " 2>/dev/null")
  if not p then
    return out, nil
  end
  for line in p:lines() do
    if line:match("%.md$") then
      local rel = ".gitlab/merge_request_templates/" .. line
      local f = io.open(ctx.cwd .. "/" .. rel, "r")
      if f then
        local content = f:read("*a")
        f:close()
        local name = line:match("([^/]+)%.md$") or line
        out[#out + 1] = { name = name, path = rel, content = content }
      end
    end
  end
  p:close()
  return out, nil
end

--- Create a merge request.
---@param cfg table
---@param ctx table
---@param opts table  -- { title, body, source_branch, target_branch, template }
---@return string|nil url, string|nil err
function M.create_mr(cfg, ctx, opts)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "create"
  argv[#argv + 1] = "-t"
  argv[#argv + 1] = opts.title
  -- --description and --template are mutually exclusive in glab; when a
  -- template is selected it supplies the description.
  if opts.body and opts.body ~= "" and not opts.template then
    argv[#argv + 1] = "--description"
    argv[#argv + 1] = opts.body
  end
  if opts.source_branch and opts.source_branch ~= "" then
    argv[#argv + 1] = "--source-branch"
    argv[#argv + 1] = opts.source_branch
  end
  if opts.target_branch and opts.target_branch ~= "" then
    argv[#argv + 1] = "--target-branch"
    argv[#argv + 1] = opts.target_branch
  end
  if opts.template and opts.template ~= "" then
    argv[#argv + 1] = "--template"
    argv[#argv + 1] = opts.template
  end
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return nil, res.error
  end
  local url = res.stdout:match("https?://%S+")
  return url, nil
end

--- Resolve or unresolve a comment thread on GitLab.
---@param cfg table
---@param ctx table
---@param mr_number integer  -- iid
---@param thread_id string  -- discussion_id
---@param resolved boolean
---@return boolean, string|nil
function M.resolve_thread(cfg, ctx, mr_number, thread_id, resolved)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "note"
  argv[#argv + 1] = resolved and "resolve" or "reopen"
  argv[#argv + 1] = tostring(mr_number)
  argv[#argv + 1] = thread_id
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

return M
