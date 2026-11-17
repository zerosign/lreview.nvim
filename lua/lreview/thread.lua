local config = require("lreview.config")

local M = {}

--- Test worker function exposed for unit testing thread execution
function M.test_worker(db_path, lazy_sqlite, args)
  return {
    ok = true,
    echo_args = args,
    computed = (args and args.val or 0) * 2,
  }
end

--- Test worker that simulates collecting notifications (item 1 test helper).
--- Simulates what sync_review_thread does: collect notify calls into a list
--- and return them in the payload.
function M.test_worker_notify(db_path, lazy_sqlite, args)
  -- Simulate thread_mode notifications (like review.sync_review does)
  local notifications = {
    { msg = "notify-test-1", level = 1 },
    { msg = "notify-test-2", level = 2 },
  }
  return {
    ok = true,
    notifications = notifications,
  }
end

--- ---------------------------------------------------------------------------
--- Per-call completion callbacks for cached workers
--- ---------------------------------------------------------------------------
-- `uv.new_work` workers are module-level singletons: their completion closure
-- is built once, so a closure that captures a per-call `callback` argument
-- forever re-invokes the FIRST call's callback (wrong count / stale notify).
-- The callback therefore lives here, outside the closure.
--
-- libuv's thread pool runs one job per worker at a time and fires exactly one
-- completion per queued job, in queue order — so a FIFO of callbacks pairs
-- correctly with results, including when a caller queues two jobs back to back.
local callback_queue = {}
local MAX_ARMED = 64

--- Arm a callback for the next result of the worker keyed by `key`.
---@param key string  -- worker identity, e.g. "review.submit"
---@param cb fun(...)|nil
function M.arm(key, cb)
  if type(cb) ~= "function" then return end
  local q = callback_queue[key]
  if not q then
    q = {}
    callback_queue[key] = q
  end
  q[#q + 1] = cb
  -- Bound the queue: if completions never fire (no uv.new_work, killed job),
  -- never grow without limit.
  while #q > MAX_ARMED do table.remove(q, 1) end
end

--- Pop the oldest armed callback for `key`, or nil when none is armed.
---@param key string
---@return fun(...)|nil
function M.pop_cb(key)
  local q = callback_queue[key]
  if not q or #q == 0 then return nil end
  return table.remove(q, 1)
end

--- Pop and invoke the oldest armed callback for `key`.
---@param key string
---@param ... any
---@return boolean fired
function M.dispatch_cb(key, ...)
  local cb = M.pop_cb(key)
  if not cb then return false end
  cb(...)
  return true
end

local action_workers = {}

--- Run an asynchronous worker task with automatic singleton worker caching and
--- per-call callback queueing.
---@param key string  -- e.g. "review.close"
---@param target_module string
---@param target_fn string
---@param payload table
---@param callback fun(...)|nil
---@param on_result (fun(res: table)|nil)  -- optional hook run on main thread before callback
function M.run_task(key, target_module, target_fn, payload, callback, on_result)
  local worker = action_workers[key]
  if not worker then
    worker = M.create_worker(target_module, target_fn, function(res)
      if on_result then
        pcall(on_result, res)
      end
      M.dispatch_cb(key, res and res.ok, res and res.err or nil, res)
    end)
    action_workers[key] = worker
  end

  M.arm(key, callback)
  worker:queue(payload)
end

--- Worker-thread helper: bootstrap SQLite on the worker thread, attach to storage,
--- invoke `fn(db)`, and ensure the connection is closed cleanly.
---@param db_path string
---@param lazy_sqlite string
---@param fn fun(db: table): table
---@return table
function M.with_worker_db(db_path, lazy_sqlite, fn)
  local sqlite = require("sqlite")
  local db = sqlite.new(db_path, { keep_open = true })
  db:eval("PRAGMA journal_mode=WAL;")
  db:eval("PRAGMA busy_timeout=5000;")
  local storage = require("lreview.storage")
  storage.attach_db(db)
  local ok, res = pcall(fn, db)
  db:close()
  if not ok then
    return { ok = false, err = tostring(res) }
  end
  return res or { ok = true }
end

--- Create a thread worker wrapper that handles environment bootstrap,
--- dynamic module resolution on the worker thread, MessagePack serialization,
--- and scheduled callback dispatch.
---@param target_module string  -- e.g. "lreview.review"
---@param target_fn string      -- e.g. "sync_review_thread"
---@param callback_fn fun(payload: table)|nil
---@return table worker_object
function M.create_worker(target_module, target_fn, callback_fn)
  local uv = vim.uv or vim.loop
  if not uv or not uv.new_work then
    return {
      queue = function() end
    }
  end

  local work = uv.new_work(function(db_path, lazy_sqlite, plugin_lua_path, mod_name, fn_name, payload_raw)
    -- 1. Bootstrap thread environment
    rawset(vim, "g", {})

    if plugin_lua_path and plugin_lua_path ~= "" then
      package.path = package.path .. ";" .. plugin_lua_path .. "/?.lua;" .. plugin_lua_path .. "/?/init.lua"
    end
    if lazy_sqlite and lazy_sqlite ~= "" then
      package.path = package.path .. ";" .. lazy_sqlite .. "/?.lua;" .. lazy_sqlite .. "/?/init.lua"
    end

    -- 2. Decode payload arguments
    local args = nil
    if payload_raw and payload_raw ~= "" then
      local ok, decoded = pcall(vim.mpack.decode, payload_raw)
      if ok then
        args = decoded
      end
    end

    -- 3. Require target module dynamically on the worker thread
    local fn = nil
    local mod = nil
    if mod_name and mod_name ~= "" then
      local ok_mod, res_mod = pcall(require, mod_name)
      if ok_mod and type(res_mod) == "table" then
        mod = res_mod
        fn = mod[fn_name]
      end
    end

    if type(fn) ~= "function" then
      return vim.mpack.encode({ ok = false, err = "function " .. tostring(fn_name) .. " not found in module " .. tostring(mod_name) })
    end

    -- 4. Execute target function
    local ok_res, res = pcall(fn, db_path, lazy_sqlite, args)
    if not ok_res then
      return vim.mpack.encode({ ok = false, err = tostring(res) })
    end

    -- 5. Encode result
    if type(res) == "table" then
      return vim.mpack.encode(res)
    else
      return vim.mpack.encode({ ok = true, result = res })
    end
  end, function(result_raw)
    -- 6. Escape fast event context using vim.schedule
    vim.schedule(function()
      local payload = nil
      if result_raw and result_raw ~= "" then
        local ok, decoded = pcall(vim.mpack.decode, result_raw)
        if ok then
          payload = decoded
        end
      end
      if callback_fn then
        callback_fn(payload)
      end
    end)
  end)

  return {
    queue = function(self, payload_table)
      local db_path = config.get_defaults().db_path
      local lazy_sqlite = vim.fn.stdpath("data") .. "/lazy/sqlite.lua/lua"
      local source_file = debug.getinfo(1, "S").source:sub(2)
      local plugin_lua_path = vim.fn.fnamemodify(source_file, ":p:h:h")

      local payload_raw = ""
      if payload_table ~= nil then
        payload_raw = vim.mpack.encode(payload_table)
      end
      work:queue(db_path, lazy_sqlite, plugin_lua_path, target_module, target_fn, payload_raw)
    end
  }
end

return M
