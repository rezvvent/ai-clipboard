# Threat model

Saved clipboard content is untrusted data. It is never treated as an instruction, prompt, script, SQL fragment, or executable payload.

| Threat | Controls in MVP | Residual/release work |
|---|---|---|
| Local attacker reads clipboard history | clipboard payloads/index/images are process-only; legacy files are deleted after confirmed migration; secrets are rejected early | memory inspection remains possible while unlocked; add explicit zeroing and hardened runtime |
| Malicious app reads history | no IPC/API is exposed; app sandbox distribution and code signing recommended | hardened runtime, sandbox entitlement validation |
| Secret reaches the LLM | secret check precedes storage; protected items are excluded before candidate construction | selected unprotected text is sent to Google; review Gemini data terms, use a paid project for production, and audit request-body logging |
| Data remains after deletion | client sends authenticated deletion tombstones and removes the item from process memory | server backups need retention/deletion policy and audited erasure |
| Clipboard poisoning | content is displayed/copied only; no command execution; URLs require explicit open action | confusable-domain UI and paste destination warnings |
| Malicious HTML/RTF | stored as opaque bytes; UI displays plain text by default; no WebView | sanitize any future HTML rendering |
| ZIP bomb/import traversal | archive import is not exposed | bounded expanded size/file count, canonical path checks, no symlinks before ZIP import ships |
| Oversized clipboard | 2 MB text and 25 MB image limits; at most 100 file references | configurable limits and thumbnail downsampling |
| Prompt injection in saved text | candidates are explicitly untrusted data; structured output only; returned IDs are checked against the submitted allowlist | continuously test model behavior and keep the LLM endpoint non-agentic |
| SQL injection | all server values use bound asyncpg parameters; legacy SQLite adapter also binds values | fuzz API validation and migration tooling |
| Sensitive logging | logger drops content/query/url/path keys and uses opaque IDs | automated privacy lint and unified-log export scrubber |
| Compromised sync server | database rows use server-managed AES-256-GCM; key is injected separately through a secret manager | the trusted server can decrypt history; require isolation, least privilege, audit, rotation, and encrypted backups |
| Server key unavailable | server ciphertext remains unreadable and plaintext fallback is forbidden | managed-key backup/rotation, disaster recovery, and device revocation |
| Clipboard/source race | source is best-effort frontmost app metadata | event-tap correlation only after privacy review |

## Trust boundaries

1. `NSPasteboard` input is attacker-controlled and size-bounded.
2. Process memory is the only local clipboard-content boundary.
3. `SERVER_DATA_KEY` in the server secret manager is the root for history confidentiality.
4. The app does not request Accessibility and never scrapes other application UI.
5. The sync API is trusted with plaintext inside TLS and encrypts all persistent payloads before database insertion.
6. Google Gemini receives bounded plaintext candidates transiently through the backend; the API key stays server-side and request bodies must never be logged by this service.
