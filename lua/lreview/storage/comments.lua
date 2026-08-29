---@meta

-- CRUD for threads + comments.
--
-- The primary offline use case is the per-buffer query: "what threads/comments
-- exist in the current buffer for this file and line range?" This is served by
-- idx_threads_buffer (mo_id, path, line_start, line_end).

local storage = require("lreview.storage")
local unpack = table.unpack or unpack
local mpack = vim.mpack
local bit = require("bit")

local M = {}

-- ---------------------------------------------------------------------------
-- Thread States (Bit Flags)
-- ---------------------------------------------------------------------------
local THREAD_STATE = {
  DRAFT    = 1, -- (0001) New local draft thread
  SYNCED   = 2, -- (0010) Thread synced from remote server
  RESOLVED = 4, -- (0100) Thread is resolved
}
M.THREAD_STATE = THREAD_STATE

-- ---------------------------------------------------------------------------
-- Comment States (Bit Flags)
-- ---------------------------------------------------------------------------
local STATE = {
  DRAFT    = 1, -- (0001) New local reply
  SYNCED   = 2, -- (0010) Clean comment matching remote
  MODIFIED = 4, -- (0100) Synced comment edited locally
  DELETED  = 8, -- (1000) Synced comment deleted locally
}
M.STATE = STATE

-- ---------------------------------------------------------------------------
-- Decoders for Compatibility
-- ---------------------------------------------------------------------------
local function decode_thread(row)
  if not row then return nil end
  local payload = row.payload and mpack.decode(row.payload) or {}
  row.payload = nil
  for k, v in pairs(payload) do
    row[k] = v
  end
  row.start_line = row.line_start
  row.end_line = row.line_end
  row.is_draft = bit.band(row.state, THREAD_STATE.DRAFT) > 0 and 1 or 0
  row.resolved = bit.band(row.state, THREAD_STATE.RESOLVED) > 0 and 1 or 0
  return row
end

local function decode_comment(row)
  if not row then return nil end
  local payload = row.payload and mpack.decode(row.payload) or {}
  row.payload = nil
  for k, v in pairs(payload) do
    row[k] = v
  end
  row.dirty = (row.state == STATE.MODIFIED) and 1 or 0
  row.deleted = (row.state == STATE.DELETED) and 1 or 0
  return row
end

-- ---------------------------------------------------------------------------
-- Threads CRUD
-- ---------------------------------------------------------------------------

--- Create a thread (draft by default).
---@param t lreview.Thread
---@return string t_id
function M.create_thread(t)
  local state_val = t.state
  if not state_val then
    state_val = 0
    if t.is_draft == 1 or t.is_draft == true then
      state_val = bit.bor(state_val, THREAD_STATE.DRAFT)
    else
      state_val = bit.bor(state_val, THREAD_STATE.SYNCED)
    end
    if t.resolved == 1 or t.resolved == true then
      state_val = bit.bor(state_val, THREAD_STATE.RESOLVED)
    end
  end

  local payload = {
    commit_sha = t.commit_sha,
    last_synced_at = t.last_synced_at,
  }

  storage.execute([[
    INSERT OR REPLACE INTO threads
      (t_id, mo_id, path, line_start, line_end, state, payload)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  ]],
    t.t_id, t.mo_id, t.path, t.start_line or t.line_start, t.end_line or t.line_end,
    state_val, mpack.encode(payload))
  return t.t_id
end

--- Get a thread by id.
---@param t_id string
---@return table|nil
function M.get_thread(t_id)
  local rows = storage.query("SELECT * FROM threads WHERE t_id = ?", t_id)
  return decode_thread(rows[1])
end

--- Per-buffer query: threads for a file+line range in an MR.
---@param mo_id string
---@param path string
---@param line integer|nil  -- if given, threads whose range covers this line
---@return table[]
function M.threads_for_buffer(mo_id, path, line)
  local sql = "SELECT * FROM threads WHERE mo_id = ? AND path = ?"
  local params = { mo_id, path }
  if line then
    sql = sql .. " AND line_start <= ? AND line_end >= ?"
    params[#params + 1] = line
    params[#params + 1] = line
  end
  sql = sql .. " ORDER BY line_start"
  local rows = storage.query(sql, unpack(params))
  for i, r in ipairs(rows) do
    rows[i] = decode_thread(r)
  end
  return rows
end

--- List all threads for an MR.
---@param mo_id string
---@return table[]
function M.threads_for_mr(mo_id)
  local rows = storage.query("SELECT * FROM threads WHERE mo_id = ? ORDER BY line_start", mo_id)
  for i, r in ipairs(rows) do
    rows[i] = decode_thread(r)
  end
  return rows
end

--- List draft threads for an MR.
---@param mo_id string
---@return table[]
function M.draft_threads(mo_id)
  local rows = storage.query("SELECT * FROM threads WHERE mo_id = ? AND (state & ?) > 0", mo_id, THREAD_STATE.DRAFT)
  for i, r in ipairs(rows) do
    rows[i] = decode_thread(r)
  end
  return rows
end

--- Mark a thread as synced (is_draft = 0).
---@param t_id string
function M.mark_synced(t_id)
  local t = M.get_thread(t_id)
  if t then
    local new_state = bit.bor(bit.bxor(t.state, THREAD_STATE.DRAFT), THREAD_STATE.SYNCED)
    local payload = {
      commit_sha = t.commit_sha,
      last_synced_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    storage.execute(
      "UPDATE threads SET state = ?, payload = ? WHERE t_id = ?",
      new_state, mpack.encode(payload), t_id
    )
  end
end

--- Delete a thread and its comments.
---@param t_id string
function M.delete_thread(t_id)
  storage.execute("DELETE FROM comments WHERE t_id = ?", t_id)
  storage.execute("DELETE FROM threads WHERE t_id = ?", t_id)
end

--- Resolve or unresolve a thread.
---@param t_id string
---@param resolved_val boolean
function M.resolve_thread(t_id, resolved_val)
  local t = M.get_thread(t_id)
  if t then
    local new_state = t.state
    if resolved_val then
      new_state = bit.bor(new_state, THREAD_STATE.RESOLVED)
    else
      new_state = bit.band(new_state, bit.bnot(THREAD_STATE.RESOLVED))
    end
    storage.execute("UPDATE threads SET state = ? WHERE t_id = ?", new_state, t_id)
  end
end

-- ---------------------------------------------------------------------------
-- Comments CRUD
-- ---------------------------------------------------------------------------

--- Add a comment to a thread.
---@param c lreview.Comment
function M.add_comment(c)
  local state_val = c.state
  if not state_val then
    if c.deleted == 1 or c.deleted == true then
      state_val = STATE.DELETED
    elseif c.dirty == 1 or c.dirty == true then
      state_val = STATE.MODIFIED
    elseif c.remote_id and c.remote_id ~= "" then
      state_val = STATE.SYNCED
    else
      state_val = STATE.DRAFT
    end
  end

  local payload = {
    author = c.author,
    body = c.body,
    created_at = c.created_at,
    in_reply_to = c.in_reply_to,
  }

  storage.execute([[
    INSERT OR REPLACE INTO comments (c_id, t_id, remote_id, state, payload)
    VALUES (?, ?, ?, ?, ?)
  ]], c.c_id, c.t_id, c.remote_id, state_val, mpack.encode(payload))
end

--- Get comments for a thread (excludes pending deletes).
---@param t_id string
---@return table[]
function M.comments_for_thread(t_id)
  local rows = storage.query("SELECT * FROM comments WHERE t_id = ? AND state != ? ORDER BY rowid", t_id, STATE.DELETED)
  for i, r in ipairs(rows) do
    rows[i] = decode_comment(r)
  end
  return rows
end

--- Update a comment body.
---@param c_id string
---@param body string
function M.update_comment(c_id, body)
  local c = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if c then
    local decoded = decode_comment(c)
    decoded.body = body
    M.add_comment(decoded)
  end
end

--- Update a comment body and state.
---@param c_id string
---@param body string
---@param state integer
function M.update_comment_body_and_state(c_id, body, state)
  local c = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if c then
    local decoded = decode_comment(c)
    decoded.body = body
    decoded.state = state
    M.add_comment(decoded)
  end
end

--- Mark a comment as clean synced.
---@param c_id string
---@param remote_id string
function M.mark_comment_synced(c_id, remote_id)
  local c = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if c then
    local decoded = decode_comment(c)
    decoded.remote_id = remote_id
    decoded.state = STATE.SYNCED
    M.add_comment(decoded)
  end
end

--- Mark a comment as clean synced (by remote_id).
---@param c_id string
function M.mark_clean(c_id)
  local c = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if c then
    local decoded = decode_comment(c)
    decoded.state = STATE.SYNCED
    M.add_comment(decoded)
  end
end

--- Delete a comment.
---@param c_id string
function M.delete_comment(c_id)
  storage.execute("DELETE FROM comments WHERE c_id = ?", c_id)
end

--- Soft-delete a comment (mark state = STATE.DELETED).
---@param c_id string
function M.soft_delete_comment(c_id)
  local c = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if c then
    local decoded = decode_comment(c)
    decoded.state = STATE.DELETED
    M.add_comment(decoded)
  end
end

--- Get all comments for all threads in a buffer (avoids N+1 query issue).
---@param mo_id string
---@param path string
---@return table[]
function M.comments_for_buffer(mo_id, path)
  local rows = storage.query([[
    SELECT c.*, t.state as thread_state, t.line_start, t.line_end
    FROM comments c
    JOIN threads t ON c.t_id = t.t_id
    WHERE t.mo_id = ? AND t.path = ? AND c.state != ?
    ORDER BY t.line_start, c.c_id
  ]], mo_id, path, STATE.DELETED)

  for i, r in ipairs(rows) do
    local decoded = decode_comment(r)
    decoded.resolved = bit.band(r.thread_state, THREAD_STATE.RESOLVED) > 0 and 1 or 0
    decoded.thread_is_draft = bit.band(r.thread_state, THREAD_STATE.DRAFT) > 0 and 1 or 0
    decoded.start_line = r.line_start
    decoded.end_line = r.line_end
    rows[i] = decoded
  end
  return rows
end

--- Get all pending comments (drafts, modified, deleted) for an MR.
---@param mo_id string
---@return table[]
function M.get_pending_comments(mo_id)
  local rows = storage.query([[
    SELECT c.*, t.path, t.line_start, t.line_end, t.state as thread_state
    FROM comments c
    JOIN threads t ON c.t_id = t.t_id
    WHERE t.mo_id = ? AND (c.state & 13) > 0
  ]], mo_id)
  for i, r in ipairs(rows) do
    local decoded = decode_comment(r)
    decoded.start_line = r.line_start
    decoded.end_line = r.line_end
    decoded.thread_is_draft = bit.band(r.thread_state, THREAD_STATE.DRAFT) > 0 and 1 or 0
    rows[i] = decoded
  end
  return rows
end

return M
