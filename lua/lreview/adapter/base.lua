---@meta

-- Base adapter: shared CLI runner + error normalization.
--
-- Key design point (from CLI discovery): gh/glab return exit code 0 even on
-- errors/not-found. So we capture combined stdout+stderr and detect errors by
-- scanning the output for known markers, not by trusting $?.

local M = {}

-- Capability flags (see adapter/init.lua M.supports). Two govern submit shape:
--   batch_submit          -- the hub can create several inline comments in one call
--   atomic_inline_batch   -- that call is all-or-nothing (so nothing partially lands)
--   verdict_in_review_batch -- the review event can ride along with that call
M.default_capabilities = {
  review_verdict   = false,
  draft_mr         = false,
  update_mr        = true,
  close_mr         = true,
  approve_mr       = false,
  list_templates   = false,
  inline_comments  = true,
  resolve_threads  = true,
  batch_submit     = true,
  -- Does that batch call succeed or fail as a whole? Default false: assume the
  -- hub can partially apply, so the engine loops and commits each op itself.
  -- Declaring this true is what lets GitHub take one review POST per group.
  atomic_inline_batch = false,
  assign_reviewers = false,
  offline_staging  = true,
  -- Can this hub carry the review verdict inside the same call that creates
  -- inline comments (GitHub review batches)? When false, lreview submits the
  -- verdict as its own `submit_verdict` call after the comments land.
  verdict_in_review_batch = false,
  -- Does the platform expose an issue tracker (list/detail/notes)?
  issues           = false,
}

---@class lreview.CliResult
---@field ok boolean
---@field stdout string
---@field stderr string
---@field combined string
---@field code integer
---@field error string|nil  -- normalized error message when not ok

-- Error markers to scan for in combined output.
local ERROR_MARKERS = {
  "gh: ",                   -- gh api errors: "gh: Not Found (HTTP 404)"
  "glab: ",                 -- glab api errors
  "ERROR",                  -- glab mr view: "ERROR: No open merge request..."
  "failed to",              -- gh pr review: "failed to create review: ..."
  "no pull requests found", -- gh pr view
  "no merge request",       -- glab mr view
  "No open merge request",
  "HTTP 4",                 -- generic
  "HTTP 5",
}

--- Detect whether combined output indicates an error.
---@param combined string
---@return boolean
local function looks_like_error(combined)
  for _, marker in ipairs(ERROR_MARKERS) do
    if combined:find(marker, 1, true) then
      return true
    end
  end
  return false
end
M.looks_like_error = looks_like_error

--- Trim a line, without depending on vim.trim (absent on worker threads).
---@param s string
---@return string
local function trim(s)
  if vim.trim then return vim.trim(s) end
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Normalize a combined output into a short error message.
---@param combined string
---@return string
local function normalize_error(combined)
  -- Prefer the last meaningful line.
  local lines = {}
  for line in combined:gmatch("[^\n]+") do
    local t = trim(line)
    if t ~= "" then
      lines[#lines + 1] = t
    end
  end
  if #lines == 0 then
    return "unknown error"
  end
  return lines[#lines]
end
M.normalize_error = normalize_error

--- Percent-encode a query value, without depending on vim.uri_encode (absent on
--- worker threads, where these adapters also run).
---@param s string
---@return string
function M.uri_encode(s)
  if vim.uri_encode then return vim.uri_encode(s) end
  return (tostring(s):gsub("[^%w%-_.~]", function(c)
    return string.format("%%%02X", c:byte())
  end):gsub(" ", "+"))
end

local function escape_arg(s)
  if vim.fn and vim.fn.shellescape then
    return vim.fn.shellescape(s)
  end
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Test seam: when set, replaces the built-in subprocess executor for every
--- call (main thread and worker threads alike, since the override is resolved
--- per invocation inside base.run).
---   function(argv, cwd) -> { stdout?, stderr?, code }|nil
--- Lets contract tests assert the exact CLI argv we send without touching the
--- network — the class of bug where the endpoint or argument shape drifted.
---@type fun(argv: string[], cwd: string|nil): table|nil
M.executor_override = nil

--- Normalize a raw subprocess result into a lreview.CliResult.
---@param argv string[]
---@param stdout string|nil
---@param stderr string|nil
---@param code integer|nil
---@return lreview.CliResult
local function build_result(argv, stdout, stderr, code)
  stdout = stdout or ""
  stderr = stderr or ""
  local combined = stdout .. "\n" .. stderr
  local ok = (code == 0) and not looks_like_error(combined)
  local err_msg = nil
  if not ok then
    -- The command line is echoed to the user on failure, so it goes through the
    -- same masking as timing records (op templates can embed a token).
    err_msg = string.format("Command failed: %s | Error: %s",
      table.concat(M.redact_argv(argv), " "), normalize_error(combined))
  end
  return {
    ok = ok,
    stdout = stdout,
    stderr = stderr,
    combined = combined,
    code = code or 1,
    error = err_msg,
  }
end

--- Worker-thread fallback: io.popen (vim.system / vim.fn are unavailable in an
--- isolated Lua state, so combined output is captured through the shell).
---@param argv string[]
---@param cwd string|nil
---@return table
local function popen_exec(argv, cwd)
  local cmd_parts = {}
  for _, arg in ipairs(argv) do
    cmd_parts[#cmd_parts + 1] = escape_arg(arg)
  end
  local cmd_str = table.concat(cmd_parts, " ")
  if cwd then
    cmd_str = "cd " .. escape_arg(cwd) .. " && " .. cmd_str
  end
  local f = io.popen(cmd_str .. " 2>&1")
  if not f then
    return { stdout = "", stderr = "failed to execute process on worker thread", code = 1 }
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
  return { stdout = out, stderr = "", code = exit_code }
end

--- Synchronous built-in executor.
---@param argv string[]
---@param cwd string|nil
---@return table
local function spawn_wait(argv, cwd)
  if vim.system then
    local o = { text = true }
    if cwd then o.cwd = cwd end
    local res = vim.system(argv, o):wait()
    return { stdout = res.stdout, stderr = res.stderr, code = res.code }
  end
  return popen_exec(argv, cwd)
end

-- Credential-shaped argument keys. A per-domain op template may embed a header
-- or a token flag, so anything we *log* or *echo back* must be masked first.
local SECRET_KEYS = {
  "authorization", "proxy-authorization", "token", "access_token",
  "password", "passwd", "secret", "apikey", "api_key", "bearer",
}
local SECRET_FLAGS = { "--token", "-t", "--password", "--passwd" }

--- Mask credential- and content-shaped values in an argv for logging.
---
--- Used ONLY for human-readable labels (timing records, error strings). The
--- real subprocess always receives the untouched argv. Comment bodies are
--- truncated too: a profiler file has no business holding review text.
---@param argv string[]
---@return string[]
function M.redact_argv(argv)
  local out = {}
  local mask_next = false
  for _, arg in ipairs(argv) do
    local s = tostring(arg)
    if mask_next then
      out[#out + 1] = "<redacted>"
      mask_next = false
    else
      local low = s:lower()
      local replaced = nil
      for _, key in ipairs(SECRET_KEYS) do
        if low:find(key .. "=", 1, true) then
          replaced = key .. "=<redacted>"
          break
        end
        if low:find(key .. ":") then
          replaced = key .. ": <redacted>"
          break
        end
      end
      if not replaced then
        for _, f in ipairs(SECRET_FLAGS) do
          if low == f then
            mask_next = true
            break
          end
        end
      end
      if not replaced then
        -- Truncate long values (bodies, query strings): enough to identify the
        -- call, not enough to archive the review.
        if #s > 48 then
          replaced = s:sub(1, 48) .. "…"
        else
          replaced = s
        end
      end
      out[#out + 1] = replaced
    end
  end
  return out
end

--- Execute a CLI command and return a normalized result.
---
--- Three paths:
---   * `callback` + no override executor  -> true async via vim.system; returns
---     nil, result is delivered to `callback` on the main thread.
---   * an override/`opts.executor`        -> invoked synchronously; the result
---     is returned *and* delivered to `callback` when one was given (keeps test
---     and worker paths deterministic instead of silently dropping the
---     callback, which the old io.popen branch did).
---   * default synchronous                -> waits on vim.system / io.popen.
---
---@param argv string[]  -- e.g. { "gh", "pr", "list", ... }
---@param opts table|nil
---@param opts.cwd string|nil
---@param opts.stdin string|nil
---@param opts.executor function|nil  -- function(argv, cwd) -> { stdout, stderr, code }
---@param callback fun(res: lreview.CliResult)|nil -- optional callback for async execution
---@return lreview.CliResult|nil
function M.run(argv, opts, callback)
  opts = opts or {}
  local exec = opts.executor or M.executor_override

  -- Async subprocess path (main thread only, no test override).
  if callback and not exec and vim.system then
    local o = { text = true }
    if opts.cwd then o.cwd = opts.cwd end
    vim.system(argv, o, function(res)
      vim.schedule(function()
        callback(build_result(argv, res.stdout, res.stderr, res.code))
      end)
    end)
    return nil
  end

  local timing = require("lreview.timing")
  local raw
  if timing.enabled() then
    local start = vim.uv.hrtime() / 1e6
    raw = exec and exec(argv, opts.cwd) or spawn_wait(argv, opts.cwd)
    timing.record(timing.CAT_CLI, table.concat(M.redact_argv(argv), " "), (vim.uv.hrtime() / 1e6) - start)
  else
    raw = exec and exec(argv, opts.cwd) or spawn_wait(argv, opts.cwd)
  end
  raw = raw or { stdout = "", stderr = "executor returned no result", code = 1 }

  local result = build_result(argv, raw.stdout, raw.stderr, raw.code)
  if callback then callback(result) end
  return result
end

--- Parse JSON from a CLI result's stdout. Returns nil + err on failure.
---@param res lreview.CliResult
---@return any|nil, string|nil
function M.parse_json(res)
  if not res.ok then
    return nil, res.error
  end
  local ok, data = pcall(vim.json.decode, res.stdout)
  if not ok then
    return nil, "failed to parse JSON: " .. tostring(data)
  end
  return data, nil
end

return M
