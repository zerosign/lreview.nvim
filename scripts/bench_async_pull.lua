package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"
local review = require("lreview.review")
local adapter = require("lreview.adapter")
local init = require("lreview")

vim.fn.delete("tmp/bench_pull.db")

init.setup({
  defaults = {
    db_path = "tmp/bench_pull.db",
  }
})

-- Mock adapter to isolate benchmark from external network I/O
adapter.resolve = function()
  return {
    adapter = {
      name = "github",
      provider = "gh",
      get_mr_detail = function()
        return { provider = "github", repo = "owner/repo", number = 100, mo_id = "github:owner/repo:100" }
      end,
      fetch_threads = function()
        return {}
      end,
    },
    cfg = {},
  }
end

-- Initialize session
review.init_session(".")

print("==========================================================================")
print("  lreview.nvim — Benchmark: Subprocess vs. uv.new_work Thread Model")
print("==========================================================================")

-- Benchmark 1: New uv.new_work Thread Model
local iters = 50
local done_count = 0

local t0 = vim.uv.hrtime()

for i = 1, iters do
  review.pull_review_async(function(success)
    done_count = done_count + 1
  end)
end

vim.wait(5000, function() return done_count == iters end, 1)

local dt_thread = (vim.uv.hrtime() - t0) / iters / 1e6

print(string.format("  [Thread Model]   uv.new_work dispatch (%d ops):  %8.3f ms / call", iters, dt_thread))

-- Benchmark 2: Subprocess Spawn Model (nvim --headless)
local sub_iters = 10
local t0_sub = vim.uv.hrtime()
for i = 1, sub_iters do
  local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-c", "qa" }
  vim.system(cmd):wait()
end
local dt_sub = (vim.uv.hrtime() - t0_sub) / sub_iters / 1e6

print(string.format("  [Subprocess]     nvim --headless spawn (%d ops): %8.3f ms / call", sub_iters, dt_sub))
print("--------------------------------------------------------------------------")

local speedup = dt_sub / dt_thread
print(string.format("  ==> Speedup: Thread model is %.1fx FASTER than Subprocess spawn!", speedup))
print("==========================================================================")
