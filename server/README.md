# AI Clipboard server storage and Gemini API

This service is the only persistent clipboard store. Clients send authenticated
payloads over TLS and keep no encryption key. The API encrypts every history
payload at rest with AES-256-GCM using `SERVER_DATA_KEY` or a derived key from
`SERVER_DATA_SECRET` in the server secret manager. It also exposes an
authenticated AI endpoint that calls Google Gemini;
the Gemini API key never reaches a desktop client.

The same account boundary also stores encrypted product resources: workspaces,
pipelines, automation rules, team spaces, lineage, recipes, connections,
integrations, and business terms. Developer endpoints include:

```text
GET  /clipboard/history
POST /clipboard/items
POST /v1/transform
POST /v1/ai/transform
POST /v1/pipelines/run
GET  /v1/workspaces
GET  /v1/resources
PUT  /v1/resources/{id}
```

## Local development

```bash
cp .env.example .env
# Replace SERVER_DATA_KEY with: openssl rand -base64 32
# Replace JWT_SECRET with: openssl rand -base64 48
# Set GEMINI_API_KEY to a key created at https://aistudio.google.com/app/apikey
docker compose up -d --build
docker compose ps
```

The default model is `gemini-3.5-flash`, which currently has a limited free
tier. Quotas and regional availability are controlled by Google and are not
guaranteed. Check readiness with authenticated `GET /v1/ai/status`.
`/v1/ai/search` decrypts a bounded set of non-protected candidates inside the
backend, sends only those candidates plus the query to Google Gemini, and does
not persist prompts or answers in this backend. Google may use Free Tier content
to improve its products; use a paid project and review Google's data terms
before processing sensitive production data. Production access logs must never
record request bodies or the `x-goog-api-key` header.

The local Compose profile intentionally permits HTTP on `localhost:8080`.
Production must terminate TLS at a trusted reverse proxy, set
`ALLOW_INSECURE_HTTP=false`, use a secrets manager for `JWT_SECRET` and database
credentials, inject a stable `SERVER_DATA_KEY` or `SERVER_DATA_SECRET`, restrict
`--forwarded-allow-ips` to the proxy, and keep database backups encrypted.
Losing or changing the data secret makes existing history unreadable.

## Managed cloud deployment

The repository root includes `render.yaml`. A Render Blueprint created from the
repository provisions:

- the FastAPI Docker service behind a public HTTPS URL;
- a paid persistent PostgreSQL datastore;
- generated `JWT_SECRET` and `SERVER_DATA_SECRET` values;
- a secret prompt for `GEMINI_API_KEY`.

After the deployment reports healthy, copy its public HTTPS URL to
`AIClipboardAPIBaseURL` in `Resources/Info.plist` and rebuild the Mac app. The
desktop user then only signs in; server setup and localhost are not exposed in
the application UI. Keep the generated data secret stable across redeployments
and configure encrypted database backups before production use.

## Security properties

- Argon2id password hashing through `pwdlib`'s recommended profile.
- 15-minute signed access tokens with issuer, audience, expiry and unique ID.
- Single-use, rotating refresh tokens; only their SHA-256 digests are stored.
- User and device scoping on every query.
- Server-managed AES-256-GCM with nonce and authenticated object metadata.
- Monotonic revisions and append-only delta cursors.
- Server-side Google Gemini API integration with structured JSON results and a health endpoint.
- `GEMINI_API_KEY` remains in the backend environment and is never returned to clients.
- Candidate IDs are checked against the request allowlist before returning.
- Clipboard candidates are treated as untrusted data to resist prompt injection.
- Strict request limits, narrow CORS, no response caching, no plaintext logs.

Before a public launch, add proxy-level per-IP and per-account rate limiting,
email verification, recovery flows, abuse monitoring without clipboard content,
automated key rotation, independent penetration testing, disaster-recovery
drills, and managed database/object-storage encryption.
