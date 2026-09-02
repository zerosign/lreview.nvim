-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local detail_editor = require("lreview.ui.detail_editor")
local review = require("lreview.review")

print("TEST: Starting MR Detail Editor Lifecycle Test...")

-- 1. Create a mock MR detail
local mock_detail = {
  provider = "github",
  number = 42,
  title = "Original MR Title",
  source_branch = "feature/test",
  target_branch = "main",
  state = "open",
  body = "Original PR description body.\nLine 2.",
}

-- 2. Open the editor (creates the buffer and splits the window)
detail_editor.open(mock_detail)

local buf_name = string.format("lreview_detail://%s/%d", mock_detail.provider, mock_detail.number)
local bufnr = nil
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  local name = vim.api.nvim_buf_get_name(b)
  if name:match(buf_name .. "$") then
    bufnr = b
    break
  end
end

if not bufnr then
  print("FAIL: Detail editor buffer was not created.")
  os.exit(1)
end
print("SUCCESS: Detail editor buffer created successfully.")

-- 3. Verify buffer contents
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local content_str = table.concat(lines, "\n")
if not content_str:match("# Title: Original MR Title") then
  print("FAIL: Title was not rendered correctly in the buffer.")
  os.exit(1)
end
if not content_str:match("Original PR description body.") then
  print("FAIL: Description was not rendered correctly in the buffer.")
  os.exit(1)
end
print("SUCCESS: Buffer contents parsed and verified.")

-- 4. Mock the review.update_review_async call to capture user updates
local captured_title = nil
local captured_body = nil
review.update_review_async = function(title, body, number, cwd, callback)
  captured_title = title
  captured_body = body
  if callback then callback(true, nil) end
end

-- 5. Simulate editing the buffer contents
local new_lines = {
  "# Title: Extremely Great PR Title",
  "",
  "## Metadata",
  "- **Provider:** github",
  "- **Number:** #42",
  "- **Source:** feature/test",
  "- **Target:** main",
  "- **Status:** open",
  "",
  "## Description",
  "This is the brand new description.",
  "It has multiple lines of text.",
  "Committed successfully.",
}

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)

-- 6. Trigger save (:w) which executes the BufWriteCmd autocommand
vim.api.nvim_buf_call(bufnr, function()
  vim.cmd("write")
end)

-- 7. Assert updates were correctly parsed and captured
if captured_title ~= "Extremely Great PR Title" then
  print("FAIL: Captured title was wrong: " .. tostring(captured_title))
  os.exit(1)
end

local expected_body = "This is the brand new description.\nIt has multiple lines of text.\nCommitted successfully."
if captured_body ~= expected_body then
  print("FAIL: Captured body was wrong: " .. tostring(captured_body))
  os.exit(1)
end

print("SUCCESS: Buffer edits successfully parsed and saved.")

-- 8. Clean up
vim.api.nvim_buf_delete(bufnr, { force = true })
print("\nALL DETAIL EDITOR TESTS PASSED.")
os.exit(0)
