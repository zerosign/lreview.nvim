---@meta

-- Git helpers: repo detection, remote URL parsing, current branch/sha.

local M = {}

--- Run a git command in the given directory (or cwd).
---@param args string[]
---@param cwd string|nil
---@return string|nil output, string|nil err
local function git(args, cwd)
  local cmd = { "git" }
  for _, a in ipairs(args) do
    cmd[#cmd + 1] = a
  end
  -- Use vim.system with the cwd option: vim.fn.system(cmd, cwd) does not
  -- reliably honor a cwd different from the process cwd in this Neovim build.
  local opts = { text = true }
  if cwd then
    opts.cwd = cwd
  end
  local res = vim.system(cmd, opts):wait()
  if res.code ~= 0 then
    return nil, res.stdout .. res.stderr
  end
  return res.stdout, nil
end

--- Find the git root of a directory (or nil if not a repo).
---@param cwd string|nil
---@return string|nil
function M.root(cwd)
  local uv = vim.uv or vim.loop
  cwd = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p")
  local current = cwd
  while current ~= "" do
    if current:sub(-1) == "/" or current:sub(-1) == "\\" then
      current = current:sub(1, -2)
    end
    local stat = uv.fs_stat(current .. "/.git")
    if stat then
      return current
    end
    local parent = vim.fn.fnamemodify(current, ":h")
    if parent == current then
      break
    end
    current = parent
  end
  return nil
end

--- Get the current branch name.
---@param cwd string|nil
---@return string|nil
function M.current_branch(cwd)
  local out, err = git({ "branch", "--show-current" }, cwd)
  if not out then
    return nil
  end
  local b = vim.trim(out)
  if b == "" then
    return nil
  end
  return b
end

--- Get the current HEAD sha.
---@param cwd string|nil
---@return string|nil
function M.head_sha(cwd)
  local out, err = git({ "rev-parse", "HEAD" }, cwd)
  if not out then
    return nil
  end
  return vim.trim(out)
end

--- Parse a git remote URL into { domain, repo } or nil.
--- Handles https://, git@host:path, ssh://git@host/path, git://.
---@param url string
---@return table|nil  -- { domain, repo }
function M.parse_remote_url(url)
  url = vim.trim(url)
  if url == "" then
    return nil
  end
  -- strip trailing slashes and .git
  url = url:gsub("/+$", "")
  url = url:gsub("%.git$", "")

  local domain, path
  -- ssh://git@host:port/path or https://host/path
  local scheme = url:match("^([a-zA-Z][a-zA-Z0-9+.-]*)://")
  if scheme then
    local rest = url:sub(#scheme + 4)
    -- strip userinfo
    rest = rest:gsub("^[^@]*@", "")
    -- strip port
    rest = rest:gsub("^([^:/]+):%d+", "%1")
    domain, path = rest:match("^([^/]+)/(.+)$")
  else
    -- scp-like: git@host:owner/repo
    local rest = url:gsub("^[^@]*@", "")
    domain, path = rest:match("^([^:]+):(.+)$")
  end

  if not domain or not path then
    return nil
  end
  return { domain = domain, repo = path }
end

--- Get the remotes of a repo as a list of { name, url, domain, repo }.
---@param cwd string|nil
---@return table[]
function M.remotes(cwd)
  local out, err = git({ "remote", "-v" }, cwd)
  if not out then
    return {}
  end
  local result = {}
  for line in out:gmatch("[^\n]+") do
    local name, url = line:match("^(%S+)%s+(%S+)")
    if name and url then
      local parsed = M.parse_remote_url(url)
      if parsed then
        result[#result + 1] = {
          name = name,
          url = url,
          domain = parsed.domain,
          repo = parsed.repo,
        }
      end
    end
  end
  return result
end

--- Get the primary remote (origin preferred, else first).
---@param cwd string|nil
---@return table|nil
function M.primary_remote(cwd)
  local remotes = M.remotes(cwd)
  for _, r in ipairs(remotes) do
    if r.name == "origin" then
      return r
    end
  end
  return remotes[1]
end

--- List remote branch names (e.g. from origin), excluding the current branch.
--- Used to offer target branches for stacked MR/PR creation.
---@param cwd string|nil
---@return string[]
function M.remote_branches(cwd)
  local out, err = git({ "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin" }, cwd)
  if not out then
    return {}
  end
  local current = M.current_branch(cwd)
  local result = {}
  for line in out:gmatch("[^\n]+") do
    local b = vim.trim(line)
    -- strip the "origin/" prefix
    b = b:gsub("^origin/", "")
    -- "origin" alone is the origin/HEAD symref; skip it along with HEAD.
    if b ~= "" and b ~= current and b ~= "HEAD" and b ~= "origin" then
      result[#result + 1] = b
    end
  end
  return result
end

--- Determine the repo's default branch (from origin/HEAD, else main/master).
---@param cwd string|nil
---@return string|nil
function M.default_branch(cwd)
  local out, err = git({ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, cwd)
  if out then
    local b = vim.trim(out):gsub("^origin/", "")
    if b ~= "" and b ~= "HEAD" then
      return b
    end
  end
  -- If current branch is a known default, return it
  local current = M.current_branch(cwd)
  if current == "main" or current == "master" then
    return current
  end
  -- Fall back to a known default in remote branches
  local branches = M.remote_branches(cwd)
  for _, b in ipairs({ "main", "master" }) do
    for _, rb in ipairs(branches) do
      if rb == b then
        return b
      end
    end
  end
  return nil
end

--- Create a new branch from the current HEAD and push it to origin.
--- Used by LocalReviewCreate to open an MR/PR from a brand-new branch.
---@param cwd string|nil
---@param name string
---@return boolean ok, string|nil err
function M.create_branch(cwd, name)
  local out, err = git({ "checkout", "-b", name }, cwd)
  if not out then
    return false, err
  end
  local out2, err2 = git({ "push", "-u", "origin", name }, cwd)
  if not out2 then
    return false, err2
  end
  return true, nil
end

--- Checkout an existing branch.
---@param name string
---@param cwd string|nil
---@return boolean ok, string|nil err
function M.checkout_branch(name, cwd)
  local out, err = git({ "checkout", name }, cwd)
  if not out then
    return false, err
  end
  return true, nil
end

--- Add a git worktree for a branch.
---@param target_dir string
---@param branch string
---@param cwd string|nil
---@return boolean ok, string|nil err
function M.create_worktree(target_dir, branch, cwd)
  local out, err = git({ "worktree", "add", target_dir, branch }, cwd)
  if not out then
    return false, err
  end
  return true, nil
end

--- Get the line numbers of added/modified lines in the current branch relative to the target branch.
---@param target_branch string
---@param rel_path string
---@param cwd string|nil
---@return table<integer, boolean>|nil  -- map of line number -> true
function M.changed_lines(target_branch, rel_path, cwd)
  -- Use git diff -U0 target_branch... -- rel_path
  -- Note: 3 dots compares against the merge base.
  local out, err = git({ "diff", "-U0", target_branch .. "...", "--", rel_path }, cwd)
  if not out then
    return nil, err
  end

  local lines = {}
  for line in out:gmatch("[^\r\n]+") do
    local start_line, count_str = line:match("^@@ %-%d+,?%d* %+([0-9]+),?([0-9]*) @@")
    if start_line then
      local start = tonumber(start_line)
      local count = tonumber(count_str) or 1
      if count_str == "" then count = 1 end
      if count > 0 then
        for i = start, start + count - 1 do
          lines[i] = true
        end
      end
    end
  end
  return lines
end

return M
