-- Sandbox Neovim config for local-review development.
--
-- Bootstraps lazy.nvim as the package manager and loads local-review as a
-- plugin from the project root, using the same `opts` structure a user would
-- put in their lazy.nvim config.

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local repo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", repo, lazypath })
end
vim.opt.rtp:prepend(lazypath)

-- Minimal sane defaults for the sandbox.
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.termguicolors = true
vim.opt.swapfile = false

-- The project root (parent of this config's repo). local-review source lives at
-- <root>/lua/lreview.
local root = vim.fn.fnamemodify(vim.fn.stdpath("config"), ":h:h")

require("lazy").setup({
  {
    dir = root,
    name = "lreview",
    dependencies = {
      "kkharji/sqlite.lua",
    },
    -- The same opts structure a user would pass in lazy.nvim.
    opts = {
      defaults = {
        db_path = vim.fn.stdpath("data") .. "/lreview/lreview.db",
        ui = { decor = "both", float = { width = 0.5, height = 0.6 } },
      },
      ["github\\.com"] = {
        adapter = "github",
        provider = "gh",
        host = "github.com",
      },
      ["gitlab\\.com|gitlab\\..*"] = {
        adapter = "gitlab",
        provider = "glab",
        host = "gitlab.com",
      },
    },
    -- Explicit config so lazy.nvim calls setup() with opts (avoids the
    -- "Lua module not found for config" warning since the plugin has no
    -- top-level lua/lreview.lua).
    config = function(_, opts)
      require("lreview").setup(opts)
    end,
  },
}, {
  root = vim.fn.stdpath("data") .. "/lazy",
  lockfile = vim.fn.stdpath("data") .. "/lazy/lock.json",
  install = { colorscheme = { "habamax" } },
})
