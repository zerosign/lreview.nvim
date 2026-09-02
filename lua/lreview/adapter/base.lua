---@meta

-- Base adapter: shared CLI runner + error normalization.
--
-- Key design point (from CLI discovery): gh/glab return exit code 0 even on
-- errors/not-found. So we capture combined stdout+stderr and detect errors by
-- scanning the output for known markers, not by trusting $?.

local M = {}

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
  assign_reviewers = false,
  offline_staging  = true,
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

--- Normalize a combined output into a short error message.
---@param combined string
---@return string
local function normalize_error(combined)
  -- Prefer the last meaningful line.
  local lines = {}
  for line in combined:gmatch("[^\n]+") do
    local t = vim.trim(line)
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

local function escape_arg(s)
  if vim.fn and vim.fn.shellescape then
    return vim.fn.shellescape(s)
  end
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Execute a CLI command and return a normalized result.
---
--- The `executor` is injectable for testing (defaults to vim.system or io.popen on threads).
---@param argv string[]  -- e.g. { "gh", "pr", "list", ... }
---@param opts table|nil
---@param opts.cwd string|nil
---@param opts.stdin string|nil
---@param opts.executor function|nil  -- function(argv, cwd) -> { stdout, stderr, code }
---@param callback fun(res: lreview.CliResult)|nil -- optional callback for async execution
---@return lreview.CliResult|nil
function M.run(argv, opts, callback)
  opts = opts or {}
  local executor = opts.executor or function(args, cwd)
    if vim.system then
      local o = { text = true }
      if cwd then
        o.cwd = cwd
      end
      if callback then
        vim.system(args, o, function(res)
          vim.schedule(function()
            local stdout = res.stdout or ""
            local stderr = res.stderr or ""
            local combined = stdout .. "\n" .. stderr
            local ok = res.code == 0 and not looks_like_error(combined)
            local err_msg = nil
            if not ok then
              err_msg = string.format("Command failed: %s | Error: %s", table.concat(argv, " "), normalize_error(combined))
            end
            callback({
              ok = ok,
              stdout = stdout,
              stderr = stderr,
              combined = combined,
              code = res.code,
              error = err_msg,
            })
          end)
        end)
        return nil
      else
        local res = vim.system(args, o):wait()
        return { stdout = res.stdout, stderr = res.stderr, code = res.code }
      end
    else
      -- Thread execution fallback: io.popen
      local cmd_parts = {}
      for _, arg in ipairs(args) do
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
  end

  if callback then
    executor(argv, opts.cwd)
    return nil
  end

  local timing = require("lreview.timing")
  local res
  if timing.enabled() then
    local start = vim.uv.hrtime() / 1e6
    res = executor(argv, opts.cwd)
    timing.record(timing.CAT_CLI, table.concat(argv, " "), (vim.uv.hrtime() / 1e6) - start)
  else
    res = executor(argv, opts.cwd)
  end
  local stdout = res.stdout or ""
  local stderr = res.stderr or ""
  local combined = stdout .. "\n" .. stderr

  local ok = res.code == 0 and not looks_like_error(combined)
  local err_msg = nil
  if not ok then
    err_msg = string.format("Command failed: %s | Error: %s", table.concat(argv, " "), normalize_error(combined))
  end
  return {
    ok = ok,
    stdout = stdout,
    stderr = stderr,
    combined = combined,
    code = res.code,
    error = err_msg,
  }
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
