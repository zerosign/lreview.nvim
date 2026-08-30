local M = {}

--- Prompt user with a floating confirmation dialog showing pending changes and verdict choices.
---@param summary_lines string[]
---@param opts table -- { has_verdict = boolean }
---@param callback fun(choice: "COMMENT"|"APPROVE"|"REQUEST_CHANGES"|nil)
function M.ask_confirmation(summary_lines, opts, callback)
  opts = opts or {}
  local has_verdict = opts.has_verdict == true

  local lines = {}
  for _, l in ipairs(summary_lines) do
    lines[#lines + 1] = l
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Select Submission Verdict:"
  if has_verdict then
    lines[#lines + 1] = "  [c] Comment  |  [a] Approve  |  [r] Request Changes  |  [q/<esc>] Cancel"
  else
    lines[#lines + 1] = "  [c/<CR>] Submit Comments  |  [q/<esc>] Cancel"
  end

  local width = 72
  local height = #lines + 2
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Confirm Review Push ",
    title_pos = "center",
  })

  local function close(result)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    callback(result)
  end

  local key_opts = { silent = true, noremap = true, buffer = buf }
  vim.keymap.set("n", "q", function() close(nil) end, key_opts)
  vim.keymap.set("n", "<esc>", function() close(nil) end, key_opts)
  vim.keymap.set("n", "c", function() close("COMMENT") end, key_opts)
  vim.keymap.set("n", "<CR>", function() close("COMMENT") end, key_opts)

  if has_verdict then
    vim.keymap.set("n", "a", function() close("APPROVE") end, key_opts)
    vim.keymap.set("n", "r", function() close("REQUEST_CHANGES") end, key_opts)
  end
end

return M
