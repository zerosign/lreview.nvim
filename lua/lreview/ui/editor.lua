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

  -- Completion in the scratchpad:
  --   @mention  -> cached repo users (see :LocalReviewPullUser)
  --   ! / #     -> MR/PR link, scoped per platform so handlers never leak:
  --                gitlab uses '!' (MR ref), github uses '#' (PR ref).
  --                Search by title, insert the ID reference (e.g. !123).
  local users_mod = require("lreview.users")
  local pr_mod = require("lreview.pull_request")
  local adapter = require("lreview.adapter")

  -- Canonical provider ("gitlab" | "github") of the active review, falling
  -- back to the repo under the current directory.
  local CANONICAL = { glab = "gitlab", gh = "github" }
  local function current_provider()
    if review.current and review.current.detail and review.current.detail.provider then
      return review.current.detail.provider
    end
    local resolved = adapter.resolve(vim.fn.getcwd())
    if not resolved then
      return nil
    end
    return CANONICAL[resolved.provider] or resolved.provider
  end

  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = buf,
    callback = function()
      local line = vim.api.nvim_get_current_line()
      local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-based byte col
      local before = line:sub(1, col)

      -- @mention completion (all platforms)
      local prefix = before:match("@([%w_.-]*)$")
      if prefix ~= nil then
        local cwd = review.current and review.current.cwd
        local users = users_mod.search_users(cwd, prefix)
        local items = {}
        for _, u in ipairs(users) do
          items[#items + 1] = { word = u.username, menu = u.name or "", kind = "User" }
        end
        if #items > 0 then
          -- Replace from just after the '@' (1-based col) to the cursor, so
          -- the selected username is inserted after the '@'.
          vim.fn.complete(col - #prefix + 1, items)
        end
        return
      end

      -- MR/PR link completion, scoped per platform.
      local provider = current_provider()
      local marker = provider == "gitlab" and "!" or (provider == "github" and "#" or nil)
      if marker then
        -- () captures the 1-based marker position; the marker char itself is
        -- discarded (we already know it), `rest` is the typed title text.
        local start_pos, _, rest = before:match("()([" .. marker .. "])([^%s]*)$")
        -- Require at least one title char: a bare marker (e.g. "Thanks!" or a
        -- "# Heading" line) must not open the completion popup.
        if start_pos and rest ~= "" then
          -- The marker must start a standalone token: skip when it is glued to
          -- a word char (e.g. "Thanks!" or "issue#123" must not trigger).
          local prev = start_pos > 1 and before:sub(start_pos - 1, start_pos - 1) or ""
          if prev ~= "" and prev:match("%w") then
            return
          end
          -- Skip '#' at line start: markdown headings (# Heading, ## Heading).
          if marker == "#" and (line:match("^%s*#+%s") or line:match("^%s*#+$")) then
            return
          end
          local cwd = review.current and review.current.cwd
          local prs = pr_mod.search(cwd, rest)
          local items = {}
          for _, mr in ipairs(prs) do
            items[#items + 1] = {
              word = marker .. mr.number,
              menu = mr.title or "",
              kind = "MR",
            }
          end
          if #items > 0 then
            -- Replace from the marker (1-based col) to the cursor, so the
            -- typed title text is swapped for the ID reference.
            vim.fn.complete(start_pos, items)
          end
        end
      end
    end,
  })
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
  end)
end

return M
