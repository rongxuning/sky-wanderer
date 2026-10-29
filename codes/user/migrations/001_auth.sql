CREATE TABLE users (
  id text PRIMARY KEY,
  created_at timestamptz NOT NULL,
  display_name text NOT NULL,
  email text NOT NULL DEFAULT '',
  retired_at timestamptz,
  merged_into_user_id text REFERENCES users (id),
  merged_from_user_ids jsonb NOT NULL DEFAULT '[]'::jsonb
);

CREATE TABLE identities (
  id text PRIMARY KEY,
  type text NOT NULL CHECK (type IN ('phone', 'wechat', 'google')),
  provider_subject text NOT NULL,
  email text,
  phone text,
  user_id text NOT NULL REFERENCES users (id),
  created_at timestamptz NOT NULL,
  UNIQUE (type, provider_subject)
);

CREATE TABLE sessions (
  token_hash text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users (id),
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL
);

CREATE TABLE owned_records (
  id text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users (id),
  kind text NOT NULL,
  payload jsonb NOT NULL
);

CREATE TABLE phone_codes (
  phone text PRIMARY KEY,
  code_hash text NOT NULL,
  expires_at timestamptz NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  sent_at timestamptz NOT NULL
);

CREATE INDEX identities_user_id_idx ON identities (user_id);
CREATE INDEX sessions_user_id_idx ON sessions (user_id);
CREATE INDEX owned_records_user_id_idx ON owned_records (user_id);
