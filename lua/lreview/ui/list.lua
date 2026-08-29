local comments = require("lreview.storage.comments")
local review = require("lreview.review")
local git = require("lreview.git")

local M = {}

--- Populate Neovim quickfix list with all comments in the current MR.
function M.open_quickfix()
  if not review.current then
    vim.notify("lreview: no active review; run LocalReviewStart first", vim.log.levels.WARN)
    return
  end
  local mo_id = review.current.detail.mo_id
  local root = git.root(review.current.cwd)
  if not root then
    vim.notify("lreview: failed to locate git root", vim.log.levels.ERROR)
    return
  end

  local threads = comments.threads_for_mr(mo_id)
  if #threads == 0 then
    vim.notify("lreview: no comments found in this MR", vim.log.levels.INFO)
    return
  end

  local qf_entries = {}
  for _, t in ipairs(threads) do
    local cs = comments.comments_for_thread(t.t_id)
    if #cs > 0 then
      local first = cs[1]
      local author = first.author or "me"
      local body = first.body:gsub("[\r\n]+", " ") -- Flatten newlines for single-line quickfix list view
      if #body > 60 then
        body = body:sub(1, 57) .. "..."
      end

      -- Format status tag
      local tag = "[● Active]"
      if comments.thread_is_resolved(t.state) then
        tag = "[✔ Resolved]"
      elseif comments.thread_is_draft(t.state) then
        tag = "[💬 Draft]"
      end

      local text = string.format("%s %s: %s", tag, author, body)
      local abs_path = root .. "/" .. t.path

      qf_entries[#qf_entries + 1] = {
        filename = abs_path,
        lnum = t.start_line,
        col = 1,
        text = text,
      }
    end
  end

  -- Set quickfix list and open window
  vim.fn.setqflist(qf_entries, "r")
  vim.cmd("copen")

  -- Map buffer-local key 'e' in quickfix window to jump and open review split
  local qf_buf = vim.api.nvim_get_current_buf()
  vim.keymap.set("n", "e", function()
    local qf_idx = vim.fn.line(".")
    local qf_list = vim.fn.getqflist()
    local entry = qf_list[qf_idx]
    if entry then
      vim.cmd("cc " .. qf_idx)
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local abs = vim.fn.expand("%:p")
      local root = git.root(vim.fn.getcwd())
      local path = abs
      if root then
        if vim.startswith(abs, root .. "/") then
          path = abs:sub(#root + 2)
        end
      end
      require("lreview.ui.thread_view").show(vim.api.nvim_get_current_buf(), path, line)
    end
  end, { silent = true, buffer = qf_buf })

  vim.notify(string.format("lreview: loaded %d comment(s) into quickfix list", #qf_entries), vim.log.levels.INFO)
end

return M
