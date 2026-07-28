CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE IF NOT EXISTS users (
    id uuid PRIMARY KEY,
    email citext NOT NULL UNIQUE,
    display_name varchar(120) NOT NULL,
    password_hash text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    disabled_at timestamptz
);

CREATE TABLE IF NOT EXISTS devices (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS devices_user_id_idx ON devices(user_id);

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    token_digest bytea NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS refresh_tokens_user_id_idx ON refresh_tokens(user_id);

-- v2: the server owns encryption-at-rest. Clients send plaintext payloads only
-- inside authenticated TLS requests and never keep an encryption key locally.
CREATE TABLE IF NOT EXISTS server_objects (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    item_id uuid NOT NULL,
    revision bigint NOT NULL CHECK (revision >= 0),
    deleted boolean NOT NULL DEFAULT false,
    ciphertext bytea NOT NULL CHECK (octet_length(ciphertext) >= 28),
    source_device_id uuid NOT NULL REFERENCES devices(id),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, item_id)
);

CREATE TABLE IF NOT EXISTS server_changes (
    cursor bigserial PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    item_id uuid NOT NULL,
    revision bigint NOT NULL CHECK (revision >= 0),
    deleted boolean NOT NULL,
    ciphertext bytea NOT NULL CHECK (octet_length(ciphertext) >= 28),
    source_device_id uuid NOT NULL REFERENCES devices(id),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS server_changes_user_cursor_idx
    ON server_changes(user_id, cursor);

-- Retain change rows only as long as clients may be offline. A scheduled job can
-- compact old rows after every active device has advanced beyond their cursor.
