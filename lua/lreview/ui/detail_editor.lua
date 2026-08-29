local review = require("lreview.review")

local M = {}

--- Parse buffer lines to extract Title and Description.
---@param bufnr integer
---@return string title, string description
local function parse_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local title = "No Title"
  local desc_lines = {}
  local in_desc = false

  for _, line in ipairs(lines) do
    if not in_desc then
      local t = line:match("^# Title:%s*(.*)") or line:match("^#%s+([^#].*)")
      if t and t ~= "" and title == "No Title" then
        title = t
      end
      if line:match("^## Description%s*") or line:match("^## Description:%s*") then
        in_desc = true
      end
    else
      desc_lines[#desc_lines + 1] = line
    end
  end

  local description = table.concat(desc_lines, "\n")
  -- Trim leading/trailing newlines
  description = description:gsub("^%s*", ""):gsub("%s*$", "")
  return title, description
end

--- Open the MR detail editor for the active MR/PR.
---@param detail lreview.MRDetail
function M.open(detail)
  local buf_name = "lreview_detail://" .. detail.provider .. "/" .. detail.number
  
  -- If buffer is already open, focus it
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(bufnr) == buf_name then
      local winids = vim.fn.win_findbuf(bufnr)
      if #winids > 0 then
        vim.api.nvim_set_current_win(winids[1])
        return
      end
    end
  end

  -- Create a new buffer
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, buf_name)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].bufhidden = "wipe"

  -- Format buffer lines
  local lines = {
    "# Title: " .. detail.title,
    "",
    "## Metadata",
    "- **Provider:** " .. detail.provider,
    "- **Number:** #" .. detail.number,
    "- **Source:** " .. detail.source_branch,
    "- **Target:** " .. detail.target_branch,
    "- **Status:** " .. detail.state,
    "",
    "## Description",
  }

  if detail.body and detail.body ~= "" then
    for line in (detail.body .. "\n"):gmatch("(.-)\r?\n") do
      lines[#lines + 1] = line
    end
  else
    lines[#lines + 1] = ""
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false

  -- Map q to wipe buffer
  local opts = { silent = true, noremap = true, buffer = bufnr }
  vim.keymap.set("n", "q", "<cmd>bwipeout!<cr>", opts)

  -- Create local BufWriteCmd autocmd to handle saves (:w)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      local title, desc = parse_buffer(bufnr)
      vim.notify("lreview: updating MR details on " .. detail.provider .. "...", vim.log.levels.INFO)
      
      local ok, err = review.update_review(title, desc)
      if not ok then
        vim.notify("lreview: failed to update MR: " .. tostring(err), vim.log.levels.ERROR)
        return
      end

      vim.bo[bufnr].modified = false
      vim.notify("lreview: MR updated successfully", vim.log.levels.INFO)
    end,
  })

  -- Split open the buffer (safely handles headless environments)
  local ok_split = pcall(vim.cmd, "split")
  if ok_split then
    pcall(vim.api.nvim_win_set_buf, 0, bufnr)
  end
end

return M
