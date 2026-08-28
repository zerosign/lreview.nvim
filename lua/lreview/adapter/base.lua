---@meta

-- Base adapter: shared CLI runner + error normalization.
--
-- Key design point (from CLI discovery): gh/glab return exit code 0 even on
-- errors/not-found. So we capture combined stdout+stderr and detect errors by
-- scanning the output for known markers, not by trusting $?.

local M = {}

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

--- Execute a CLI command and return a normalized result.
---
--- The `executor` is injectable for testing (defaults to vim.fn.system).
---@param argv string[]  -- e.g. { "gh", "pr", "list", ... }
---@param opts table|nil
---@param opts.cwd string|nil
---@param opts.stdin string|nil
---@param opts.executor function|nil  -- function(argv, cwd) -> { stdout, stderr, code }
---@return lreview.CliResult
function M.run(argv, opts)
  opts = opts or {}
  local executor = opts.executor or function(args, cwd)
    -- Use vim.system with the cwd option (vim.fn.system(args, cwd) does not
    -- reliably honor a cwd different from the process cwd in this build).
    local o = { text = true }
    if cwd then
      o.cwd = cwd
    end
    local res = vim.system(args, o):wait()
    return { stdout = res.stdout, stderr = res.stderr, code = res.code }
  end

  local res = executor(argv, opts.cwd)
  local stdout = res.stdout or ""
  local stderr = res.stderr or ""
  local combined = stdout .. "\n" .. stderr

  local ok = res.code == 0 and not looks_like_error(combined)
  return {
    ok = ok,
    stdout = stdout,
    stderr = stderr,
    combined = combined,
    code = res.code,
    error = ok and nil or normalize_error(combined),
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
