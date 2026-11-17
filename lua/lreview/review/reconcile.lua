---@meta

-- Thread reconciliation engine: fetches remote threads and reconciles them
-- with local storage (batched O(1) in-memory index, conflict detection,
-- and uncertain outbox adoption).

local storage = require("lreview.storage")
local comments = require("lreview.storage.comments")
local outbox = require("lreview.storage.outbox")

local M = {}

--- Fetch remote threads via adapter.
---@param detail lreview.MRDetail
---@param resolved table
---@param ctx table
---@return table[]|nil remote_threads, string|nil err
function M.fetch_remote_threads(detail, resolved, ctx)
  return resolved.adapter.fetch_threads(resolved.cfg, ctx, detail.number, detail.mo_id)
end

--- Reconcile remote threads into local storage (batched, O(n)).
--- Pure DB work — no network calls. Separated from fetch so both
--- sync_review and submit_review_thread can share it.
---@param detail lreview.MRDetail
---@param remote_threads table[]
---@param notify_fn (fun(msg: string, level: integer|nil))|nil
---@return integer synced  -- number of remote threads processed
function M.reconcile_threads(detail, remote_threads, notify_fn)
  local notify = notify_fn or function(msg, level)
    if vim and vim.notify then
      vim.notify(msg, level or vim.log.levels.INFO)
    end
  end

  local remote_t_ids = {}
  local remote_c_ids = {}
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local n = 0

  -- Batched reconcile: load all local comments for this MR once, index them in
  -- memory by t_id -> c_id. Turns the N+1 inner-loop lookup into O(1) lookups.
  local local_by_thread = {}
  local local_comments = storage.query([[
    SELECT c.*, t.path, t.line_start, t.line_end, t.state as thread_state
    FROM comments c JOIN threads t ON c.t_id = t.t_id
    WHERE t.mo_id = ?
  ]], detail.mo_id)
  for _, lc in ipairs(local_comments) do
    local_by_thread[lc.t_id] = local_by_thread[lc.t_id] or {}
    local_by_thread[lc.t_id][lc.c_id] = lc
  end

  -- Crash-recovery index: ops that were RUNNING when the process died have an
  -- unknown outcome. If the remote turns out to already contain that body, we
  -- adopt it (mark the op DONE, consume the local draft) instead of leaving the
  -- draft queued to be posted a second time on the next submit.
  local uncertain = outbox.uncertain_by_body(detail.mo_id)

  for _, t in ipairs(remote_threads) do
    remote_t_ids[t.t_id] = true
    local local_t = comments.get_thread(t.t_id)

    if local_t == nil then
      -- Brand new remote thread — insert as SYNCED.
      comments.create_thread({
        t_id = t.t_id,
        mo_id = detail.mo_id,
        path = t.path,
        commit_sha = t.commit_sha,
        start_line = t.start_line,
        end_line = t.end_line,
        is_draft = false,
        resolved = t.resolved == 1,
        last_synced_at = now,
      })
    elseif comments.thread_is_draft(local_t.state) then
      -- Local DRAFT thread: never overwrite it with remote data.
    else
      -- Existing synced thread: update resolved bit and payload.
      comments.create_thread({
        t_id = t.t_id,
        mo_id = detail.mo_id,
        path = t.path,
        commit_sha = t.commit_sha,
        start_line = t.start_line,
        end_line = t.end_line,
        is_draft = false,
        resolved = t.resolved == 1,
        last_synced_at = now,
      })
    end

    -- Process comments inside this thread.
    for _, c in ipairs(t.comments or {}) do
      remote_c_ids[c.c_id] = true

      -- Find our local copy by remote_id (c_id on remote == c_id in our DB
      -- once synced; for first-time arrivals, look by remote_id field).
      local local_c
      local t_idx = local_by_thread[t.t_id]
      if t_idx then
        local_c = t_idx[c.c_id]
        if not local_c then
          for _, lc in pairs(t_idx) do
            if lc.remote_id == c.remote_id then
              local_c = lc
              break
            end
          end
        end
      end

      if local_c then
        local decoded_lc = local_c
        if decoded_lc.payload then
          local mpack_payload = vim.mpack.decode(decoded_lc.payload) or {}
          decoded_lc = vim.tbl_extend("force", decoded_lc, mpack_payload)
          decoded_lc.payload = nil
        end

        if decoded_lc then
          local lstate = decoded_lc.state

          if lstate == comments.STATE.DRAFT then
            -- DRAFT: never overwrite.
          elseif lstate == comments.STATE.SYNCED then
            comments.add_comment({
              c_id = c.c_id,
              t_id = t.t_id,
              remote_id = c.remote_id,
              author = c.author,
              body = c.body,
              created_at = c.created_at,
              in_reply_to = c.in_reply_to,
              state = comments.STATE.SYNCED,
            })
          elseif lstate == comments.STATE.MODIFIED then
            local synced_body = decoded_lc.synced_body
            if c.body ~= synced_body then
              comments.mark_comment_conflict(decoded_lc.c_id, c.body, "remote_edited")
              notify(
                string.format("lreview: conflict on %s:%d — remote edited a comment you are editing",
                  t.path, t.start_line or 0),
                vim.log.levels.WARN)
            end
          elseif lstate == comments.STATE.DELETED then
            local synced_body = decoded_lc.synced_body
            if c.body ~= synced_body then
              comments.mark_comment_conflict(decoded_lc.c_id, c.body, "remote_edited")
              notify(
                string.format("lreview: conflict on %s:%d — remote edited a comment you deleted",
                  t.path, t.start_line or 0),
                vim.log.levels.WARN)
            end
          elseif lstate == comments.STATE.CONFLICT then
            comments.mark_comment_conflict(decoded_lc.c_id, c.body, decoded_lc.conflict_reason or "remote_edited")
          end
        end
      else
        -- No local copy. Before inserting a fresh SYNCED row, check whether
        -- this is a comment WE pushed whose result was never recorded locally
        -- (crash between the network call and the outbox write). Adopting it
        -- consumes the local draft so it cannot be posted twice.
        local adopt = uncertain[c.body or ""]
        if adopt then
          outbox.mark_done(adopt.op_id, c.remote_id)
          comments.delete_comment(adopt.c_id)
          if adopt.op == outbox.OP.CREATE_THREAD then
            comments.delete_thread(adopt.t_id)
          end
          uncertain[c.body or ""] = nil
        end
        comments.add_comment({
          c_id = c.c_id,
          t_id = t.t_id,
          remote_id = c.remote_id,
          author = c.author,
          body = c.body,
          created_at = c.created_at,
          in_reply_to = c.in_reply_to,
          state = comments.STATE.SYNCED,
        })
      end
    end
    n = n + 1
  end

  -- Handle remote-side deletions
  local all_synced = storage.query([[
    SELECT c.c_id, c.remote_id, c.state, c.payload, t.path, t.line_start
    FROM comments c
    JOIN threads t ON c.t_id = t.t_id
    WHERE t.mo_id = ? AND c.remote_id IS NOT NULL
  ]], detail.mo_id)

  for _, ec in ipairs(all_synced or {}) do
    if not remote_c_ids[ec.remote_id] then
      local lstate = ec.state

      if lstate == comments.STATE.SYNCED then
        comments.delete_comment(ec.c_id)
      elseif lstate == comments.STATE.MODIFIED then
        comments.mark_comment_conflict(ec.c_id, "", "remote_deleted")
        notify(
          string.format("lreview: conflict on %s:%d — remote deleted a comment you are editing",
            ec.path or "?", ec.line_start or 0),
          vim.log.levels.WARN)
      elseif lstate == comments.STATE.DELETED then
        comments.delete_comment(ec.c_id)
      end
    end
  end

  -- Handle threads deleted on the remote
  local all_local_threads = comments.threads_for_mr(detail.mo_id)
  for _, lt in ipairs(all_local_threads) do
    if not comments.thread_is_draft(lt.state) and not remote_t_ids[lt.t_id] then
      local draft_children = storage.query([[
        SELECT COUNT(*) as n FROM comments WHERE t_id = ? AND state = ?
      ]], lt.t_id, comments.STATE.DRAFT)
      local has_orphaned_drafts = (draft_children[1] and draft_children[1].n or 0) > 0

      if has_orphaned_drafts then
        comments.mark_thread_conflict(lt.t_id, "remote_deleted_has_drafts")
        notify(
          string.format("lreview: conflict — thread on %s deleted remotely but you have unsent replies",
            lt.path or "?"),
          vim.log.levels.WARN)
      else
        comments.delete_thread(lt.t_id)
      end
    end
  end

  return n
end

return M
