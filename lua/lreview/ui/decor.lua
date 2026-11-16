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

  -- Group threads by line number to avoid duplicate side-by-side extmarks
  local line_threads = {}
  local line_order = {}
  for _, t_id in ipairs(thread_order) do
    local t = threads[t_id]
    local l = t.start_line
    if not line_threads[l] then
      line_threads[l] = {}
      table.insert(line_order, l)
    end
    table.insert(line_threads[l], t)
  end

  for _, l in ipairs(line_order) do
    local ts = line_threads[l]
    local total_comments = 0
    local draft_count = 0
    local any_active = false
    local any_draft = false
    local all_resolved = true

    for _, t in ipairs(ts) do
      total_comments = total_comments + #t.comments
      local is_resolved = t.resolved
      local is_draft = t.is_draft
      if not is_resolved then
        all_resolved = false
      end
      if is_draft then
        any_draft = true
      else
        any_active = true
      end
      for _, c in ipairs(t.comments) do
        if not c.remote_id or c.remote_id == "" then
          draft_count = draft_count + 1
        end
      end
    end

    local sign_hl = all_resolved and "Comment" or (any_draft and "LReviewSignDraft" or "LReviewSignSynced")
    local text_hl = all_resolved and "Comment" or (any_draft and "LReviewVirtTextDraft" or "LReviewVirtTextSynced")
    local num_hl = all_resolved and "LReviewNumResolved" or (any_draft and "LReviewNumDraft" or "LReviewNumSynced")
    local sign_text = all_resolved and "✔" or (any_draft and "💬" or "●")

    -- Each thread has exactly 1 root comment; the rest are replies. Total
    -- replies on this line = total_comments - #ts.
    local reply_count = total_comments - #ts

    -- Base preview. Single-thread lines get a rich snippet (`@author: "…"`),
    -- which is what most reviews look like. Multi-thread lines keep the
    -- aggregate form so the preview never overflows the editor.
    local virt_text_str
    if #ts == 1 then
      local first_thread = ts[1]
      local first_comment = first_thread.comments[1]
      if first_comment then
        local author = first_comment.author or "me"
        local body = (first_comment.body or ""):gsub("[\r\n]+", " ")
        -- Truncate at 45 chars (multibyte-safe via strcharpart) so the EOL
        -- preview stays subtle. Longer bodies end with `…`.
        local max_chars = 45
        if vim.fn.strchars(body) > max_chars then
          body = vim.fn.strcharpart(body, 0, max_chars) .. "…"
        end
        virt_text_str = string.format('   @%s: "%s"', author, body)
      else
        virt_text_str = "   (empty thread)"
      end
    else
      virt_text_str = string.format("   %d threads (%d comments)", #ts, total_comments)
    end

    if reply_count > 0 then
      local noun = (reply_count == 1) and "reply" or "replies"
      virt_text_str = virt_text_str .. string.format(" (+%d %s)", reply_count, noun)
    end
    if draft_count > 0 then
      virt_text_str = virt_text_str .. " (" .. draft_count .. " draft)"
    end
    if all_resolved then
      virt_text_str = virt_text_str .. " (Resolved)"
    end

    -- Extmarks are 0-indexed for lines.
    local line_idx = l - 1
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
  -- Use async path: if the cache is populated, apply highlights immediately;
  -- otherwise kick off a background thread and re-refresh when done. (item 7)
  local sync = require("lreview.sync")
  local changed = sync.get_changed_lines_cached(review.current.cwd, rel_path)
  if changed then
    for line_num, _ in pairs(changed) do
      local l_idx = line_num - 1
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, l_idx, 0, {
        number_hl_group = "LReviewDiffAdd",
        priority = 50,
      })
    end
  else
    -- Cache miss: compute on worker thread; re-refresh buffer when done.
    sync.get_changed_lines_async(review.current.cwd, rel_path, bufnr)
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
    M._wire_open(bufnr)
  end
end

--- Disable review highlights for a buffer.
---@param bufnr integer
function M.disable(bufnr)
  if M.enabled_buffers[bufnr] then
    M.clear(bufnr)
    M._unwire_open(bufnr)
    M.enabled_buffers[bufnr] = nil
  end
end

--- Toggle review highlights in the current buffer.
---@param bufnr integer|nil
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.enabled_buffers[bufnr] then
    M.clear(bufnr)
    M._unwire_open(bufnr)
    M.enabled_buffers[bufnr] = nil
    vim.notify("lreview: review highlights disabled", vim.log.levels.INFO)
  else
    M.enabled_buffers[bufnr] = true
    M.refresh(bufnr)
    M._wire_open(bufnr)
    vim.notify("lreview: review highlights enabled", vim.log.levels.INFO)
  end
end

--- Install the `K` keymap (and optional `CursorHold` autocmd) for a buffer.
--- Idempotent. `ui.hover_open = true` in setup opts turns the passive hover
--- behavior on; the `K` keymap is always installed and does not conflict with
--- LSP hover (which most users bind to `<C-k>` or a different leader).
---@param bufnr integer
function M._wire_open(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local thread_view = require("lreview.ui.thread_view")

  vim.keymap.set("n", "K", function()
    if not review.current then return end
    local abs = vim.api.nvim_buf_get_name(bufnr)
    local root = review.current.cwd
    if root and abs:sub(1, #root) == #root and abs:sub(#root + 1, #root + 1) == "/" then
      abs = abs:sub(#root + 2)
    end
    local line = vim.api.nvim_win_get_cursor(0)[1]
    thread_view.show(bufnr, abs, line)
  end, { silent = true, noremap = true, buffer = bufnr, desc = "lreview: open thread" })

  local ui_cfg = (require("lreview.config").get_defaults().ui or {})
  if ui_cfg.hover_open == true then
    local grp = vim.api.nvim_create_augroup("lreview_hover_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd("CursorHold", {
      group = grp,
      buffer = bufnr,
      callback = function()
        if not review.current then return end
        local rel = get_rel_path(bufnr)
        if not rel then return end
        local line = vim.api.nvim_win_get_cursor(0)[1]
        local threads = comments.threads_for_buffer(review.current.detail.mo_id, rel, line)
        if #threads > 0 then
          thread_view.show(bufnr, rel, line)
        end
      end,
    })
  end
end

--- Remove the keymaps/autocmds installed by `_wire_open`.
---@param bufnr integer
function M._unwire_open(bufnr)
  pcall(vim.keymap.del, "n", "K", { buffer = bufnr })
  local grp_name = "lreview_hover_" .. bufnr
  pcall(vim.api.nvim_del_augroup_by_name, grp_name)
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

local function get_mr_threads_sorted()
  if not review.current or not review.current.detail then return {} end
  local mo_id = review.current.detail.mo_id
  local all = comments.threads_for_mr(mo_id)
  table.sort(all, function(a, b)
    if a.path == b.path then
      return (a.start_line or 0) < (b.start_line or 0)
    end
    return (a.path or "") < (b.path or "")
  end)
  return all
end

local function jump_to_thread(t)
  if not t or not review.current then return end
  local root = review.current.cwd or vim.fn.getcwd()
  local target_path = root .. "/" .. t.path
  local cur_buf = vim.api.nvim_get_current_buf()
  local cur_abs = vim.api.nvim_buf_get_name(cur_buf)
  if cur_abs ~= target_path then
    vim.cmd("edit " .. vim.fn.fnameescape(target_path))
  end
  local target_buf = vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_win_set_cursor, 0, { t.start_line, 0 })
  require("lreview.ui.thread_view").show(target_buf, t.path, t.start_line)
end

--- Jump to the next review thread across the MR.
function M.next_thread()
  local bufnr = vim.api.nvim_get_current_buf()
  local rel_path = get_rel_path(bufnr)
  local lines = M.get_thread_lines(bufnr)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  -- Try within current buffer first
  for _, l in ipairs(lines) do
    if l > cursor_line then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      require("lreview.ui.thread_view").show(bufnr, rel_path, l)
      return
    end
  end

  -- Advance across MR files
  local all = get_mr_threads_sorted()
  if #all == 0 then
    vim.notify("lreview: no review comments in this review", vim.log.levels.WARN)
    return
  end

  if rel_path then
    for _, t in ipairs(all) do
      if (t.path > rel_path) or (t.path == rel_path and (t.start_line or 0) > cursor_line) then
        jump_to_thread(t)
        return
      end
    end
  end

  -- Wrap around to first thread in the review
  jump_to_thread(all[1])
end

--- Jump to the previous review thread across the MR.
function M.prev_thread()
  local bufnr = vim.api.nvim_get_current_buf()
  local rel_path = get_rel_path(bufnr)
  local lines = M.get_thread_lines(bufnr)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  -- Try within current buffer first
  for i = #lines, 1, -1 do
    local l = lines[i]
    if l < cursor_line then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      require("lreview.ui.thread_view").show(bufnr, rel_path, l)
      return
    end
  end

  -- Move backward across MR files
  local all = get_mr_threads_sorted()
  if #all == 0 then
    vim.notify("lreview: no review comments in this review", vim.log.levels.WARN)
    return
  end

  if rel_path then
    for i = #all, 1, -1 do
      local t = all[i]
      if (t.path < rel_path) or (t.path == rel_path and (t.start_line or 0) < cursor_line) then
        jump_to_thread(t)
        return
      end
    end
  end

  -- Wrap around to last thread in the review
  jump_to_thread(all[#all])
end

--- Populate Neovim quickfix list with all review threads.
function M.populate_quickfix()
  if not review.current or not review.current.detail then
    vim.notify("lreview: no active review; run LocalReviewStart first", vim.log.levels.WARN)
    return
  end
  local threads = get_mr_threads_sorted()
  if #threads == 0 then
    vim.notify("lreview: no review comments in this review", vim.log.levels.INFO)
    return
  end
  local root = review.current.cwd or vim.fn.getcwd()
  local qf_items = {}
  for _, t in ipairs(threads) do
    local cs = comments.comments_for_thread(t.t_id)
    local first = cs[1]
    local preview = first and first.body or "(no content)"
    preview = preview:gsub("[\r\n]+", " ")
    local author = first and first.author or "me"
    local status = comments.thread_is_resolved(t.state) and "[Resolved]"
        or (comments.thread_is_draft(t.state) and "[Draft]" or "[Active]")
    local abs_path = root .. "/" .. t.path
    qf_items[#qf_items + 1] = {
      filename = abs_path,
      lnum = t.start_line,
      col = 1,
      text = string.format("%s @%s: %s", status, author, preview),
    }
  end
  vim.fn.setqflist(qf_items, "r")
  pcall(vim.fn.setqflist, {}, "a", { title = "LReview: #" .. tostring(review.current.detail.number) })
  vim.cmd("copen")
  vim.notify(string.format("lreview: loaded %d comment(s) into quickfix", #qf_items), vim.log.levels.INFO)
end

return M
