local M = {}

local dirty_buffers = {}
local timer = nil
local subscribers = {
  panel = {},
  decor = {},
}

-- In-memory diff cache per (repo_cwd, path) -> changed_lines table
local diff_cache = {}

--- Clear or invalidate the diff cache for a given cwd or all cwds.
---@param cwd string|nil
function M.invalidate_diff_cache(cwd)
  if cwd then
    diff_cache[cwd] = nil
  else
    diff_cache = {}
  end
end

--- Get changed lines for a file path, utilizing the in-memory diff cache.
---@param cwd string
---@param path string
---@return table|nil
function M.get_changed_lines(cwd, path)
  if not cwd or not path or path == "" then
    return nil
  end

  diff_cache[cwd] = diff_cache[cwd] or {}
  if diff_cache[cwd][path] ~= nil then
    return diff_cache[cwd][path]
  end

  local git = require("lreview.git")
  local lines = git.changed_lines(path, cwd)
  diff_cache[cwd][path] = lines or {}
  return diff_cache[cwd][path]
end

--- Mark a buffer as needing a UI/decor refresh.
---@param bufnr integer
function M.mark_dirty(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    dirty_buffers[bufnr] = true
  end
  M.schedule(80)
end

--- Subscribe a callback function to sync events.
---@param kind "panel"|"decor"
---@param fn fun()
function M.subscribe(kind, fn)
  if subscribers[kind] then
    table.insert(subscribers[kind], fn)
  end
end

--- Schedule a debounced flush.
---@param delay_ms integer|nil
function M.schedule(delay_ms)
  delay_ms = delay_ms or 80
  local uv = vim.uv or vim.loop
  if not timer then
    timer = uv.new_timer()
  end
  if timer then
    timer:stop()
    timer:start(delay_ms, 0, function()
      vim.schedule(function()
        M.flush()
      end)
    end)
  else
    M.flush()
  end
end

--- Perform the debounced flush: refresh dirty buffers and notify subscribers.
function M.flush()
  local decor = require("lreview.ui.decor")

  -- 1. Refresh dirty buffers
  for bufnr, _ in pairs(dirty_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      decor.refresh(bufnr)
    end
  end
  dirty_buffers = {}

  -- 2. Notify subscribers (summary panel, thread view)
  for _, fn in ipairs(subscribers.panel) do
    pcall(fn)
  end
  for _, fn in ipairs(subscribers.decor) do
    pcall(fn)
  end
end

return M
