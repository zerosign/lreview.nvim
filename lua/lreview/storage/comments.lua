---@meta

-- CRUD for threads + comments.
--
-- The primary offline use case is the per-buffer query: "what threads/comments
-- exist in the current buffer for this file and line range?" This is served by
-- idx_threads_buffer (mo_id, path, start_line, end_line).

local storage = require("lreview.storage")
local unpack = table.unpack or unpack

local M = {}

-- ---------------------------------------------------------------------------
-- Threads
-- ---------------------------------------------------------------------------

--- Create a thread (draft by default).
---@param t lreview.Thread
---@return string t_id
function M.create_thread(t)
  storage.execute([[
    INSERT OR REPLACE INTO threads
      (t_id, mo_id, path, commit_sha, start_line, end_line, is_draft, last_synced_at, resolved)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]],
    t.t_id, t.mo_id, t.path, t.commit_sha, t.start_line, t.end_line,
    t.is_draft and 1 or 0, t.last_synced_at, t.resolved and 1 or 0)
  return t.t_id
end

--- Get a thread by id.
---@param t_id string
---@return table|nil
function M.get_thread(t_id)
  local rows = storage.query("SELECT * FROM threads WHERE t_id = ?", t_id)
  return rows[1]
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
    sql = sql .. " AND start_line <= ? AND (end_line IS NULL OR end_line >= ?)"
    params[#params + 1] = line
    params[#params + 1] = line
  end
  sql = sql .. " ORDER BY start_line"
  return storage.query(sql, unpack(params))
end

--- List all threads for an MR.
---@param mo_id string
---@return table[]
function M.threads_for_mr(mo_id)
  return storage.query("SELECT * FROM threads WHERE mo_id = ? ORDER BY start_line", mo_id)
end

--- List draft threads for an MR.
---@param mo_id string
---@return table[]
function M.draft_threads(mo_id)
  return storage.query("SELECT * FROM threads WHERE mo_id = ? AND is_draft = 1", mo_id)
end

--- Mark a thread as synced (is_draft = 0).
---@param t_id string
function M.mark_synced(t_id)
  storage.execute(
    "UPDATE threads SET is_draft = 0, last_synced_at = ? WHERE t_id = ?",
    os.date("!%Y-%m-%dT%H:%M:%SZ"), t_id
  )
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
  storage.execute("UPDATE threads SET resolved = ? WHERE t_id = ?", resolved_val and 1 or 0, t_id)
end

-- ---------------------------------------------------------------------------
local STATE = {
  DRAFT    = 1, -- (0001) New local draft
  SYNCED   = 2, -- (0010) Clean remote comment
  MODIFIED = 4, -- (0100) Synced comment edited locally
  DELETED  = 8, -- (1000) Synced comment deleted locally
}
M.STATE = STATE

-- Comments
-- ---------------------------------------------------------------------------

--- Add a comment to a thread.
---@param c lreview.Comment
function M.add_comment(c)
  local state_val = c.state or STATE.DRAFT
  storage.execute([[
    INSERT OR REPLACE INTO comments (c_id, t_id, remote_id, author, body, created_at, in_reply_to, state)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  ]], c.c_id, c.t_id, c.remote_id, c.author, c.body, c.created_at, c.in_reply_to, state_val)
end

--- Get comments for a thread (excludes pending deletes).
---@param t_id string
---@return table[]
function M.comments_for_thread(t_id)
  return storage.query("SELECT * FROM comments WHERE t_id = ? AND state != ? ORDER BY created_at", t_id, STATE.DELETED)
end

--- Update a comment body.
---@param c_id string
---@param body string
function M.update_comment(c_id, body)
  storage.execute("UPDATE comments SET body = ? WHERE c_id = ?", body, c_id)
end

--- Update a comment body and state.
---@param c_id string
---@param body string
---@param state integer
function M.update_comment_body_and_state(c_id, body, state)
  storage.execute("UPDATE comments SET body = ?, state = ? WHERE c_id = ?", body, state, c_id)
end

--- Mark a comment as clean synced.
---@param c_id string
---@param remote_id string
function M.mark_comment_synced(c_id, remote_id)
  storage.execute("UPDATE comments SET remote_id = ?, state = ? WHERE c_id = ?", remote_id, STATE.SYNCED, c_id)
end

--- Mark a comment as clean synced (by remote_id).
---@param c_id string
function M.mark_clean(c_id)
  storage.execute("UPDATE comments SET state = ? WHERE c_id = ?", STATE.SYNCED, c_id)
end

--- Delete a comment.
---@param c_id string
function M.delete_comment(c_id)
  storage.execute("DELETE FROM comments WHERE c_id = ?", c_id)
end

--- Soft-delete a comment (mark state = STATE.DELETED).
---@param c_id string
function M.soft_delete_comment(c_id)
  storage.execute("UPDATE comments SET state = ? WHERE c_id = ?", STATE.DELETED, c_id)
end

--- Get all comments for all threads in a buffer (avoids N+1 query issue).
---@param mo_id string
---@param path string
---@return table[]
function M.comments_for_buffer(mo_id, path)
  return storage.query([[
    SELECT c.*, t.resolved, t.is_draft as thread_is_draft, t.start_line, t.end_line
    FROM comments c
    JOIN threads t ON c.t_id = t.t_id
    WHERE t.mo_id = ? AND t.path = ?
    ORDER BY t.start_line, c.created_at
  ]], mo_id, path)
end

return M
