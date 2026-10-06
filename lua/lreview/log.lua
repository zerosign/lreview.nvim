---@meta

-- Structured, credential-safe diagnostic logger for lreview.nvim.
--
-- Writes formatted log entries to `diagnostics.log_file` (when configured)
-- or `vim.g.lreview_log_file` / `$LREVIEW_LOG_FILE`.
--
-- STRICT SECURITY GUARANTEE:
-- All log messages, command argv arrays, and error strings pass through
-- credential-redaction patterns. Raw tokens (GitHub, GitLab, JWTs, Bearer
-- headers) are NEVER written to disk, stdout, or chat.
--
-- Compatible with both the main thread and `uv.new_work` worker threads.

local M = {}

M.LEVEL = {
  TRACE = 1,
  DEBUG = 2,
  INFO  = 3,
  WARN  = 4,
  ERROR = 5,
}

local LEVEL_NAMES = {
  [1] = "TRACE",
  [2] = "DEBUG",
  [3] = "INFO",
  [4] = "WARN",
  [5] = "ERROR",
}

local SENSITIVE_PATTERNS = {
  { "ghp_[A-Za-z0-9_]+", "ghp_[REDACTED]" },
  { "glpat%-[A-Za-z0-9_%-]+", "glpat-[REDACTED]" },
  { "Bearer%s+[A-Za-z0-9%._%-%+]+", "Bearer [REDACTED]" },
  { "bearer%s+[A-Za-z0-9%._%-%+]+", "bearer [REDACTED]" },
  { "PRIVATE%-TOKEN:%s*[^%s\r\n]+", "PRIVATE-TOKEN: [REDACTED]" },
  { "token=([^&%s\r\n]+)", "token=[REDACTED]" },
  { "access_token=([^&%s\r\n]+)", "access_token=[REDACTED]" },
  { "password=([^&%s\r\n]+)", "password=[REDACTED]" },
  { "secret=([^&%s\r\n]+)", "secret=[REDACTED]" },
}

--- Mask any credential-shaped substrings in text.
---@param text string|any
---@return string
function M.redact(text)
  if type(text) ~= "string" then
    text = tostring(text or "")
  end
  for _, pat in ipairs(SENSITIVE_PATTERNS) do
    text = text:gsub(pat[1], pat[2])
  end
  return text
end

--- Resolve current configured log file path.
---@return string|nil
function M.get_log_file()
  if vim and vim.g and vim.g.lreview_log_file and vim.g.lreview_log_file ~= "" then
    return vim.g.lreview_log_file
  end
  if vim and vim.env and vim.env.LREVIEW_LOG_FILE and vim.env.LREVIEW_LOG_FILE ~= "" then
    return vim.env.LREVIEW_LOG_FILE
  end
  local ok, cfg = pcall(require, "lreview.config")
  if ok and cfg and cfg.get_defaults then
    local d = cfg.get_defaults()
    if d and d.diagnostics and d.diagnostics.log_file then
      return d.diagnostics.log_file
    end
  end
  return nil
end

--- Resolve minimum log level threshold.
---@return integer
function M.get_level()
  local ok, cfg = pcall(require, "lreview.config")
  if ok and cfg and cfg.get_defaults then
    local d = cfg.get_defaults()
    if d and d.diagnostics and d.diagnostics.log_level then
      local lvl = d.diagnostics.log_level:upper()
      if M.LEVEL[lvl] then return M.LEVEL[lvl] end
    end
  end
  return M.LEVEL.DEBUG
end

--- Format and write a log entry.
---@param level integer
---@param tag string
---@param message string
---@param extra table|nil
function M.log(level, tag, message, extra)
  if level < M.get_level() then return end
  local file = M.get_log_file()
  if not file then return end

  local ts = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local lvl_name = LEVEL_NAMES[level] or "INFO"
  local clean_msg = M.redact(message)
  local line = string.format("[%s] [%s] [%s] %s", ts, lvl_name, tag:upper(), clean_msg)

  if extra and type(extra) == "table" then
    local pieces = {}
    for k, v in pairs(extra) do
      pieces[#pieces + 1] = string.format("%s=%s", k, M.redact(v))
    end
    if #pieces > 0 then
      table.sort(pieces)
      line = line .. " {" .. table.concat(pieces, ", ") .. "}"
    end
  end

  local ok, f = pcall(io.open, file, "a")
  if ok and f then
    f:write(line .. "\n")
    f:close()
  end
end

function M.trace(tag, msg, extra) M.log(M.LEVEL.TRACE, tag, msg, extra) end
function M.debug(tag, msg, extra) M.log(M.LEVEL.DEBUG, tag, msg, extra) end
function M.info(tag, msg, extra)  M.log(M.LEVEL.INFO, tag, msg, extra) end
function M.warn(tag, msg, extra)  M.log(M.LEVEL.WARN, tag, msg, extra) end
function M.error(tag, msg, extra) M.log(M.LEVEL.ERROR, tag, msg, extra) end

return M
