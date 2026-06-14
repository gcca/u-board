-- migrate:up

CREATE TABLE auth_user (
  username TEXT PRIMARY KEY NOT NULL,
  password BLOB NOT NULL,
  role INTEGER NOT NULL DEFAULT 3 CHECK (role IN (0, 1, 2, 3)),
  last_logged_in INTEGER,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE auth_session (
  key TEXT PRIMARY KEY NOT NULL,
  username TEXT NOT NULL REFERENCES auth_user(username),
  revoked INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0, 1)),
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE auth_app_provider (
  client_id TEXT PRIMARY KEY NOT NULL,
  client_secret TEXT NOT NULL,
  tenant_id TEXT,
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE datamark_source (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('github', 'drive')),
  name TEXT NOT NULL UNIQUE,
  description TEXT NOT NULL DEFAULT ''
);

CREATE TABLE datamark_source_github (
  source_id INTEGER PRIMARY KEY NOT NULL REFERENCES datamark_source(id) ON DELETE CASCADE,
  org TEXT NOT NULL,
  repo TEXT NOT NULL,
  release TEXT NOT NULL,
  asset TEXT NOT NULL
);

CREATE TABLE datamark_source_drive (
  source_id INTEGER PRIMARY KEY NOT NULL REFERENCES datamark_source(id) ON DELETE CASCADE,
  fpath TEXT NOT NULL
);

CREATE TABLE datamark_view (
  name TEXT PRIMARY KEY NOT NULL,
  query TEXT NOT NULL,
  source_id INTEGER NOT NULL REFERENCES datamark_source(id) ON DELETE CASCADE,
  create_at INTEGER NOT NULL DEFAULT (unixepoch())
);

-- migrate:down

DROP TABLE IF EXISTS datamark_view;
DROP TABLE IF EXISTS datamark_source_github;
DROP TABLE IF EXISTS datamark_source_drive;
DROP TABLE IF EXISTS datamark_source;
DROP TABLE IF EXISTS auth_app_provider;
DROP TABLE IF EXISTS auth_session;
DROP TABLE IF EXISTS auth_user;
