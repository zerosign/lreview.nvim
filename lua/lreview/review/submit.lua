---@meta

-- Submit and outbox pipeline for review comments:
-- Computes change-set diffs, builds push ops, drives transactional
-- platform submission (GitHub atomic review batch / GitLab per-note loop),
-- and handles crash-recovery adoption.

local adapter = require("lreview.adapter")
local storage = require("lreview.storage")
local comments = require("lreview.storage.comments")
local outbox = require("lreview.storage.outbox")

local M = {}

--- Compute explicit change-set of pending local modifications for an MR.
---@param mo_id string
---@return table
function M.compute_change_set(mo_id)
  local pending = comments.get_pending_comments(mo_id)
  local cs = {
    additions = {},
    replies = {},
    updates = {},
    deletions = {},
  }
  for _, d in ipairs(pending or {}) do
    if d.state == comments.STATE.DELETED then
      cs.deletions[#cs.deletions + 1] = d
    elseif d.state == comments.STATE.MODIFIED then
      cs.updates[#cs.updates + 1] = d
    elseif comments.thread_is_draft(d.thread_state) then
      cs.additions[#cs.additions + 1] = d
    else
      cs.replies[#cs.replies + 1] = d
    end
  end
  return cs
end

--- Resolve the comment a reply should be threaded under.
---
--- GitHub replies need a *comment* id; GitLab needs the discussion id. A synced
--- thread whose only remote comment is pending-delete (or whose first comment is
--- itself an unpushed draft) has no valid parent, so this returns nil and the
--- caller reports it — instead of concatenating nil into a CLI argument, which
--- is what v3 did.
---@param resolved table
---@param t_id string
---@return string|nil parent, string|nil err
function M.reply_parent(resolved, t_id)
  local cs = comments.comments_for_thread(t_id)
  if resolved.provider == "gh" or resolved.provider == "github" then
    for _, c in ipairs(cs) do
      if c.remote_id and c.remote_id ~= "" and not comments.is_deleted(c.state) then
        return c.remote_id, nil
      end
    end
    return nil, "thread has no pushed comment to reply to"
  end
  if #cs == 0 then
    return nil, "unknown thread"
  end
  -- GitLab threads replies by discussion id, which is our t_id.
  return t_id, nil
end

--- Translate pending comment states into push ops. Pure: reads storage only.
---
--- Ops are keyed by (c_id, op), so re-running submit never queues the same
--- mutation twice. The verdict becomes its own op whenever it cannot ride along
--- with a comment batch — exactly the case (approve/request-changes with only
--- replies or edits) where v3 dropped it silently.
---@param detail lreview.MRDetail
---@param resolved table
---@param thread_id string|nil
---@param verdict string|nil
---@return table[] ops, string[] skipped
function M.build_ops(detail, resolved, thread_id, verdict)
  local cs = M.compute_change_set(detail.mo_id)
  local ops, skipped = {}, {}
  local function keep(item)
    return not thread_id or item.t_id == thread_id
  end

  local has_new = false
  for _, d in ipairs(cs.additions) do
    if keep(d) then
      has_new = true
      ops[#ops + 1] = {
        mo_id = detail.mo_id, t_id = d.t_id, c_id = d.c_id,
        op = outbox.OP.CREATE_THREAD,
        payload = { path = d.path, line = d.start_line, end_line = d.end_line, body = d.body },
      }
    end
  end

  for _, d in ipairs(cs.replies) do
    if keep(d) then
      local parent, perr = M.reply_parent(resolved, d.t_id)
      if parent then
        ops[#ops + 1] = {
          mo_id = detail.mo_id, t_id = d.t_id, c_id = d.c_id, op = outbox.OP.REPLY,
          payload = { body = d.body, parent = parent },
        }
      else
        skipped[#skipped + 1] = string.format("%s:%d (%s)",
          d.path or "?", d.start_line or 0, perr or "unthreadable")
      end
    end
  end

  for _, d in ipairs(cs.updates) do
    if keep(d) then
      ops[#ops + 1] = {
        mo_id = detail.mo_id, t_id = d.t_id, c_id = d.c_id, op = outbox.OP.EDIT,
        payload = { body = d.body, remote_id = d.remote_id },
      }
    end
  end

  for _, d in ipairs(cs.deletions) do
    if keep(d) then
      ops[#ops + 1] = {
        mo_id = detail.mo_id, t_id = d.t_id, c_id = d.c_id, op = outbox.OP.DELETE,
        payload = { remote_id = d.remote_id, body = d.body or "" },
      }
    end
  end

  if not thread_id and verdict and verdict ~= "COMMENT"
      and adapter.supports(resolved, "review_verdict") then
    local rides_along = has_new and adapter.supports(resolved, "atomic_inline_batch")
    if not rides_along then
      ops[#ops + 1] = {
        mo_id = detail.mo_id, t_id = "__mr__", c_id = "__mr__", op = outbox.OP.VERDICT,
        payload = { verdict = verdict, body = detail.description or "" },
      }
    end
  end

  return ops, skipped
end

--- Push the pending changes, driven by the outbox.
---
--- Replaces v3's "mark everything IN_FLIGHT, abort the batch on the first
--- error", which stranded the untouched items in a state PENDING_PUSH_MASK
--- excluded — i.e. drafts that were silently unpushable until a restart. Now:
---   * each op is committed the moment it succeeds (status DONE + the local
---     transition, in one transaction), so a later failure can never re-send a
---     note that already landed;
---   * a failure marks that op FAILED and stops its category, leaving the rest
---     QUEUED — they get retried, not resurrected from a lock;
---   * returns (pushed, err, remaining) so the caller can say "4 pushed, 2 left"
---     instead of pretending a per-note API was atomic.
---@param detail lreview.MRDetail
---@param resolved table
---@param ctx table
---@param thread_id string|nil  -- optional filter
---@param verdict string|nil
---@return integer pushed, string|nil err, integer remaining
function M.submit_pushes(detail, resolved, ctx, thread_id, verdict)
  -- Hubs expect an uppercase event, and callers outside the confirm UI (tests,
  -- scripts, custom adapters) may pass "approve"/"comment". Normalize once.
  if verdict then verdict = tostring(verdict):upper() end

  local conflict_count = comments.count_conflicts(detail.mo_id)
  if conflict_count > 0 then
    return 0, string.format(
      "%d conflict(s) must be resolved before pushing. Use :LocalReviewConflicts to review.",
      conflict_count), outbox.count_pending(detail.mo_id)
  end

  local ops, skipped = M.build_ops(detail, resolved, thread_id, verdict)
  outbox.enqueue(ops)

  local function take_pending()
    local all = outbox.pending(detail.mo_id)
    if not thread_id then return all end
    local out = {}
    for _, op in ipairs(all) do
      if op.t_id == thread_id then out[#out + 1] = op end
    end
    return out
  end

  if #take_pending() == 0 then
    if #skipped > 0 then
      return 0, "nothing pushable: " .. table.concat(skipped, "; "), 0
    end
    return 0, "no draft, edited, or deleted comments to submit", 0
  end

  local number = detail.number
  local pushed = 0
  local first_err = nil
  local function record(err)
    if err and not first_err then first_err = tostring(err) end
  end

  --- Commit a successful op together with its local state transition.
  local function commit(op, remote_id, local_fn)
    local ok_tx, tx_err = storage.with_transaction(function()
      outbox.mark_done(op.op_id, remote_id)
      if local_fn then local_fn(op) end
    end)
    if not ok_tx then
      -- The call landed but the bookkeeping did not. Keep the op non-terminal
      -- and flag it uncertain: reconcile adopts it by body match instead of the
      -- next submit posting a second copy.
      outbox.mark_uncertain(op.op_id, "pushed but not recorded locally: " .. tostring(tx_err))
      record("pushed a change that could not be recorded locally: " .. tostring(tx_err))
      return false
    end
    pushed = pushed + 1
    return true
  end

  local function group(kind)
    local out = {}
    for _, op in ipairs(take_pending()) do
      if op.op == kind then out[#out + 1] = op end
    end
    return out
  end

  local function consume_draft(op)
    comments.delete_comment(op.c_id)
    comments.delete_thread(op.t_id)
  end

  -- 1. New threads -----------------------------------------------------------
  local creates = group(outbox.OP.CREATE_THREAD)
  if #creates > 0 then
    local function to_batch(list)
      local batch = {}
      for _, op in ipairs(list) do
        batch[#batch + 1] = {
          path = op.path, line = op.line, start_line = op.line, end_line = op.end_line,
          body = op.body, t_id = op.t_id, c_id = op.c_id,
        }
      end
      return batch
    end

    if adapter.supports(resolved, "atomic_inline_batch") then
      -- One review POST: GitHub creates all comments or none. Lock the group
      -- first: if the process dies mid-call, recovery flags these ops
      -- uncertain and reconcile adopts whatever actually landed.
      for _, op in ipairs(creates) do outbox.mark_running(op.op_id) end
      local ok, err = resolved.adapter.submit_inline_review(
        resolved.cfg, ctx, number, to_batch(creates), nil, { verdict = verdict })
      if ok then
        for _, op in ipairs(creates) do
          -- The synced copy arrives via the reconcile that follows: a batch
          -- review POST does not hand back per-comment ids.
          commit(op, nil, consume_draft)
        end
      else
        -- Nothing landed (all-or-nothing), so the group goes back to QUEUED.
        for _, op in ipairs(creates) do outbox.mark_queued(op.op_id) end
        record(err)
      end
    else
      -- Per-note platforms: drive the loop here so every success is committed
      -- immediately. This is what stops a mid-loop failure from re-posting the
      -- notes that already landed.
      for _, op in ipairs(creates) do
        outbox.mark_running(op.op_id)
        local ok, err = resolved.adapter.submit_inline_review(
          resolved.cfg, ctx, number, to_batch({ op }))
        if not ok then
          outbox.mark_failed(op.op_id, err)
          record(err)
          break
        end
        commit(op, nil, consume_draft)
      end
    end
  end

  -- 2. Replies --------------------------------------------------------------
  for _, op in ipairs(group(outbox.OP.REPLY)) do
    outbox.mark_running(op.op_id)
    local remote_id, err = resolved.adapter.submit_reply(
      resolved.cfg, ctx, number, op.parent, op.body)
    if not remote_id then
      outbox.mark_failed(op.op_id, err)
      record(err)
      break
    end
    local rid = remote_id
    commit(op, rid, function(o) comments.mark_comment_synced(o.c_id, rid) end)
  end

  -- 3. Edits ----------------------------------------------------------------
  for _, op in ipairs(group(outbox.OP.EDIT)) do
    if not op.remote_id or op.remote_id == "" then
      outbox.mark_failed(op.op_id, "comment was never pushed")
      record("an edited comment has no remote id; pull to reconcile before editing it")
      break
    end
    outbox.mark_running(op.op_id)
    local ok, err = resolved.adapter.update_comment(
      resolved.cfg, ctx, number, op.t_id, op.remote_id, op.body)
    if not ok then
      outbox.mark_failed(op.op_id, err)
      record(err)
      break
    end
    commit(op, op.remote_id, function(o) comments.mark_clean(o.c_id) end)
  end

  -- 4. Deletions ------------------------------------------------------------
  for _, op in ipairs(group(outbox.OP.DELETE)) do
    if not op.remote_id or op.remote_id == "" then
      -- Local-only draft: there is no remote object to delete, so consuming it
      -- locally IS the whole job (v3 sent a real API call and 404'd).
      commit(op, nil, function(o) comments.delete_comment(o.c_id) end)
    else
      outbox.mark_running(op.op_id)
      local ok, err = resolved.adapter.delete_comment(
        resolved.cfg, ctx, number, op.t_id, op.remote_id)
      if not ok then
        outbox.mark_failed(op.op_id, err)
        record(err)
        break
      end
      commit(op, op.remote_id, function(o) comments.delete_comment(o.c_id) end)
    end
  end

  -- 5. Verdict --------------------------------------------------------------
  -- Only reached when build_ops decided the verdict could not ride along with a
  -- comment batch. An adapter that claims review_verdict but ships no
  -- submit_verdict is reported as a failure rather than a silent no-op.
  for _, op in ipairs(group(outbox.OP.VERDICT)) do
    local ok, err
    outbox.mark_running(op.op_id)
    if resolved.adapter.submit_verdict then
      ok, err = resolved.adapter.submit_verdict(
        resolved.cfg, ctx, number, op.verdict, op.body)
    else
      ok, err = false, "active adapter declares review_verdict but has no submit_verdict"
    end
    if not ok then
      outbox.mark_failed(op.op_id, err)
      record(err)
      break
    end
    commit(op, nil)
  end

  local remaining = #take_pending()
  if #skipped > 0 then
    record("skipped: " .. table.concat(skipped, "; "))
  end
  return pushed, first_err, remaining
end

return M
