---@meta

-- Conflict resolution view.
--
-- The submit path refuses to push while any comment is in CONFLICT state, so
-- without this surface a single remote edit permanently wedges an MR. It is one
-- on-demand float (no panel, no autocmd) showing the local version next to the
-- remote version, with two keys per conflict.
--
-- Storage already had the transitions (`resolve_conflict_keep_local` ->
-- MODIFIED so the local text pushes next, `resolve_conflict_accept_remote` ->
-- SYNCED with the remote text); only the door was missing.

local review = require("lreview.review")
local comments = require("lreview.storage.comments")

local M = {}

---@type { bufnr: integer, winid: integer|nil, rows: table[] }|nil
M.state = nil

local function setup_highlights()
  local set = function(name, link)
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  set("LReviewConflictHeader", "WarningMsg")
  set("LReviewConflictLocal", "DiffChange")
  set("LReviewConflictRemote", "DiffAdd")
end

--- Build the buffer lines plus a map of which conflict starts at which line.
---@param mo_id string
---@return string[] lines, table[] rows  -- rows: { line = first line of block, c_id = ... }
local function render(mo_id)
  local conflicts = comments.get_conflicts(mo_id)
  local lines, rows = {}, {}

  lines[#lines + 1] = "=== Review Conflicts ==="
  if #conflicts == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "No conflicts. Local drafts and the remote agree."
    return lines, rows
  end

  lines[#lines + 1] = string.format(
    "%d conflict(s). Cursor onto a block, then [k] keep local / [a] accept remote.", #conflicts)
  lines[#lines + 1] = ""

  for _, c in ipairs(conflicts) do
    local reason = c.conflict_reason or "remote_edited"
    local where = string.format("%s:%d", c.path or "?", c.start_line or 0)
    local head = string.format("  %s  (%s)", where, reason == "remote_deleted" and "deleted on remote"
        or reason == "thread_gone" and "thread gone on remote" or "edited on remote")
    rows[#rows + 1] = { line = #lines + 1, c_id = c.c_id }
    lines[#lines + 1] = head
    lines[#lines + 1] = "  YOURS:"
    for _, l in ipairs(vim.split(c.body or "", "\n", { plain = true })) do
      lines[#lines + 1] = "    " .. l
    end
    lines[#lines + 1] = "  REMOTE:"
    for _, l in ipairs(vim.split(c.conflict_remote_body or "(empty)", "\n", { plain = true })) do
      lines[#lines + 1] = "    " .. l
    end
    lines[#lines + 1] = ""
  end

  return lines, rows
end

--- Which conflict block the cursor currently sits in.
---@param row integer
---@return table|nil
local function conflict_at(row)
  if not M.state then return nil end
  local found = nil
  for _, r in ipairs(M.state.rows) do
    if r.line <= row then found = r end
  end
  return found
end

local function redraw()
  if not M.state or not vim.api.nvim_buf_is_valid(M.state.bufnr) then return end
  local mo_id = review.current and review.current.detail and review.current.detail.mo_id
  if not mo_id then return end
  local lines, rows = render(mo_id)
  vim.bo[M.state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.bufnr, 0, -1, false, lines)
  vim.bo[M.state.bufnr].modifiable = false
  vim.bo[M.state.bufnr].bufhidden = "wipe"
  vim.bo[M.state.bufnr].filetype = "lreviewconflicts"
  M.state.rows = rows

  -- Highlight block boundaries by line so the two versions are scannable.
  local ns = vim.api.nvim_create_namespace("lreview.conflicts")
  vim.api.nvim_buf_clear_namespace(M.state.bufnr, ns, 0, -1)
  for _, r in ipairs(rows) do
    vim.api.nvim_buf_set_extmark(M.state.bufnr, ns, r.line - 1, 0, { hl_group = "LReviewConflictHeader" })
    vim.api.nvim_buf_set_extmark(M.state.bufnr, ns, r.line, 0, { hl_group = "LReviewConflictLocal", end_line = r.line + 1 })
  end
end

--- Resolve the conflict under the cursor.
---@param action "keep"|"remote"
local function resolve_at_cursor(action)
  local row = vim.api.nvim_win_get_cursor(M.state and M.state.winid or 0)[1]
  local target = conflict_at(row)
  if not target then
    vim.notify("lreview: move the cursor onto a conflict block", vim.log.levels.WARN)
    return
  end
  if action == "keep" then
    comments.resolve_conflict_keep_local(target.c_id)
    vim.notify("lreview: keeping your version — it will push on next submit", vim.log.levels.INFO)
  else
    comments.resolve_conflict_accept_remote(target.c_id)
    vim.notify("lreview: accepted the remote version", vim.log.levels.INFO)
  end
  redraw()
  local sync = require("lreview.sync")
  for bufnr, _ in pairs(require("lreview.ui.decor").enabled_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then sync.mark_dirty(bufnr) end
  end
  sync.schedule()
end

function M.close()
  if M.state and M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
    vim.api.nvim_win_close(M.state.winid, true)
  end
  M.state = nil
end

--- Open the conflict float for the active review.
function M.open()
  if not review.current or not review.current.detail then
    vim.notify("lreview: no active review; run LocalReviewStart first", vim.log.levels.WARN)
    return
  end
  setup_highlights()
  if M.state and vim.api.nvim_buf_is_valid(M.state.bufnr) then
    M.close()
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  local cfg = require("lreview.config").get_defaults()
  local ui = cfg.ui or {}
  local float = ui.float or {}
  local width = math.min(78, math.floor(vim.o.columns * (float.width or 0.6)))
  local height = math.min(24, math.floor(vim.o.lines * (float.height or 0.6)))

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = float.border or "rounded",
    title = " Review Conflicts ",
    title_pos = "center",
  })
  vim.bo[bufnr].swapfile = false

  M.state = { bufnr = bufnr, winid = winid, rows = {} }
  redraw()

  local opts = { silent = true, noremap = true, buffer = bufnr }
  vim.keymap.set("n", "k", function() resolve_at_cursor("keep") end, opts)
  vim.keymap.set("n", "a", function() resolve_at_cursor("remote") end, opts)
  vim.keymap.set("n", "r", redraw, opts)
  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "<esc>", M.close, opts)
end

return M
