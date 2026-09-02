---@meta

-- Lightweight duration instrumentation for lreview.nvim.
--
-- When diagnostics.timing is enabled, every instrumented operation (git
-- subprocess, gh/glab CLI call, sqlite statement, flow span) records how long
-- it took. Records are appended to the timing file (when configured) and
-- emitted to the nvim log under the "[lreview-timing]" tag so the tmux E2E
-- scenario (`scripts/test_tmux_scenarios.fish`) can capture and report them.
--
-- A single library is kept in memory so that callers can retrieve the trace
-- for a whole flow (e.g. resolve MR) as one unit.

local M = {}

-- Category tags used consistently across the codebase.
M.CAT_GIT = "git"
M.CAT_CLI = "cli"
M.CAT_SQLITE = "sqlite"
M.CAT_FLOW = "flow"

-- In-memory timeline (accumulated records for the current session).
local timeline = {}
local enabled = false
local log_file = nil

-- Sorted-style interval index: monotonically increasing microsecond clock.
local function now_ms()
  if vim and vim.uv and vim.uv.hrtime then
    return vim.uv.hrtime() / 1e6
  end
  return os.clock() * 1000 -- fallback (throws? no: returns CPU time) / use os.time fallback
end

local function flush_to_file()
  if not log_file or log_file == "" then
    return
  end
  local ok, f = pcall(io.open, log_file, "a")
  if not ok or not f then
    return
  end
  for _, rec in ipairs(timeline) do
    f:write(string.format("%s\t%s\t%s\t%.3f\n", rec.t, rec.category, rec.label, rec.duration_ms))
  end
  f:close()
  timeline = {}
end

--- Enable/disable timing and (re)configure the output file.
---@param cfg { timing: boolean|nil, timing_file: string|nil }
function M.configure(cfg)
  enabled = (cfg and cfg.timing) == true
  log_file = (cfg and cfg.timing_file) or nil
  if not enabled then
    timeline = {}
  end
end

--- Whether timing instrumentation is active.
---@return boolean
function M.enabled()
  return enabled
end

--- Record a completed operation.
---@param category string  -- one of M.CAT_*
---@param label string     -- human readable tag, e.g. "git status --porcelain"
---@param duration_ms number
function M.record(category, label, duration_ms)
  if not enabled then
    return
  end
  local rec = {
    t = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    category = category,
    label = label,
    duration_ms = duration_ms,
  }
  table.insert(timeline, rec)
  -- Emit a compact, greppable line to the nvim log (guard for worker threads,
  -- where vim.notify / vim.log may be absent).
  if vim and vim.notify then
    pcall(vim.notify,
      string.format("[lreview-timing] %s %s %.3fms", category, label, duration_ms),
      (vim.log and vim.log.levels and vim.log.levels.DEBUG) or 0)
  end
  if #timeline >= 100 then
    flush_to_file()
  end
end

--- Time a synchronous function, recording the duration under `category`/`label`.
---@param category string
---@param label string
---@param fn fun(): T
---@return T
function M.time(category, label, fn)
  if not enabled then
    return fn()
  end
  local start = now_ms()
  local ok, res = pcall(fn)
  local dur = now_ms() - start
  M.record(category, label, dur)
  if ok then
    return res
  end
  error(res)
end

--- Git/wrapper-style time helper that measures a callable taking no args but
--- returning (ok, result). Records the duration and re-raises errors.
---@param category string
---@param label string
---@param fn fun(): (boolean, T)
---@return boolean, T
function M.try(category, label, fn)
  if not enabled then
    return fn()
  end
  local start = now_ms()
  local ok, a, b = pcall(fn)
  local dur = now_ms() - start
  M.record(category, label, dur)
  if ok then
    return a, b
  end
  error(a)
end

--- Return the current trace (copy). Useful for dumping an entire flow at the end.
---@return table[]
function M.snapshot()
  return vim.deepcopy(timeline)
end

--- Write any buffered records to the timing file (if configured).
function M.flush()
  flush_to_file()
end

return M
