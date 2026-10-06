-- Unit tests for lreview.log: credential redaction, log levels, and file writing

local log = require("lreview.log")

print("TEST: Starting lreview.log Unit Tests...")

-- 1. Test redaction of various token patterns
local test_token_gh = "ghp_1234567890abcdef1234567890abcdef"
local redacted_gh = log.redact("Using token " .. test_token_gh .. " for auth")
assert(not redacted_gh:find("1234567890abcdef"), "GitHub token must be redacted")
assert(redacted_gh:find("ghp_%[REDACTED%]"), "Must contain ghp_[REDACTED]")

local test_token_gl = "glpat-ABCDEFGHIJK_12345678"
local redacted_gl = log.redact("Header: PRIVATE-TOKEN: " .. test_token_gl)
assert(not redacted_gl:find("ABCDEFGHIJK"), "GitLab token must be redacted")
assert(redacted_gl:find("PRIVATE%-TOKEN: %[REDACTED%]"), "Must contain PRIVATE-TOKEN: [REDACTED]")

local bearer = "Bearer mysecrettoken123"
local redacted_bearer = log.redact("Auth header " .. bearer)
assert(not redacted_bearer:find("mysecrettoken123"), "Bearer token must be redacted")
assert(redacted_bearer:find("Bearer %[REDACTED%]"), "Must contain Bearer [REDACTED]")

print("SUCCESS: Credential redaction patterns verified.")

-- 2. Test file logging
local test_log_file = "tmp/test_log_output.log"
vim.fn.delete(test_log_file)
vim.g.lreview_log_file = test_log_file

log.info("test", "A safe log message", { count = 5 })
log.warn("test", "A token " .. test_token_gh .. " appeared")

local f = io.open(test_log_file, "r")
assert(f, "Log file should exist")
local content = f:read("*a")
f:close()

assert(content:find("%[INFO%]"), "Log should contain [INFO]")
assert(content:find("%[WARN%]"), "Log should contain [WARN]")
assert(content:find("A safe log message"), "Log should contain message")
assert(content:find("count=5"), "Log should contain extra fields")
assert(not content:find("1234567890abcdef"), "Log file must NEVER contain raw tokens")
assert(content:find("ghp_%[REDACTED%]"), "Log file should contain redacted marker")

vim.fn.delete(test_log_file)
vim.g.lreview_log_file = nil

print("SUCCESS: File logging and token-free guarantee verified.")
print("\nALL LOG TESTS PASSED.")
os.exit(0)
