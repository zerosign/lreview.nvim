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

--- Get the repo-relative path of a buffer.
---@param bufnr integer
---@return string|nil
local function get_rel_path(bufnr)
  local abs = vim.api.nvim_buf_get_name(bufnr)
  if abs == "" then
    return nil
  end
  local root = git.root(vim.fn.getcwd())
  if not root then
    return nil
  end
  if vim.startswith(abs, root .. "/") then
    return abs:sub(#root + 2)
  end
  return abs
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
        resolved = c.resolved,
        is_draft = c.thread_is_draft,
        comments = {}
      }
      thread_order[#thread_order + 1] = c.t_id
    end
    table.insert(threads[c.t_id].comments, c)
  end

  for _, t_id in ipairs(thread_order) do
    local t = threads[t_id]
    local cs = t.comments
    local is_draft = (t.is_draft == 1)
    local is_resolved = (t.resolved == 1)
    local sign_hl = is_resolved and "Comment" or (is_draft and "LReviewSignDraft" or "LReviewSignSynced")
    local text_hl = is_resolved and "Comment" or (is_draft and "LReviewVirtTextDraft" or "LReviewVirtTextSynced")
    local sign_text = is_resolved and "✔" or (is_draft and "💬" or "●")

    local draft_count = 0
    for _, c in ipairs(cs) do
      if not c.remote_id or c.remote_id == "" then
        draft_count = draft_count + 1
      end
    end

    local virt_text_str = string.format("   %d comment(s)", #cs)
    if draft_count > 0 then
      virt_text_str = virt_text_str .. string.format(" (%d draft)", draft_count)
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
    })
  end
end

-- Tracks enabled buffers
M.enabled_buffers = {}

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

    -- Auto-hover when cursor pauses on a line with review comments
    vim.api.nvim_create_autocmd("CursorHold", {
      buffer = bufnr,
      callback = function()
        local line = vim.api.nvim_win_get_cursor(0)[1]
        local abs = vim.api.nvim_buf_get_name(0)
        local root = git.root(vim.fn.getcwd())
        local path = abs
        if root and vim.startswith(abs, root .. "/") then
          path = abs:sub(#root + 2)
        end
        if review.current then
          local threads = comments.threads_for_buffer(review.current.detail.mo_id, path, line)
          if #threads > 0 then
            require("lreview.ui.thread_view").show(bufnr, path, line)
          else
            require("lreview.ui.thread_view").close()
          end
        end
      end,
      group = vim.api.nvim_create_augroup(grp_name, { clear = true }),
    })

    vim.notify("lreview: review highlights enabled", vim.log.levels.INFO)
  end
end

return M
