-- SQLite schema version baseline tracking.
-- Incremental updates (v4, v5, etc.) will be defined here.

local M = {}

M.version = 6

M.migrations = {
  [4] = [[
-- v4: add deleted column to comments table (0 = active, 1 = soft-deleted)
ALTER TABLE comments ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;
]],
  [5] = [[
-- v5: repo_users table for @mention completion.
-- repo_key is "<provider>:<repo>" (e.g. "gitlab:zerodevs/sample-review").
CREATE TABLE IF NOT EXISTS repo_users (
  repo_key   TEXT NOT NULL,
  username   TEXT NOT NULL,
  name       TEXT,
  avatar_url TEXT,
  fetched_at TEXT,
  PRIMARY KEY (repo_key, username)
);
]],
  [6] = [[
-- v6: FTS5 trigram indexes for substring search over repo users and MRs.
-- External-content FTS5 tables stay in sync via triggers; the 'rebuild'
-- commands populate the index for rows that already exist.
-- NOTE: this migration must run via db:execute (multi-statement) because the
-- trigger bodies contain semicolons.

CREATE VIRTUAL TABLE IF NOT EXISTS repo_users_fts USING fts5(
  username, name,
  content='repo_users',
  content_rowid='rowid',
  tokenize='trigram'
);
CREATE TRIGGER IF NOT EXISTS repo_users_ai AFTER INSERT ON repo_users BEGIN
  INSERT INTO repo_users_fts(rowid, username, name) VALUES (new.rowid, new.username, new.name);
END;
CREATE TRIGGER IF NOT EXISTS repo_users_ad AFTER DELETE ON repo_users BEGIN
  INSERT INTO repo_users_fts(repo_users_fts, rowid, username, name) VALUES ('delete', old.rowid, old.username, old.name);
END;
CREATE TRIGGER IF NOT EXISTS repo_users_au AFTER UPDATE ON repo_users BEGIN
  INSERT INTO repo_users_fts(repo_users_fts, rowid, username, name) VALUES ('delete', old.rowid, old.username, old.name);
  INSERT INTO repo_users_fts(rowid, username, name) VALUES (new.rowid, new.username, new.name);
END;

CREATE VIRTUAL TABLE IF NOT EXISTS pull_requests_fts USING fts5(
  number, title,
  content='pull_requests',
  content_rowid='rowid',
  tokenize='trigram'
);
CREATE TRIGGER IF NOT EXISTS pull_requests_ai AFTER INSERT ON pull_requests BEGIN
  INSERT INTO pull_requests_fts(rowid, number, title) VALUES (new.rowid, new.number, new.title);
END;
CREATE TRIGGER IF NOT EXISTS pull_requests_ad AFTER DELETE ON pull_requests BEGIN
  INSERT INTO pull_requests_fts(pull_requests_fts, rowid, number, title) VALUES ('delete', old.rowid, old.number, old.title);
END;
CREATE TRIGGER IF NOT EXISTS pull_requests_au AFTER UPDATE ON pull_requests BEGIN
  INSERT INTO pull_requests_fts(pull_requests_fts, rowid, number, title) VALUES ('delete', old.rowid, old.number, old.title);
  INSERT INTO pull_requests_fts(rowid, number, title) VALUES (new.rowid, new.number, new.title);
END;

INSERT INTO repo_users_fts(repo_users_fts) VALUES('rebuild');
INSERT INTO pull_requests_fts(pull_requests_fts) VALUES('rebuild');
]]
}

return M
