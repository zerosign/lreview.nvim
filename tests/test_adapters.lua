local base = require("lreview.adapter.base")
local github = require("lreview.adapter.github")
local gitlab = require("lreview.adapter.gitlab")

print("TEST: Starting Adapter Unit Tests using CLI Mocks...")

-- Save the original executor runner
local original_run = base.run

-- Simple mock state
local last_command = nil
local next_response = { ok = true, code = 0, stdout = "[]", stderr = "", combined = "" }

-- Override base.run
base.run = function(argv, opts)
  last_command = argv
  local stdout = next_response.stdout or ""
  local stderr = next_response.stderr or ""
  return {
    ok = next_response.ok,
    code = next_response.code or 0,
    stdout = stdout,
    stderr = stderr,
    combined = next_response.combined or (stdout .. "\n" .. stderr),
    error = next_response.ok and nil or "Mock command error"
  }
end

local cfg = { provider = "gh", adapter = "github" }
local ctx = { repo = "owner/repo", host = "github.com", cwd = "." }

-- ============================================================================
-- 1. Test GitHub Adapter Methods
-- ============================================================================

-- Test list_pull_requests
next_response = {
  ok = true,
  code = 0,
  stdout = '[{"number":42,"title":"Mock PR","author":{"login":"zerosign"},"state":"OPEN","headRefName":"branch","baseRefName":"master"}]'
}
local prs, err = github.list_pull_requests(cfg, ctx)
if not prs or #prs ~= 1 or prs[1].number ~= 42 then
  print("FAIL: github.list_pull_requests parsing failed.")
  os.exit(1)
end
local has_pr, has_list = false, false
for _, arg in ipairs(last_command) do
  if arg == "pr" then has_pr = true end
  if arg == "list" then has_list = true end
end
if not has_pr or not has_list then
  print("FAIL: github.list_pull_requests constructed incorrect command line: " .. table.concat(last_command, " "))
  os.exit(1)
end

-- Test get_mr_detail
next_response = {
  ok = true,
  code = 0,
  stdout = '{"number":42,"title":"Mock PR","author":{"login":"zerosign"},"state":"OPEN","headRefName":"branch","baseRefName":"master","body":"Description"}'
}
local detail, err = github.get_mr_detail(cfg, ctx, 42)
if not detail or detail.description ~= "Description" then
  print("FAIL: github.get_mr_detail failed.")
  os.exit(1)
end

-- Test fetch_inline_comments
next_response = {
  ok = true,
  code = 0,
  stdout = '[{"id":999,"user":{"login":"reviewer"},"body":"Comment","created_at":"2026-08-29"}]'
}
local comments, err = github.fetch_inline_comments(cfg, ctx, 42)
if not comments or #comments ~= 1 or comments[1].c_id ~= "999" then
  print("FAIL: github.fetch_inline_comments failed.")
  os.exit(1)
end

-- Test resolve_thread
next_response = { ok = true, code = 0, stdout = "{}" }
local ok, err = github.resolve_thread(cfg, ctx, 42, "thread_123", true)
if not ok then
  print("FAIL: github.resolve_thread failed.")
  os.exit(1)
end

-- Test close_mr & approve_mr
next_response = { ok = true, code = 0, stdout = "closed" }
local ok, err = github.close_mr(cfg, ctx, 42)
if not ok then
  print("FAIL: github.close_mr failed.")
  os.exit(1)
end

next_response = { ok = true, code = 0, stdout = "approved" }
local ok, err = github.approve_mr(cfg, ctx, 42)
if not ok then
  print("FAIL: github.approve_mr failed.")
  os.exit(1)
end

print("SUCCESS: GitHub adapter mocks verified.")

-- ============================================================================
-- 2. Test GitLab Adapter Methods
-- ============================================================================
local gl_cfg = { provider = "glab", adapter = "gitlab" }

-- Test list_pull_requests
next_response = {
  ok = true,
  code = 0,
  stdout = '[{"iid":12,"title":"Mock MR","author":{"username":"zerosign"},"state":"opened","source_branch":"branch","target_branch":"master"}]'
}
local prs_gl, err = gitlab.list_pull_requests(gl_cfg, ctx)
if not prs_gl or #prs_gl ~= 1 or prs_gl[1].number ~= 12 then
  print("FAIL: gitlab.list_pull_requests parsing failed.")
  os.exit(1)
end
local has_mr, has_list = false, false
for _, arg in ipairs(last_command) do
  if arg == "mr" then has_mr = true end
  if arg == "list" then has_list = true end
end
if not has_mr or not has_list then
  print("FAIL: gitlab.list_pull_requests constructed incorrect command line: " .. table.concat(last_command, " "))
  os.exit(1)
end

-- Test get_mr_detail
next_response = {
  ok = true,
  code = 0,
  stdout = '{"iid":12,"title":"Mock MR","author":{"username":"zerosign"},"state":"opened","source_branch":"branch","target_branch":"master","description":"Description"}'
}
local detail_gl, err = gitlab.get_mr_detail(gl_cfg, ctx, 12)
if not detail_gl or detail_gl.description ~= "Description" then
  print("FAIL: gitlab.get_mr_detail failed.")
  os.exit(1)
end

-- Test close_mr & approve_mr
next_response = { ok = true, code = 0, stdout = "closed" }
local ok, err = gitlab.close_mr(gl_cfg, ctx, 12)
if not ok then
  print("FAIL: gitlab.close_mr failed.")
  os.exit(1)
end

next_response = { ok = true, code = 0, stdout = "approved" }
local ok, err = gitlab.approve_mr(gl_cfg, ctx, 12)
if not ok then
  print("FAIL: gitlab.approve_mr failed.")
  os.exit(1)
end

print("SUCCESS: GitLab adapter mocks verified.")

-- Restore original runner
base.run = original_run

print("\nALL ADAPTER TESTS PASSED.")
os.exit(0)
