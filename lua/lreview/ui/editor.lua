local comments = require("lreview.storage.comments")
local review = require("lreview.review")
local decor = require("lreview.ui.decor")

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
local function create_scratchpad(initial_text, save_callback)
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

  -- Set up floating editor window centered in the screen
  local w = math.floor(vim.o.columns * 0.6)
  local h = math.floor(vim.o.lines * 0.5)
  local row = math.floor((vim.o.lines - h) / 2)
  local col = math.floor((vim.o.columns - w) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = w,
    height = h,
    border = "rounded",
  })

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

  -- Keymap to save and close with <C-cr> or <leader>s
  local opts = { silent = true, noremap = true, buffer = buf }
  vim.keymap.set("i", "<C-cr>", "<cmd>w<cr>", opts)
  vim.keymap.set("n", "<leader>s", "<cmd>w<cr>", opts)
  vim.keymap.set("n", "q", "<cmd>q<cr>", opts)
end

--- Open editor to write a reply to a thread.
---@param thread_id string
function M.open_reply(thread_id)
  create_scratchpad(nil, function(text)
    local reply = {
      c_id = uuid(),
      t_id = thread_id,
      remote_id = nil,
      author = nil,
      body = text,
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      in_reply_to = nil, -- Will be filled during remote submit if needed
    }
    comments.add_comment(reply)
    
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
    comments.update_comment(c_id, text)

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

  create_scratchpad(nil, function(text)
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

    -- Refresh active buffer highlights
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 then
      decor.refresh(bufnr)
    end
    vim.notify("lreview: draft comment added", vim.log.levels.INFO)
  end)
end

return M
