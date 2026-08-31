package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"
local sync = require("lreview.sync")
local git = require("lreview.git")

print("==========================================================================")
print("  lreview.nvim — Benchmark: Core Plan 2 (Sync Bus & Diff Cache)")
print("==========================================================================")

local cwd = vim.fn.getcwd()
local sample_file = "lua/lreview/init.lua"

-- Simulate a real review session so the diff cache resolves the target branch
-- from review.current (avoids the git.default_branch fallback that only runs
-- when no review is active — a non-production path).
local review = require("lreview.review")
review.current = { cwd = cwd, detail = { target_branch = "master" } }

-- Benchmark 1: Uncached git.changed_lines vs Cached sync.get_changed_lines
local iters = 100

-- Uncached
local t0_uncached = vim.uv.hrtime()
for _ = 1, iters do
  git.changed_lines(sample_file, cwd)
end
local dt_uncached = (vim.uv.hrtime() - t0_uncached) / iters / 1e6

-- Cached (Sync Bus)
sync.invalidate_diff_cache()
local t0_cached = vim.uv.hrtime()
for _ = 1, iters do
  sync.get_changed_lines(cwd, sample_file)
end
local dt_cached = (vim.uv.hrtime() - t0_cached) / iters / 1e6

print(string.format("  [Uncached git diff]   Direct git process (%d ops): %8.3f ms / call", iters, dt_uncached))
print(string.format("  [Cached Sync Bus]     In-memory diff cache (%d ops): %8.3f ms / call", iters, dt_cached))
print("--------------------------------------------------------------------------")

local speedup = dt_uncached / (dt_cached > 0 and dt_cached or 0.0001)
print(string.format("  ==> Diff Cache Speedup: %.1fx FASTER per decor refresh!", speedup))

-- Benchmark 2: Rapid Event Coalescing (100 mark_dirty calls -> 1 debounced flush)
local render_passes = 0
sync.subscribe("decor", function()
  render_passes = render_passes + 1
end)

local t0_mark = vim.uv.hrtime()
local buf = vim.api.nvim_create_buf(false, true)

for _ = 1, 100 do
  sync.mark_dirty(buf)
end

vim.wait(1000, function() return render_passes > 0 end, 10)
local dt_mark = (vim.uv.hrtime() - t0_mark) / 1e6

print("--------------------------------------------------------------------------")
print(string.format("  [Event Coalescing]   100 mark_dirty calls -> %d render pass (%.3f ms total)", render_passes, dt_mark))
print("==========================================================================")
