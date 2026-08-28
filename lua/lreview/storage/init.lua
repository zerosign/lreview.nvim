---@meta

-- Storage layer: SQLite (lsqlite3) connection + migrations.

local config = require("lreview.config")
local schema = require("lreview.storage.schema")

local M = {}

---@type table|nil  -- the open lsqlite3 db handle
M.db = nil

--- Open (or create) the database and run migrations.
---@param db_path string|nil
---@return boolean ok, string|nil err
function M.open(db_path)
  if M.db then
    return true, nil
  end
  local ok, lsqlite3 = pcall(require, "lsqlite3")
  if not ok then
    return false, "lsqlite3 not available: " .. tostring(lsqlite3)
  end

  db_path = db_path or config.get_defaults().db_path
  local dir = vim.fn.fnamemodify(db_path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end

  local db = lsqlite3.open(db_path)
  if not db then
    return false, "failed to open sqlite db: " .. db_path
  end
  db:busy_timeout(config.get_defaults().db.busy_timeout_ms or 5000)
  db:exec("PRAGMA journal_mode=WAL;")
  db:exec("PRAGMA synchronous=NORMAL;")
  db:exec("PRAGMA foreign_keys=ON;")

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
  local stmt = M.db:prepare("SELECT v FROM meta WHERE k = 'schema_version'")
  if not stmt then
    return 0
  end
  local ok = stmt:step()
  local v = 0
  -- SQLITE_ROW (100) means a row was returned; SQLITE_DONE (101) means no row.
  if ok == 100 then
    v = tonumber(stmt:get_value(0)) or 0
  end
  stmt:finalize()
  return v
end

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
        local ok, err = M.db:exec(sql)
        if ok ~= 0 then
          return false, "failed to initialize base schema: " .. tostring(err)
        end
        local cur_row = nil
        for row in M.db:nrows("SELECT v FROM meta WHERE k = 'schema_version'") do
          cur_row = row
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
      local ok, err = M.db:exec(sql)
      if ok ~= 0 then
        return false, "migration " .. v .. " failed: " .. tostring(err)
      end
      M.db:exec("INSERT OR REPLACE INTO meta (k, v) VALUES ('schema_version', '" .. v .. "')")
    end
  end
  return true, nil
end

--- Execute a statement with params, returning rows.
---@param sql string
---@vararg any  -- positional bind params (nil values allowed)
---@return table[] rows
function M.query(sql, ...)
  if not M.db then
    return {}
  end
  local stmt = M.db:prepare(sql)
  if not stmt then
    return {}
  end
  -- select('#', ...) gives the true arg count even when params contain nil
  -- values; a plain `#params` would stop at the first nil hole. Indexing
  -- params[i] for i up to n returns nil for holes, which binds NULL.
  local n = select("#", ...)
  local params = { ... }
  for i = 1, n do
    stmt:bind(i, params[i])
  end
  local rows = {}
  for row in stmt:nrows() do
    rows[#rows + 1] = row
  end
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
  local stmt = M.db:prepare(sql)
  if not stmt then
    return nil
  end
  local n = select("#", ...)
  local params = { ... }
  for i = 1, n do
    stmt:bind(i, params[i])
  end
  local ok, err = stmt:step()
  stmt:finalize()
  if ok ~= 0 and ok ~= 101 then
    vim.notify("lreview: sqlite step error: " .. tostring(err), vim.log.levels.ERROR)
    return nil
  end
  return M.db:last_insert_rowid()
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
