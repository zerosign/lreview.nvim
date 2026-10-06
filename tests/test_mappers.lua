local mappers = require("lreview.mappers")

print("TEST: Starting Mappers Unit Tests...")

-- ============================================================================
-- 1. Test GitHub Mappers
-- ============================================================================

-- Mock PR list JSON from gh
local mock_gh_pr = {
  number = 42,
  title = "Add new feature",
  author = { login = "zerosign" },
  state = "OPEN",
  headRefName = "feature-branch",
  baseRefName = "master",
  url = "https://github.com/owner/repo/pull/42",
  updatedAt = "2026-08-29T12:00:00Z"
}

local mr = mappers.gh_pr_to_mr(mock_gh_pr, "owner/repo")
if mr.number ~= 42 or mr.provider ~= "github" or mr.repo ~= "owner/repo" or mr.source_branch ~= "feature-branch" then
  print("FAIL: gh_pr_to_mr failed.")
  os.exit(1)
end

-- Test list mapping
local prs = mappers.gh_prs_to_pull_requests({ mock_gh_pr }, "owner/repo")
if #prs ~= 1 or prs[1].number ~= 42 then
  print("FAIL: gh_prs_to_pull_requests failed.")
  os.exit(1)
end

-- Test PR View detail mapping
local mock_gh_detail = {
  number = 42,
  title = "Add new feature",
  author = { login = "zerosign" },
  state = "OPEN",
  headRefName = "feature-branch",
  baseRefName = "master",
  url = "https://github.com/owner/repo/pull/42",
  updatedAt = "2026-08-29T12:00:00Z",
  body = "PR description body content.",
  baseRefOid = "basesha123",
  headRefOid = "headsha456",
  mergeable = "MERGEABLE",
  files = {
    { path = "lua/lreview/init.lua", additions = 10, deletions = 2, changeType = "MODIFIED" }
  },
  commits = {
    { oid = "commitsha789", messageHeadline = "feat: add mapping tests", authors = { { login = "zerosign" } } }
  }
}

local detail = mappers.gh_pr_view_to_mrdetail(mock_gh_detail, "owner/repo")
if detail.description ~= "PR description body content." or detail.base_sha ~= "basesha123" or not detail.mergeable then
  print("FAIL: gh_pr_view_to_mrdetail failed.")
  os.exit(1)
end
if #detail.files ~= 1 or detail.files[1].path ~= "lua/lreview/init.lua" then
  print("FAIL: gh_pr_view_to_mrdetail files mapping failed.")
  os.exit(1)
end
if #detail.commits ~= 1 or detail.commits[1].sha ~= "commitsha789" or detail.commits[1].author ~= "zerosign" then
  print("FAIL: gh_pr_view_to_mrdetail commits mapping failed.")
  os.exit(1)
end

-- Test review comment mapping
local mock_gh_comment = {
  id = 999,
  user = { login = "reviewer" },
  body = "Review comment content.",
  created_at = "2026-08-29T12:30:00Z",
  in_reply_to_id = 888,
  path = "lua/lreview/git.lua",
  original_line = 15,
  commit_id = "commitsha789"
}
local comment = mappers.gh_review_comment_to_comment(mock_gh_comment)
if comment.c_id ~= "999" or comment.in_reply_to ~= "888" or comment.path ~= "lua/lreview/git.lua" or comment.line ~= 15 then
  print("FAIL: gh_review_comment_to_comment failed.")
  os.exit(1)
end

-- Test issue comment mapping
local mock_gh_issue_comment = {
  id = 777,
  author = { login = "zerosign" },
  body = "Issue comment content.",
  createdAt = "2026-08-29T12:45:00Z"
}
local issue_comment = mappers.gh_issue_comment_to_comment(mock_gh_issue_comment)
if issue_comment.c_id ~= "777" or issue_comment.author ~= "zerosign" or issue_comment.body ~= "Issue comment content." then
  print("FAIL: gh_issue_comment_to_comment failed.")
  os.exit(1)
end

print("SUCCESS: GitHub mappers verified.")

-- ============================================================================
-- 2. Test GitLab Mappers
-- ============================================================================

-- Mock MR list JSON from glab
local mock_glab_mr = {
  iid = 12,
  title = "Fix GitLab adapter mapping",
  author = { username = "zerosign" },
  state = "opened",
  source_branch = "fix/gitlab-mapping",
  target_branch = "master",
  web_url = "https://gitlab.com/owner/repo/-/merge_requests/12",
  updated_at = "2026-08-29T13:00:00Z"
}

local mr_gl = mappers.glab_mr_to_mr(mock_glab_mr, "owner/repo")
if mr_gl.number ~= 12 or mr_gl.provider ~= "gitlab" or mr_gl.repo ~= "owner/repo" or mr_gl.source_branch ~= "fix/gitlab-mapping" then
  print("FAIL: glab_mr_to_mr failed.")
  os.exit(1)
end

-- Test list mapping
local prs_gl = mappers.glab_merge_requests_to_pull_requests({ mock_glab_mr }, "owner/repo")
if #prs_gl ~= 1 or prs_gl[1].number ~= 12 then
  print("FAIL: glab_merge_requests_to_pull_requests failed.")
  os.exit(1)
end

-- Test detail mapping
local mock_glab_detail = {
  iid = 12,
  title = "Fix GitLab adapter mapping",
  author = { username = "zerosign" },
  state = "opened",
  source_branch = "fix/gitlab-mapping",
  target_branch = "master",
  web_url = "https://gitlab.com/owner/repo/-/merge_requests/12",
  updated_at = "2026-08-29T13:00:00Z",
  description = "Detailed merge request description.",
  sha = "glabheadsha123",
  detailed_merge_status = "mergeable"
}
local detail_gl = mappers.glab_mr_view_to_mrdetail(mock_glab_detail, "owner/repo")
if detail_gl.description ~= "Detailed merge request description." or detail_gl.head_sha ~= "glabheadsha123" or not detail_gl.mergeable then
  print("FAIL: glab_mr_view_to_mrdetail failed.")
  os.exit(1)
end

-- Test discussions/threads mapping
local mock_glab_discussions = {
  {
    id = "disc_123",
    notes = {
      {
        id = 111,
        system = false,
        author = { username = "zerosign" },
        body = "First thread comment",
        position = {
          new_path = "lua/lreview/init.lua",
          head_sha = "glabheadsha123",
          new_line = 5,
          line_range = {
            start = { new_line = 5 },
            ["end"] = { new_line = 7 }
          }
        }
      },
      {
        id = 222,
        system = false,
        author = { username = "reviewer" },
        body = "Thread reply comment"
      },
      {
        id = 333,
        system = true, -- should be filtered out
        body = "automated system message"
      }
    }
  }
}

local threads = mappers.glab_discussions_to_threads(mock_glab_discussions, "gitlab:owner/repo:12")
if #threads ~= 1 then
  print("FAIL: glab_discussions_to_threads failed.")
  os.exit(1)
end
local t = threads[1]
if t.t_id ~= "disc_123" or t.path ~= "lua/lreview/init.lua" or t.start_line ~= 5 or t.end_line ~= 7 then
  print("FAIL: glab_discussions_to_threads thread metadata mapping failed.")
  os.exit(1)
end
if #t.comments ~= 2 then
  print("FAIL: glab_discussions_to_threads comments count or system filtering failed.")
  os.exit(1)
end
if t.comments[1].c_id ~= "111" or t.comments[2].c_id ~= "222" then
  print("FAIL: glab_discussions_to_threads comments order mapping failed.")
  os.exit(1)
end

print("SUCCESS: GitLab mappers verified.")

-- ============================================================================
-- 3. Test Issue Mappers and vim.NIL handling
-- ============================================================================

-- Mock GitHub issue with vim.NIL fields (e.g. milestone, assignees, etc.)
local mock_gh_issue_with_nil = {
  number = 18,
  title = "FreeBSD Build?",
  body = "i tried using cargo crates to compile...",
  state = "open",
  html_url = "https://github.com/MaikBuse/gosuto/issues/18",
  comments = 0,
  closed_at = vim.NIL,
  updated_at = "2026-09-28T17:20:46Z",
  assignee = vim.NIL,
  assignees = vim.NIL,
  milestone = vim.NIL,
  labels = vim.NIL,
  user = {
    login = "Konpaku-LVX",
    id = 76745649
  }
}

local gh_issue = mappers.gh_issue_to_issue(mock_gh_issue_with_nil, "MaikBuse/gosuto")
if gh_issue.number ~= 18 or gh_issue.author ~= "Konpaku-LVX" or gh_issue.milestone ~= nil or gh_issue.assignees ~= nil or gh_issue.labels ~= nil then
  print("FAIL: gh_issue_to_issue with vim.NIL failed.")
  os.exit(1)
end

-- Mock GitHub issue with milestone object and assignees
local mock_gh_issue_full = {
  number = 19,
  title = "Another issue",
  body = vim.NIL,
  state = "CLOSED",
  html_url = "https://github.com/MaikBuse/gosuto/issues/19",
  comments = 5,
  closed_at = "2026-09-29T10:00:00Z",
  updated_at = "2026-09-29T10:00:00Z",
  assignees = { { login = "user1" }, { login = "user2" } },
  milestone = { title = "v1.0" },
  labels = { { name = "bug" }, { name = "help wanted" } },
  user = { login = "creator" }
}

local gh_issue2 = mappers.gh_issue_to_issue(mock_gh_issue_full, "MaikBuse/gosuto")
if gh_issue2.state ~= "closed" or gh_issue2.milestone ~= "v1.0" or #gh_issue2.assignees ~= 2 or gh_issue2.labels ~= "bug,help wanted" or gh_issue2.body ~= nil then
  print("FAIL: gh_issue_to_issue with full fields failed.")
  os.exit(1)
end

-- Test gh_issues_to_issues array filtering (issue with vim.NIL pull_request vs real PR)
local mock_gh_pr_as_issue = {
  number = 20,
  title = "A Pull Request",
  pull_request = { url = "https://api.github.com/repos/MaikBuse/gosuto/pulls/20" },
  user = { login = "pr-author" },
}
local mock_gh_issue_with_nil_pr = {
  number = 21,
  title = "A Regular Issue",
  pull_request = vim.NIL,
  user = { login = "issue-author" },
}
local filtered_issues = mappers.gh_issues_to_issues({ mock_gh_pr_as_issue, mock_gh_issue_with_nil_pr }, "MaikBuse/gosuto")
if #filtered_issues ~= 1 or filtered_issues[1].number ~= 21 then
  print("FAIL: gh_issues_to_issues failed to filter PR or improperly dropped issue with pull_request = vim.NIL.")
  os.exit(1)
end

-- Mock GitHub issue note with vim.NIL
local mock_gh_note = {
  id = 12345,
  user = { login = "commenter" },
  created_at = "2026-09-29T12:00:00Z",
  body = "Note body",
}
local gh_note = mappers.gh_issue_note_to_note(mock_gh_note, "MaikBuse/gosuto", 18)
if gh_note.remote_id ~= "12345" or gh_note.author ~= "commenter" or gh_note.body ~= "Note body" then
  print("FAIL: gh_issue_note_to_note failed.")
  os.exit(1)
end

-- Mock GitLab issue with vim.NIL fields
local mock_glab_issue_with_nil = {
  iid = 4,
  title = "Sample GitLab Issue",
  description = vim.NIL,
  state = "opened",
  web_url = "https://gitlab.com/zerodevs/sample-review/-/issues/4",
  user_notes_count = 2,
  closed_at = vim.NIL,
  updated_at = "2026-09-30T10:00:00Z",
  assignees = vim.NIL,
  milestone = vim.NIL,
  labels = vim.NIL,
  author = { username = "zerodevs" }
}

local glab_issue = mappers.glab_issue_to_issue(mock_glab_issue_with_nil, "zerodevs/sample-review")
if glab_issue.number ~= 4 or glab_issue.author ~= "zerodevs" or glab_issue.milestone ~= nil or glab_issue.assignees ~= nil or glab_issue.description ~= nil then
  print("FAIL: glab_issue_to_issue with vim.NIL failed.")
  os.exit(1)
end

-- Mock GitLab issue note with vim.NIL
local mock_glab_note = {
  id = 987,
  author = { username = "glabuser" },
  created_at = "2026-09-30T11:00:00Z",
  body = "GitLab note body",
  system = false,
}
local glab_note = mappers.glab_issue_note_to_note(mock_glab_note, "zerodevs/sample-review", 4)
if glab_note.remote_id ~= "987" or glab_note.author ~= "glabuser" or glab_note.body ~= "GitLab note body" or glab_note.system ~= false then
  print("FAIL: glab_issue_note_to_note failed.")
  os.exit(1)
end

print("SUCCESS: Issue mappers and vim.NIL handling verified.")

print("\nALL MAPPER TESTS PASSED.")
os.exit(0)

