---@meta

-- Submit outbox (schema v4).
--
-- One row per pending network mutation. This is what `submit_review` executes,
-- and it is the single source of truth for "has this change landed remotely?".
--
-- Why a table instead of `comments.state = IN_FLIGHT` (v3):
--   * The comment row keeps describing its CONTENT (DRAFT/SYNCED/MODIFIED/
--     DELETED/CONFLICT); "is it being pushed" is orthogonal. In v3 an item
--     marked IN_FLIGHT fell outside PENDING_PUSH_MASK, so any partial-failure
--     batch silently hid the remaining drafts until a restart.
--   * Success is committed per-op the moment the call returns, so a retry
--     cannot re-post what already landed (GitLab notes are per-note, so an
--     all-or-nothing revert of the whole batch duplicated comments there).
--   * An op left RUNNING by a crash has an unknown outcome; it is re-queued
--     with `uncertain = 1` and adopted by body-match during reconcile rather
--     than blindly re-sent.
--
-- Status machine:  QUEUED -> RUNNING -> DONE | FAILED
--                  FAILED -> RUNNING (retry)      RUNNING -> QUEUED (crash)
-- `pending` = anything that is not DONE, i.e. QUEUED | RUNNING | FAILED.

local storage = require("lreview.storage")
local mpack = vim.mpack

local M = {}

M.OP = {
  CREATE_THREAD = "create_thread",
  REPLY         = "reply",
  EDIT          = "edit",
  DELETE        = "delete",
  VERDICT       = "verdict",
}

M.STATUS = {
  QUEUED = "QUEUED",
  RUNNING = "RUNNING",
  DONE   = "DONE",
  FAILED = "FAILED",
}

--- Category execution order: create threads first so replies/edit targets
--- exist, verdict last so the review state flips after its comments land.
M.OP_ORDER = {
  [M.OP.CREATE_THREAD] = 1,
  [M.OP.REPLY]         = 2,
  [M.OP.EDIT]          = 3,
  [M.OP.DELETE]        = 4,
  [M.OP.VERDICT]       = 5,
}

--- Local op id.
---
--- Time-prefixed on purpose: bare `math.random` ids (as review.lua uses for
--- draft comment ids) replay the same sequence every restart in an unseeded
--- LuaJIT, and an op_id collision would silently overwrite a ledger row.
local seq = 0
local function uuid()
  seq = seq + 1
  return string.format("%x-%04x-%04x", os.time(), seq % 0xffff, math.random(0, 0xffff))
end
M.uuid = uuid

local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function decode_op(row)
  if not row then return nil end
  local payload = row.payload and mpack.decode(row.payload) or {}
  row.payload = nil
  for k, v in pairs(payload) do row[k] = v end
  row.uncertain = (row.uncertain or 0) == 1
  return row
end
M.decode_op = decode_op

--- Queue one op, or refresh the snapshot of an existing non-terminal one.
---
--- Dedupe key is (c_id, op): if the same comment already has an open op of the
--- same kind, we do NOT create a second one (that is what stops a double
--- submit from double-posting). If its body changed since it was queued, the
--- queued payload is replaced so the retry sends the current text.
---@param op table  -- { mo_id, t_id, c_id, op, payload = {...} }
---@return string|nil op_id, boolean updated
local function enqueue_one(op)
  local snap = mpack.encode(op.payload or {})

  -- A pending delete makes any other open op on the same comment pointless
  -- (and would otherwise send an edit for a note we are about to remove).
  if op.op == M.OP.DELETE then
    storage.execute([[
      DELETE FROM push_ops
      WHERE c_id = ? AND op != ? AND status != ?
    ]], op.c_id, M.OP.DELETE, M.STATUS.DONE)
  end

  local existing = storage.query([[
    SELECT op_id, payload FROM push_ops
    WHERE c_id = ? AND op = ? AND status != ?
    ORDER BY created_at DESC LIMIT 1
  ]], op.c_id, op.op, M.STATUS.DONE)
  local row = existing[1]
  if row then
    storage.execute([[
      UPDATE push_ops SET payload = ?, status = ?, error = NULL, updated_at = ?
      WHERE op_id = ?
    ]], snap, M.STATUS.QUEUED, now(), row.op_id)
    return row.op_id, row.payload ~= snap
  end

  local op_id = op.op_id or uuid()
  storage.execute([[
    INSERT INTO push_ops (op_id, mo_id, t_id, c_id, op, status, attempts, uncertain,
                          payload, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
  ]], op_id, op.mo_id, op.t_id, op.c_id, op.op, M.STATUS.QUEUED, snap, now(), now())
  return op_id, true
end

--- Queue a batch of ops in one transaction.
---@param ops table[]
---@return integer queued, string|nil err
function M.enqueue(ops)
  if not ops or #ops == 0 then return 0, nil end
  local queued = 0
  local ok, err = storage.with_transaction(function()
    for _, op in ipairs(ops) do
      local _, created_or_refreshed = enqueue_one(op)
      if created_or_refreshed then queued = queued + 1 end
    end
  end)
  if not ok then
    -- Never swallow it: a failed enqueue would leave the submit looking at an
    -- empty outbox and report "nothing to push" for real drafts.
    return 0, tostring(err)
  end
  return queued, nil
end

--- All non-terminal ops for an MR, in category then creation order.
---@param mo_id string
---@return table[]
function M.pending(mo_id)
  local rows = storage.query([[
    SELECT * FROM push_ops
    WHERE mo_id = ? AND status != ?
    ORDER BY created_at ASC
  ]], mo_id, M.STATUS.DONE)
  local out = {}
  for _, r in ipairs(rows) do out[#out + 1] = decode_op(r) end
  table.sort(out, function(a, b)
    local oa, ob = M.OP_ORDER[a.op] or 99, M.OP_ORDER[b.op] or 99
    if oa ~= ob then return oa < ob end
    return (a.created_at or "") < (b.created_at or "")
  end)
  return out
end

--- Ops still queued for one thread (what `:LocalReviewSubmit <thread>` leaves).
---@param mo_id string
---@param t_id string
---@return integer
function M.count_pending_for_thread(mo_id, t_id)
  local rows = storage.query([[
    SELECT COUNT(*) AS n FROM push_ops
    WHERE mo_id = ? AND t_id = ? AND status != ?
  ]], mo_id, t_id, M.STATUS.DONE)
  return (rows[1] and rows[1].n) or 0
end

--- Count of non-terminal ops for an MR.
---@param mo_id string
---@return integer
function M.count_pending(mo_id)
  local rows = storage.query([[
    SELECT COUNT(*) AS n FROM push_ops WHERE mo_id = ? AND status != ?
  ]], mo_id, M.STATUS.DONE)
  return (rows[1] and rows[1].n) or 0
end

--- Count of ops that failed (not merely still queued).
---@param mo_id string
---@return integer
function M.count_failed(mo_id)
  local rows = storage.query([[
    SELECT COUNT(*) AS n FROM push_ops WHERE mo_id = ? AND status = ?
  ]], mo_id, M.STATUS.FAILED)
  return (rows[1] and rows[1].n) or 0
end

---@param op_id string
function M.mark_running(op_id)
  storage.execute("UPDATE push_ops SET status = ?, attempts = attempts + 1, updated_at = ? WHERE op_id = ?",
    M.STATUS.RUNNING, now(), op_id)
end

--- Put an op back in the queue after a call that provably did nothing (an
--- all-or-nothing batch that failed as a whole). Keeps `attempts` for
--- diagnostics but clears the lock so the row is plainly retryable.
---@param op_id string
function M.mark_queued(op_id)
  storage.execute("UPDATE push_ops SET status = ?, updated_at = ? WHERE op_id = ?",
    M.STATUS.QUEUED, now(), op_id)
end

--- Record an outcome we cannot trust: the network call succeeded but the local
--- commit failed. Mark it FAILED *and* uncertain so the next reconcile adopts
--- the comment by body match instead of the next submit posting a duplicate.
---@param op_id string
---@param err string
function M.mark_uncertain(op_id, err)
  storage.execute([[
    UPDATE push_ops SET status = ?, error = ?, uncertain = 1, updated_at = ? WHERE op_id = ?
  ]], M.STATUS.FAILED, err, now(), op_id)
end

--- Put an op back in the queue after a call that provably did nothing (an
--- all-or-nothing batch that failed as a whole). Keeps `attempts` for
--- diagnostics but clears the lock so the row is plainly retryable.
---@param op_id string
function M.mark_queued(op_id)
  storage.execute("UPDATE push_ops SET status = ?, updated_at = ? WHERE op_id = ?",
    M.STATUS.QUEUED, now(), op_id)
end

--- Record an outcome we cannot trust: the call succeeded but the local commit
--- failed. FAILED *and* uncertain, so the next reconcile adopts the comment by
--- body match instead of the next submit posting a duplicate.
---@param op_id string
---@param err string
function M.mark_uncertain(op_id, err)
  storage.execute([[
    UPDATE push_ops SET status = ?, error = ?, uncertain = 1, updated_at = ? WHERE op_id = ?
  ]], M.STATUS.FAILED, err, now(), op_id)
end

---@param op_id string
---@param remote_id string|nil
function M.mark_done(op_id, remote_id)
  storage.execute([[
    UPDATE push_ops SET status = ?, remote_id = ?, error = NULL, updated_at = ? WHERE op_id = ?
  ]], M.STATUS.DONE, remote_id, now(), op_id)
end

---@param op_id string
---@param err string
function M.mark_failed(op_id, err)
  storage.execute("UPDATE push_ops SET status = ?, error = ?, updated_at = ? WHERE op_id = ?",
    M.STATUS.FAILED, err, now(), op_id)
end

--- Crash recovery: an op that was RUNNING when the process died has an unknown
--- outcome. Re-queue it but flag `uncertain`, so submit/reconcile can adopt it
--- if the platform turns out to already have the comment (body match) instead
--- of posting a duplicate.
--- Uses idx_push_ops_running (partial index on status='RUNNING').
---@return integer recovered
function M.recover_stale()
  local rows = storage.query("SELECT op_id FROM push_ops WHERE status = ?", M.STATUS.RUNNING)
  if #rows == 0 then return 0 end
  storage.with_transaction(function()
    for _, r in ipairs(rows) do
      storage.execute([[
        UPDATE push_ops SET status = ?, uncertain = 1, updated_at = ? WHERE op_id = ?
      ]], M.STATUS.QUEUED, now(), r.op_id)
    end
  end)
  return #rows
end

--- Non-terminal ops flagged `uncertain`, indexed by the body they would send.
--- The reconcile pass consults this to adopt comments that actually landed.
---@param mo_id string
---@return table<string, table>  -- body -> op row
function M.uncertain_by_body(mo_id)
  local out = {}
  for _, op in ipairs(M.pending(mo_id)) do
    if op.uncertain and (op.op == M.OP.CREATE_THREAD or op.op == M.OP.REPLY) then
      out[op.body or ""] = op
    end
  end
  return out
end

--- Adopt a crashed-but-successful op: mark it DONE with the remote id found on
--- the platform, so the local draft is consumed instead of re-posted.
---@param op_id string
---@param remote_id string
function M.adopt(op_id, remote_id)
  M.mark_done(op_id, remote_id)
end

--- Prune the ledger rows for an MR (they only exist to survive one submit and
--- its reconcile; keeping them forever would grow the table without a reader).
---@param mo_id string
---@return integer pruned
function M.prune_done(mo_id)
  local rows = storage.query("SELECT op_id FROM push_ops WHERE mo_id = ? AND status = ?",
    mo_id, M.STATUS.DONE)
  if #rows > 0 then
    storage.execute("DELETE FROM push_ops WHERE mo_id = ? AND status = ?", mo_id, M.STATUS.DONE)
  end
  return #rows
end

--- Purge any open or failed verdict ops for an MR.
--- Verdicts are ephemeral to a review submission session; an old failed or
--- pending verdict must never block or poison subsequent submissions.
---@param mo_id string
function M.purge_verdict(mo_id)
  storage.execute([[
    DELETE FROM push_ops
    WHERE mo_id = ? AND op = ? AND status != ?
  ]], mo_id, M.OP.VERDICT, M.STATUS.DONE)
end

--- Delete an op from the outbox by op_id.
---@param op_id string
function M.delete_op(op_id)
  storage.execute("DELETE FROM push_ops WHERE op_id = ?", op_id)
end

return M
