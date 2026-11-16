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

  -- Find a buffer with this name whether or not it's currently in a window.
  -- If it exists (even hidden), reuse it — creating a new one and calling
  -- `nvim_buf_set_name` would E95 because the name is already taken.
  local existing_bufnr = nil
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == buf_name then
      existing_bufnr = bufnr
      break
    end
  end

  local bufnr
  if existing_bufnr then
    -- Already open in a window? Just focus it and return.
    local winids = vim.fn.win_findbuf(existing_bufnr)
    if #winids > 0 then
      vim.api.nvim_set_current_win(winids[1])
      return
    end
    bufnr = existing_bufnr
  else
    bufnr = vim.api.nvim_create_buf(true, false)
    -- Set buftype *before* the name so any watcher never treats this as a
    -- plain file path. `acwrite` (plus `bufhidden = wipe`) keeps Neovim from
    -- registering an fs_watch against the URI.
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].filetype = "markdown"
    vim.bo[bufnr].bufhidden = "wipe"
    local ok_name, err_name = pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)
    if not ok_name then
      -- Someone else grabbed the name in the interim (rare; concurrent :ls).
      -- Fall back to a scratch-style unique name so we do not error out.
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.bo[bufnr].buftype = "acwrite"
      vim.bo[bufnr].filetype = "markdown"
      vim.api.nvim_buf_set_name(bufnr, buf_name .. "-" .. tostring(vim.uv.get_pid()))
    end
    vim.bo[bufnr].bufhidden = "wipe"
  end

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

  -- `description` is the model's field (mappers write it); `body` is kept as a
  -- fallback for locally-built fallback details. Reading only `.body` meant the
  -- MR description rendered as an empty block for every real MR.
  local desc = detail.description or detail.body
  if desc and desc ~= "" then
    for line in (desc .. "\n"):gmatch("(.-)\r?\n") do
      lines[#lines + 1] = line
    end
  else
    lines[#lines + 1] = ""
  end

  -- Only register the BufWriteCmd autocmd once per buffer (avoid stacking on
  -- every reopen of a reused hidden buffer).
  local aug_name = "lreview_detail_" .. bufnr
  if vim.api.nvim_create_augroup then
    pcall(vim.api.nvim_del_augroup_by_name, aug_name)
  end
  local grp = vim.api.nvim_create_augroup(aug_name, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = grp,
    buffer = bufnr,
    callback = function()
      local title, desc = parse_buffer(bufnr)
      vim.notify("lreview: updating MR details on " .. detail.provider .. "...", vim.log.levels.INFO)
      review.update_review_async(title, desc, detail.number, vim.fn.getcwd(), function(ok, err)
        if not ok then
          vim.notify("lreview: failed to update MR: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        vim.bo[bufnr].modified = false
        vim.notify("lreview: MR updated successfully", vim.log.levels.INFO)
      end)
    end,
  })

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false

  -- Open the buffer in a split (or just focus it if it was reused and hidden).
  local winids = vim.fn.win_findbuf(bufnr)
  if #winids > 0 then
    vim.api.nvim_set_current_win(winids[1])
  else
    local ok_split = pcall(vim.cmd, "split")
    if ok_split then
      pcall(vim.api.nvim_win_set_buf, 0, bufnr)
    end
  end
end

return M
