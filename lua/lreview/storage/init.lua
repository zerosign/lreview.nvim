---@meta

-- Storage layer: SQLite (sqlite.lua FFI wrapper) connection + migrations.

local config = require("lreview.config")
local schema = require("lreview.storage.schema")

local M = {}

---@type table|nil  -- the sqlite.db instance
M.db = nil

local stmt_mod
local clib

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
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
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
  M.gc(30)
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

--- Run schema migrations.
---@return boolean ok, string|nil err
function M.migrate()
  if not M.db then
    return false, "db not open"
  end
  local cur = M.current_version()
  if cur == 0 then
    -- Load base schema from schema.sql located in the same directory.
    local source = debug.getinfo(1).source:match("@(.*)$")
    if source then
      local sql_file = vim.fn.fnamemodify(source, ":h") .. "/schema.sql"
      local f = io.open(sql_file, "r")
      if f then
        local sql = f:read("*a")
        f:close()
        -- Split by semicolon and execute statements sequentially
        for stmt in sql:gmatch("[^;]+") do
          local trimmed = vim.trim(stmt)
          if trimmed ~= "" then
            local ok, err = M.db:eval(trimmed)
            if not ok then
              return false, "failed to initialize base schema statement: " .. trimmed .. " | Error: " .. tostring(M.db:status().msg)
            end
          end
        end
        local cur_row = nil
        local rows = M.db:eval("SELECT v FROM meta WHERE k = 'schema_version'")
        if type(rows) == "table" then
          if rows[1] then
            cur_row = rows[1]
          elseif rows.v then
            cur_row = rows
          end
        end
        if cur_row then
          cur = tonumber(cur_row.v) or 4
        else
          cur = 4
        end
      else
        return false, "could not find schema.sql at " .. sql_file
      end
    else
      return false, "could not determine source path for schema.sql"
    end
  end

  for v = cur + 1, schema.version do
    local sql = schema.migrations[v]
    if sql then
      -- Split migration scripts by semicolon and execute sequentially
      for stmt in sql:gmatch("[^;]+") do
        local trimmed = vim.trim(stmt)
        if trimmed ~= "" then
          local ok, err = M.db:eval(trimmed)
          if not ok then
            return false, "migration " .. v .. " failed on statement: " .. trimmed .. " | Error: " .. tostring(M.db:status().msg)
          end
        end
      end
      M.db:eval("INSERT OR REPLACE INTO meta (k, v) VALUES ('schema_version', ?)", { tostring(v) })
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

--- Execute a statement with params, returning rows.
---@param sql string
---@vararg any  -- positional bind params (nil values allowed)
---@return table[] rows
function M.query(sql, ...)
  if not M.db then
    return {}
  end
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
  if not M.db then
    return nil
  end
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
function M.gc(age_days)
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
        WHERE t.is_draft = 0
          AND pr.state IN ('merged', 'closed')
          AND pr.updated_at < ?
      )
  ]], date_threshold)

  -- 2. Delete non-draft threads of old merged/closed PRs
  -- Exclude any threads that contain local draft replies (to prevent orphaned comments).
  M.execute([[
    DELETE FROM threads 
    WHERE is_draft = 0 
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
