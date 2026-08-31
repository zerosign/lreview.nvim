local M = {}

local dirty_buffers = {}
local timer = nil
local subscribers = {
  panel = {},
  decor = {},
}

-- In-memory diff cache per (repo_cwd, path) -> changed_lines table
local diff_cache = {}

-- Async worker thread for computing git.changed_lines off the main thread.
-- (Plan doc 12 §3.8 / doc 09 §2.6 — item 7: biggest UI-latency win.)
local diff_worker = nil
-- Pending async requests: key = cwd .. "\0" .. path, value = list of
-- { bufnr, callback } waiting for that path's diff to complete.
local diff_pending = {}

--- Clear or invalidate the diff cache for a given cwd or all cwds.
---@param cwd string|nil
function M.invalidate_diff_cache(cwd)
  if cwd then
    diff_cache[cwd] = nil
  else
    diff_cache = {}
  end
end

--- Return the cached changed-lines for a path WITHOUT computing (cache-only).
--- Returns nil if not cached. Used by decor to decide between sync apply and
--- async kick-off. (item 7)
---@param cwd string
---@param path string
---@return table|nil
function M.get_changed_lines_cached(cwd, path)
  if not cwd or not path or path == "" then return nil end
  diff_cache[cwd] = diff_cache[cwd] or {}
  return diff_cache[cwd][path]
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
  local review
  local ok_review = pcall(function() review = require("lreview.review") end)
  local target_branch = ok_review and review and review.current
    and review.current.detail and review.current.detail.target_branch
  if not target_branch then
    local ok_def, def = pcall(git.default_branch, cwd)
    if not ok_def then
      def = nil
    end
    target_branch = def or "main"
  end
  local ok_lines, lines, lerr = pcall(git.changed_lines, target_branch, path, cwd)
  if not ok_lines then
    lines = nil
  end
  diff_cache[cwd][path] = lines or {}
  return diff_cache[cwd][path]
end

--- Async version of get_changed_lines that runs the git diff on a worker
--- thread. Returns the cached value immediately if available; otherwise
--- kicks off a background thread and refreshes the buffer when done.
--- (item 7 — biggest UI-latency win.)
---@param cwd string
---@param path string
---@param bufnr integer|nil  -- buffer to refresh on completion
---@param callback fun(lines: table)|nil
function M.get_changed_lines_async(cwd, path, bufnr, callback)
  if not cwd or not path or path == "" then
    if callback then callback({}) end
    return {}
  end

  diff_cache[cwd] = diff_cache[cwd] or {}
  -- Cache hit: return synchronously.
  if diff_cache[cwd][path] ~= nil then
    if callback then callback(diff_cache[cwd][path]) end
    return diff_cache[cwd][path]
  end

  -- Cache miss: compute on worker thread.
  local git = require("lreview.git")
  local review = require("lreview.review")
  local target_branch = review.current
    and review.current.detail and review.current.detail.target_branch
  if not target_branch then
    local ok_def, def = pcall(git.default_branch, cwd)
    if not ok_def then def = nil end
    target_branch = def or "main"
  end

  -- Register this request as pending so the worker callback can dispatch to
  -- the correct bufnr/callback (avoids closure-capture of only the first call).
  local key = cwd .. "\0" .. path
  diff_pending[key] = diff_pending[key] or {}
  table.insert(diff_pending[key], { bufnr = bufnr, callback = callback })

  if not diff_worker then
    local thread = require("lreview.thread")
    diff_worker = thread.create_worker("lreview.git", "changed_lines_thread", function(res)
      if not res then return end
      local ok, lines, r_cwd, r_path = res.ok, res.lines, res.cwd, res.path
      if r_cwd and r_path then
        diff_cache[r_cwd] = diff_cache[r_cwd] or {}
        diff_cache[r_cwd][r_path] = (ok and lines) or {}
      end
      -- Dispatch to every request waiting on this (cwd, path).
      local rkey = (r_cwd or "") .. "\0" .. (r_path or "")
      local waiters = diff_pending[rkey]
      diff_pending[rkey] = nil
      if waiters then
        local result = diff_cache[r_cwd] and diff_cache[r_cwd][r_path] or {}
        for _, w in ipairs(waiters) do
          if w.bufnr and vim.api.nvim_buf_is_valid(w.bufnr) then
            vim.schedule(function()
              if vim.api.nvim_buf_is_valid(w.bufnr) then
                require("lreview.ui.decor").refresh(w.bufnr)
              end
            end)
          end
          if w.callback then w.callback(result) end
        end
      end
    end)
  end

  -- Return nil to indicate "not yet available"; the buffer will be refreshed
  -- when the thread completes.
  diff_worker:queue({ cwd = cwd, path = path, target_branch = target_branch })
  return nil
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
