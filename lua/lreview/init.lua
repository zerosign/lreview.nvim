---@meta

-- Neovim plugin entry point and user command registration.

local config = require("lreview.config")
local review = require("lreview.review")
local adapter = require("lreview.adapter")
local storage = require("lreview.storage")
local commands = require("lreview.commands")

local M = {}

--- Setup lreview configuration and register autocommands/commands.
---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  local diag = (opts and opts.defaults and opts.defaults.diagnostics) or nil
  local timing = require("lreview.timing")
  timing.configure(diag or {})
  if timing.enabled() then
    -- Flush buffered timing records to the timing file on exit so tmux E2E
    -- scenarios can report them. Only registered when timing is opt-in enabled.
    local augroup = vim.api.nvim_create_augroup("LReviewTimingFlush", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = augroup,
      callback = function()
        pcall(function() timing.flush() end)
      end,
    })
  end
  commands.register()
end

M.register_commands = commands.register

--- Public API surface.
M.api = {
  config = config,
  review = review,
  adapter = adapter,
  storage = storage,
  decor = require("lreview.ui.decor"),
  thread_view = require("lreview.ui.thread_view"),
  editor = require("lreview.ui.editor"),
  detail_editor = require("lreview.ui.detail_editor"),
  summary = require("lreview.ui.summary"),
  wizard = require("lreview.ui.wizard"),
  init_session = review.init_session,
  init_session_async = review.init_session_async,
  add_comment = review.add_comment,
  submit_review = review.submit_review,
  sync_review = review.sync_review,
  pull_review_async = review.pull_review_async,
  close_review_async = review.close_review_async,
  approve_review_async = review.approve_review_async,
  resolve_thread_async = review.resolve_thread_async,
  request_reviewers_async = review.request_reviewers_async,
  update_review_async = review.update_review_async,
  create_review_async = review.create_review_async,
  resolve = adapter.resolve,
  users = require("lreview.users"),
  fetch_users = require("lreview.users").fetch_users,
  pull_request = require("lreview.pull_request"),
  fetch_pull_requests = require("lreview.pull_request").fetch,
  issues = require("lreview.issues"),
  issue_views = require("lreview.ui.issues"),
  conflicts = require("lreview.ui.conflicts"),
  outbox = require("lreview.storage.outbox"),
  next_thread = require("lreview.ui.decor").next_thread,
  prev_thread = require("lreview.ui.decor").prev_thread,
}

return M
