# DESKTOP_PLAN — Command.app Full Parity Build Plan

Build plan for the native Swift macOS app (`~/Claude-Code-Projects/claude-command`) to reach
full equal functionality with the web app, after which the web UI can be retired.

**Ground rules**
- Web app stays frozen; this repo is the server/API layer (see `WEB_APP_CONTRACT.md`, Contract v1).
- MCP server (`mcp-server/`) and hooks (`hooks/*.sh`) untouched — they share the same API +
  Firestore, so desktop inherits their writes automatically.
- gal-kb stays local (`localhost:3337` + filesystem). Desktop reaches KB-backed features via
  `http://localhost:5280` (same Mac) and `GalKBService.swift` for raw file reads.
- Base URL: `http://localhost:5280` primary; `https://gal-projects.contentstackapps.com` fallback
  for API calls (desktop token works against both). Firestore-direct is location-independent.
  KB routes (`/api/kb/*`), Gmail, Calendar, and `/api/today/priority` KB-density scoring only work
  fully against :5280 — degrade gracefully against prod.
- Auth: `X-Desktop-Token` (HMAC, 30-day TTL — refresh proactively via `POST /api/desktop-auth/token`,
  not on 401) for API calls; Firebase custom token (`POST /api/desktop-auth/firebase-token`,
  uid `gal-desktop`) for Firestore REST. Both exist today.

**Server prerequisites (this repo — done in Phases 3–4)**
- firestore.rules v2 deployed (`firebase deploy --only firestore:rules`) — grants below.
- `machineAuth.ts` — desktop token accepted on the drive-sync family.
- `CONTRACT_VERSION` in `GET /api/version`.

---

## M0 — Foundations hardening (mostly exists; verify)

- Startup: `GET /api/version`, assert `contract_version >= 1`; log/banner mismatch.
- Base-URL failover: try :5280, fall back to prod; per-feature capability flags
  (KB features off when :5280 unreachable).
- Token hygiene: desktop token re-mint before expiry; Firebase ID-token refresh already handled
  by `FirebaseAuthService` (5-min early renewal).
- Verify: cold-launch with empty Keychain → token minted, tasks load, contract version logged.

## M1 — Tasks + Today (first daily-drivable build)

- Tasks view parity with `TasksView.tsx`: date-bucket grouping (Overdue/Today/Tomorrow/named-day/
  This Week/…/No Due Date), session grouping, compact mode, pin, keyboard nav (j/k, d, >/</w),
  batch select → done/reschedule, dup detection (port Jaccard: ≥0.45 flag, ≥0.75 auto-merge
  meeting-sourced; `src/lib/textUtils.ts` is the reference implementation).
- Data: Firestore direct read/write (`tasks` rw granted); create via `POST /api/tasks`
  (server assigns seq, runs detector/classifier); batch ops via `POST /api/tasks/batch`.
- Today view: 3-zone layout from local task cache; ranking via `GET /api/today/priority`
  (server-side scoring incl. topic importance); digest via `GET /api/today/digest`;
  calendar strip via `GET /api/calendar/events?date=`.
- Verify: create/edit/complete from desktop → visible live in web + `list_tasks` MCP tool;
  ranking matches web Today view.

## M2 — Realtime + offline (decision milestone)

- **Recommended: polling with watermark.** Firestore REST `runQuery` on `tasks`/`sessions`
  ordered by `updated_at > lastSeen` every 30–60s; immediate refetch after own mutations and on
  `NSApplication.didBecomeActive`; read `meta/syncStatus` doc each poll to detect hook-driven
  syncs cheaply.
- Alternative (only if polling feels laggy): adopt firebase-ios-sdk for true listeners + offline
  cache — heavy dependency, replaces hand-rolled `FirestoreService`. Measure first.
- Offline: persist last-known snapshots to Application Support JSON for instant cold start;
  queue failed writes for retry (optimistic mutations already exist).
- Verify: run a stop hook → session appears in desktop within one poll interval.

## M3 — Mail + Calendar

- GmailView parity: render `GmailViewData` from `GET /api/gmail/threads` as-is (server does
  triage + Haiku classification); thread actions `POST /api/gmail/threads/[id]`; bulk archive
  `POST /api/gmail/batch-archive`; email→task `POST /api/gmail/extract-task`; keyboard nav.
- Gmail organize (W3): trigger `POST /api/gmail/organize` (dry-run preview → apply), render
  run summary from response; history in `gmail_organize_runs` is server-side.
- CalendarView: agenda (today + week) from `GET /api/calendar/events`; RSVP routes incl.
  tentative; MeetingPrepPanel port — related tasks/sessions client-side Jaccard + related
  emails via gmail/threads; **Meeting History & Follow-ups** via `GET /api/kb/meetings/match`
  + `POST /api/kb/meetings/[ref]/extract-todos` (W1, :5280 only).
- Verify: archive from desktop → confirmed in Gmail; RSVP visible in Google Calendar;
  meeting history shows for a recurring event.

## M4 — Drive + Backlog

- DriveView: list from Firestore `drive_documents`/`drive_activities` (read granted in rules v2)
  or `GET /api/drive/documents`; status mutations `PATCH /api/drive/documents/[id]`; doc→task;
  proposals via `/api/drive/proposals`; manual sync `POST /api/drive/sync` with desktop token
  (machineAuth accepts it).
- BacklogView: reads from Firestore `backlog` + `backlog_batches`; CRUD via `/api/backlog*`;
  "Copy for session" batch flow via `POST /api/backlog-batches` — keep the
  `[TRACKER_BATCH:batchId:projectId]` clipboard marker **byte-identical** (sync routes parse it).
- Verify: change doc status on desktop → web DriveContext updates; create batch → consume via a
  real Claude Code session.

## M5 — Search + Chat + Parse + Topics

- ⌘K palette over local caches (tasks/sessions/projects/backlog/drive) — no server calls;
  parity reference `SearchPalette.tsx` (substring match, command mode when query empty).
- Chat: `POST /api/chat` (body shape from `ChatWidget.tsx`; read `reply` field).
- Quick capture: `POST /api/parse` → prefilled task/session create.
- Topics (W2): manage via `/api/topics*` (desktop is the primary topics UI — list, edit
  importance/aliases/relationships); task topic chips read `topics` collection (Firestore read
  granted); conceptual sift via `POST /api/tasks/sift` → render triage flow from `GET`.
- Verify: spot-check palette results vs web on same query; sift themes render with ranked tasks.

## M6 — Settings + config + scheduled + session detail

- Settings: `GET/PATCH /api/config` (ignored-session globs, notification toggles, classify-all).
- Scheduled prompts: read-only list (Firestore `scheduled_prompts`).
- Session/project detail: Firestore reads + `PATCH /api/sessions/[id]`, `suggest-tags`,
  `projects/[id]/brief`; `plan_md` markdown render.
- Verify: PATCH a config value → web settings reflects it.

## M7 — Native notifications

- Register desktop via `POST /api/notifications` (marker e.g. `device: 'command-macos'`).
- Delivery: poll/read `active_notifications` (read granted in rules v2) → present via
  `UNUserNotificationCenter`; honor dismiss-by-tag semantics. Do NOT touch the stop-hook →
  `/api/notifications/send` FCM path (web/PWA keeps working).
- Verify: run stop hook → native macOS notification appears; dismissal propagates.

## M8 — Parity sign-off + web decommission gates

- Checklist audit against the view table in `WEB_APP_CONTRACT.md` / plan Phase A5.
- Two weeks desktop-as-daily-driver with zero fallbacks to web.
- Then (separate decision): mark web-only routes deprecated in apiDocs, consider retiring PWA,
  revisit dropping `gal-web` Firebase grants.

---

## M0/M1 implementation detail (file-level, for the claude-command repo)

Reconstructed from PLAN.md Phase 1–2 notes + `macos/Command/Package.resolved`. Existing Swift
components: `FirebaseAuthService.swift` (custom→ID token via identitytoolkit/securetoken REST,
Keychain, 5-min early renewal), `FirestoreService.swift` (hand-rolled Firestore REST wrapper +
wire-format codec; fetch/update/create/delete tasks, fetchSessionsData), `AppState` (Firestore-first
reads + optimistic mutations, `createTask` API-only for seq/detector), `GalKBService.swift`
(FileManager reads of gal-kb), `mintTokenViaSyncSecret` (startup token mint), `ChatReply` model.

### M0 — Foundations (verify + small additions)
- **`VersionService.swift`** (new, small): on launch `GET /api/version`, assert
  `contract_version >= 1`; log + banner on mismatch. Contract source: `src/lib/apiDocs.ts`
  CONTRACT_VERSION.
- **Networking layer**: base-URL failover — try `http://localhost:5280`, fall back to
  `https://gal-projects.contentstackapps.com` for API calls. Per-feature capability flags:
  KB (`/api/kb/*`), Gmail, Calendar, `/api/today/priority` are :5280-only — disable those
  surfaces when :5280 is unreachable rather than erroring.
- **Token hygiene**: keep `mintTokenViaSyncSecret` at startup; add proactive desktop-token
  re-mint before the 30-day TTL (`src/lib/desktopToken.ts` — never wait for a 401).
  `FirebaseAuthService`'s 5-min ID-token early renewal: verify only.
- Verify: cold launch with empty Keychain → token minted, tasks load, contract version logged.

### M1 — Tasks + Today (first daily-drivable build)
- **`TasksView.swift`**: date-bucket grouping (Overdue/Today/Tomorrow/named-day/This Week/
  Next Week/by-month/No Due Date), session grouping, compact mode, pin toggle, batch select →
  done/reschedule. Keyboard nav j/k/d/>/</w via the already-resolved KeyboardShortcuts package.
- **`TextUtils.swift`** (new): port `tokenize` + `jaccardSimilarity` from `src/lib/textUtils.ts`
  byte-for-byte semantics; dup detection ≥0.45 flag, ≥0.75 auto-merge for meeting-sourced
  (granola/gemini/meeting) tasks.
- **Data**: reads/mutations via existing `FirestoreService` (tasks rw under rules v2);
  create via `POST /api/tasks` (now accepts priority/category/effort/pinned/topics/meeting_ref);
  batch ops `POST /api/tasks/batch`.
- **`TodayView.swift`**: 3-zone layout from the local task cache; Focus-now via
  `GET /api/today/priority` (topic-importance scoring — :5280 capability-flagged);
  digest `GET /api/today/digest`; calendar strip `GET /api/calendar/events?date=`.
- Verify: create/edit/complete on desktop → live in web + `list_tasks` MCP tool; ranking
  matches the web Today view.

### Future note — call recordings
`Package.resolved` already bundles **WhisperKit + swift-transformers** (on-device
speech-to-text). When call recording lands, transcripts become a new notes provider behind the
server's `getMeetingNotesText()` seam (`src/lib/kb/meetingNotes.ts`) and/or feed
`POST /api/kb/meetings/extract-todos` — no tracker schema changes needed.

---

## Risks / open questions

1. **Deployed Firestore rules state unknown** — dump current rules from Firebase console before
   deploying v2. If prod is already locked, web realtime is silently broken today (v2 + gal-web
   fixes it); if open, v2 is the lockdown.
2. Realtime: polling first, measure, only then consider firebase-ios-sdk.
3. KB-backed features are :5280-only by design — capability-flag them off against prod.
4. Desktop token TTL 30d — proactive refresh, not on-401.
5. `POST /api/notifications` registration must not pollute FCM send fan-out — send route should
   skip non-FCM/webpush subscription types.
