# Data flow

## Capture and server persistence

```mermaid
sequenceDiagram
    participant P as NSPasteboard
    participant M as Monitor
    participant L as Pipeline
    participant R as Privacy/secret rules
    participant D as Process memory
    participant S as encrypted sync server
    participant DB as PostgreSQL
    P->>M: changeCount changes
    M->>L: CapturedContent
    L->>R: normalize, classify, inspect
    alt paused/excluded/rejected
        R-->>L: discard
    else duplicate
        L->>D: increment usage
    else permitted
        L->>D: insert canonical item
        L->>S: TLS + authenticated payload
        S->>S: AES-256-GCM
        S->>DB: ciphertext only
    end
```

Stage failures never log content. Unsupported or oversized payloads stop at the boundary. Clipboard payloads and image bytes are never written to local storage.

## Retrieval and paste

The AI request contains only the query and selected RU/EN locale. The server
decrypts its own history, excludes protected items, selects candidates, and
sends those bounded snippets to Google Gemini using a backend-only API key. It
returns a localized answer plus allowlisted item IDs. The Mac has no API key,
local AI model, or persisted index.

## Encrypted device sync

```mermaid
sequenceDiagram
    participant M as macOS client
    participant S as Sync API
    participant P as PostgreSQL
    participant W as Windows/Web client
    M->>S: TLS + bearer token + item
    S->>S: AES-256-GCM encryption
    S->>P: ciphertext + item id + revision
    W->>S: changes after cursor
    S->>S: decrypt authorized payloads
    S-->>W: TLS + item changes
```

There is no client recovery key. The server owns `SERVER_DATA_KEY`, can decrypt
authorized history for synchronization and AI, and must therefore run inside a
trusted, audited environment. Database rows and backups contain AES-GCM
ciphertext rather than clipboard plaintext.
