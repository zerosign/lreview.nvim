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
  DRAFT    = 1,  -- (00001) New local draft thread
  SYNCED   = 2,  -- (00010) Thread synced from remote server
  RESOLVED = 4,  -- (00100) Thread is resolved (combinable with SYNCED)
  DELETED  = 8,  -- (01000) Thread deleted locally (future support)
  CONFLICT = 16, -- (10000) Remote changed thread while local edits pending
}
M.THREAD_STATE = THREAD_STATE

-- ---------------------------------------------------------------------------
-- Comment States (Bit Flags)
-- ---------------------------------------------------------------------------
local STATE = {
  DRAFT     = 1,  -- (000001) New local reply, never pushed
  SYNCED    = 2,  -- (000010) Matches current remote state
  IN_FLIGHT = 4,  -- (000100) Currently pushing over network thread
  MODIFIED  = 8,  -- (001000) Synced comment edited locally (not yet pushed)
  DELETED   = 16, -- (010000) Synced comment deleted locally (not yet pushed)
  CONFLICT  = 32, -- (100000) Remote changed while we had local edits pending
}
M.STATE = STATE

-- Mask for all states that require a push (excludes SYNCED, IN_FLIGHT, and CONFLICT).
M.PENDING_PUSH_MASK = STATE.DRAFT + STATE.MODIFIED + STATE.DELETED -- 25

-- ---------------------------------------------------------------------------
-- Comment State Predicates
-- ---------------------------------------------------------------------------
--- Check comment state flags. All accept the raw integer `state` column value.

function M.is_draft(s)     return s == STATE.DRAFT     end
function M.is_synced(s)    return s == STATE.SYNCED    end
function M.is_in_flight(s) return s == STATE.IN_FLIGHT end
function M.is_modified(s) return s == STATE.MODIFIED end
function M.is_deleted(s)  return s == STATE.DELETED  end
function M.is_conflict(s) return s == STATE.CONFLICT end
function M.needs_push(s)  return bit.band(s, M.PENDING_PUSH_MASK) > 0 end

-- ---------------------------------------------------------------------------
-- Thread State Predicates
-- ---------------------------------------------------------------------------
--- Check thread state flags. All accept the raw integer `state` column value.

function M.thread_is_draft(s)    return bit.band(s, THREAD_STATE.DRAFT)    > 0 end
function M.thread_is_synced(s)   return bit.band(s, THREAD_STATE.SYNCED)   > 0 end
function M.thread_is_resolved(s) return bit.band(s, THREAD_STATE.RESOLVED) > 0 end
function M.thread_is_conflict(s) return bit.band(s, THREAD_STATE.CONFLICT) > 0 end

-- ---------------------------------------------------------------------------
-- Decoders (payload only — no computed boolean fields)
-- ---------------------------------------------------------------------------
local function decode_thread(row)
  if not row then return nil end
  local payload = row.payload and mpack.decode(row.payload) or {}
  row.payload = nil
  for k, v in pairs(payload) do
    row[k] = v
  end
  -- Alias new canonical names to legacy names for call-site compatibility.
  row.start_line = row.line_start
  row.end_line   = row.line_end
  return row
end

local function decode_comment(row)
  if not row then return nil end
  local payload = row.payload and mpack.decode(row.payload) or {}
  row.payload = nil
  for k, v in pairs(payload) do
    row[k] = v
  end
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
    -- synced_body: the remote body at last successful sync.
    -- This is our base for detecting whether the remote changed
    -- independently of our local edits.
    synced_body = (state_val == STATE.SYNCED) and c.body or c.synced_body,
    -- Conflict metadata (only present when state == CONFLICT)
    conflict_remote_body = c.conflict_remote_body,
    conflict_reason = c.conflict_reason,
    conflict_detected_at = c.conflict_detected_at,
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

--- Mark a comment state as IN_FLIGHT.
---@param c_id string
function M.mark_in_flight(c_id)
  local c = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if c then
    local decoded = decode_comment(c)
    decoded.prev_state = decoded.state
    decoded.state = STATE.IN_FLIGHT
    M.add_comment(decoded)
  end
end

--- Revert a comment state from IN_FLIGHT back to its previous state.
---@param c_id string
---@param fallback_state integer|nil
function M.revert_in_flight(c_id, fallback_state)
  local c = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if c then
    local decoded = decode_comment(c)
    decoded.state = decoded.prev_state or fallback_state or STATE.DRAFT
    decoded.prev_state = nil
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
    decoded.thread_state = r.thread_state
    decoded.start_line = r.line_start
    decoded.end_line = r.line_end
    rows[i] = decoded
  end
  return rows
end

--- Get all pending comments (drafts, modified, deleted) for an MR.
--- Comments in CONFLICT state are excluded — they must be resolved first.
---@param mo_id string
---@return table[]
function M.get_pending_comments(mo_id)
  local rows = storage.query([[
    SELECT c.*, t.path, t.line_start, t.line_end, t.state as thread_state
    FROM comments c
    JOIN threads t ON c.t_id = t.t_id
    WHERE t.mo_id = ? AND (c.state & ?) > 0
  ]], mo_id, M.PENDING_PUSH_MASK)
  for i, r in ipairs(rows) do
    local decoded = decode_comment(r)
    decoded.thread_state = r.thread_state
    decoded.start_line = r.line_start
    decoded.end_line = r.line_end
    rows[i] = decoded
  end
  return rows
end

--- Transition a comment to CONFLICT state, storing both local and remote bodies.
---@param c_id string
---@param remote_body string    -- what the remote has right now
---@param reason string         -- "remote_edited" | "remote_deleted" | "thread_gone"
function M.mark_comment_conflict(c_id, remote_body, reason)
  local row = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if not row then return end
  local decoded = decode_comment(row)
  decoded.state = STATE.CONFLICT
  decoded.conflict_remote_body = remote_body
  decoded.conflict_reason = reason
  decoded.conflict_detected_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  -- decoded.body remains the LOCAL version
  -- decoded.synced_body remains the base version
  M.add_comment(decoded)
end

--- Transition a thread to CONFLICT state.
---@param t_id string
---@param reason string  -- "remote_deleted_has_drafts"
function M.mark_thread_conflict(t_id, reason)
  local t = M.get_thread(t_id)
  if not t then return end
  local new_state = bit.bor(t.state, THREAD_STATE.CONFLICT)
  local payload = {
    commit_sha = t.commit_sha,
    last_synced_at = t.last_synced_at,
    conflict_reason = reason,
    conflict_detected_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  storage.execute(
    "UPDATE threads SET state = ?, payload = ? WHERE t_id = ?",
    new_state, mpack.encode(payload), t_id
  )
end

--- Resolve a CONFLICT comment by keeping the local version.
--- Transitions back to MODIFIED so it will be pushed on next submit.
---@param c_id string
function M.resolve_conflict_keep_local(c_id)
  local row = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if not row then return end
  local decoded = decode_comment(row)
  if decoded.state ~= STATE.CONFLICT then return end
  decoded.state = STATE.MODIFIED
  decoded.conflict_remote_body = nil
  decoded.conflict_reason = nil
  decoded.conflict_detected_at = nil
  M.add_comment(decoded)
end

--- Resolve a CONFLICT comment by accepting the remote version.
--- Transitions to SYNCED with the remote body.
---@param c_id string
function M.resolve_conflict_accept_remote(c_id)
  local row = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if not row then return end
  local decoded = decode_comment(row)
  if decoded.state ~= STATE.CONFLICT then return end
  -- Accept remote body as the new truth.
  decoded.body = decoded.conflict_remote_body
  decoded.state = STATE.SYNCED
  decoded.conflict_remote_body = nil
  decoded.conflict_reason = nil
  decoded.conflict_detected_at = nil
  M.add_comment(decoded)
end

--- Get all conflicting comments for an MR (for the conflict resolution UI).
---@param mo_id string
---@return table[]
function M.get_conflicts(mo_id)
  local rows = storage.query([[
    SELECT c.*, t.path, t.line_start, t.line_end
    FROM comments c
    JOIN threads t ON c.t_id = t.t_id
    WHERE t.mo_id = ? AND c.state = ?
    ORDER BY t.line_start, c.c_id
  ]], mo_id, STATE.CONFLICT)
  for i, r in ipairs(rows) do
    local decoded = decode_comment(r)
    decoded.start_line = r.line_start
    decoded.end_line = r.line_end
    rows[i] = decoded
  end
  return rows
end

--- Count all conflicting comments for an MR.
---@param mo_id string
---@return integer
function M.count_conflicts(mo_id)
  local rows = storage.query([[
    SELECT COUNT(*) as n
    FROM comments c
    JOIN threads t ON c.t_id = t.t_id
    WHERE t.mo_id = ? AND c.state = ?
  ]], mo_id, STATE.CONFLICT)
  return (rows[1] and rows[1].n) or 0
end

return M
