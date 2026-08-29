-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local storage = require("lreview.storage")
local comments = require("lreview.storage.comments")
local pull_request = require("lreview.storage.pull_request")

print("TEST: Starting Storage Layer Unit Tests...")

-- 1. Configure and open a temporary test database
local test_db_path = "tmp/test_storage_suite.db"
vim.fn.delete(test_db_path)

require("lreview").setup({
  defaults = {
    db_path = test_db_path,
  }
})

local ok, err = storage.open()
if not ok then
  print("FAIL: Could not open test database: " .. tostring(err))
  os.exit(1)
end
print("SUCCESS: Database connection opened successfully.")

-- ============================================================================
-- 2. Test Pull Requests Storage
-- ============================================================================
local mock_pr = {
  provider = "github",
  repo = "owner/repo",
  number = 100,
  mo_id = "github:owner/repo:100",
  title = "Update database driver to FFI",
  body = "Resolves issue #5",
  source_branch = "feature/ffi-driver",
  target_branch = "main",
  state = "open",
  head_sha = "abc123headsha",
  base_sha = "def456basesha",
  url = "https://github.com/owner/repo/pull/100",
  updated_at = "2026-08-29T00:00:00Z",
}

pull_request.upsert(mock_pr)
local retrieved_pr = pull_request.get(mock_pr.mo_id)

if not retrieved_pr or retrieved_pr.title ~= mock_pr.title then
  print("FAIL: Pull Request upsert or retrieval failed.")
  os.exit(1)
end

local all_prs = pull_request.list(mock_pr.provider, mock_pr.repo)
if #all_prs ~= 1 then
  print("FAIL: Pull Request list() query failed.")
  os.exit(1)
end
print("SUCCESS: Pull Request queries and upserts verified.")

-- ============================================================================
-- 3. Test Comments & Threads Storage
-- ============================================================================
local mock_thread = {
  t_id = "thread_abc_123",
  mo_id = mock_pr.mo_id,
  path = "lua/lreview/storage/init.lua",
  commit_sha = "abc123headsha",
  start_line = 10,
  end_line = 12,
  is_draft = true,
  last_synced_at = nil,
  resolved = false,
}

local created_t_id = comments.create_thread(mock_thread)
if created_t_id ~= mock_thread.t_id then
  print("FAIL: Thread creation failed.")
  os.exit(1)
end

-- Test adding comments
local comment1 = {
  c_id = "comment_1",
  t_id = mock_thread.t_id,
  remote_id = nil,
  author = "zerosign",
  body = "Review comment text line 1.",
  created_at = "2026-08-29T08:00:00Z",
  in_reply_to = nil,
}

local comment2 = {
  c_id = "comment_2",
  t_id = mock_thread.t_id,
  remote_id = "remote_comment_2_id",
  author = "reviewer",
  body = "Review comment response.",
  created_at = "2026-08-29T08:15:00Z",
  in_reply_to = "comment_1",
}

comments.add_comment(comment1)
comments.add_comment(comment2)

-- Query checks
local thread_comments = comments.comments_for_thread(mock_thread.t_id)
if #thread_comments ~= 2 then
  print("FAIL: Comments retrieval for thread failed.")
  os.exit(1)
end

local buffer_comments = comments.comments_for_buffer(mock_pr.mo_id, mock_thread.path)
if #buffer_comments ~= 2 then
  print("FAIL: Comments retrieval for buffer failed.")
  os.exit(1)
end

-- Test comment update
local updated_body = "Updated comment text line 1."
comments.update_comment(comment1.c_id, updated_body)
local updated_comment = storage.query("SELECT * FROM comments WHERE c_id = ?", comment1.c_id)[1]
if not updated_comment or updated_comment.body ~= updated_body then
  print("FAIL: Comment update failed.")
  os.exit(1)
end

-- Test draft list queries
local draft_threads = comments.draft_threads(mock_pr.mo_id)
if #draft_threads ~= 1 then
  print("FAIL: Draft threads query failed.")
  os.exit(1)
end

-- Test synchronization markers
comments.mark_synced(mock_thread.t_id)
local thread_synced = comments.get_thread(mock_thread.t_id)
if not thread_synced or thread_synced.is_draft == 1 or not thread_synced.last_synced_at then
  print("FAIL: Thread synchronization mapping failed.")
  os.exit(1)
end

-- Test thread resolution
comments.resolve_thread(mock_thread.t_id, true)
local resolved_thread = comments.get_thread(mock_thread.t_id)
if not resolved_thread or resolved_thread.resolved ~= 1 then
  print("FAIL: Thread resolution toggle failed.")
  os.exit(1)
end

-- Test deletion
comments.delete_comment(comment2.c_id)
local deleted_comment = storage.query("SELECT * FROM comments WHERE c_id = ?", comment2.c_id)[1]
if deleted_comment then
  print("FAIL: Comment deletion failed.")
  os.exit(1)
end

comments.delete_thread(mock_thread.t_id)
local deleted_thread = comments.get_thread(mock_thread.t_id)
if deleted_thread then
  print("FAIL: Thread deletion failed.")
  os.exit(1)
end

print("SUCCESS: Comment and Thread operations verified.")

-- 4. Teardown
storage.close()
vim.fn.delete(test_db_path)
print("\nALL STORAGE TESTS PASSED.")
os.exit(0)
