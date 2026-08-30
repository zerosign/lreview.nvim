-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local summary = require("lreview.ui.summary")
local review = require("lreview.review")
local adapter = require("lreview.adapter")
local materialize = require("lreview.materialize")

print("==========================================================================")
print("  lreview.nvim — Benchmark: Phase 2 & 3 (Capabilities, Topology, UI Overview)")
print("==========================================================================")

-- Benchmark 1: Capability Query Latency
local gh_adapter = adapter.get("github")
local resolved_gh = { adapter = gh_adapter }
local cap_iters = 10000

local t0_cap = vim.uv.hrtime()
for _ = 1, cap_iters do
  adapter.supports(resolved_gh, "draft_mr")
end
local dt_cap = (vim.uv.hrtime() - t0_cap) / cap_iters / 1e6

print(string.format("  [Capability Query]   adapter.supports (%d ops): %8.4f ms / call", cap_iters, dt_cap))

-- Benchmark 2: Materialization Resolution Speed
local t0_mat = vim.uv.hrtime()
for _ = 1, cap_iters do
  materialize.resolve_mode({ topology = "monorepo-single" }, 15)
end
local dt_mat = (vim.uv.hrtime() - t0_mat) / cap_iters / 1e6

print(string.format("  [Materialize Mode]   resolve_mode (%d ops):     %8.4f ms / call", cap_iters, dt_mat))

-- Benchmark 3: File Overview Redraw with 500 Changed Files
local big_files = {}
for i = 1, 500 do
  big_files[#big_files + 1] = {
    path = "src/modules/sub_" .. i .. "/service.lua",
    additions = i * 2,
    deletions = i,
  }
end

review.current = {
  cwd = vim.fn.getcwd(),
  detail = {
    mo_id = "github:test/repo:1",
    files = big_files,
  }
}

summary.open()
summary.toggle_view_mode() -- Switch to files mode

local redraw_iters = 100
local t0_redraw = vim.uv.hrtime()
for _ = 1, redraw_iters do
  summary.redraw()
end
local dt_redraw = (vim.uv.hrtime() - t0_redraw) / redraw_iters / 1e6

summary.close()

print(string.format("  [File Overview UI]   500-file table redraw (%d ops):%8.3f ms / pass", redraw_iters, dt_redraw))
print("==========================================================================")
