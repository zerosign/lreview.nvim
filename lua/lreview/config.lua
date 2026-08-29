---@meta

-- Configuration for lreview.nvim.
--
-- Structure (as passed via lazy.nvim `opts`):
--   {
--     defaults = { ... global defaults ... },
--     ["<domain-regex>"] = { adapter=..., provider=..., host=..., <op> = <string|fn> },
--     ...
--   }
--
-- Per-domain blocks are keyed by a regex matched against the git remote URL
-- domain. Each block deep-merges over `defaults`. Ops may be:
--   - a string CLI template with {ref}/{id}/{repo}/{host} placeholders, or
--   - a Lua function(ctx) -> string (or nil to fall back to the adapter default).

local M = {}

M.defaults = {
  db_path = vim.fn.stdpath("data") .. "/lreview/lreview.db",
  db = {
    busy_timeout_ms = 5000,
    keep_days = 30,
    auto_housekeep = false,
  },
  ui = {
    decor = "both",               -- "sign" | "virtual_text" | "both" | "none"
    float = { width = 0.5, height = 0.6 },
    layout = "split",             -- "float" | "split" | "vsplit"
  },
  open = { method = "checkout" }, -- fetch+checkout the MR branch
  submit_immediately = false,
}

-- Deep merge b into a (mutates a, returns a). Tables are merged recursively,
-- non-table values from b win.
---@param a table
---@param b table
---@return table
local function deep_merge(a, b)
  for k, v in pairs(b) do
    if type(v) == "table" and type(a[k]) == "table" then
      deep_merge(a[k], v)
    else
      a[k] = v
    end
  end
  return a
end
M.deep_merge = deep_merge

-- The user-provided opts (set by setup()).
M.user_opts = {}

--- Set the user opts (called from setup()).
---@param opts table|nil
function M.setup(opts)
  M.user_opts = opts or {}
end

--- Get the global defaults (user `defaults` merged over builtin defaults).
---@return table
function M.get_defaults()
  local d = vim.deepcopy(M.defaults)
  if M.user_opts.defaults then
    deep_merge(d, M.user_opts.defaults)
  end
  return d
end

--- Translate a regex-style escape sequence into a Lua pattern escape.
--- Config domain keys are written in regex style (e.g. "gitlab\\.com"), but
--- Lua patterns use `%` (not `\`) for escaping. This converts `\X` -> `%X`.
---@param regex string
---@return string
local function to_lua_pattern(regex)
  return (regex:gsub("\\(.)", "%%%1"))
end

--- Resolve the per-domain config for a given domain.
--- Returns the merged config (defaults + matched per-domain block) or nil.
---
--- Domain keys are matched against the git remote domain. Keys are written in
--- regex style: `\.` escapes a literal dot, and `|` separates alternatives
--- (e.g. "gitlab\\.com|gitlab\\..*"). Lua patterns have no `|` alternation and
--- use `%` for escaping, so each `|`-separated alternative is translated to a
--- Lua pattern and tried independently; the first match wins.
---@param domain string
---@return table|nil
function M.for_domain(domain)
  local d = M.get_defaults()
  local matched = nil
  for pattern, block in pairs(M.user_opts) do
    if pattern ~= "defaults" and type(pattern) == "string" then
      local ok, err = pcall(function()
        -- Split on `|` (regex-style alternation) and try each piece as an
        -- independent Lua pattern.
        for alt in pattern:gmatch("[^|]+") do
          if domain:match(to_lua_pattern(alt)) then
            matched = block
            break
          end
        end
      end)
      if not ok then
        vim.notify("lreview: bad domain regex '" .. pattern .. "': " .. tostring(err), vim.log.levels.WARN)
      end
    end
  end
  if matched then
    deep_merge(d, matched)
  end
  return d
end

return M
