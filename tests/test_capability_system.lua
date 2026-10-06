local adapter = require("lreview.adapter")
local base = require("lreview.adapter.base")

print("TEST: Starting Capability System Unit Tests...")

-- 1. Verify GitHub adapter capabilities
local gh_adapter = adapter.get("github")
local resolved_gh = { adapter = gh_adapter }

if not adapter.supports(resolved_gh, "draft_mr") then
  print("FAIL: GitHub adapter should support draft_mr capability")
  os.exit(1)
end

if not adapter.supports(resolved_gh, "review_verdict") then
  print("FAIL: GitHub adapter should support review_verdict capability")
  os.exit(1)
end

-- 2. Verify GitLab adapter capabilities.
local gl_adapter = adapter.get("gitlab")
local resolved_gl = { adapter = gl_adapter }

--
-- `glab mr note create` is one note per call, so GitLab must NOT claim a batch
-- inline create (v3 claimed batch_submit=true, which implied atomic all-or-
-- nothing semantics that do not exist there and led to duplicate posts after a
-- mid-loop failure). The submit engine drives on atomic_inline_batch; batch_submit
-- is left as accurate metadata for third-party logic.
if adapter.supports(resolved_gl, "batch_submit") then
  print("FAIL: GitLab must not claim batch_submit (glab creates one note per call)")
  os.exit(1)
end

if adapter.supports(resolved_gl, "atomic_inline_batch") then
  print("FAIL: GitLab must not claim atomic_inline_batch")
  os.exit(1)
end

if adapter.supports(resolved_gl, "verdict_in_review_batch") then
  print("FAIL: GitLab has no review event on its note calls; verdict must be its own call")
  os.exit(1)
end

if not adapter.supports(resolved_gl, "issues") then
  print("FAIL: GitLab adapter should support the issues capability")
  os.exit(1)
end

-- 2b. GitHub's review POST really does batch comments, atomically, and can carry
-- the verdict inside it.
local resolved_gh2 = { adapter = gh_adapter }
if not adapter.supports(resolved_gh2, "batch_submit") then
  print("FAIL: GitHub should claim batch_submit")
  os.exit(1)
end
if not adapter.supports(resolved_gh2, "atomic_inline_batch") then
  print("FAIL: GitHub should claim atomic_inline_batch")
  os.exit(1)
end
if not adapter.supports(resolved_gh2, "verdict_in_review_batch") then
  print("FAIL: GitHub should claim verdict_in_review_batch")
  os.exit(1)
end
if not adapter.supports(resolved_gh2, "issues") then
  print("FAIL: GitHub should claim issues")
  os.exit(1)
end

-- 3. Verify Custom Adapter Fallback to base.default_capabilities
local custom_adapter = {
  name = "custom",
  capabilities = {
    review_verdict = true, -- explicit override
  }
}
local resolved_custom = { adapter = custom_adapter }

if not adapter.supports(resolved_custom, "review_verdict") then
  print("FAIL: Custom adapter explicit capability override failed")
  os.exit(1)
end

-- inline_comments is true in base defaults, update_mr is true, approve_mr is false
if not adapter.supports(resolved_custom, "inline_comments") then
  print("FAIL: Custom adapter should inherit base default inline_comments=true")
  os.exit(1)
end

if adapter.supports(resolved_custom, "approve_mr") then
  print("FAIL: Custom adapter should inherit base default approve_mr=false")
  os.exit(1)
end

-- The new submit-shape flags must default off, so a custom adapter is never
-- assumed to support an atomic batch, an in-batch verdict, or an issue tracker.
if adapter.supports(resolved_custom, "atomic_inline_batch") then
  print("FAIL: Custom adapter should default atomic_inline_batch=false")
  os.exit(1)
end
if adapter.supports(resolved_custom, "verdict_in_review_batch") then
  print("FAIL: Custom adapter should default verdict_in_review_batch=false")
  os.exit(1)
end
if adapter.supports(resolved_custom, "issues") then
  print("FAIL: Custom adapter should default issues=false")
  os.exit(1)
end

print("SUCCESS: Adapter capabilities, overrides, and base fallbacks verified.")
print("ALL CAPABILITY SYSTEM TESTS PASSED.")
