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

-- 2. Verify GitLab adapter capabilities
local gl_adapter = adapter.get("gitlab")
local resolved_gl = { adapter = gl_adapter }

if not adapter.supports(resolved_gl, "batch_submit") then
  print("FAIL: GitLab adapter should support batch_submit capability")
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

print("SUCCESS: Adapter capabilities, overrides, and base fallbacks verified.")
print("ALL CAPABILITY SYSTEM TESTS PASSED.")
