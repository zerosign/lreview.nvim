local comments = require("lreview.storage.comments")
local review = require("lreview.review")
local decor = require("lreview.ui.decor")
local config = require("lreview.config")
local storage = require("lreview.storage")

local M = {}

--- Generate a local uuid (v4-ish) for draft ids.
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

--- Create the scratchpad window and buffer.
---@param initial_text string|nil
---@param save_callback fun(text: string)
---@param extra_opts table|nil
local function create_scratchpad(initial_text, save_callback, extra_opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "acwrite"  -- Custom write protocol to allow :w
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, "lreview://comment/" .. uuid())

  if initial_text then
    local lines = {}
    for part in initial_text:gmatch("[^\r\n]+") do
      lines[#lines + 1] = part
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end

  -- Set up editor window based on layout preference
  local ui_cfg = config.get_defaults().ui or {}
  local layout = ui_cfg.layout or "float"
  local win

  if layout == "split" or layout == "vsplit" then
    local split_pos = ui_cfg.split and ui_cfg.split.position or "botright"
    local split_size = ui_cfg.split and ui_cfg.split.size or 10
    local split_cmd = (layout == "vsplit") and "vnew" or "new"
    vim.cmd(string.format("silent %s %d%s", split_pos, split_size, split_cmd))
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  else
    -- Float (default)
    local w = math.floor(vim.o.columns * 0.6)
    local h = math.floor(vim.o.lines * 0.5)
    local row = math.floor((vim.o.lines - h) / 2)
    local col = math.floor((vim.o.columns - w) / 2)
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = row,
      col = col,
      width = w,
      height = h,
      border = "rounded",
    })
  end

  -- Intercept write commands (:w, :wq)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = vim.trim(table.concat(lines, "\n"))
      if text ~= "" then
        save_callback(text)
        vim.bo[buf].modified = false
        vim.api.nvim_win_close(win, true)
      else
        vim.notify("lreview: comment cannot be empty", vim.log.levels.WARN)
      end
    end,
  })

  -- Keymap to save and close with <C-cr>, <leader>s, or <C-s>
  local opts = { silent = true, noremap = true, buffer = buf }
  vim.keymap.set("i", "<C-cr>", "<cmd>w<cr>", opts)
  vim.keymap.set("n", "<leader>s", "<cmd>w<cr>", opts)
  vim.keymap.set({ "n", "i" }, "<C-s>", "<cmd>w<cr>", opts)

  -- Clean exit and discard keymaps
  local function close_scratchpad(force)
    if not vim.api.nvim_win_is_valid(win) then return end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local cur_text = vim.trim(table.concat(lines, "\n"))
    local orig_text = vim.trim(initial_text or "")
    if not force and cur_text ~= "" and cur_text ~= orig_text then
      local choice = vim.fn.confirm("Discard comment?", "&Yes\n&No", 2)
      if choice ~= 1 then return end
    end
    vim.bo[buf].modified = false
    vim.api.nvim_win_close(win, true)
  end

  vim.keymap.set("n", "q", function() close_scratchpad(false) end, opts)
  vim.keymap.set("n", "<esc>", function() close_scratchpad(false) end, opts)
  vim.keymap.set({ "n", "i" }, "<C-c>", function() close_scratchpad(false) end, opts)

  -- Code suggestion shortcut (<C-g>) when context lines are available.
  -- Logic lives in `ui.completion.insert_suggestion` so the stacked reply
  -- float can offer the same shortcut without duplicating it.
  local completion = require("lreview.ui.completion")
  if extra_opts and extra_opts.context_lines and #extra_opts.context_lines > 0 then
    local ctx = extra_opts.context_lines
    vim.keymap.set({ "n", "i" }, "<C-g>", function()
      completion.insert_suggestion(buf, win, ctx)
    end, opts)
  end

  -- Completion in the scratchpad: @mention + MR/PR link refs. Shared with the
  -- stacked reply float via `ui.completion`.
  completion.attach(buf)
end

--- Open editor to write a reply to a thread.
---@param thread_id string
function M.open_reply(thread_id)
  create_scratchpad(nil, function(text)
    local submit_immediately = config.get_defaults().submit_immediately
    if submit_immediately then
      vim.notify("lreview: submitting reply immediately...", vim.log.levels.INFO)
      local remote_id, err = review.push_reply_immediately(thread_id, text)
      if not remote_id then
        vim.notify("lreview: failed to push reply: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
    else
      local reply = {
        c_id = uuid(),
        t_id = thread_id,
        remote_id = nil,
        author = nil,
        body = text,
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        in_reply_to = nil,
      }
      comments.add_comment(reply)
    end
    
    -- Refresh Thread View and Code buffer decor
    local thread_view = require("lreview.ui.thread_view")
    if thread_view.state and thread_view.state.thread_id == thread_id then
      thread_view.redraw()
      local bufnr = vim.fn.bufnr(thread_view.state.path)
      if bufnr ~= -1 then
        decor.refresh(bufnr)
      end
    end
    vim.notify("lreview: reply added", vim.log.levels.INFO)
  end)
end

--- Open editor to edit an existing draft comment.
---@param c_id string
---@param current_body string
function M.open_edit(c_id, current_body)
  create_scratchpad(current_body, function(text)
    local submit_immediately = config.get_defaults().submit_immediately
    local c = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
    local is_synced = c and c.remote_id and c.remote_id ~= ""
    if submit_immediately then
      if is_synced then
        vim.notify("lreview: updating synced comment remote-side...", vim.log.levels.INFO)
      else
        vim.notify("lreview: updating comment immediately...", vim.log.levels.INFO)
      end
      local ok, err = review.push_edit_immediately(c_id, text)
      if not ok then
        vim.notify("lreview: failed to update comment: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
    else
      if is_synced then
        comments.update_comment_body_and_state(c_id, text, comments.STATE.MODIFIED)
      else
        comments.update_comment(c_id, text)
      end
    end

    -- Refresh Thread View
    local thread_view = require("lreview.ui.thread_view")
    if thread_view.state then
      thread_view.redraw()
      local bufnr = vim.fn.bufnr(thread_view.state.path)
      if bufnr ~= -1 then
        decor.refresh(bufnr)
      end
    end
    vim.notify("lreview: comment updated", vim.log.levels.INFO)
  end)
end

--- Open editor to create a brand new comment thread from the code buffer.
---@param path string
---@param start_line integer
---@param end_line integer
function M.open_new_comment(path, start_line, end_line)
  if not review.current then
    vim.notify("lreview: no active review; run LocalReviewStart first", vim.log.levels.WARN)
    return
  end
  local mo_id = review.current.detail.mo_id

  local context_lines = nil
  local cur_buf = vim.api.nvim_get_current_buf()
  if cur_buf and vim.api.nvim_buf_is_valid(cur_buf) then
    local total = vim.api.nvim_buf_line_count(cur_buf)
    local s = math.max(1, math.min(start_line, total))
    local e = math.max(s, math.min(end_line, total))
    context_lines = vim.api.nvim_buf_get_lines(cur_buf, s - 1, e, false)
  end

  create_scratchpad(nil, function(text)
    local submit_immediately = config.get_defaults().submit_immediately
    if submit_immediately then
      vim.notify("lreview: submitting comment immediately...", vim.log.levels.INFO)
      local ok, err = review.push_thread_immediately(path, start_line, end_line, text)
      if not ok then
        vim.notify("lreview: failed to push comment: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
    else
      local t_id = uuid()
      local thread = {
        t_id = t_id,
        mo_id = mo_id,
        path = path,
        commit_sha = review.current.detail.head_sha,
        start_line = start_line,
        end_line = end_line,
        is_draft = true,
        last_synced_at = nil,
      }
      comments.create_thread(thread)

      local c = {
        c_id = uuid(),
        t_id = t_id,
        remote_id = nil,
        author = nil,
        body = text,
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        in_reply_to = nil,
      }
      comments.add_comment(c)
    end

    -- Refresh active buffer highlights
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 then
      decor.refresh(bufnr)
    end
    vim.notify("lreview: draft comment added", vim.log.levels.INFO)
  end, { context_lines = context_lines })
end

--- Create an MR scratchpad editor for multi-line description and title editing.
--- Pre-filled with Title header line and template content.
---@param template_content string|nil
---@param save_callback fun(title: string, body: string)
function M.open_mr_editor(template_content, save_callback)
  local initial_lines = {
    "# Title: Enter MR Title Here",
    "",
    "<!-- Write your merge request description below -->",
  }
  if template_content and template_content ~= "" then
    for l in template_content:gmatch("[^\r\n]+") do
      initial_lines[#initial_lines + 1] = l
    end
  end

  local initial_text = table.concat(initial_lines, "\n")

  create_scratchpad(initial_text, function(text)
    local title = "New Merge Request"
    local body_lines = {}
    local parsed_title = false

    for line in text:gmatch("[^\r\n]+") do
      if not parsed_title and line:match("^#%s*Title:%s*(.*)") then
        local t = line:match("^#%s*Title:%s*(.*)")
        if t and t ~= "" then title = t end
        parsed_title = true
      elseif not line:match("^<!%-%-.*%-%->") then
        body_lines[#body_lines + 1] = line
      end
    end

    local body = table.concat(body_lines, "\n"):gsub("^%s*(.-)%s*$", "%1")
    save_callback(title, body)
  end)
end

return M
