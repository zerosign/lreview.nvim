local comments = require("lreview.storage.comments")
local config = require("lreview.config")
local review = require("lreview.review")

local M = {}

-- Store active view state: { bufnr, winid, line_map, thread_line_map, mo_id, path, line }
M.state = nil

local sync = require("lreview.sync")
sync.subscribe("panel", function()
  if M.state and vim.api.nvim_buf_is_valid(M.state.bufnr) then
    M.redraw()
  end
end)

--- Close the active thread view if open.
function M.close()
  if M.state then
    if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
      vim.api.nvim_win_close(M.state.winid, true)
    end
    M.state = nil
  end
end

--- Render thread comments into a markdown string and construct line maps.
---@param mo_id integer
---@param rel_path string
---@param line integer
---@return string[] lines, table line_map, table thread_line_map
local function format_threads_for_line(mo_id, rel_path, line)
  local threads = comments.threads_for_buffer(mo_id, rel_path, line)
  local lines = {}
  local line_map = {}
  local thread_line_map = {}

  local function add_line(text, c_id, t_id)
    lines[#lines + 1] = text
    if c_id then
      line_map[#lines] = c_id
    end
    if t_id then
      thread_line_map[#lines] = t_id
    end
  end

  for idx, t in ipairs(threads) do
    if idx > 1 then
      add_line("")
      add_line("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
      add_line("")
    end

    local ts = comments.comments_for_thread(t.t_id)
    local resolved_tag = comments.thread_is_resolved(t.state) and " [✔ RESOLVED]" or " [● ACTIVE]"
    
    add_line(string.format("💬 THREAD #%d%s", idx, resolved_tag), nil, t.t_id)
    add_line("===========================================================", nil, t.t_id)
    add_line("", nil, t.t_id)

    for i, c in ipairs(ts) do
      local is_draft = not c.remote_id or c.remote_id == ""
      local author = c.author or "me"
      local status = is_draft and " (Draft)" or ""
      local time_str = c.created_at or ""

      -- Format header:  author • time • status
      local header = " " .. author .. "  •  " .. time_str .. "  " .. status
      add_line(header, c.c_id, t.t_id)
      add_line(string.rep("─", vim.fn.strdisplaywidth(header)), c.c_id, t.t_id)

      -- Format body (split by lines)
      local body = c.body
      for part in body:gmatch("[^\r\n]+") do
        add_line(part, c.c_id, t.t_id)
      end

      -- Spacer between comments in the same thread
      if i < #ts then
        add_line("", nil, t.t_id)
      end
    end
  end

  -- Help footer
  add_line("")
  add_line("───────────────────────────────────────────────────────────")
  add_line(" [r] Reply  |  [e] Edit Draft  |  [d] Delete Draft  |  [q] Close")
  add_line(" [s] Toggle Thread Resolve State  |  [P] Submit Review")

  return lines, line_map, thread_line_map
end

--- Draw/redraw the current thread view buffer.
function M.redraw()
  if not M.state or not vim.api.nvim_buf_is_valid(M.state.bufnr) then
    return
  end
  local lines, line_map, thread_line_map = format_threads_for_line(M.state.mo_id, M.state.path, M.state.line)
  M.state.line_map = line_map
  M.state.thread_line_map = thread_line_map

  -- Temporarily set modifiable to update buffer contents
  vim.bo[M.state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.bufnr, 0, -1, false, lines)
  vim.bo[M.state.bufnr].modifiable = false
end

--- Resolve key actions (reply, edit, delete) in the current thread view.
---@param action "reply"|"edit"|"delete"|"resolve"|"submit"
local function handle_action(action)
  if not M.state then
    return
  end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local c_id = M.state.line_map[cursor_line]
  local t_id = M.state.thread_line_map[cursor_line]

  -- If cursor is on a non-comment line, search upwards then downwards to find closest thread ID
  if not t_id then
    for i = cursor_line, 1, -1 do
      if M.state.thread_line_map[i] then
        t_id = M.state.thread_line_map[i]
        break
      end
    end
  end
  if not t_id then
    for i = cursor_line, #M.state.thread_line_map do
      if M.state.thread_line_map[i] then
        t_id = M.state.thread_line_map[i]
        break
      end
    end
  end

  if not t_id then
    vim.notify("lreview: move cursor into a thread block to perform action", vim.log.levels.WARN)
    return
  end

  if action == "reply" then
    require("lreview.ui.editor").open_reply(t_id)
  elseif action == "edit" then
    if not c_id then
      vim.notify("lreview: move cursor onto a comment to edit it", vim.log.levels.WARN)
      return
    end
    local ts = comments.comments_for_thread(t_id)
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
    local ts = comments.comments_for_thread(t_id)
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

    -- If no active comments left in thread, close or delete
    local remaining = comments.comments_for_thread(t_id)
    if #remaining == 0 then
      local t = comments.get_thread(t_id)
      if t and comments.thread_is_draft(t.state) then
        comments.delete_thread(t_id)
      end
      -- If there are other threads on the line, just redraw instead of closing the whole window
      local all_threads = comments.threads_for_buffer(M.state.mo_id, M.state.path, M.state.line)
      if #all_threads == 0 then
        M.close()
        vim.notify("lreview: thread closed", vim.log.levels.INFO)
      else
        M.redraw()
      end
    else
      M.redraw()
    end

    local bufnr = vim.fn.bufnr(M.state.path)
    if bufnr ~= -1 then
      require("lreview.ui.decor").refresh(bufnr)
    end
  elseif action == "resolve" then
    local t = comments.get_thread(t_id)
    if t then
      local new_val = not comments.thread_is_resolved(t.state)
      local ok, err = review.resolve_thread(t_id, new_val)
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

  -- If already viewing this line, focus it (if already visible), redraw, and return.
  if M.state and M.state.path == rel_path and M.state.line == line and vim.api.nvim_buf_is_valid(M.state.bufnr) then
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
    thread_line_map = {},
    mo_id = mo_id,
    path = rel_path,
    line = line,
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
