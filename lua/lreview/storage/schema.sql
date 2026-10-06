-- SQLite base schema for lreview.nvim  (schema_version = 4)
--
-- Index policy (kept aligned with the actual query shapes in storage/*):
--   * Every index below serves a WHERE/ORDER BY that runs on a hot path
--     (session start, per-buffer decor refresh, submit, GC). Columns that no
--     query filters on are deliberately left out to keep write cost low.
--   * Bitmask columns (threads.state, comments.state) are filtered with
--     `(state & ?) > 0` / `state != ?`, which SQLite cannot use an index for.
--     Those are served by the leading equality columns instead, and the
--     predicate-only cases use partial indexes (WHERE <predicate>) so the
--     index itself encodes the filter.

-- ---------------------------------------------------------------------------
-- pull_requests — MR/PR cache
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pull_requests (
  mo_id         TEXT PRIMARY KEY,   -- "<provider>:<repo>:<number>"
  provider      TEXT NOT NULL,
  repo          TEXT NOT NULL,
  number        INTEGER NOT NULL,
  title         TEXT,
  state         TEXT,
  updated_at    TEXT,
  -- Flat columns (were payload-only in v3): branch resolution is the single
  -- hottest lookup in the plugin (`:LocalReviewStart` / offline fallback) and
  -- cannot be indexed while it lives inside a MessagePack BLOB.
  source_branch TEXT,
  target_branch TEXT,
  payload       BLOB
);

-- Serves list()/search() ORDER BY number DESC without a sort pass.
CREATE INDEX IF NOT EXISTS idx_pr_provider_repo
  ON pull_requests(provider, repo, number DESC);

-- Serves by_source_branch(): provider+repo+branch equality.
CREATE INDEX IF NOT EXISTS idx_pr_branch
  ON pull_requests(provider, repo, source_branch);

-- ---------------------------------------------------------------------------
-- threads — region-scoped conversations
-- ---------------------------------------------------------------------------
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

-- Per-buffer decor refresh: mo_id + path equality, then line_start range scan.
CREATE INDEX IF NOT EXISTS idx_threads_buffer ON threads(mo_id, path, line_start, line_end);

-- ---------------------------------------------------------------------------
-- comments — individual notes
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS comments (
  c_id        TEXT PRIMARY KEY,     -- local uuid OR remote id when synced
  t_id        TEXT NOT NULL,
  remote_id   TEXT,
  state       INTEGER NOT NULL DEFAULT 1, -- COMMENT_STATE
  payload     BLOB,
  FOREIGN KEY(t_id) REFERENCES threads(t_id)
);

CREATE INDEX IF NOT EXISTS idx_comments_thread ON comments(t_id);

-- GC + delete-cascade: "which comments are still local-only (never pushed)".
-- Partial index keyed on t_id covers the subquery without touching the table.
CREATE INDEX IF NOT EXISTS idx_comments_local
  ON comments(t_id) WHERE remote_id IS NULL;

-- Reconcile's remote-deletion sweep selects every comment that has a remote
-- counterpart; partial index keeps it out of the draft rows entirely.
CREATE INDEX IF NOT EXISTS idx_comments_remote
  ON comments(remote_id) WHERE remote_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- push_ops — submit outbox (replaces the v3 "comment.state = IN_FLIGHT" lock)
-- ---------------------------------------------------------------------------
-- Each pending network mutation is ONE row here, so a comment's own `state`
-- only ever describes its *content* relative to the remote (DRAFT/SYNCED/
-- MODIFIED/DELETED/CONFLICT). Consequences:
--   * nothing can be stranded in a non-pushable state (v3 leaked IN_FLIGHT rows
--     that PENDING_PUSH_MASK excluded, silently hiding drafts);
--   * a completed op is recorded with its remote id the moment it succeeds, so
--     a retry never re-posts what already landed (idempotent submit);
--   * `uncertain = 1` marks ops whose outcome is unknown after a crash; the
--     reconcile pass adopts them by body match instead of re-sending.
-- No FK to comments: a DONE op is a ledger entry that must outlive the local
-- draft row it consumed.
CREATE TABLE IF NOT EXISTS push_ops (
  op_id      TEXT PRIMARY KEY,        -- local uuid
  mo_id      TEXT NOT NULL,
  t_id       TEXT NOT NULL,
  c_id       TEXT NOT NULL,
  op         TEXT NOT NULL,           -- create_thread | reply | edit | delete | verdict
  status     TEXT NOT NULL,           -- QUEUED | RUNNING | DONE | FAILED
  attempts   INTEGER NOT NULL DEFAULT 0,
  uncertain  INTEGER NOT NULL DEFAULT 0,
  remote_id  TEXT,                    -- platform id returned by the call
  error      TEXT,
  payload    BLOB,                    -- mpack snapshot of what to send
  created_at TEXT,
  updated_at TEXT
);

-- Submit: "all non-terminal ops for this MR, in category order".
CREATE INDEX IF NOT EXISTS idx_push_ops_pending
  ON push_ops(mo_id, status, op);

-- Enqueue dedupe: "does this comment already have an open op of this kind?".
CREATE INDEX IF NOT EXISTS idx_push_ops_comment
  ON push_ops(c_id, op, status);

-- Crash recovery at session start: only RUNNING rows matter, and they are
-- always a tiny fraction of the table.
CREATE INDEX IF NOT EXISTS idx_push_ops_running
  ON push_ops(op_id) WHERE status = 'RUNNING';

-- ---------------------------------------------------------------------------
-- reviews — batch submission record
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reviews (
  r_id         TEXT PRIMARY KEY,
  mo_id        TEXT NOT NULL,
  state        TEXT,
  body         TEXT,
  submitted_at TEXT
);

-- Deleted by mo_id on both the manual delete and the GC sweep.
CREATE INDEX IF NOT EXISTS idx_reviews_mo ON reviews(mo_id);

-- ---------------------------------------------------------------------------
-- issues — offline issue index (correlation target for MR descriptions)
-- ---------------------------------------------------------------------------
-- Flat columns are those a query filters or sorts on; `title` and `body` stay
-- flat (not payload-only) precisely so the FTS5 trigram index below can index
-- them. `labels` is flat as a joined string so `:LocalReviewIssues bug` can
-- filter without decoding one payload per row.
CREATE TABLE IF NOT EXISTS issues (
  issue_id      TEXT PRIMARY KEY,     -- "<provider>:<repo>:<number>"
  provider      TEXT NOT NULL,
  repo          TEXT NOT NULL,
  number        INTEGER NOT NULL,
  title         TEXT,
  body          TEXT,
  state         TEXT,                 -- "open" | "closed"
  author        TEXT,
  labels        TEXT,                 -- comma-joined, for cheap LIKE filtering
  url           TEXT,
  comment_count INTEGER,
  closed_at     TEXT,
  updated_at    TEXT,
  payload       BLOB                  -- milestone, assignees, type, weight, ...
);

-- The list/picker query is always "this repo, this state, newest number first".
CREATE INDEX IF NOT EXISTS idx_issues_repo
  ON issues(provider, repo, state, number DESC);

-- Per-issue sync staleness + author lookups without decoding payloads.
CREATE INDEX IF NOT EXISTS idx_issues_author
  ON issues(provider, repo, author);

CREATE VIRTUAL TABLE IF NOT EXISTS issues_fts USING fts5(
  title, body,
  content='issues',
  content_rowid='rowid',
  tokenize='trigram'
);

CREATE TRIGGER IF NOT EXISTS issues_ai AFTER INSERT ON issues BEGIN
  INSERT INTO issues_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
END;
CREATE TRIGGER IF NOT EXISTS issues_ad AFTER DELETE ON issues BEGIN
  INSERT INTO issues_fts(issues_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
END;
CREATE TRIGGER IF NOT EXISTS issues_au AFTER UPDATE ON issues BEGIN
  INSERT INTO issues_fts(issues_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
  INSERT INTO issues_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
END;

-- ---------------------------------------------------------------------------
-- issue_notes — per-issue discussion, cached so a detail view is instant
-- ---------------------------------------------------------------------------
-- note_id is composite ("<issue_id>:<remote note id>") because GitHub and
-- GitLab both mint small integer note ids; unqualified they collide across
-- providers sharing one database.
CREATE TABLE IF NOT EXISTS issue_notes (
  note_id    TEXT PRIMARY KEY,
  issue_id   TEXT NOT NULL,
  remote_id  TEXT,
  author     TEXT,
  created_at TEXT,
  body       TEXT,
  system     INTEGER NOT NULL DEFAULT 0,  -- "changed label" noise from the hub
  payload    BLOB,
  FOREIGN KEY(issue_id) REFERENCES issues(issue_id)
);

-- The only query shape is "all notes of one issue, oldest first".
CREATE INDEX IF NOT EXISTS idx_issue_notes_issue ON issue_notes(issue_id, created_at);

CREATE INDEX IF NOT EXISTS idx_issue_notes_remote
  ON issue_notes(remote_id) WHERE remote_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- repo_users — offline user index (reviewer assignment)
-- ---------------------------------------------------------------------------
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
