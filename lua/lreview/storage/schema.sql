-- SQLite base schema for lreview.nvim (Version 3)

CREATE TABLE IF NOT EXISTS pull_requests (
  mo_id         TEXT PRIMARY KEY,   -- "<provider>:<repo>:<number>"
  provider      TEXT NOT NULL,
  repo          TEXT NOT NULL,
  number        INTEGER NOT NULL,
  title         TEXT,
  author        TEXT,
  state         TEXT,
  source_branch TEXT,
  target_branch TEXT,
  description   TEXT,
  base_sha      TEXT,
  head_sha      TEXT,
  url           TEXT,
  updated_at    TEXT
);

CREATE INDEX IF NOT EXISTS idx_pr_provider_repo ON pull_requests(provider, repo);
CREATE INDEX IF NOT EXISTS idx_pr_source_branch ON pull_requests(source_branch);

CREATE TABLE IF NOT EXISTS threads (
  t_id           TEXT PRIMARY KEY,  -- local uuid or remote discussion id
  mo_id          TEXT NOT NULL,
  path           TEXT,
  commit_sha     TEXT,
  start_line     INTEGER,
  end_line       INTEGER,
  is_draft       INTEGER NOT NULL DEFAULT 1,
  last_synced_at TEXT,
  resolved       INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY(mo_id) REFERENCES pull_requests(mo_id)
);

CREATE INDEX IF NOT EXISTS idx_threads_buffer ON threads(mo_id, path, start_line, end_line);
CREATE INDEX IF NOT EXISTS idx_threads_draft ON threads(mo_id, is_draft);

CREATE TABLE IF NOT EXISTS comments (
  c_id        TEXT PRIMARY KEY,     -- local uuid OR remote id when synced
  t_id        TEXT NOT NULL,
  remote_id   TEXT,
  author      TEXT,
  body        TEXT,
  created_at  TEXT,
  in_reply_to TEXT,
  deleted     INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY(t_id) REFERENCES threads(t_id)
);

CREATE INDEX IF NOT EXISTS idx_comments_thread ON comments(t_id, created_at);

CREATE TABLE IF NOT EXISTS reviews (
  r_id         TEXT PRIMARY KEY,
  mo_id        TEXT NOT NULL,
  state        TEXT,
  body         TEXT,
  submitted_at TEXT,
  FOREIGN KEY(mo_id) REFERENCES pull_requests(mo_id)
);

CREATE TABLE IF NOT EXISTS meta (
  k TEXT PRIMARY KEY,
  v TEXT
);

-- Seed the initial schema version
INSERT OR REPLACE INTO meta (k, v) VALUES ('schema_version', '4');
