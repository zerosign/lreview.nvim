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
      if t.resolved == 1 then
        tag = "[✔ Resolved]"
      elseif t.is_draft == 1 then
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
  vim.notify(string.format("lreview: loaded %d comment(s) into quickfix list", #qf_entries), vim.log.levels.INFO)
end

return M
