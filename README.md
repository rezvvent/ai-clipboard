# AI Clipboard

AI Clipboard is a synchronized personal memory for everything you copy. It monitors the macOS pasteboard, stores permitted history only on an encrypted server, and lets you retrieve an old item by exact text or meaning with `⌘⇧V`.

This repository contains a working macOS 13+ app and its required encrypted sync/LLM backend. The desktop app is written in Swift 5.10, SwiftUI, AppKit, Carbon, AuthenticationServices, and StoreKit 2. Clipboard payloads and images use a process-only UI cache and are never written to the Mac's disk; there is no local AI index or clipboard encryption key.

## What works

- text, RTF, TIFF/PNG images, file URLs, and file lists from `NSPasteboard`;
- configurable low-frequency `changeCount` monitoring;
- normalization, type detection, privacy filtering, secret detection, and permanent normalized-text deduplication;
- permanent canonical deduplication for text, URLs, and pixel-identical images, including a one-time repair of legacy duplicates;
- volatile in-memory history/search cache rebuilt from the server on launch;
- server-only persistent history with server-managed AES-256-GCM and cross-device sync;
- Google Gemini LLM through a server-held API key with server-side candidate selection;
- immediate clipboard capture before server setup using volatile RAM only, followed by automatic upload after connection;
- regular Dock presence plus menu-bar operation; closing the last window keeps capture running and a Dock click reopens the library;
- a first-run autorun modal with working “Later”, “Open Settings”, and registration actions, plus a settings toggle;
- main history window, details, stable per-section counters, pinning, favorites, deletion, and JSON export;
- a custom monochrome design system across the library, details, quick search, settings, and onboarding—without stock SwiftUI lists or cards;
- system, light, and dark appearance modes plus live Russian/English switching;
- a user-recordable, persistent global shortcut (`⌘⇧V` by default) for the floating server-LLM search panel;
- copy, plain-text copy, and focus restoration; insertion is left to the standard `⌘V`;
- no automatic protection for URLs; users explicitly decide which links to protect;
- password, OTP, seed-phrase, token, private-key, connection-string, and payment-card safeguards;
- a dedicated account window, server email registration/sign-in, Google OAuth 2.0 + PKCE integration points, and sign-out;
- StoreKit 2 monthly/yearly subscription purchase, entitlement refresh, and purchase restoration;
- excluded applications, capture pause, English and Russian UI, and onboarding;
- functional application picker and copied-URL domain exclusions;
- clear active/paused capture status, timed pause controls, manual resume, and automatic status recovery.
- a dedicated **AI Search** tab backed by the Gemini API, with localized Russian/English answers, result cards, analytics, and smart collections;
- structured smart-search operators such as `type:sql`, `app:"DBeaver"`, `project:marketplace`, `copied:this_week`, `contains:postgres`, and `sensitive:false`;
- quick non-destructive text actions in item details: clean formatting, plain text, list conversion, and link extraction;
- automatic CSV/TSV profiling with inferred column types, missing values, duplicate rows, and potential PII markers;
- protected items are hidden from every regular section and AI surface; opening the Protected section requires macOS device-owner authentication;
- signing out or changing account immediately clears the process cache, and a sync session is accepted only for its matching account;
- cross-device sync using the server account, encrypted image payloads, delta cursors, and deletion tombstones;
- a deployable FastAPI/PostgreSQL/Gemini API service using Argon2id credentials and rotating refresh tokens.

## Requirements

- macOS 13 Ventura or newer;
- Xcode 15.4+ command-line tools;
- Apple Silicon or Intel Mac;
- system SQLite compiled with FTS5 (included in supported macOS versions).

Verify the toolchain:

```bash
swift --version
xcodebuild -version
sqlite3 ':memory:' 'pragma compile_options;' | grep FTS5
```

## Build and run

Run directly during development:

```bash
swift run AIClipboard
```

Run with the safe demonstration dataset:

```bash
swift run AIClipboard --seed
```

Build an ad-hoc signed universal `.app` bundle (arm64 + x86_64):

```bash
chmod +x scripts/build-app.sh
scripts/build-app.sh release
open ".build/AI Clipboard.app"
```

The generated app is at `.build/AI Clipboard.app`. For distribution, replace ad-hoc signing with a Developer ID signature, hardened runtime, notarization, and a release provisioning process.

Move the app to `/Applications` before enabling automatic startup. On first use, AI Clipboard shows an instruction modal instead of silently registering itself. On macOS 13+, it registers the main app through `SMAppService` and exposes its actual system status under **Settings → General → Startup**. If macOS requires approval, the modal and settings screen open the correct **Login Items** panel.

The Quick Search shortcut is changed under **Settings → General → Behavior**. Click the shortcut field, press any combination containing Command, Option, Control, or Shift, and the global Carbon hotkey is immediately re-registered and persisted. Conflicting shortcuts are rejected and the previous working shortcut remains active.

Selecting a Quick Search result copies the original item and returns focus where possible. AI Clipboard does not synthesize keystrokes or request Accessibility access; paste with the standard `⌘V`.

### Configure encrypted sync

The release build contains one managed HTTPS API address in
`AIClipboardAPIBaseURL`. Registration and sign-in create/connect the server
account automatically; users do not enter a host and never run localhost.
Another device downloads the same history after signing in with the same
server account.

The root `render.yaml` provisions a Docker web service and a persistent managed
PostgreSQL database. In Render, create a Blueprint from this repository, enter
`GEMINI_API_KEY` when prompted, then copy the resulting HTTPS service URL into
`Resources/Info.plist` before building the desktop release. `JWT_SECRET` and
`SERVER_DATA_SECRET` are generated by the platform and stay on the server.

Local Docker remains available for backend developers only:

```bash
cd server
cp .env.example .env
# Create a key at https://aistudio.google.com/app/apikey
# Set GEMINI_API_KEY, SERVER_DATA_KEY, and JWT_SECRET in .env
docker compose up -d --build
```

Set `AI_CLIPBOARD_API_URL=http://localhost:8080` only when running the Swift
client from a development shell. Production uses the bundled HTTPS URL and
managed secrets. See `server/README.md`.

Clipboard capture no longer waits for this setup: it starts as soon as the app
starts. Before a server is connected, captured items exist only in volatile RAM
and are lost when the app quits. Connecting storage uploads the current RAM
buffer. Durable history, cross-device sync, and AI recall require the server.

### Configure Google sign-in

The UI and OAuth 2.0 + PKCE flow are implemented, but each distributed app needs its own Google Cloud OAuth client. Set `GoogleOAuthClientID` and `GoogleOAuthCallbackScheme` in `Resources/Info.plist`, and keep the callback scheme in `CFBundleURLTypes` identical. Until a client ID is supplied, the Google button explains that the build is not configured rather than opening a broken login.

Google server identity verification still requires a backend Google sign-in
endpoint before that provider can share the same cloud history. Email accounts
already use the backend as their source of identity.

### Configure subscriptions

Create these auto-renewable subscription products in App Store Connect:

```text
com.aiclipboard.pro.monthly
com.aiclipboard.pro.yearly
```

StoreKit supplies localized prices, performs purchases, restores transactions, and derives Pro state from verified current entitlements. A StoreKit configuration or App Store Connect products are required for plans to appear.

## Test

```bash
swift test
swift test -c release
```

The suite covers normalization, classification, secrets, query parsing, ranking, volatile search, permanent text/URL/image deduplication, pasteboard representation selection, first-run autorun policy, removal of obsolete local storage/keys, exclusions, deletion, server encryption, LLM contracts, and sync transport.

## System permissions

Reading `NSPasteboard.general` and registering the Carbon hotkey do not require a consent dialog. The app no longer requests Accessibility permission. Selecting a result puts the correct content on the clipboard and the user presses `⌘V`.

AI Clipboard does not request screen recording, contacts, calendar, microphone, camera, or Full Disk Access.

## Privacy and storage

Only configuration and secrets live under:

```text
~/Library/Application Support/AIClipboard/
├── settings.json
└── sync-session.json
```

`settings.json` contains preferences only and `sync-session.json` contains
auth/device state. There is no local clipboard encryption key. Clipboard text,
URLs, images, metadata, and search vectors are not persisted on the Mac. Version
0.10 removes legacy `AIClipboard.sqlite`, `protected-content.key`,
`sync-master.key`, and `Objects/` immediately on startup. This deletion is
irreversible. Obvious passwords, OTPs, private keys, and seed phrases are
rejected before upload.

The server receives data over TLS and encrypts every stored payload with
AES-256-GCM using `SERVER_DATA_KEY` from the server secret manager. The server
decrypts permitted history internally for AI recall; protected items are
excluded before selected snippets and the query are sent to Google Gemini. The
backend does not persist prompts or answers, and the Gemini API key exists only
in server configuration. Google states that Free Tier content may be used to
improve its products.

## Architecture

The code follows a pragmatic Clean Architecture boundary:

```text
SwiftUI/AppKit UI
        ↓
Application use cases (pipeline, search)
        ↓
Domain models + protocols
        ↓
Process memory / encrypted server / Pasteboard / Carbon adapters
```

Important files:

- `Sources/AIClipboardCore/DomainModels.swift` — domain entities and search value objects;
- `Sources/AIClipboardCore/ApplicationServices.swift` — event pipeline, privacy, search, export;
- `Sources/AIClipboardCore/InMemoryClipboardRepository.swift` — process-only UI cache;
- `Sources/AIClipboardCore/SQLiteClipboardRepository.swift` — retained test/compatibility adapter, unused by the app;
- `Sources/AIClipboardCore/ProcessingServices.swift` — normalization, classification, and secret detection;
- `Sources/AIClipboardCore/ServerTransportModels.swift` — TLS transport payloads;
- `Sources/AIClipboardApp/SystemAdapters.swift` — pasteboard, hotkey, and panel adapters;
- `Sources/AIClipboardApp/SecureSyncCoordinator.swift` — server history, model status, and device sync;
- `Sources/AIClipboardApp/AIWorkspaceView.swift` — server-LLM recall and analytics;
- `Sources/AIClipboardApp/HotKeyRecorder.swift` — native custom shortcut recorder;
- `Sources/AIClipboardApp/AccountAndSubscription.swift` — server accounts, Google OAuth integration, and StoreKit 2;
- `Sources/AIClipboardApp/Views.swift` — history, quick search, and details;
- `Documentation/` — architecture, data flow, threat model, schema, permissions, and ADRs.

## AI search

The client sends only the query and RU/EN locale. The authenticated server
decrypts permitted server history, performs candidate selection, and calls
`gemini-3.5-flash` using a Google AI Studio key stored only in the backend
environment. Candidate text is explicitly marked as untrusted data, protected
items never enter the model request, and returned IDs are checked against the
server allowlist.

## Known MVP limitations

- The Gemini free tier has quotas, regional restrictions, and Google data-use terms; it is suitable for development but not an unlimited private production service.
- Local app identity and sync-server identity are currently connected by email but use separate credential stores. Production should consolidate them behind verified server identity.
- Google sign-in needs a project-specific OAuth client ID. Subscription products need App Store Connect configuration and signed distribution.
- Website exclusions block copied URLs whose host matches the configured domain. Preventing arbitrary text or images copied from a specific open browser tab requires a browser extension or explicit browser-context integration.
- Window title and browser-domain capture are not enabled; they require explicit Accessibility context and careful privacy UI.
- Protected-item reveal authenticates the viewing action; server envelopes are decrypted into process memory, so a production hardening pass should add explicit memory-zeroing and a short-lived protected-content session.
- JSON export is implemented. CSV generation exists in the core API; full ZIP import/export UI is not included yet.
- UI automation requires a signed `.app`, accessibility consent, and a dedicated test host; core and integration tests run from SwiftPM.

## Roadmap

1. Streaming LLM responses, model health UI, and encrypted per-user retrieval service.
2. Trash restore, retention scheduler, thumbnails, and backup restore UI.
3. User-editable hotkey recorder and richer filters.
4. Safe JSON/CSV/ZIP import with bounded decompression and archive path validation.
5. Hardened runtime, notarization, performance corpus, VoiceOver audit, and XCUITest host.
6. Device management, revocation, server-key rotation, deployment automation, and Windows/Web clients.

## Contributing

Create a focused branch, keep platform APIs behind protocols, add tests for every detector or migration change, and run `swift test` plus `scripts/build-app.sh release` before opening a pull request. Never commit real clipboard databases, tokens, user exports, signing identities, or model files without documented licenses and checksums.

See [Documentation/Architecture.md](Documentation/Architecture.md) and [Documentation/ThreatModel.md](Documentation/ThreatModel.md) before changing storage, capture, encryption, import, or cloud boundaries.
