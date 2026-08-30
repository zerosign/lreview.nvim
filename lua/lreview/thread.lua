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
