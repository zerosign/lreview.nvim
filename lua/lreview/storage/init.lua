local config = require("lreview.config")
local schema = require("lreview.storage.schema")

local M = {}

---@type table|nil  -- the sqlite.db instance
M.db = nil

local stmt_mod
local clib
local uv = vim.uv or vim.loop

local gc_work = uv.new_work(function(db_path, lazy_sqlite, age_days)
  if lazy_sqlite and lazy_sqlite ~= "" then
    package.path = package.path .. ";" .. lazy_sqlite .. "/?.lua;" .. lazy_sqlite .. "/?/init.lua"
  end
  local ok, sqlite = pcall(require, "sqlite")
  if not ok then
    return "sqlite not available: " .. tostring(sqlite)
  end
  local db = sqlite.new(db_path)
  if not db then
    return "failed to open sqlite db: " .. tostring(db_path)
  end

  age_days = tonumber(age_days) or 30
  local threshold_sec = os.time() - (age_days * 24 * 60 * 60)
  local date_threshold = os.date("!%Y-%m-%dT%H:%M:%SZ", threshold_sec)

  db:eval("DELETE FROM comments WHERE remote_id IS NOT NULL AND t_id IN (SELECT t.t_id FROM threads t JOIN pull_requests pr ON t.mo_id = pr.mo_id WHERE (t.state & 1) = 0 AND pr.state IN ('merged', 'closed') AND pr.updated_at < ?)", { date_threshold })
  db:eval("DELETE FROM threads WHERE (state & 1) = 0 AND mo_id IN (SELECT mo_id FROM pull_requests WHERE state IN ('merged', 'closed') AND updated_at < ?) AND t_id NOT IN (SELECT DISTINCT t_id FROM comments WHERE remote_id IS NULL)", { date_threshold })
  db:eval("DELETE FROM reviews WHERE mo_id IN (SELECT mo_id FROM pull_requests WHERE state IN ('merged', 'closed') AND updated_at < ?)", { date_threshold })
  db:eval("DELETE FROM pull_requests WHERE state IN ('merged', 'closed') AND updated_at < ? AND mo_id NOT IN (SELECT DISTINCT mo_id FROM threads)", { date_threshold })

  db:close()
  return "success"
end, function(result)
  if result ~= "success" then
    vim.schedule(function()
      vim.notify("lreview background gc error: " .. tostring(result), vim.log.levels.WARN)
    end)
  end
end)

local function ensure_db()
  if not M.db then
    local ok, err = M.open()
    if not ok then
      error("lreview: failed to auto-open database: " .. tostring(err))
    end
  end
  return M.db
end

--- Open (or create) the database and run migrations.
---@param db_path string|nil
---@return boolean ok, string|nil err
function M.open(db_path)
  if M.db then
    return true, nil
  end
  local ok, sqlite = pcall(require, "sqlite")
  if not ok then
    return false, "sqlite.lua not available: " .. tostring(sqlite)
  end

  stmt_mod = require("sqlite.stmt")
  clib = require("sqlite.defs")

  db_path = db_path or config.get_defaults().db_path
  local dir = vim.fn.fnamemodify(db_path, ":h")
  if not uv.fs_stat(dir) then
    uv.fs_mkdir(dir, 448) -- 0700 octal
  end

  -- We must find sqlite.lua dynamically for background sync jobs
  local lazy_sqlite = vim.fn.stdpath("data") .. "/lazy/sqlite.lua/lua"
  if vim.fn.isdirectory(lazy_sqlite) == 1 then
    package.path = package.path .. ";" .. lazy_sqlite .. "/?.lua;" .. lazy_sqlite .. "/?/init.lua"
  end

  local db = sqlite.new(db_path, { keep_open = true })
  if not db then
    return false, "failed to open sqlite db: " .. db_path
  end

  db:eval("PRAGMA journal_mode=WAL;")
  db:eval("PRAGMA synchronous=NORMAL;")
  db:eval("PRAGMA foreign_keys=ON;")
  local timeout = config.get_defaults().db.busy_timeout_ms or 5000
  db:eval("PRAGMA busy_timeout=" .. timeout .. ";")

  M.db = db
  local okm, errm = M.migrate()
  if not okm then
    M.close()
    return false, errm
  end
  local db_cfg = config.get_defaults().db
  if db_cfg.auto_housekeep then
    M.gc(db_cfg.keep_days or 30, false)
  end
  return true, nil
end

--- Close the database.
---@return nil
function M.close()
  if M.db then
    M.db:close()
    M.db = nil
  end
end

--- Get the current schema version from meta.
---@return integer
function M.current_version()
  if not M.db then
    return 0
  end
  local check = M.db:eval("SELECT name FROM sqlite_master WHERE type='table' AND name='meta'")
  if not check or type(check) ~= "table" or not (check[1] or check.name) then
    return 0
  end
  local rows = M.db:eval("SELECT v FROM meta WHERE k = 'schema_version'")
  if type(rows) == "table" and rows[1] then
    return tonumber(rows[1].v) or 0
  elseif type(rows) == "table" and rows.v then
    return tonumber(rows.v) or 0
  end
  return 0
end

--- Run schema migrations (clean slate drop and recreate on version mismatch).
---@return boolean ok, string|nil err
function M.migrate()
  if not M.db then
    return false, "db not open"
  end
  local cur = M.current_version()
  if cur ~= schema.version then
    -- Drop all tables/triggers if any exist to ensure a clean slate
    local tables = {
      "comments", "threads", "pull_requests", "reviews", "repo_users",
      "repo_users_fts", "pull_requests_fts", "meta"
    }
    for _, tbl in ipairs(tables) do
      pcall(function() M.db:execute("DROP TABLE IF EXISTS " .. tbl) end)
    end
    pcall(function() M.db:execute("DROP TRIGGER IF EXISTS repo_users_ai") end)
    pcall(function() M.db:execute("DROP TRIGGER IF EXISTS repo_users_ad") end)
    pcall(function() M.db:execute("DROP TRIGGER IF EXISTS repo_users_au") end)
    pcall(function() M.db:execute("DROP TRIGGER IF EXISTS pull_requests_ai") end)
    pcall(function() M.db:execute("DROP TRIGGER IF EXISTS pull_requests_ad") end)
    pcall(function() M.db:execute("DROP TRIGGER IF EXISTS pull_requests_au") end)

    -- Load base schema from schema.sql located in the same directory.
    local source = debug.getinfo(1).source:match("@(.*)$")
    if source then
      local sql_file = vim.fn.fnamemodify(source, ":h") .. "/schema.sql"
      local f = io.open(sql_file, "r")
      if f then
        local sql = f:read("*a")
        f:close()

        -- Run baseline schema using db:execute (sqlite3_exec) to support multi-statements/triggers
        local ok, err = pcall(function()
          M.db:execute(sql)
        end)
        if not ok then
          return false, "failed to initialize base schema: " .. tostring(err)
        end
        M.db:eval("INSERT OR REPLACE INTO meta (k, v) VALUES ('schema_version', ?)", { tostring(schema.version) })
      else
        return false, "could not find schema.sql at " .. sql_file
      end
    else
      return false, "could not determine source path for schema.sql"
    end
  end
  return true, nil
end

--- Safely bind parameters to statement bypasses buggy sqlite.lua binding loops.
---@param pstmt any  -- sqlite_pstmt FFI pointer
---@param i integer  -- 1-based bind parameter index
---@param val any    -- bind value
local function safe_bind(pstmt, i, val)
  local t = type(val)
  if t == "number" then
    clib.bind_double(pstmt, i, val)
  elseif t == "string" then
    clib.bind_text(pstmt, i, val, #val, nil)
  elseif t == "boolean" then
    clib.bind_double(pstmt, i, val and 1 or 0)
  elseif t == "nil" then
    clib.bind_null(pstmt, i)
  else
    error("lreview: unsupported query parameter type: " .. t)
  end
end

--- Execute a callback within an explicit SQLite transaction.
---@param fn fun(): any
---@return boolean ok, any result_or_err
function M.with_transaction(fn)
  if not M.db then
    return false, "database connection is not open"
  end
  local exec_ok, begin_err = pcall(function() M.db:execute("BEGIN TRANSACTION;") end)
  if not exec_ok then
    return false, begin_err
  end

  local ok, res = pcall(fn)
  if ok then
    pcall(function() M.db:execute("COMMIT;") end)
    return true, res
  else
    pcall(function() M.db:execute("ROLLBACK;") end)
    return false, res
  end
end

--- Execute a parameterized SQL query returning rows.
---@param sql string
---@vararg any  -- positional bind params (nil values allowed)
---@return table[] rows
function M.query(sql, ...)
  ensure_db()
  local stmt = stmt_mod:parse(M.db.conn, sql)
  local n = select("#", ...)
  local params = { ... }
  for i = 1, n do
    safe_bind(stmt.pstmt, i, params[i])
  end
  local rows = {}
  stmt:each(function()
    rows[#rows + 1] = stmt:kv()
  end)
  stmt:finalize()
  return rows
end

--- Execute a statement with params, returning last insert id.
---@param sql string
---@vararg any  -- positional bind params (nil values allowed)
---@return integer|nil last_id
function M.execute(sql, ...)
  ensure_db()
  local stmt = stmt_mod:parse(M.db.conn, sql)
  local n = select("#", ...)
  local params = { ... }
  for i = 1, n do
    safe_bind(stmt.pstmt, i, params[i])
  end
  local code = stmt:step()
  stmt:finalize()
  if code ~= clib.flags.row and code ~= clib.flags.done then
    local err = M.db:status()
    vim.notify("lreview: sqlite execute error (" .. err.code .. "): " .. tostring(err.msg), vim.log.levels.ERROR)
    return nil
  end
  local res = M.db:eval("SELECT last_insert_rowid() AS id")
  if type(res) == "table" then
    if res[1] then
      return res[1].id
    elseif res.id then
      return res.id
    end
  end
  return nil
end

--- Run garbage collection to clean up merged/closed PR comments older than X days.
--- Protects local drafts from deletion.
---@param age_days integer|nil
---@param sync boolean|nil  -- if true, run synchronously on main thread (defaults to false/async)
function M.gc(age_days, sync)
  if sync == nil then sync = false end
  if not sync then
    local db_path = config.get_defaults().db_path
    local lazy_sqlite = vim.fn.stdpath("data") .. "/lazy/sqlite.lua/lua"
    gc_work:queue(db_path, lazy_sqlite, tostring(age_days or 30))
    return
  end

  if not M.db then
    return
  end
  age_days = age_days or 30
  local threshold_sec = os.time() - (age_days * 24 * 60 * 60)
  local date_threshold = os.date("!%Y-%m-%dT%H:%M:%SZ", threshold_sec)

  -- 1. Delete comments belonging to non-draft threads of old merged/closed PRs
  -- Exclude any comments that are local drafts (remote_id IS NULL).
  M.execute([[
    DELETE FROM comments 
    WHERE remote_id IS NOT NULL 
      AND t_id IN (
        SELECT t.t_id FROM threads t
        JOIN pull_requests pr ON t.mo_id = pr.mo_id
        WHERE (t.state & 1) = 0
          AND pr.state IN ('merged', 'closed')
          AND pr.updated_at < ?
      )
  ]], date_threshold)

  -- 2. Delete non-draft threads of old merged/closed PRs
  -- Exclude any threads that contain local draft replies (to prevent orphaned comments).
  M.execute([[
    DELETE FROM threads 
    WHERE (state & 1) = 0 
      AND mo_id IN (
        SELECT mo_id FROM pull_requests
        WHERE state IN ('merged', 'closed')
          AND updated_at < ?
      )
      AND t_id NOT IN (
        SELECT DISTINCT t_id FROM comments WHERE remote_id IS NULL
      )
  ]], date_threshold)

  -- 3. Delete reviews of old merged/closed PRs
  M.execute([[
    DELETE FROM reviews 
    WHERE mo_id IN (
      SELECT mo_id FROM pull_requests
      WHERE state IN ('merged', 'closed')
        AND updated_at < ?
    )
  ]], date_threshold)

  -- 4. Delete old merged/closed PRs
  -- Exclude PRs that still have active threads (which might contain drafts).
  M.execute([[
    DELETE FROM pull_requests
    WHERE state IN ('merged', 'closed')
      AND updated_at < ?
      AND mo_id NOT IN (
        SELECT DISTINCT mo_id FROM threads
      )
  ]], date_threshold)
end

return M
