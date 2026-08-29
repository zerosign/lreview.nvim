---@meta

-- Adapter registry / factory.
--
-- Resolves the active adapter for the current repo by:
--   1. reading git remotes (git.lua)
--   2. regex-matching the remote domain against the configured per-domain blocks
--   3. falling back to defaults if no match
--
-- Returns a resolved context { adapter, provider, host, repo, cfg } used by
-- the rest of the plugin.

local config = require("lreview.config")
local git = require("lreview.git")

local M = {}

-- Built-in adapters keyed by name.
local adapters = {
  github = require("lreview.adapter.github"),
  gitlab = require("lreview.adapter.gitlab"),
}

--- Get an adapter by name. Supports dynamic loading of custom adapter modules.
---@param name string
---@return table|nil
function M.get(name)
  local adapter = adapters[name]
  if not adapter then
    local ok, mod = pcall(require, name)
    if ok then
      return mod
    end
  end
  return adapter
end

--- Resolve the active adapter context for a directory.
---@param cwd string|nil
---@return table|nil  -- { adapter, provider, host, repo, cfg, remote }
function M.resolve(cwd)
  local remote = git.primary_remote(cwd)
  if not remote then
    return nil
  end
  local cfg = config.for_domain(remote.domain)
  if not cfg then
    return nil
  end
  local adapter_name = cfg.adapter or "github"
  local adapter = M.get(adapter_name)
  if not adapter then
    return nil
  end
  return {
    adapter = adapter,
    provider = cfg.provider or adapter.provider,
    host = cfg.host or remote.domain,
    repo = remote.repo,
    cfg = cfg,
    remote = remote,
    cwd = cwd,
  }
end

--- Build a ctx table for adapter op calls.
---@param resolved table
---@param ref string|nil
---@return table
function M.ctx(resolved, ref)
  return {
    adapter = resolved.adapter,
    provider = resolved.provider,
    host = resolved.host,
    repo = resolved.repo,
    cfg = resolved.cfg,
    cwd = resolved.cwd,
    ref = ref,
  }
end

return M
