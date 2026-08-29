#!/usr/bin/env fish
# Sandbox Neovim launcher for local-review development.
#
# Redirects all Neovim state/config/data/cache into this project's ./sandbox
# directory so we never touch ~/.config/nvim, ~/.local/state/nvim, etc.
#
# Usage:
#   ./scripts/sandbox-nvim.fish [nvim args...]
#   ./scripts/sandbox-nvim.fish --headless -c "lua print('hi')" -c "qa"
#
# Env overrides:
#   LREVIEW_SANDBOX_DIR  - override the sandbox root (default: <project>/sandbox)
#   LREVIEW_NVIM         - override the nvim binary (default: nvim)

set -l PROJECT_ROOT (realpath (dirname (status filename))/..)
set -l SANDBOX_DIR (test -n "$LREVIEW_SANDBOX_DIR"; and echo "$LREVIEW_SANDBOX_DIR"; or echo "$PROJECT_ROOT/sandbox")
set -l NVIM_BIN (test -n "$LREVIEW_NVIM"; and echo "$LREVIEW_NVIM"; or echo nvim)

mkdir -p "$SANDBOX_DIR/config" "$SANDBOX_DIR/data" "$SANDBOX_DIR/state" "$SANDBOX_DIR/cache"

set -gx XDG_CONFIG_HOME "$SANDBOX_DIR/config"
set -gx XDG_DATA_HOME "$SANDBOX_DIR/data"
set -gx XDG_STATE_HOME "$SANDBOX_DIR/state"
set -gx XDG_CACHE_HOME "$SANDBOX_DIR/cache"

# The sandbox overrides XDG_CONFIG_HOME, which would hide the gh/glab CLI auth
# (they read ~/.config/gh and ~/.config/glab). Point the CLIs back at the real
# user config so authenticated calls work inside the sandbox.
if test -d "$HOME/.config/gh"
  set -gx GH_CONFIG_DIR "$HOME/.config/gh"
end
if test -d "$HOME/.config/glab-cli"
  set -gx GLAB_CONFIG_DIR "$HOME/.config/glab-cli"
end

# Ensure the plugin source is on the runtimepath so `require("lreview")` works.
# The plugin lives at <project>/lua/lreview.
set -gx LREVIEW_PLUGIN_ROOT "$PROJECT_ROOT"

# Add the sandbox luarocks tree (lsqlite3) to the Lua search paths so
# `require("lsqlite3")` works without manual setup.
set -l LUA_ROCKS "$SANDBOX_DIR/luarocks/lib/lua/5.1"
if test -d "$LUA_ROCKS"
  set -l LUA_PATH_EXTRA "$LUA_ROCKS/?.lua;$LUA_ROCKS/?/init.lua"
  set -l LUA_CPATH_EXTRA "$LUA_ROCKS/?.so"
  set -gx LUA_PATH "$LUA_PATH_EXTRA;;$LUA_PATH"
  set -gx LUA_CPATH "$LUA_CPATH_EXTRA;;$LUA_CPATH"
end

# Also expose the user's system luarocks tree (luacov, etc.) so coverage runs
# work without manual LUA_PATH setup. Only added when present.
set -l SYS_LUA_ROCKS "$HOME/.luarocks/share/lua/5.1"
if test -d "$SYS_LUA_ROCKS"
  set -gx LUA_PATH "$SYS_LUA_ROCKS/?.lua;$SYS_LUA_ROCKS/?/init.lua;;$LUA_PATH"
end

exec "$NVIM_BIN" \
  --cmd "set runtimepath^=$PROJECT_ROOT" \
  --cmd "set runtimepath^=$PROJECT_ROOT/lua" \
  $argv
