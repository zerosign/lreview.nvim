local comments = require("lreview.storage.comments")
local review = require("lreview.review")
local git = require("lreview.git")
local config = require("lreview.config")

local M = {}

local ns = vim.api.nvim_create_namespace("lreview_summary")

local function setup_highlights()
  local defs = {
    LReviewSummaryDraft = { link = "WarningMsg" },
    LReviewSummaryActive = { link = "Identifier" },
    LReviewSummaryResolved = { link = "Comment" },
    LReviewSummaryConflict = { link = "ErrorMsg" },
    LReviewSummaryHeader = { link = "Title" },
    LReviewSummaryLocation = { link = "Directory" },
  }
  for name, opts in pairs(defs) do
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end
end

M.state = nil -- { bufnr, winid, threads_map = { [line] = thread }, show_all = boolean }

function M.close()
  if M.state then
    if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
      vim.api.nvim_win_close(M.state.winid, true)
    end
    M.state = nil
  end
end

function M.redraw()
  if not M.state or not vim.api.nvim_buf_is_valid(M.state.bufnr) then return end
  if not review.current then return end

  local mo_id = review.current.detail.mo_id
  local root = git.root(review.current.cwd)
  if not root then return end

  local lines = {}
  local threads_map = {}
  local files_map = {}

  M.state.view_mode = M.state.view_mode or "threads"
  M.state.sort_mode = M.state.sort_mode or "path"

  local win_w = (M.state and M.state.winid and vim.api.nvim_win_is_valid(M.state.winid)) and vim.api.nvim_win_get_width(M.state.winid) or 100
  if win_w < 80 then win_w = 80 end

  local is_unlinked = review.current and review.current.detail and review.current.detail.unlinked
  if M.state.view_mode == "files" then
    lines[#lines + 1] = is_unlinked and "=== Local Review Summary [Files - Local / Unlinked] ===" or "=== Local Review Summary [Files] ==="
    if is_unlinked then
      lines[#lines + 1] = string.format("Branch: %s ──> %s | No active remote PR/MR (Press [C] to Create PR/MR)",
        review.current.detail.source_branch or "head", review.current.detail.target_branch or "main")
    else
      lines[#lines + 1] = string.format("Filter: %s | Sort: [%s] (f: filter, g: toggle view, S: cycle sort)",
        M.state.show_all and "[Showing All]" or "[Active & Drafts Only]", M.state.sort_mode)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(" %-12s %-8s %-8s %s", "Status", "+Adds", "-Dels", "Path")
    lines[#lines + 1] = string.rep("─", win_w)

    local mr_files = review.current.detail.files or {}
    local file_rows = {}
    for _, f in ipairs(mr_files) do
      local path = f.path or f.filename or f.old_path or ""
      local adds = f.additions or f.adds or 0
      local dels = f.deletions or f.dels or 0
      local file_comments = comments.comments_for_buffer(mo_id, path)

      local total_comments = #file_comments
      local status = "[✔ Clean]"
      if total_comments > 0 then
        status = string.format("[💬 %d]", total_comments)
      end

      file_rows[#file_rows + 1] = {
        path = path,
        adds = adds,
        dels = dels,
        comments_count = total_comments,
        status = status,
      }
    end

    -- Sort file rows
    table.sort(file_rows, function(a, b)
      if M.state.sort_mode == "comments" then
        return a.comments_count > b.comments_count
      elseif M.state.sort_mode == "additions" then
        return a.adds > b.adds
      elseif M.state.sort_mode == "deletions" then
        return a.dels > b.dels
      else
        return a.path < b.path
      end
    end)

    for _, row in ipairs(file_rows) do
      lines[#lines + 1] = string.format(" %-12s +%-7d -%-7d %s", row.status, row.adds, row.dels, row.path)
      files_map[#lines] = row
    end

    if #file_rows == 0 then
      lines[#lines + 1] = "  No file changes found."
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = string.rep("─", win_w)
    lines[#lines + 1] = " [o/<CR>] Open File | [A] Approve | [R] Reject | [g] Switch to Threads View | [q] Close"
  else
    lines[#lines + 1] = "=== Local Review Summary [Threads] ==="
    lines[#lines + 1] = "Filter: " .. (M.state.show_all and "[Showing All]" or "[Active & Drafts Only]") .. " (f: filter, g: toggle view, u: pull)"
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(" %-12s %-12s %-25s %s", "Status", "Author", "Location", "Preview")
    lines[#lines + 1] = string.rep("─", 80)

    local threads = comments.threads_for_mr(mo_id)
    local count = 0
    for _, t in ipairs(threads) do
      local is_resolved = comments.thread_is_resolved(t.state)
      if M.state.show_all or not is_resolved then
        local cs = comments.comments_for_thread(t.t_id)
        if #cs > 0 then
          count = count + 1
          local first = cs[1]
          local author = first.author or "me"
          local body = first.body:gsub("[\r\n]+", " "):sub(1, 37)
          local status = is_resolved and "[✔ Resolved]" or (comments.thread_is_draft(t.state) and "[💬 Draft]" or "[● Active]")

          local loc = string.format("%s:%d", t.path, t.start_line)
          if #loc > 24 then loc = "..." .. loc:sub(-21) end

          lines[#lines + 1] = string.format(" %-12s %-12s %-25s %s", status, author, loc, body)
          threads_map[#lines] = t
        end
      end
    end

    if count == 0 then
      lines[#lines + 1] = "  No discussions found."
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = string.rep("─", 80)
    lines[#lines + 1] = " [o/<CR>] Open Thread | [s/r] Resolve | [A] Approve | [R] Reject | [g] Switch to Files View | [q] Close"
  end

  M.state.threads_map = threads_map
  M.state.files_map = files_map

  vim.bo[M.state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.bufnr, 0, -1, false, lines)
  vim.bo[M.state.bufnr].modifiable = false

  setup_highlights()
  vim.api.nvim_buf_clear_namespace(M.state.bufnr, ns, 0, -1)

  -- Highlight header lines (0-indexed in API)
  pcall(vim.api.nvim_buf_add_highlight, M.state.bufnr, ns, "LReviewSummaryHeader", 0, 0, -1)
  pcall(vim.api.nvim_buf_add_highlight, M.state.bufnr, ns, "Comment", 1, 0, -1)
  pcall(vim.api.nvim_buf_add_highlight, M.state.bufnr, ns, "LReviewSummaryHeader", 3, 0, -1)
  pcall(vim.api.nvim_buf_add_highlight, M.state.bufnr, ns, "Comment", 4, 0, -1)

  -- Highlight each mapped thread line
  for line_idx, t in pairs(threads_map) do
    local is_resolved = comments.thread_is_resolved(t.state)
    local is_draft = comments.thread_is_draft(t.state)

    local has_edit = false
    local has_del = false
    local has_conflict = false
    local cs = comments.comments_for_thread(t.t_id)
    for _, c in ipairs(cs) do
      if c.state == comments.STATE.MODIFIED then
        has_edit = true
      elseif c.state == comments.STATE.DELETED then
        has_del = true
      elseif c.state == comments.STATE.CONFLICT then
        has_conflict = true
      end
    end

    local hl_group = "LReviewSummaryActive"
    if has_conflict then
      hl_group = "LReviewSummaryConflict"
    elseif is_resolved then
      hl_group = "LReviewSummaryResolved"
    elseif is_draft or has_edit or has_del then
      hl_group = "LReviewSummaryDraft"
    end

    pcall(vim.api.nvim_buf_add_highlight, M.state.bufnr, ns, hl_group, line_idx - 1, 1, 13)
    pcall(vim.api.nvim_buf_add_highlight, M.state.bufnr, ns, "LReviewSummaryLocation", line_idx - 1, 27, 52)
  end

  local total_lines = #lines
  if total_lines >= 4 then
    pcall(vim.api.nvim_buf_add_highlight, M.state.bufnr, ns, "Comment", total_lines - 3, 0, -1)
    pcall(vim.api.nvim_buf_add_highlight, M.state.bufnr, ns, "Comment", total_lines - 2, 0, -1)
    pcall(vim.api.nvim_buf_add_highlight, M.state.bufnr, ns, "Comment", total_lines - 1, 0, -1)
  end
end

function M.toggle_view_mode()
  if M.state then
    M.state.view_mode = (M.state.view_mode == "files") and "threads" or "files"
    M.redraw()
  end
end

function M.cycle_sort_mode()
  if M.state then
    local modes = { "path", "comments", "additions", "deletions" }
    local current = M.state.sort_mode or "path"
    for i, m in ipairs(modes) do
      if m == current then
        M.state.sort_mode = modes[(i % #modes) + 1]
        break
      end
    end
    M.redraw()
  end
end

local function refresh_buffer_highlights(path)
  local decor = require("lreview.ui.decor")
  for bufnr, _ in pairs(decor.enabled_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      local suffix = path:gsub("%.", "%%."):gsub("%-", "%%-")
      if name:match(suffix .. "$") then
        decor.refresh(bufnr)
      end
    end
  end
end

local function refresh_all_buffer_highlights()
  local decor = require("lreview.ui.decor")
  for bufnr, _ in pairs(decor.enabled_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      decor.refresh(bufnr)
    end
  end
end

local sync = require("lreview.sync")

sync.subscribe("panel", function()
  if M.state and vim.api.nvim_buf_is_valid(M.state.bufnr) then
    M.redraw()
  end
end)

local function handle_action(action)
  if not M.state then return end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  if M.state.view_mode == "files" and action == "open" then
    local f_item = M.state.files_map[cursor_line]
    if not f_item then
      vim.notify("lreview: move cursor onto a file row to open", vim.log.levels.WARN)
      return
    end
    M.close()
    local root = git.root(review.current.cwd)
    if not root then return end
    vim.cmd("edit " .. root .. "/" .. f_item.path)
    return
  end

  local thread = M.state.threads_map[cursor_line]

  if not thread and action ~= "push_all" and action ~= "pull" and action ~= "approve" and action ~= "reject" then
    vim.notify("lreview: move cursor onto a discussion or file row to perform action", vim.log.levels.WARN)
    return
  end

  if action == "open" then
    M.close()
    local root = git.root(review.current.cwd)
    if not root then return end
    vim.cmd("edit " .. root .. "/" .. thread.path)
    vim.api.nvim_win_set_cursor(0, { thread.start_line, 0 })
    require("lreview.ui.thread_view").show(vim.api.nvim_get_current_buf(), thread.path, thread.start_line)
  elseif action == "resolve" then
    local new_val = not comments.thread_is_resolved(thread.state)
    review.resolve_thread_async(thread.t_id, new_val, function(ok, err)
      if not ok then
        vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      local sync2 = require("lreview.sync")
      sync2.schedule()
      vim.notify(new_val and "lreview: thread resolved" or "lreview: thread reopened", vim.log.levels.INFO)
    end)
  elseif action == "delete" then
    if comments.thread_is_draft(thread.state) then
      comments.delete_thread(thread.t_id)
      sync.schedule()
      vim.notify("lreview: local draft thread deleted", vim.log.levels.INFO)
    else
      vim.notify("lreview: cannot delete a synced remote thread directly", vim.log.levels.WARN)
    end
  elseif action == "push_selected" then
    vim.notify("lreview: submitting selected thread changes...", vim.log.levels.INFO)
    review.submit_review(thread.t_id, function(ok, count, err)
      if err then
        vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      else
        vim.notify(string.format("lreview: successfully pushed %d comment(s)", count), vim.log.levels.INFO)
        sync.schedule()
      end
    end)
  elseif action == "push_all" then
    vim.notify("lreview: submitting all local changes...", vim.log.levels.INFO)
    review.submit_review(nil, function(ok, count, err)
      if err then
        vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      else
        vim.notify(string.format("lreview: successfully pushed %d comment(s)", count), vim.log.levels.INFO)
        sync.schedule()
      end
    end)
  elseif action == "pull" then
    vim.notify("lreview: pulling remote updates...", vim.log.levels.INFO)
    review.pull_review_async(function(success)
      if success then
        sync.schedule()
      end
    end)
  elseif action == "approve" then
    local adapter = require("lreview.adapter")
    local resolved = adapter.resolve(review.current and review.current.cwd)
    if not adapter.supports(resolved, "approve_mr") then
      vim.notify("lreview: approve MR capability is not supported by active adapter", vim.log.levels.WARN)
      return
    end
    review.approve_review_async(nil, function(ok, err)
      if not ok then
        vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      else
        vim.notify("lreview: MR approved successfully", vim.log.levels.INFO)
        local sync2 = require("lreview.sync")
        sync2.schedule()
      end
    end)
  elseif action == "reject" then
    local adapter = require("lreview.adapter")
    local resolved = adapter.resolve(review.current and review.current.cwd)
    if not adapter.supports(resolved, "review_verdict") then
      vim.notify("lreview: review verdict capability is not supported by active adapter", vim.log.levels.WARN)
      return
    end
    vim.notify("lreview: submitting request changes verdict...", vim.log.levels.INFO)
    review.submit_review(nil, function(ok, count, err)
      if err then
        vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
      else
        sync.schedule()
      end
    end)
  end
end

function M.toggle_filter()
  if M.state then
    M.state.show_all = not M.state.show_all
    M.redraw()
  end
end

function M.open()
  if not review.current then
    -- Non-blocking: render from a local fallback immediately, upgrade to the
    -- real MR detail when it resolves in the background.
    local detail, err = review.init_session_async(nil, function(real_detail, real_err)
      if real_detail and M.state and vim.api.nvim_buf_is_valid(M.state.bufnr) then
        M.redraw()
      end
    end)
    if not detail then
      vim.notify("lreview: failed to initialize review session: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
  end

  M.close()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "lreview_summary"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  M.state = {
    bufnr = buf,
    winid = nil,
    threads_map = {},
    show_all = false,
  }

  local opts = { silent = true, noremap = true, buffer = buf }
  vim.keymap.set("n", "q", function() M.close() end, opts)
  vim.keymap.set("n", "<esc>", function() M.close() end, opts)
  vim.keymap.set("n", "o", function() handle_action("open") end, opts)
  vim.keymap.set("n", "<CR>", function() handle_action("open") end, opts)
  vim.keymap.set("n", "s", function() handle_action("resolve") end, opts)
  vim.keymap.set("n", "r", function() handle_action("resolve") end, opts)
  vim.keymap.set("n", "d", function() handle_action("delete") end, opts)
  vim.keymap.set("n", "p", function() handle_action("push_selected") end, opts)
  vim.keymap.set("n", "P", function() handle_action("push_all") end, opts)
  vim.keymap.set("n", "u", function() handle_action("pull") end, opts)
  vim.keymap.set("n", "f", function() M.toggle_filter() end, opts)
  vim.keymap.set("n", "g", function() M.toggle_view_mode() end, opts)
  vim.keymap.set("n", "S", function() M.cycle_sort_mode() end, opts)
  vim.keymap.set("n", "A", function() handle_action("approve") end, opts)
  vim.keymap.set("n", "R", function() handle_action("reject") end, opts)
  vim.keymap.set("n", "C", function() M.close() vim.cmd("LocalReviewCreate") end, opts)

  local ui_cfg = config.get_defaults().ui or {}
  local layout = ui_cfg.layout or "split"
  if layout == "float" then
    layout = "split"
  end
  local winid

  if layout == "split" or layout == "vsplit" then
    local split_pos = ui_cfg.split and ui_cfg.split.position or "botright"
    local default_size = (layout == "vsplit") and 60 or 15
    local split_size = (ui_cfg.split and ui_cfg.split.size) and ui_cfg.split.size or default_size
    local split_cmd = (layout == "vsplit") and "vnew" or "new"

    vim.cmd(string.format("silent %s %d%s", split_pos, split_size, split_cmd))
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, buf)
  else
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, buf)
  end

  M.state.winid = winid
  M.redraw()
  if vim.api.nvim_buf_line_count(buf) >= 6 then
    pcall(vim.api.nvim_win_set_cursor, winid, { 6, 1 })
  end
end

return M
