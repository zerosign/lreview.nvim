local materialize = require("lreview.materialize")

print("TEST: Starting Materialization Strategy Unit Tests...")

-- 1. Test Mode Resolution for Topology 3 (Simple)
local mode_simple = materialize.resolve_mode({ topology = "simple" }, 5)
if mode_simple ~= "checkout" then
  print("FAIL: Simple topology should resolve to 'checkout'")
  os.exit(1)
end

-- 2. Test Mode Resolution for Topology 1 (Monorepo Multi)
local mode_multi = materialize.resolve_mode({ topology = "monorepo-multi" }, 5)
if mode_multi ~= "worktree" then
  print("FAIL: Monorepo multi topology should resolve to 'worktree'")
  os.exit(1)
end

-- 3. Test Mode Resolution for Topology 2 (Monorepo Single) with file count threshold
local mode_single_small = materialize.resolve_mode({ topology = "monorepo-single" }, 5)
if mode_single_small ~= "checkout" then
  print("FAIL: Small single monorepo MR should resolve to 'checkout'")
  os.exit(1)
end

local mode_single_large = materialize.resolve_mode({ topology = "monorepo-single" }, 25)
if mode_single_large ~= "worktree" then
  print("FAIL: Large single monorepo MR (>20 files) should resolve to 'worktree'")
  os.exit(1)
end

print("SUCCESS: Materialization mode resolution verified across topologies.")
print("ALL MATERIALIZATION TESTS PASSED.")
