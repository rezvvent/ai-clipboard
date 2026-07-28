# Architecture decision records

## ADR-001 — SwiftUI + AppKit/Carbon

**Status:** accepted. SwiftUI provides the UI. AppKit supplies pasteboard,
window, and focus integration; Carbon supplies the global hotkey.

## ADR-002 — No local clipboard persistence

**Status:** accepted. The macOS runtime uses only an in-memory repository.
Clipboard databases, image objects, embeddings, and encryption keys are not
written locally. Legacy clipboard files are removed at v0.8 startup.

## ADR-003 — Server-managed encryption

**Status:** accepted. Clients send authenticated payloads over TLS. The server
encrypts each payload with AES-256-GCM using a 32-byte `SERVER_DATA_KEY` injected
from its secret manager. PostgreSQL and backups contain ciphertext. This makes
the server a trusted confidentiality boundary and enables server-side AI.

## ADR-004 — Cloud LLM through the backend

**Status:** accepted. The backend calls Google Gemini with an API key that is
never shipped to clients. The server selects non-protected candidates from
server history, treats them as untrusted data, requires structured JSON, and
allowlists returned item IDs. The requested response language comes from the
macOS RU/EN setting. Free Tier use is development-oriented because Google may
use submitted content to improve its products.

## ADR-005 — First-run autorun choice

**Status:** accepted. The autorun modal is the first sheet on a new installation.
It explains macOS Login Items and offers enable, system settings, or later.

## ADR-006 — Structured redacted logging

**Status:** accepted. Logs may contain stable event names, coarse types, status,
and opaque IDs. Clipboard content, queries, paths, complete URLs, tokens, and
personal data are forbidden.
