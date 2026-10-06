---@meta

-- CRUD for the issues + issue_notes tables (offline issue index).
--
-- Issues are the correlation target of an MR description ("fixes #123",
-- "!45", a linked issue): with the list cached locally, resolving what a change
-- is *about* costs one indexed query instead of a round trip.
--
-- Query shapes this layer serves, and the index that backs each:
--   list()/count() by repo+state, newest number first  -> idx_issues_repo
--   by_number()                                        -> PRIMARY KEY (issue_id)
--   search() >=3 chars                                 -> issues_fts (trigram)
--   search() <3 chars (trigram needs 3)                -> idx_issues_repo scan
--   notes_for(issue_id) oldest first                   -> idx_issue_notes_issue

local storage = require("lreview.storage")
local model = require("lreview.model")
local mpack = vim.mpack
local unpack = table.unpack or unpack

local M = {}

local function decode_issue(row)
  if not row then return nil end
  local payload = row.payload and mpack.decode(row.payload) or {}
  row.payload = nil
  for k, v in pairs(payload) do row[k] = v end
  return row
end

local function decode_note(row)
  if not row then return nil end
  local payload = row.payload and mpack.decode(row.payload) or {}
  row.payload = nil
  for k, v in pairs(payload) do row[k] = v end
  row.system = (row.system or 0) == 1
  return row
end

--- Canonical issue_id for a repo + number.
---@param provider string
---@param repo string
---@param number integer|string
---@return string
function M.issue_id(provider, repo, number)
  return model.issue_id(provider, repo, number)
end

--- Upsert one issue row.
---@param i lreview.Issue
function M.upsert(i)
  local payload = {
    assignees = i.assignees,
    milestone = i.milestone,
  }
  storage.execute([[
    INSERT OR REPLACE INTO issues
      (issue_id, provider, repo, number, title, body, state, author, labels,
       url, comment_count, closed_at, updated_at, payload)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]], i.issue_id, i.provider, i.repo, i.number, i.title, i.body, i.state,
      i.author, i.labels, i.url, i.comment_count, i.closed_at, i.updated_at,
      mpack.encode(payload))
end

--- Upsert a page of issues in one transaction (called per fetched page).
---@param list lreview.Issue[]
---@return integer written, string|nil err
function M.upsert_many(list)
  if not list or #list == 0 then return 0, nil end
  local n = 0
  local ok, err = storage.with_transaction(function()
    for _, i in ipairs(list) do
      M.upsert(i)
      n = n + 1
    end
  end)
  if not ok then return 0, tostring(err) end
  return n, nil
end

--- Replace the cached notes for one issue (delete + insert in one txn, so a
--- half-written note list is never visible).
---@param issue_id string
---@param notes lreview.IssueNote[]
---@return integer written, string|nil err
function M.replace_notes(issue_id, notes)
  local n = 0
  local ok, err = storage.with_transaction(function()
    storage.execute("DELETE FROM issue_notes WHERE issue_id = ?", issue_id)
    for _, note in ipairs(notes or {}) do
      storage.execute([[
        INSERT OR REPLACE INTO issue_notes
          (note_id, issue_id, remote_id, author, created_at, body, system, payload)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ]], note.note_id, issue_id, note.remote_id, note.author, note.created_at,
          note.body, note.system and 1 or 0, mpack.encode({ updated_at = note.updated_at }))
      n = n + 1
    end
  end)
  if not ok then return 0, tostring(err) end
  return n, nil
end

---@param issue_id string
---@return lreview.Issue|nil
function M.get(issue_id)
  local rows = storage.query("SELECT * FROM issues WHERE issue_id = ?", issue_id)
  return decode_issue(rows[1])
end

--- Indexed PK lookup by repo + number.
---@param provider string
---@param repo string
---@param number integer|string
---@return lreview.Issue|nil
function M.by_number(provider, repo, number)
  return M.get(M.issue_id(provider, repo, number))
end

--- Issues for one repo, optionally filtered by state.
---@param provider string
---@param repo string
---@param opts table|nil  -- { state = "open"|"closed"|nil, limit = n }
---@return table[]
function M.list(provider, repo, opts)
  opts = opts or {}
  local sql, params
  if opts.state and opts.state ~= "" and opts.state ~= "all" then
    sql = [[
      SELECT * FROM issues WHERE provider = ? AND repo = ? AND state = ?
      ORDER BY number DESC LIMIT ?
    ]]
    params = { provider, repo, opts.state, opts.limit or 500 }
  else
    sql = [[
      SELECT * FROM issues WHERE provider = ? AND repo = ?
      ORDER BY number DESC LIMIT ?
    ]]
    params = { provider, repo, opts.limit or 500 }
  end
  local rows = storage.query(sql, unpack(params))
  for i, r in ipairs(rows) do rows[i] = decode_issue(r) end
  return rows
end

--- Cached note count for a repo+state (drives the staleness decision).
---@param provider string
---@param repo string
---@param state string|nil
---@return integer
function M.count(provider, repo, state)
  if state and state ~= "" and state ~= "all" then
    local rows = storage.query(
      "SELECT COUNT(*) AS n FROM issues WHERE provider = ? AND repo = ? AND state = ?",
      provider, repo, state)
    return (rows[1] and rows[1].n) or 0
  end
  local rows = storage.query(
    "SELECT COUNT(*) AS n FROM issues WHERE provider = ? AND repo = ?", provider, repo)
  return (rows[1] and rows[1].n) or 0
end

--- Notes for one issue, oldest first. System events excluded unless asked.
---@param issue_id string
---@param opts table|nil  -- { include_system = boolean }
---@return table[]
function M.notes_for(issue_id, opts)
  opts = opts or {}
  local sql, params
  if opts.include_system then
    sql = "SELECT * FROM issue_notes WHERE issue_id = ? ORDER BY created_at ASC"
    params = { issue_id }
  else
    sql = "SELECT * FROM issue_notes WHERE issue_id = ? AND system = 0 ORDER BY created_at ASC"
    params = { issue_id }
  end
  local rows = storage.query(sql, unpack(params))
  for i, r in ipairs(rows) do rows[i] = decode_note(r) end
  return rows
end

--- Escape a string for use inside an FTS5 phrase query (doubles quotes).
---@param q string
---@return string
local function fts_phrase(q)
  return '"' .. q:gsub('"', '""') .. '"'
end

--- Search cached issues by number/title/body substring.
---
--- The trigram tokenizer needs >=3 characters; shorter queries (typical when
--- typing a number like "4") fall back to an indexed scan of the repo's rows.
---@param provider string
---@param repo string
---@param query string|nil
---@param opts table|nil  -- { state, limit }
---@return table[]
function M.search(provider, repo, query, opts)
  opts = opts or {}
  if not query or query == "" then
    return M.list(provider, repo, { state = opts.state, limit = opts.limit })
  end

  local q = query:lower()
  local rows
  if #q >= 3 then
    rows = storage.query([[
      SELECT i.*
      FROM issues_fts f
      JOIN issues i ON i.rowid = f.rowid
      WHERE issues_fts MATCH ? AND i.provider = ? AND i.repo = ?
      ORDER BY i.number DESC LIMIT ?
    ]], fts_phrase(q), provider, repo, opts.limit or 200)
  else
    rows = storage.query([[
      SELECT * FROM issues WHERE provider = ? AND repo = ?
      ORDER BY number DESC LIMIT ?
    ]], provider, repo, opts.limit or 500)
    rows = vim.iter(rows):filter(function(r)
      return tostring(r.number):find(q, 1, true)
          or ((r.title or ""):lower():find(q, 1, true)) ~= nil
    end):totable()
  end
  for i, r in ipairs(rows) do rows[i] = decode_issue(r) end

  if opts.state and opts.state ~= "" and opts.state ~= "all" then
    rows = vim.iter(rows):filter(function(r) return r.state == opts.state end):totable()
  end
  return rows
end

--- Delete an issue and its notes.
---@param issue_id string
function M.delete(issue_id)
  storage.execute("DELETE FROM issue_notes WHERE issue_id = ?", issue_id)
  storage.execute("DELETE FROM issues WHERE issue_id = ?", issue_id)
end

-- ---------------------------------------------------------------------------
-- Staleness (meta KV: `k` is the primary key, so no index is needed)
-- ---------------------------------------------------------------------------

---@param provider string
---@param repo string
---@param state string|nil
---@return string  -- meta key
local function sync_key(provider, repo, state)
  return "issues_synced_at:" .. provider .. ":" .. repo .. ":" .. (state or "open")
end

--- When was this repo's issue list last pulled (unix seconds) or nil.
---@param provider string
---@param repo string
---@param state string|nil
---@return integer|nil
function M.get_synced_at(provider, repo, state)
  local raw = storage.kv_get(sync_key(provider, repo, state))
  return raw and tonumber(raw) or nil
end

---@param provider string
---@param repo string
---@param state string|nil
function M.mark_synced(provider, repo, state)
  storage.kv_set(sync_key(provider, repo, state), tostring(os.time()))
end

--- Is the cached list missing or older than `max_age_min` minutes?
---@param provider string
---@param repo string
---@param state string|nil
---@param max_age_min integer
---@return boolean
function M.is_stale(provider, repo, state, max_age_min)
  if M.count(provider, repo, state) == 0 then return true end
  local at = M.get_synced_at(provider, repo, state)
  if not at then return true end
  return (os.time() - at) > (max_age_min * 60)
end

return M
