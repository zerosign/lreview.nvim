---@meta

-- Issue views.
--
-- Deliberately thin: the picker goes through `vim.ui.select`, so telescope,
-- fzf-lua and snacks.picker upgrade it automatically in the user's config and
-- lreview owns no list UI. The detail view is a plain markdown buffer with a
-- stable name, so render-markdown.nvim (or any other ft plugin) can decorate it
-- without lreview knowing about it.

local issues = require("lreview.issues")
local adapter = require("lreview.adapter")

local M = {}

---@type { bufnr: integer, issue_id: string }|nil
M.state = nil

--- One display line per issue, for the picker.
---@param i table
---@return string
local function format_item(i)
  local parts = { "#" .. tostring(i.number), i.title or "(no title)" }
  if i.labels and i.labels ~= "" then
    parts[#parts + 1] = "[" .. i.labels .. "]"
  end
  if i.state and i.state ~= "open" then
    parts[#parts + 1] = "(" .. i.state .. ")"
  end
  return table.concat(parts, "  ")
end

--- Sync and reload the issue buffer asynchronously.
local function sync_buffer(bufnr, notify_on_success)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local num = tonumber(vim.b[bufnr].lreview_issue_number)
  if not num then return end
  issues.pull_one_async(num, function(ok, fresh, err)
    if not ok then
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.render(bufnr, fresh)
      if notify_on_success ~= false then
        vim.notify("lreview: issue #" .. num .. " synced", vim.log.levels.INFO)
      end
    end
  end)
end

local bufread_registered = false
local function ensure_bufread_cmd()
  if bufread_registered then return end
  bufread_registered = true
  vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "lreview_issue://*",
    callback = function(ev)
      sync_buffer(ev.buf, true)
    end,
  })
end

--- Open the cached detail (body + discussion) for one issue.
---@param i table
function M.open(i)
  if not i or not i.issue_id then return end
  ensure_bufread_cmd()
  local buf_name = "lreview_issue://" .. i.provider .. "/" .. i.repo .. "/" .. i.number

  local bufnr = vim.fn.bufnr(buf_name)
  if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, buf_name)
    local opts = { silent = true, noremap = true, buffer = bufnr }
    vim.keymap.set("n", "q", "<cmd>close<cr>", opts)
    -- Reads the number back off the buffer: a reused buffer must re-sync the
    -- issue it is showing, not the one whose closure happened to be first.
    vim.keymap.set("n", "S", function() sync_buffer(bufnr, true) end, opts)
    vim.keymap.set("n", "r", function() sync_buffer(bufnr, true) end, opts)
    vim.keymap.set("n", "<C-r>", function() sync_buffer(bufnr, true) end, opts)
  end

  vim.b[bufnr].lreview_issue_number = i.number
  M.state = { bufnr = bufnr, issue_id = i.issue_id }
  M.render(bufnr, i)

  -- If comments exist remotely but haven't been cached yet, auto-fetch in background
  local cached_notes = issues.notes(i.issue_id)
  if (i.comment_count or 0) > 0 and #cached_notes == 0 then
    sync_buffer(bufnr, false)
  end

  local winids = vim.fn.win_findbuf(bufnr)
  if #winids > 0 then
    vim.api.nvim_set_current_win(winids[1])
  elseif pcall(vim.cmd, "split") then
    pcall(vim.api.nvim_win_set_buf, 0, bufnr)
  end
end

--- Write the buffer body: metadata, description, discussion.
--- Preserves window view and cursor position across active windows.
---@param bufnr integer
---@param i table
function M.render(bufnr, i)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- Save view in all windows displaying this buffer
  local winids = vim.fn.win_findbuf(bufnr)
  local views = {}
  for _, wid in ipairs(winids) do
    if vim.api.nvim_win_is_valid(wid) then
      views[wid] = vim.api.nvim_win_call(wid, vim.fn.winsaveview)
    end
  end

  local lines = {}
  lines[#lines + 1] = "# " .. (i.title or "(no title)")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "- **Issue:** #" .. tostring(i.number) .. " (" .. (i.state or "open") .. ")"
  lines[#lines + 1] = "- **Provider:** " .. tostring(i.provider) .. " / " .. tostring(i.repo)
  if i.author then lines[#lines + 1] = "- **Author:** @" .. i.author end
  if i.assignees and #i.assignees > 0 then lines[#lines + 1] = "- **Assignees:** @" .. table.concat(i.assignees, ", @") end
  if i.milestone then lines[#lines + 1] = "- **Milestone:** " .. i.milestone end
  if i.labels and i.labels ~= "" then lines[#lines + 1] = "- **Labels:** " .. i.labels end
  if i.updated_at then lines[#lines + 1] = "- **Updated:** " .. tostring(i.updated_at) end
  if i.url then lines[#lines + 1] = "- **URL:** " .. i.url end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Description"
  for _, l in ipairs(vim.split(i.body or "(empty)", "\n", { plain = true })) do
    lines[#lines + 1] = l
  end

  local notes = issues.notes(i.issue_id)
  lines[#lines + 1] = ""
  if #notes > 0 then
    lines[#lines + 1] = "## Discussion (" .. #notes .. ")"
    for _, n in ipairs(notes) do
      lines[#lines + 1] = ""
      lines[#lines + 1] = "**@" .. tostring(n.author or "unknown") .. "**"
          .. (n.created_at and ("  (" .. tostring(n.created_at) .. ")") or "")
      for _, l in ipairs(vim.split(n.body or "", "\n", { plain = true })) do
        lines[#lines + 1] = "> " .. l
      end
    end
  else
    lines[#lines + 1] = "## Discussion"
    lines[#lines + 1] = "(no discussion cached — press [S] to sync this issue)"
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].swapfile = false

  -- Restore view in all windows displaying this buffer
  for wid, view in pairs(views) do
    if vim.api.nvim_win_is_valid(wid) then
      pcall(vim.api.nvim_win_call, wid, function()
        vim.fn.winrestview(view)
      end)
    end
  end
end

--- Pick an issue from the local cache (pulling first when the cache is empty or
--- older than the TTL). Selection is delegated to `vim.ui.select`.
---@param opts table|nil  -- { state = "open"|"closed"|"all", force = boolean, on_pick = fun(issue) }
function M.pick(opts)
  opts = opts or {}
  issues.ensure_fresh_async({
    state = opts.state,
    force = opts.force,
    on_done = function(ok, err)
      if not ok then
        vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      local list = issues.list({ state = opts.state })
      if #list == 0 then
        vim.notify("lreview: no " .. (opts.state or "open") .. " issues cached for this repo", vim.log.levels.WARN)
        return
      end
      vim.ui.select(list, {
        prompt = "Issue (" .. #list .. " cached):",
        format_item = format_item,
      }, function(choice)
        if not choice then return end
        if opts.on_pick then opts.on_pick(choice) end
        M.open(choice)
      end)
    end,
  })
end

--- Show one issue by number, pulling it from the hub when not cached.
---@param number integer|string
function M.show(number)
  local n = tonumber(number)
  if not n then
    vim.notify("lreview: :LocalReviewIssue needs an issue number", vim.log.levels.WARN)
    return
  end
  issues.with_issue(n, function(issue, err)
    if not issue then
      vim.notify("lreview: " .. tostring(err or ("issue #" .. n .. " not found")), vim.log.levels.ERROR)
      return
    end
    M.open(issue)
  end)
end

--- Resolve issue numbers referenced from a text (an MR description).
--- Returns only the ones already cached, so correlation costs no network.
---@param text string|nil
---@return table[]  -- { { number = n, issue = row }, ... }
function M.referenced(text)
  local out = {}
  if not text or text == "" then return out end
  local resolved = adapter.resolve(vim.fn.getcwd())
  if not resolved then return out end
  local provider = issues.canonical(resolved)
  local repo = resolved.repo
  if not repo then return out end

  local seen = {}
  -- `#123`, `!45` (GitLab issue shorthand), `owner/repo#12`, and bare issue URLs.
  for num in text:gmatch("#(%d+)") do seen[tonumber(num)] = true end
  for num in text:gmatch("!(%d+)") do seen[tonumber(num)] = true end
  for num in text:gmatch("[/%w%.%-_]+#(%d+)") do seen[tonumber(num)] = true end
  for num in text:gmatch("issues/(%d+)") do seen[tonumber(num)] = true end

  for num in pairs(seen) do
    local row = issues.lookup(provider, repo, num)
    if row then out[#out + 1] = { number = num, issue = row } end
  end
  table.sort(out, function(a, b) return a.number < b.number end)
  return out
end

return M
