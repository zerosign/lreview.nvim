local comments = require("lreview.storage.comments")
local review = require("lreview.review")
local git = require("lreview.git")

local M = {}

local ns = vim.api.nvim_create_namespace("lreview_decor")

-- Default highlights mapped to standard groups.
local function setup_highlights()
  local defs = {
    LReviewSignDraft = { link = "WarningMsg" },
    LReviewSignSynced = { link = "Comment" },
    LReviewVirtTextDraft = { link = "WarningMsg" },
    LReviewVirtTextSynced = { link = "Comment" },
    LReviewNumDraft = { link = "DiffChange" },
    LReviewNumSynced = { link = "DiffAdd" },
    LReviewNumResolved = { link = "Comment" },
    LReviewDiffAdd = { link = "DiffAdd" },
  }
  for name, opts in pairs(defs) do
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end
end

--- Clear all review decorations from a buffer.
---@param bufnr integer
function M.clear(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

local function get_rel_path(bufnr)
  local abs = vim.api.nvim_buf_get_name(bufnr)
  if abs == "" then
    return nil
  end
  if not review.current then
    return nil
  end
  local root = review.current.cwd
  if not root then
    return nil
  end
  if root:sub(-1) ~= "/" and root:sub(-1) ~= "\\" then
    root = root .. "/"
  end
  if vim.startswith(abs, root) then
    return abs:sub(#root + 1)
  end
  return nil
end

--- Refresh review decorations in a buffer.
---@param bufnr integer
function M.refresh(bufnr)
  M.clear(bufnr)
  setup_highlights()

  if not review.current then
    return
  end
  local mo_id = review.current.detail.mo_id
  local rel_path = get_rel_path(bufnr)
  if not rel_path then
    return
  end

  local all_comments = comments.comments_for_buffer(mo_id, rel_path)

  -- Group comments by thread t_id while preserving order
  local threads = {}
  local thread_order = {}
  for _, c in ipairs(all_comments) do
    if not threads[c.t_id] then
      threads[c.t_id] = {
        t_id = c.t_id,
        start_line = c.start_line,
        resolved = comments.thread_is_resolved(c.thread_state),
        is_draft = comments.thread_is_draft(c.thread_state),
        comments = {}
      }
      thread_order[#thread_order + 1] = c.t_id
    end
    table.insert(threads[c.t_id].comments, c)
  end

  for _, t_id in ipairs(thread_order) do
    local t = threads[t_id]
    local cs = t.comments
    local is_draft = t.is_draft
    local is_resolved = t.resolved
    local sign_hl = is_resolved and "Comment" or (is_draft and "LReviewSignDraft" or "LReviewSignSynced")
    local text_hl = is_resolved and "Comment" or (is_draft and "LReviewVirtTextDraft" or "LReviewVirtTextSynced")
    local num_hl = is_resolved and "LReviewNumResolved" or (is_draft and "LReviewNumDraft" or "LReviewNumSynced")
    local sign_text = is_resolved and "✔" or (is_draft and "💬" or "●")

    local draft_count = 0
    for _, c in ipairs(cs) do
      if not c.remote_id or c.remote_id == "" then
        draft_count = draft_count + 1
      end
    end

    local virt_text_str = "   " .. #cs .. " comment(s)"
    if draft_count > 0 then
      virt_text_str = virt_text_str .. " (" .. draft_count .. " draft)"
    end
    if is_resolved then
      virt_text_str = virt_text_str .. " (Resolved)"
    end

    -- Extmarks are 0-indexed for lines.
    local line_idx = t.start_line - 1
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line_idx, 0, {
      sign_text = sign_text,
      sign_hl_group = sign_hl,
      virt_text = { { virt_text_str, text_hl } },
      virt_text_pos = "eol",
      number_hl_group = num_hl,
      priority = 100,
    })
  end

  -- Highlight diff changes (added/modified lines in MR)
  local target_branch = review.current.detail.target_branch
  if target_branch then
    local changed = git.changed_lines(target_branch, rel_path, review.current.cwd)
    if changed then
      for line_num, _ in pairs(changed) do
        local l_idx = line_num - 1
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, l_idx, 0, {
          number_hl_group = "LReviewDiffAdd",
          priority = 50,
        })
      end
    end
  end
end

-- Tracks enabled buffers
M.enabled_buffers = {}

--- Enable review highlights for a buffer.
---@param bufnr integer
function M.enable(bufnr)
  if not M.enabled_buffers[bufnr] then
    M.enabled_buffers[bufnr] = true
    M.refresh(bufnr)
  end
end

--- Disable review highlights for a buffer.
---@param bufnr integer
function M.disable(bufnr)
  if M.enabled_buffers[bufnr] then
    M.clear(bufnr)
    local grp_name = "lreview_hover_" .. bufnr
    pcall(vim.api.nvim_del_augroup_by_name, grp_name)
    M.enabled_buffers[bufnr] = nil
  end
end

--- Toggle review highlights in the current buffer.
---@param bufnr integer|nil
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local grp_name = "lreview_hover_" .. bufnr
  if M.enabled_buffers[bufnr] then
    M.clear(bufnr)
    pcall(vim.api.nvim_del_augroup_by_name, grp_name)
    M.enabled_buffers[bufnr] = nil
    vim.notify("lreview: review highlights disabled", vim.log.levels.INFO)
  else
    M.enabled_buffers[bufnr] = true
    M.refresh(bufnr)



    vim.notify("lreview: review highlights enabled", vim.log.levels.INFO)
  end
end

--- Get all lines in the active buffer that have discussion threads.
---@param bufnr integer
---@return integer[]
function M.get_thread_lines(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not review.current then return {} end
  local rel_path = get_rel_path(bufnr)
  if not rel_path then return {} end
  local mo_id = review.current.detail.mo_id
  local all_comments = comments.comments_for_buffer(mo_id, rel_path)
  local lines = {}
  local seen = {}
  for _, c in ipairs(all_comments) do
    if not seen[c.start_line] then
      seen[c.start_line] = true
      table.insert(lines, c.start_line)
    end
  end
  table.sort(lines)
  return lines
end

--- Jump to the next review thread in the current buffer.
function M.next_thread()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = M.get_thread_lines(bufnr)
  if #lines == 0 then
    vim.notify("lreview: no review comments in this buffer", vim.log.levels.WARN)
    return
  end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  for _, l in ipairs(lines) do
    if l > cursor_line then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      require("lreview.ui.thread_view").show(bufnr, get_rel_path(bufnr), l)
      return
    end
  end
  -- wrap around to first
  vim.api.nvim_win_set_cursor(0, { lines[1], 0 })
  require("lreview.ui.thread_view").show(bufnr, get_rel_path(bufnr), lines[1])
end

--- Jump to the previous review thread in the current buffer.
function M.prev_thread()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = M.get_thread_lines(bufnr)
  if #lines == 0 then
    vim.notify("lreview: no review comments in this buffer", vim.log.levels.WARN)
    return
  end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  for i = #lines, 1, -1 do
    local l = lines[i]
    if l < cursor_line then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      require("lreview.ui.thread_view").show(bufnr, get_rel_path(bufnr), l)
      return
    end
  end
  -- wrap around to last
  vim.api.nvim_win_set_cursor(0, { lines[#lines], 0 })
  require("lreview.ui.thread_view").show(bufnr, get_rel_path(bufnr), lines[#lines])
end

return M
