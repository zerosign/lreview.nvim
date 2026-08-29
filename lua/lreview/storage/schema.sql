-- SQLite base schema for lreview.nvim

CREATE TABLE IF NOT EXISTS pull_requests (
  mo_id         TEXT PRIMARY KEY,   -- "<provider>:<repo>:<number>"
  provider      TEXT NOT NULL,
  repo          TEXT NOT NULL,
  number        INTEGER NOT NULL,
  title         TEXT,
  state         TEXT,
  updated_at    TEXT,
  payload       BLOB
);

CREATE INDEX IF NOT EXISTS idx_pr_provider_repo ON pull_requests(provider, repo);

CREATE TABLE IF NOT EXISTS threads (
  t_id           TEXT PRIMARY KEY,  -- local uuid or remote discussion id
  mo_id          TEXT NOT NULL,
  path           TEXT NOT NULL,
  line_start     INTEGER NOT NULL,
  line_end       INTEGER NOT NULL,
  state          INTEGER NOT NULL DEFAULT 1, -- THREAD_STATE
  payload        BLOB,
  FOREIGN KEY(mo_id) REFERENCES pull_requests(mo_id)
);

CREATE INDEX IF NOT EXISTS idx_threads_buffer ON threads(mo_id, path, line_start, line_end);

CREATE TABLE IF NOT EXISTS comments (
  c_id        TEXT PRIMARY KEY,     -- local uuid OR remote id when synced
  t_id        TEXT NOT NULL,
  remote_id   TEXT,
  state       INTEGER NOT NULL DEFAULT 1, -- COMMENT_STATE
  payload     BLOB,
  FOREIGN KEY(t_id) REFERENCES threads(t_id)
);

CREATE INDEX IF NOT EXISTS idx_comments_thread ON comments(t_id);

CREATE TABLE IF NOT EXISTS reviews (
  r_id         TEXT PRIMARY KEY,
  mo_id        TEXT NOT NULL,
  state        TEXT,
  body         TEXT,
  submitted_at TEXT,
  FOREIGN KEY(mo_id) REFERENCES pull_requests(mo_id)
);

CREATE TABLE IF NOT EXISTS repo_users (
  repo_key   TEXT NOT NULL,
  username   TEXT NOT NULL,
  name       TEXT,
  payload    BLOB,
  PRIMARY KEY (repo_key, username)
);

-- FTS5 trigram indexes for substring search over repo users and MRs.
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

CREATE TABLE IF NOT EXISTS meta (
  k TEXT PRIMARY KEY,
  v TEXT
);
