# Database schema

The active application creates no local clipboard database. PostgreSQL is the
only persistent history store.

- `users`: server identities and Argon2id password hashes.
- `devices`: user-owned client identifiers and activity timestamps.
- `refresh_tokens`: rotating token digests; plaintext refresh tokens are never
  stored by PostgreSQL.
- `server_objects`: latest item revision and AES-256-GCM ciphertext.
- `server_changes`: append-only encrypted changes used by device cursors.

`SERVER_DATA_KEY` is injected into the API from the server secret manager and is
not stored in PostgreSQL or sent to clients. A random 12-byte nonce and
authenticated user/item/revision/deletion metadata bind each ciphertext.

The repository still contains a SQLite adapter for compatibility tests, but the
macOS runtime instantiates only `InMemoryClipboardRepository` and deletes legacy
SQLite/object/key files during v0.8 startup.
