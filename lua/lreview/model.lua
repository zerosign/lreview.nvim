---@meta

-- Unified data model for lreview.nvim.
--
-- These are the canonical local types the plugin consumes. Foreign platform
-- shapes (gh/glab JSON) are converted into these by the mappers. The storage
-- schema is derived from these types, not from any platform.

local M = {}

---@class lreview.MR  -- list row
---@field mo_id string  -- "<provider>:<repo>:<number>"
---@field provider string  -- "github" | "gitlab" | ...
---@field repo string  -- "owner/name"
---@field number integer
---@field title string
---@field author string
---@field state string  -- "open" | "closed" | "merged" | ...
---@field source_branch string
---@field target_branch string
---@field url string
---@field updated_at string|nil

---@class lreview.MRDetail  -- full detail
---@field mo_id string
---@field provider string
---@field repo string
---@field number integer
---@field title string
---@field author string
---@field state string
---@field source_branch string
---@field target_branch string
---@field url string
---@field description string|nil
---@field base_sha string|nil
---@field head_sha string|nil
---@field mergeable boolean|nil
---@field files lreview.File[]|nil
---@field commits lreview.Commit[]|nil

---@class lreview.File
---@field path string
---@field additions integer
---@field deletions integer
---@field change_type string  -- "MODIFIED" | "ADDED" | "REMOVED" | ...

---@class lreview.Commit
---@field sha string
---@field message string
---@field author string|nil

---@class lreview.Comment  -- a single comment within a thread
---@field c_id string  -- local uuid or remote id when synced
---@field remote_id string|nil
---@field author string|nil
---@field body string
---@field created_at string|nil
---@field in_reply_to string|nil  -- remote id of parent comment (github) / discussion id (gitlab)

---@class lreview.Thread  -- a region-scoped conversation
---@field t_id string
---@field mo_id string
---@field path string
---@field commit_sha string|nil
---@field start_line integer|nil
---@field end_line integer|nil
---@field is_draft boolean
---@field last_synced_at string|nil
---@field comments lreview.Comment[]

---@class lreview.Review  -- a batch submission
---@field r_id string
---@field mo_id string
---@field comments lreview.Comment[]
---@field body string|nil

---@class lreview.Issue  -- issue/bug tracker row (not a review thread)
---@field issue_id string  -- "<provider>:<repo>:<number>"
---@field provider string
---@field repo string
---@field number integer
---@field title string
---@field body string|nil
---@field state string  -- "open" | "closed"
---@field author string|nil
---@field labels string|nil  -- comma-joined names
---@field url string|nil
---@field comment_count integer|nil
---@field closed_at string|nil
---@field updated_at string|nil
---@field assignees string[]|nil
---@field milestone string|nil

---@class lreview.IssueNote  -- a comment on an issue
---@field note_id string  -- "<provider>:<repo>:<number>:note:<remote id>"
---@field issue_id string
---@field remote_id string|nil
---@field author string|nil
---@field created_at string|nil
---@field body string
---@field system boolean  -- hub-generated noise ("changed label", ...)

--- Build a canonical mo_id from provider/repo/number.
---@param provider string
---@param repo string
---@param number integer|string
---@return string
function M.mo_id(provider, repo, number)
  -- Concatenation (not string.format) for LuaJIT-friendliness; called often.
  return provider .. ":" .. repo .. ":" .. tostring(number)
end

--- Canonical id for an issue. Same shape as mo_id on purpose: one database
--- holds GitHub + GitLab rows and the provider prefix is what disambiguates.
---@param provider string
---@param repo string
---@param number integer|string
---@return string
function M.issue_id(provider, repo, number)
  return M.mo_id(provider, repo, number)
end

--- Canonical id for an issue note. Both hubs mint small integer note ids, so an
--- unqualified note id collides across providers sharing one database.
---@param provider string
---@param repo string
---@param number integer|string
---@param note_id integer|string
---@return string
function M.note_id(provider, repo, number, note_id)
  return M.mo_id(provider, repo, number) .. ":note:" .. tostring(note_id)
end

--- Parse a mo_id back into its parts.
---@param mo_id string
---@return string provider, string repo, string number
function M.parse_mo_id(mo_id)
  local provider, repo, number = mo_id:match("^([^:]+):([^:]+):(.+)$")
  return provider, repo, number
end

return M
