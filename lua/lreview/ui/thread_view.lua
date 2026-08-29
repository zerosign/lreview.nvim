local comments = require("lreview.storage.comments")
local config = require("lreview.config")
local review = require("lreview.review")

local M = {}

-- Store active view state: { bufnr = bufnr, winid = winid, line_map = { [line] = c_id }, mo_id = mo_id, path = path, thread_id = thread_id }
M.state = nil

--- Close the active thread view if open.
function M.close()
  if M.state then
    if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
      vim.api.nvim_win_close(M.state.winid, true)
    end
    M.state = nil
  end
end

--- Render thread comments into a markdown string and construct line map.
---@param thread_id string
---@return string[] lines, table line_map
local function format_thread(thread_id)
  local ts = comments.comments_for_thread(thread_id)
  local lines = {}
  local line_map = {}

  local t = comments.get_thread(thread_id)
  local function add_line(text, c_id)
    lines[#lines + 1] = text
    if c_id then
      line_map[#lines] = c_id
    end
  end

  if t and comments.thread_is_resolved(t.state) then
    add_line("✔ RESOLVED THREAD")
    add_line("=================")
    add_line("")
  end

  for i, c in ipairs(ts) do
    local is_draft = not c.remote_id or c.remote_id == ""
    local author = c.author or "me"
    local status = ""
    if is_draft then
      status = " (Draft)"
    end
    local time_str = c.created_at or ""

    -- Format header:  author • time • status
    local header = " " .. author .. "  •  " .. time_str .. "  " .. status
    add_line(header, c.c_id)
    add_line(string.rep("─", vim.fn.strdisplaywidth(header)), c.c_id)

    -- Format body (split by lines)
    local body = c.body
    for part in body:gmatch("[^\r\n]+") do
      add_line(part, c.c_id)
    end

    -- Spacer between comments
    if i < #ts then
      add_line("")
    end
  end

  -- Help footer
  add_line("")
  add_line("───────────────────────────────────────────────────────────")
  add_line(" [r] Reply  |  [e] Edit Draft  |  [d] Delete Draft  |  [q] Close")
  local toggle_resolve_help = (t and comments.thread_is_resolved(t.state)) and " [s] Reopen Thread" or " [s] Resolve Thread"
  add_line(toggle_resolve_help)

  return lines, line_map
end

--- Draw/redraw the current thread view buffer.
function M.redraw()
  if not M.state or not vim.api.nvim_buf_is_valid(M.state.bufnr) then
    return
  end
  local lines, line_map = format_thread(M.state.thread_id)
  M.state.line_map = line_map

  -- Temporarily set modifiable to update buffer contents
  vim.bo[M.state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.bufnr, 0, -1, false, lines)
  vim.bo[M.state.bufnr].modifiable = false
end

--- Resolve key actions (reply, edit, delete) in the current thread view.
---@param action "reply"|"edit"|"delete"
local function handle_action(action)
  if not M.state then
    return
  end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local c_id = M.state.line_map[cursor_line]

  if action == "reply" then
    require("lreview.ui.editor").open_reply(M.state.thread_id)
  elseif action == "edit" then
    if not c_id then
      vim.notify("lreview: move cursor onto a comment to edit it", vim.log.levels.WARN)
      return
    end
    local ts = comments.comments_for_thread(M.state.thread_id)
    local target_comment
    for _, c in ipairs(ts) do
      if c.c_id == c_id then
        target_comment = c
        break
      end
    end
    if not target_comment then return end
    require("lreview.ui.editor").open_edit(c_id, target_comment.body)
  elseif action == "delete" then
    if not c_id then
      vim.notify("lreview: move cursor onto a comment to delete it", vim.log.levels.WARN)
      return
    end
    local ts = comments.comments_for_thread(M.state.thread_id)
    local target_comment
    for _, c in ipairs(ts) do
      if c.c_id == c_id then
        target_comment = c
        break
      end
    end
    if not target_comment then return end

    local is_synced = target_comment.remote_id and target_comment.remote_id ~= ""
    if is_synced then
      comments.soft_delete_comment(c_id)
      vim.notify("lreview: comment marked for deletion (press P on the panel to push)", vim.log.levels.INFO)
    else
      comments.delete_comment(c_id)
      vim.notify("lreview: draft deleted", vim.log.levels.INFO)
    end

    -- If no active comments left in thread, close thread view (only delete thread row if it is a draft)
    local remaining = comments.comments_for_thread(M.state.thread_id)
    if #remaining == 0 then
      local t = comments.get_thread(M.state.thread_id)
      if t and comments.thread_is_draft(t.state) then
        comments.delete_thread(M.state.thread_id)
      end
      M.close()
      vim.notify("lreview: thread closed", vim.log.levels.INFO)
    else
      M.redraw()
    end
    local bufnr = vim.fn.bufnr(M.state.path)
    if bufnr ~= -1 then
      require("lreview.ui.decor").refresh(bufnr)
    end
  elseif action == "resolve" then
    local t = comments.get_thread(M.state.thread_id)
    if t then
      local new_val = not comments.thread_is_resolved(t.state)
      local ok, err = review.resolve_thread(M.state.thread_id, new_val)
      if not ok then
        vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      M.redraw()
      vim.notify(new_val and "lreview: thread resolved" or "lreview: thread reopened", vim.log.levels.INFO)
      local bufnr = vim.fn.bufnr(M.state.path)
      if bufnr ~= -1 then
        require("lreview.ui.decor").refresh(bufnr)
      end
    end
  elseif action == "submit" then
    vim.notify("lreview: submitting review...", vim.log.levels.INFO)
    local count, err = review.submit_review()
    if err then
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
    else
      vim.notify(string.format("lreview: successfully submitted %d comment(s)", count), vim.log.levels.INFO)
      M.redraw()
      local bufnr = vim.fn.bufnr(M.state.path)
      if bufnr ~= -1 then
        require("lreview.ui.decor").refresh(bufnr)
      end
    end
  end
end

--- Open or refresh the thread view window at the current cursor line.
---@param bufnr integer
---@param rel_path string
---@param line integer
function M.show(bufnr, rel_path, line)
  if not review.current then
    return
  end
  local mo_id = review.current.detail.mo_id
  local threads = comments.threads_for_buffer(mo_id, rel_path, line)

  if #threads == 0 then
    -- Clean close if no threads present.
    M.close()
    return
  end
  local t = threads[1]

  -- If already viewing this thread, focus it (if already visible), redraw, and return.
  if M.state and M.state.thread_id == t.t_id and vim.api.nvim_buf_is_valid(M.state.bufnr) then
    if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
      vim.api.nvim_set_current_win(M.state.winid)
    end
    M.redraw()
    return
  end

  M.close()

  -- Reuse or create the read-only markdown buffer
  local buf = M.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    M.buf = buf

    -- Apply buffer-local mappings once
    local opts = { silent = true, noremap = true, buffer = buf }
    vim.keymap.set("n", "q", function() M.close() end, opts)
    vim.keymap.set("n", "<esc>", function() M.close() end, opts)
    vim.keymap.set("n", "r", function() handle_action("reply") end, opts)
    vim.keymap.set("n", "e", function() handle_action("edit") end, opts)
    vim.keymap.set("n", "d", function() handle_action("delete") end, opts)
    vim.keymap.set("n", "s", function() handle_action("resolve") end, opts)
    vim.keymap.set("n", "P", function() handle_action("submit") end, opts)
  end

  -- Save initial state
  M.state = {
    bufnr = buf,
    winid = nil,
    line_map = {},
    mo_id = mo_id,
    path = rel_path,
    thread_id = t.t_id,
  }

  M.redraw()

  -- Retrieve layout configuration
  local ui_cfg = config.get_defaults().ui or {}
  local layout = ui_cfg.layout or "split"
  if layout == "float" then
    layout = "split"
  end
  local winid

  if layout == "split" or layout == "vsplit" then
    local split_pos = ui_cfg.split and ui_cfg.split.position or "botright"
    local split_size = ui_cfg.split and ui_cfg.split.size or 15
    local split_cmd = (layout == "vsplit") and "vnew" or "new"

    vim.cmd(string.format("silent %s %d%s", split_pos, split_size, split_cmd))
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, buf)
  else
    -- Full buffer layout: open in current window
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, buf)
  end

  M.state.winid = winid
end

return M
