---@meta

-- Shared completion wiring for the comment scratchpad and the stacked reply
-- float. Extracted from `ui/editor.lua` so both buffers get the same
-- `@mention` and MR/PR link completion without duplicating the logic.
--
-- Triggers:
--   @<word>   -> cached repo users (see `:LocalReviewPullUser`)
--   !<title>  -> GitLab MR link, replaced with `!<number>`
--   #<title>  -> GitHub PR link, replaced with `#<number>` (markdown-heading
--                and word-glued `#` are skipped so a bare marker never
--                opens the popup)

local review = require("lreview.review")
local users_mod = require("lreview.users")
local pr_mod = require("lreview.pull_request")
local adapter = require("lreview.adapter")

local M = {}

local CANONICAL = { glab = "gitlab", gh = "github" }

--- Canonical provider name ("gitlab" | "github") of the active review.
---@return string|nil
local function current_provider()
  if review.current and review.current.detail and review.current.detail.provider then
    return review.current.detail.provider
  end
  local resolved = adapter.resolve(vim.fn.getcwd())
  if not resolved then return nil end
  return CANONICAL[resolved.provider] or resolved.provider
end

--- Wire completion autocmd onto `buf`. Safe to call once per buffer.
---@param buf integer
function M.attach(buf)
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = buf,
    callback = function()
      local line = vim.api.nvim_get_current_line()
      local col = vim.api.nvim_win_get_cursor(0)[2]
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
          vim.fn.complete(col - #prefix + 1, items)
        end
        return
      end

      -- MR/PR link completion, scoped per platform.
      local provider = current_provider()
      local marker = provider == "gitlab" and "!" or (provider == "github" and "#" or nil)
      if marker then
        local start_pos, _, rest = before:match("()([" .. marker .. "])([^%s]*)$")
        if start_pos and rest ~= "" then
          local prev = start_pos > 1 and before:sub(start_pos - 1, start_pos - 1) or ""
          if prev ~= "" and prev:match("%w") then return end
          if marker == "#" and (line:match("^%s*#+%s") or line:match("^%s*#+$")) then return end
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
            vim.fn.complete(start_pos, items)
          end
        end
      end
    end,
  })
end

--- Insert a `​```suggestion` block around the current cursor line from the given
--- context lines (GitHub suggestion syntax). No-op if there are no lines.
---@param buf integer
---@param win integer
---@param context_lines string[]|nil
function M.insert_suggestion(buf, win, context_lines)
  if not context_lines or #context_lines == 0 then return end
  local s_lines = { "```suggestion" }
  for _, cl in ipairs(context_lines) do
    s_lines[#s_lines + 1] = cl
  end
  s_lines[#s_lines + 1] = "```"
  local cur_row = vim.api.nvim_win_get_cursor(win)[1]
  vim.api.nvim_buf_set_lines(buf, cur_row - 1, cur_row - 1, false, s_lines)
  pcall(vim.api.nvim_win_set_cursor, win, { cur_row + 1, 0 })
end

return M
