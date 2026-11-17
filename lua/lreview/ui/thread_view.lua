local comments = require("lreview.storage.comments")
local config = require("lreview.config")
local review = require("lreview.review")
local decor = require("lreview.ui.decor")

local M = {}

local ns = vim.api.nvim_create_namespace("lreview_thread_view")

local function setup_highlights()
  local defs = {
    LReviewThreadHeader = { link = "Title" },
    LReviewThreadDivider = { link = "Comment" },
    LReviewThreadLocal = { link = "DiagnosticWarn" },
    LReviewThreadRemote = { link = "DiagnosticOk" },
    LReviewThreadConflict = { link = "DiagnosticError" },
    LReviewThreadAuthor = { link = "Identifier" },
    LReviewThreadTime = { link = "Comment" },
  }
  for name, opts in pairs(defs) do
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end
end

-- Format an ISO 8601 timestamp string into a clean "YYYY-MM-DD HH:MM:SS" display.
local function format_time(ts)
  if not ts or ts == "" then return "" end
  local date, time = ts:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d:%d%d)")
  if date and time then
    return date .. " " .. time
  end
  return ts
end

-- Resolve status badge and highlight group for a comment.
local function comment_status_badge(c, is_first)
  if c.state == comments.STATE.CONFLICT then
    return "[⚠ CONFLICT (Remote Changed)]", "LReviewThreadConflict"
  elseif c.state == comments.STATE.MODIFIED then
    return "[✎ Local Edit (Unsynced)]", "LReviewThreadLocal"
  elseif c.state == comments.STATE.DELETED then
    return "[✖ Local Delete (Unsynced)]", "LReviewThreadLocal"
  elseif c.state == comments.STATE.DRAFT or (not c.remote_id or c.remote_id == "") then
    if is_first then
      return "[● Local Draft (Unsynced)]", "LReviewThreadLocal"
    else
      return "[● Local Reply (Unsynced)]", "LReviewThreadLocal"
    end
  else
    return "[✔ Remote (Synced)]", "LReviewThreadRemote"
  end
end

-- Store active view state: { bufnr, winid, line_map, thread_line_map, mo_id, path, line }
M.state = nil
-- Active stacked reply float: { bufnr, winid, t_id, thread_winid }
M.reply_state = nil

local sync = require("lreview.sync")
sync.subscribe("panel", function()
  if M.state and vim.api.nvim_buf_is_valid(M.state.bufnr) then
    M.redraw()
  end
end)

--- Close the active thread view if open.
function M.close()
  M.close_reply()
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
---@return string[] lines, table line_map, table thread_line_map, table highlights
local function format_threads_for_line(mo_id, rel_path, line)
  local threads = comments.threads_for_buffer(mo_id, rel_path, line)
  local lines = {}
  local line_map = {}
  local thread_line_map = {}
  local highlights = {}

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
      highlights[#highlights + 1] = { line = #lines - 1, hl_group = "LReviewThreadDivider", col_start = 0, col_end = -1 }
      add_line("")
    end

    local ts = comments.comments_for_thread(t.t_id)

    -- Count unsynced items in this thread
    local unsynced_count = 0
    for _, c in ipairs(ts) do
      if c.state ~= comments.STATE.SYNCED or (not c.remote_id or c.remote_id == "") then
        unsynced_count = unsynced_count + 1
      end
    end

    local resolved_tag = comments.thread_is_resolved(t.state) and " [✔ RESOLVED]" or " [● ACTIVE]"
    local sync_tag = (unsynced_count > 0)
      and string.format(" [● %d Unsynced]", unsynced_count)
      or " [✔ Synced]"

    add_line(string.format("💬 THREAD #%d%s%s", idx, resolved_tag, sync_tag), nil, t.t_id)
    highlights[#highlights + 1] = { line = #lines - 1, hl_group = "LReviewThreadHeader", col_start = 0, col_end = -1 }

    add_line("===========================================================", nil, t.t_id)
    highlights[#highlights + 1] = { line = #lines - 1, hl_group = "LReviewThreadDivider", col_start = 0, col_end = -1 }
    add_line("", nil, t.t_id)

    for i, c in ipairs(ts) do
      local author = c.author or "me"
      local time_str = format_time(c.created_at)
      local badge, badge_hl = comment_status_badge(c, i == 1)

      -- Format header:  author  •  time  •  badge
      local icon_part = " "
      local author_part = author
      local time_part = (time_str ~= "") and ("  •  " .. time_str) or ""
      local badge_part = "  •  " .. badge

      local header = icon_part .. author_part .. time_part .. badge_part
      add_line(header, c.c_id, t.t_id)
      local cur_line_idx = #lines - 1

      local c_start = #icon_part
      local c_end = c_start + #author_part
      highlights[#highlights + 1] = { line = cur_line_idx, hl_group = "LReviewThreadAuthor", col_start = c_start, col_end = c_end }

      if time_str ~= "" then
        local t_start = c_end + 5
        local t_end = t_start + #time_str
        highlights[#highlights + 1] = { line = cur_line_idx, hl_group = "LReviewThreadTime", col_start = t_start, col_end = t_end }
      end

      local b_start = #header - #badge
      local b_end = #header
      highlights[#highlights + 1] = { line = cur_line_idx, hl_group = badge_hl, col_start = b_start, col_end = b_end }

      local underline = string.rep("─", vim.fn.strdisplaywidth(header))
      add_line(underline, c.c_id, t.t_id)
      highlights[#highlights + 1] = { line = #lines - 1, hl_group = "LReviewThreadDivider", col_start = 0, col_end = -1 }

      -- Format body (split by lines)
      local body = c.body or ""
      for part in body:gmatch("[^\r\n]+") do
        add_line(part, c.c_id, t.t_id)
      end

      -- Clear divider line between comments in the same thread
      if i < #ts then
        add_line("", nil, t.t_id)
        add_line("  ─────────────────────────────────────────────────────────", nil, t.t_id)
        highlights[#highlights + 1] = { line = #lines - 1, hl_group = "LReviewThreadDivider", col_start = 0, col_end = -1 }
        add_line("", nil, t.t_id)
      end
    end
  end

  -- Help footer
  add_line("")
  add_line("───────────────────────────────────────────────────────────")
  highlights[#highlights + 1] = { line = #lines - 1, hl_group = "Comment", col_start = 0, col_end = -1 }
  add_line(" [r] Reply  |  [e] Edit  |  [d] Delete  |  [s] Resolve  |  [P] Submit  |  [q] Close")
  highlights[#highlights + 1] = { line = #lines - 1, hl_group = "Comment", col_start = 0, col_end = -1 }

  return lines, line_map, thread_line_map, highlights
end

--- Generate a local uuid (v4-ish) for draft comment ids.
---@return string
local function uuid()
  local t = {}
  for i = 1, 32 do
    local r = math.random(0, 15)
    t[i] = string.format("%x", r)
  end
  t[13] = "4"
  t[17] = string.format("%x", math.floor(math.random(8, 11)))
  return table.concat(t, "", 1, 8) .. "-" .. table.concat(t, "", 9, 12)
    .. "-" .. table.concat(t, "", 13, 16) .. "-" .. table.concat(t, "", 17, 20)
    .. "-" .. table.concat(t, "", 21, 32)
end

--- Resolve the source window's top-left in editor coordinates.
--- Handles both Neovim API conventions:
---   * standard Neovim returns two values (row, col)
---   * the zig-forked dev build (0.13.0-dev+ga705bbe5d4) returns a single
---     table `{row, col}`
--- Callers get two integers either way.
---@param win integer
---@return integer row, integer col
local function m_win_position(win)
  local a, b = vim.api.nvim_win_get_position(win)
  if type(a) == "table" then
    return a[1] or 0, a[2] or 0
  end
  return a or 0, b or 0
end

--- Resolve the thread id under (or nearest to) the current cursor line.
---@return string|nil
local function t_id_at_cursor()
  if not M.state then
    return nil
  end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local t_id = M.state.thread_line_map[cursor_line]

  -- If cursor is on a non-comment line, search upwards then downwards.
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
  return t_id
end

--- Close the stacked reply input float if it is open.
function M.close_reply()
  if M.reply_state then
    local rs = M.reply_state
    if rs.winid and vim.api.nvim_win_is_valid(rs.winid) then
      vim.api.nvim_win_close(rs.winid, true)
    end
    if rs.bufnr and vim.api.nvim_buf_is_valid(rs.bufnr) then
      pcall(vim.api.nvim_buf_delete, rs.bufnr, { force = true })
    end
    M.reply_state = nil
  end
end

--- Open a stacked reply input float docked beneath the thread window.
--- The reply is saved as a local draft comment on <C-s> and pushed later
--- via :LocalReviewSubmit (outbox REPLY op), unless `submit_immediately`
--- is configured, in which case the reply is pushed to the hub on save.
--- If `ui.reply_layout == "scratchpad"`, falls back to `editor.open_reply()`.
---@param t_id string
function M.open_reply_float(t_id)
  if not M.state then
    return
  end

  local ui_cfg = (config.get_defaults().ui or {})
  if ui_cfg.reply_layout == "scratchpad" then
    return require("lreview.ui.editor").open_reply(t_id)
  end

  M.close_reply()

  local thread_winid = M.state.winid
  local cur_win = vim.api.nvim_get_current_win()
  local anchor_win = (thread_winid and vim.api.nvim_win_is_valid(thread_winid)) and thread_winid or cur_win
  local relative = (anchor_win == cur_win) and "cursor" or "win"

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, "lreview://reply/" .. t_id)

  local opts = { silent = true, noremap = true, buffer = buf }
  local width = 72
  local min_height = 4
  local max_height = 12
  local cur_height = min_height

  local win = vim.api.nvim_open_win(buf, true, {
    relative = relative,
    win = (relative == "win") and anchor_win or nil,
    row = 1,
    col = 0,
    width = width,
    height = cur_height,
    style = "minimal",
    border = "rounded",
    title = " ✍️ Reply ",
    title_pos = "center",
  })

  -- Auto-grow/shrink the float to fit content (bounded), so multi-line replies
  -- stay visible without manual resize.
  local function fit_height()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local want = #lines
    -- Also grow if a single line has wrapped, approximating visually.
    local win_width = width - 2  -- minus borders
    for _, l in ipairs(lines) do
      if vim.fn.strdisplaywidth(l) > win_width then want = want + 1 end
    end
    want = math.max(min_height, math.min(max_height, want))
    if want ~= cur_height and vim.api.nvim_win_is_valid(win) then
      cur_height = want
      pcall(vim.api.nvim_win_set_height, win, want)
    end
  end
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    callback = fit_height,
  })

  local submit_immediately = (config.get_defaults().submit_immediately == true)

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    if text == "" then
      vim.notify("lreview: reply cannot be empty", vim.log.levels.WARN)
      return
    end
    if submit_immediately then
      -- Push directly through the same path the scratchpad uses. Close the
      -- float first so the sync-bus refresh doesn't fight with it.
      M.close_reply()
      vim.notify("lreview: submitting reply immediately...", vim.log.levels.INFO)
      local remote_id, err = review.push_reply_immediately(t_id, text)
      if not remote_id then
        vim.notify("lreview: failed to push reply: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      if M.state and vim.api.nvim_buf_is_valid(M.state.bufnr) then
        M.redraw()
        local bufnr = vim.fn.bufnr(M.state.path)
        if bufnr ~= -1 then decor.refresh(bufnr) end
      end
      vim.notify("lreview: reply pushed", vim.log.levels.INFO)
      return
    end
    comments.add_comment({
      c_id = uuid(),
      t_id = t_id,
      remote_id = nil,
      author = nil,
      body = text,
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      in_reply_to = nil,
    })
    -- Redraw the thread view so the new draft reply appears immediately.
    M.redraw()
    local bufnr = vim.fn.bufnr(M.state.path)
    if bufnr ~= -1 then
      decor.refresh(bufnr)
    end
    vim.notify("lreview: reply added as draft (push with :LocalReviewSubmit)", vim.log.levels.INFO)
    M.close_reply()
  end

  local function cancel()
    M.close_reply()
  end

  vim.keymap.set({ "n", "i" }, "<C-s>", submit, opts)
  vim.keymap.set({ "n", "i" }, "<C-cr>", submit, opts)
  vim.keymap.set("n", "q", cancel, opts)
  vim.keymap.set("n", "<esc>", cancel, opts)
  vim.keymap.set({ "n", "i" }, "<C-c>", cancel, opts)

  -- Shared @mention + MR/PR link completion (same logic as the scratchpad).
  local completion = require("lreview.ui.completion")
  completion.attach(buf)

  -- <C-g> inserts a ```suggestion block from the thread's target lines, when
  -- the thread has a valid code range on a buffer that's open.
  local context_lines
  local thread = comments.get_thread(t_id)
  if thread and M.state.path then
    local code_bufnr = vim.fn.bufnr(M.state.path)
    if code_bufnr ~= -1 and vim.api.nvim_buf_is_valid(code_bufnr) then
      local s = math.max(1, thread.start_line or 1)
      local e = math.max(s, thread.end_line or s)
      context_lines = vim.api.nvim_buf_get_lines(code_bufnr, s - 1, e, false)
    end
  end
  if context_lines and #context_lines > 0 then
    vim.keymap.set({ "n", "i" }, "<C-g>", function()
      completion.insert_suggestion(buf, win, context_lines)
    end, opts)
  end

  -- Start in insert mode so the user can type immediately.
  vim.cmd("startinsert")

  M.reply_state = { bufnr = buf, winid = win, t_id = t_id, thread_winid = thread_winid }
end

--- Draw/redraw the current thread view buffer.
function M.redraw()
  if not M.state or not vim.api.nvim_buf_is_valid(M.state.bufnr) then
    return
  end
  local lines, line_map, thread_line_map, highlights = format_threads_for_line(M.state.mo_id, M.state.path, M.state.line)
  M.state.line_map = line_map
  M.state.thread_line_map = thread_line_map

  -- Temporarily set modifiable to update buffer contents
  vim.bo[M.state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.bufnr, 0, -1, false, lines)
  vim.bo[M.state.bufnr].modifiable = false

  setup_highlights()
  vim.api.nvim_buf_clear_namespace(M.state.bufnr, ns, 0, -1)
  for _, hl in ipairs(highlights or {}) do
    pcall(vim.api.nvim_buf_add_highlight, M.state.bufnr, ns, hl.hl_group, hl.line, hl.col_start, hl.col_end)
  end
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
    if t_id then
      M.open_reply_float(t_id)
    end
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
      review.resolve_thread_async(t_id, new_val, function(ok, err)
        if not ok then
          vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        vim.notify(new_val and "lreview: thread resolved" or "lreview: thread reopened", vim.log.levels.INFO)
        local bufnr = vim.fn.bufnr(M.state.path)
        if bufnr ~= -1 then
          require("lreview.ui.decor").refresh(bufnr)
        end
      end)
    end
  elseif action == "submit" then
    vim.notify("lreview: submitting review...", vim.log.levels.INFO)
    review.submit_review(nil, function(ok, count, err)
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
    end)
  end
end

--- Open or refresh the thread view window at the current cursor line.
---@param bufnr integer
---@param rel_path string
---@param line integer
function M.show(bufnr, rel_path, line)
  if not review.current then
    vim.notify("lreview: no active review; run :LocalReviewToggle first", vim.log.levels.WARN)
    return
  end
  local mo_id = review.current.detail.mo_id
  local threads = comments.threads_for_buffer(mo_id, rel_path, line)

  if #threads == 0 then
    -- Diagnostics: this path used to be silent, so a path/mo_id mismatch or
    -- simply being on an uncommented line looked identical. Print what was
    -- queried so it's obvious which case you're in.
    local all_on_path = comments.threads_for_buffer(mo_id, rel_path, nil)
    if #all_on_path == 0 then
      vim.notify(
        string.format(
          "lreview: no threads on this path. mo_id=%s path=%s (cursor line=%d; check with :LocalReviewSummary if this MR has threads on other files)",
          tostring(mo_id), tostring(rel_path), line),
        vim.log.levels.INFO)
    else
      local hint = {}
      for i, t in ipairs(all_on_path) do
        if i > 5 then hint[#hint + 1] = "…"; break end
        hint[#hint + 1] = string.format("%d:%d", t.start_line or 0, t.end_line or t.start_line or 0)
      end
      vim.notify(
        string.format(
          "lreview: cursor line %d is not inside any thread range on %s (thread ranges: %s)",
          line, tostring(rel_path), table.concat(hint, ", ")),
        vim.log.levels.INFO)
    end
    M.close()
    return
  end

  -- Always anchor to the CURRENT window's cursor — `M.show` is only invoked
  -- from a code buffer context (K keymap, :LocalReviewOpen, next/prev thread
  -- jump). A previously-saved source_win would go stale when the user moves
  -- to a different code buffer.
  local source_win = vim.api.nvim_get_current_win()

  -- Fast path: the SAME line's thread view is already open AND its window is
  -- still on screen. Focus it and redraw in place. If the window was closed
  -- externally (`<C-w>c`, `:close`, mouse click-away, buffer wipe), the fast
  -- path's redraw would touch a hidden buffer and nothing would appear — fall
  -- through to a full reopen instead. This used to be the source of "K only
  -- works once" reports.
  local win_still_valid = M.state
      and M.state.winid
      and vim.api.nvim_win_is_valid(M.state.winid)
  if M.state and M.state.path == rel_path and M.state.line == line
      and vim.api.nvim_buf_is_valid(M.state.bufnr) and win_still_valid then
    vim.api.nvim_set_current_win(M.state.winid)
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
    vim.keymap.set("n", "r", function()
      local t_id = t_id_at_cursor()
      if t_id then
        M.open_reply_float(t_id)
      else
        vim.notify("lreview: move cursor into a thread block to reply", vim.log.levels.WARN)
      end
    end, opts)
    vim.keymap.set("n", "e", function() handle_action("edit") end, opts)
    vim.keymap.set("n", "d", function() handle_action("delete") end, opts)
    vim.keymap.set("n", "s", function() handle_action("resolve") end, opts)
    vim.keymap.set("n", "P", function() handle_action("submit") end, opts)
  end

  -- Save initial state
  M.state = {
    bufnr = buf,
    winid = nil,
    source_win = source_win,
    line_map = {},
    thread_line_map = {},
    mo_id = mo_id,
    path = rel_path,
    line = line,
    layout = nil,
  }

  M.redraw()

  -- Retrieve layout configuration
  local ui_cfg = config.get_defaults().ui or {}
  local layout = ui_cfg.layout or "split"
  local winid

  if layout == "float" then
    -- Honor `ui.layout = "float"` — the previous code silently coerced this to
    -- "split" with the comment "layout = split", so users configuring float
    -- got no float. Now: compute width/height from `ui.float.width`/`height`
    -- (fraction of the editor, or absolute integer), pick a row above or
    -- below the cursor depending on available space, and open the window.
    local float_cfg = ui_cfg.float or {}
    local raw_w = float_cfg.width or 0.7
    local raw_h = float_cfg.height or 0.5
    local width = (raw_w <= 1) and math.floor(vim.o.columns * raw_w) or raw_w
    local height = (raw_h <= 1) and math.floor(vim.o.lines * raw_h) or raw_h
    width = math.max(60, math.min(vim.o.columns - 2, width))
    height = math.max(6, math.min(vim.o.lines - 2, height))

    -- Focus the source window so `relative = "cursor"` anchors there, then
    -- flip to `relative = "editor"` for absolute positioning (the row calc
    -- needs to know where the cursor sits in the outer editor, not just in
    -- the current window).
    if vim.api.nvim_win_is_valid(source_win) then
      pcall(vim.api.nvim_set_current_win, source_win)
    end
    local win_row, win_col = m_win_position(source_win)
    local cursor_row = vim.api.nvim_win_get_cursor(source_win)[1] - 1

    local rows_below = (win_row + vim.api.nvim_win_get_height(source_win)) - cursor_row
    local row
    if rows_below >= height + 3 then
      row = cursor_row + 1
    elseif cursor_row > height + 1 then
      row = cursor_row - height - 1
    else
      row = math.max(0, math.floor((vim.o.lines - height) / 2))
    end
    local col = math.max(0, win_col + math.floor((vim.api.nvim_win_get_width(source_win) - width) / 2))

    winid = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = row,
      col = col,
      width = width,
      height = height,
      style = "minimal",
      border = float_cfg.border or "rounded",
      title = string.format(" Review Thread (%s:%d) ", rel_path, line),
      title_pos = "center",
      zindex = 50,
    })
    M.state.layout = "float"
  else
    M.state.layout = layout
    if layout == "split" or layout == "vsplit" then
      local split_pos = ui_cfg.split and ui_cfg.split.position or "botright"
      local default_size = (layout == "vsplit") and 50 or 15
      local split_size = (ui_cfg.split and ui_cfg.split.size) and ui_cfg.split.size or default_size
      local split_cmd = (layout == "vsplit") and "vnew" or "new"

      vim.cmd(string.format("silent %s %d%s", split_pos, split_size, split_cmd))
      winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, buf)
    else
      -- Full buffer layout: open in current window
      winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, buf)
    end
  end

  M.state.winid = winid
end

return M
