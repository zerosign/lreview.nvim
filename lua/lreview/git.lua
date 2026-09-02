---@meta

-- Git helpers: repo detection, remote URL parsing, current branch/sha.

local M = {}

--- Shell-escape a single argument for io.popen (thread fallback).
---@param s string
---@return string
local function shell_escape(s)
  if vim.fn and vim.fn.shellescape then
    return vim.fn.shellescape(s)
  end
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Unsynchronized git runner (no timing). See git() for the wrapped form.
---@param args string[]
---@param cwd string|nil
---@return string|nil output, string|nil err
local function git_raw(args, cwd)
  local cmd = { "git" }
  for _, a in ipairs(args) do
    cmd[#cmd + 1] = a
  end
  if vim.system then
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

  -- Thread execution fallback: io.popen (vim.system is nil on worker threads).
  local parts = {}
  for _, a in ipairs(cmd) do
    parts[#parts + 1] = shell_escape(a)
  end
  local cmd_str = table.concat(parts, " ")
  if cwd then
    cmd_str = "cd " .. shell_escape(cwd) .. " && " .. cmd_str
  end
  local f = io.popen(cmd_str .. " 2>&1")
  if not f then
    return nil, "failed to execute git on worker thread"
  end
  local out = f:read("*a") or ""
  local ok_close, exit_type, code = f:close()
  local exit_code = 0
  if type(code) == "number" then
    exit_code = code
  elseif type(exit_type) == "number" then
    exit_code = exit_type
  elseif ok_close == false or ok_close == nil then
    exit_code = 1
  end
  if exit_code ~= 0 then
    return nil, out
  end
  return out, nil
end

--- Run a git command in the given directory (or cwd).
--- On the main thread this uses vim.system (honors cwd reliably). On a worker
--- thread vim.system is nil, so we fall back to io.popen (see doc 12 §3.8).
---@param args string[]
---@param cwd string|nil
---@return string|nil output, string|nil err
local function git(args, cwd)
  local timing = require("lreview.timing")
  local label = "git " .. table.concat(args, " ")
  if not timing.enabled() then
    return git_raw(args, cwd)
  end
  local start = vim.uv.hrtime() / 1e6
  local out, err = git_raw(args, cwd)
  timing.record(timing.CAT_GIT, label, (vim.uv.hrtime() / 1e6) - start)
  return out, err
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
  if out and out ~= "" then
    local b = vim.trim(out):gsub("^origin/", "")
    if b ~= "" and b ~= "HEAD" then
      return b
    end
  end
  for _, candidate in ipairs({ "main", "master" }) do
    local chk, _ = git({ "rev-parse", "--verify", "refs/heads/" .. candidate }, cwd)
    if chk and chk ~= "" then
      return candidate
    end
  end
  return "main"
end

--- Get changed files and diff stats for local review fallback.
---@param cwd string|nil
---@param target_branch string|nil
---@return table[]  -- list of { path=..., additions=..., deletions=... }
function M.changed_files(cwd, target_branch)
  target_branch = target_branch or M.default_branch(cwd) or "main"
  local out, _ = git({ "diff", "--numstat", target_branch }, cwd)
  if not out or out == "" then
    out, _ = git({ "diff", "--numstat", "HEAD" }, cwd)
  end
  local files = {}
  if out and out ~= "" then
    for line in out:gmatch("[^\n]+") do
      local adds, dels, p = line:match("^(%d+)%s+(%d+)%s+(.+)$")
      if adds and dels and p then
        files[#files + 1] = {
          path = p,
          additions = tonumber(adds) or 0,
          deletions = tonumber(dels) or 0,
        }
      end
    end
  end
  return files
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

--- Thread entry point for changed_lines.
--- Executed on a worker thread (isolated Lua state, vim.system/vim.fn nil).
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, path, target_branch }
---@return table  -- { ok, lines?, err?, cwd, path }
function M.changed_lines_thread(db_path, lazy_sqlite, args)
  local lines, err = M.changed_lines(args.target_branch, args.path, args.cwd)
  if not lines then
    return { ok = false, err = err, cwd = args.cwd, path = args.path }
  end
  return { ok = true, lines = lines, cwd = args.cwd, path = args.path }
end

return M
