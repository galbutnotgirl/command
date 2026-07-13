# Command — Status Log

Running log of what's been built, current state, and what's next. Written so a fresh
agent (human or AI — Codex, Claude, whoever) can pick up this project cold. Update this
file at the end of any substantial work session; don't let it go stale.

Repo: `galbutnotgirl/command`. Current version: **1.2.0-alpha.8**
(`git checkout checkpoint-before-trigger-refactor` rolls back to just before the biggest
recent change if something in there needs undoing).

## What this app is

A native macOS menu-bar agent (`agent/*.swift`, SwiftUI/AppKit, not Electron) that:
- Captures a text selection, screenshot, typed popup, or dictated voice input via global
  hotkey and either pastes a rendered prompt into the Claude desktop app, or runs it as a
  background `claude -p` handoff (no window) via a vendored Electron-free Node core
  (`vendor/claude-command-capture/`).
- Also does clipboard history (`clipwatch.py` bundled subprocess) and on-device dictation (Parakeet
  TDT via FluidAudio).

See `docs/BACKGROUND_TRIGGER_INTEGRATION.md` for the background-handoff architecture in
detail — that doc is current as of alpha.6 and is the one to read before touching that code.

## Session timeline (chronological, oldest first)

1. **release.sh hardening** (`cfb58f7`) — pre-flight guards (clean tree, on main, tag not
   already published) + `--publish` flag to automate tag/push/`gh release create`.
2. **In-app bug reporting** (`f34e235`) — About tab "Report a Bug" opens a pre-filled
   GitHub issue (version/macOS/repro template).
3. **Context Rules path-prefix matching** (`a54041a`) — Google Docs/Sheets/Slides all live
   on `docs.google.com`; added `pathPrefix` so a rule can require e.g. `/document/` to
   distinguish them (previously any of the three matched the same generic rule).
4. **Handoff lifecycle features** (`1894a2e`, `8655a87`, `b85442a`) — Retry for failed
   submissions, retention/auto-cleanup (default 7 days, mirrors clipboard history), and
   stalled-run recovery ("mark as failed" for a run stuck at `running` because the CLI
   process died without the record ever getting rewritten).
5. **Custom Handoffs born** (`05df652`) — the old fixed "Skill Handoff"/"Screenshot
   Handoff" actions (one shared global skill+template) became user-configurable: any
   Custom Action gained an `isHandoff` toggle + `skill` field, each with its own prompt.
   A few false starts along the way (`1b4bd69`/`a3b1529` — moved Custom Actions into the
   Handoffs tab, then reverted after the user clarified they wanted Handoffs *grouped
   under* Shortcuts, not living in their own tab) and a dark-mode contrast fix (`a338f39`
   — `.bordered` button text was unreadable purple-on-dark-gray; made the accent color
   appearance-aware).
6. **"Handoff History" naming + retention tuning** (`09bbd51`, `46ec09b`) — renamed the
   Handoffs tab to match "Clipboard History" naming, defaulted retention to match
   clipboard's 7 days, and folded the last of the old Custom Handoffs section directly
   into Custom Actions (one list, not two).
7. **Daily auto-update check** (`240d2ca`) — background `Updater.shared.check()` once a
   day (or on launch if overdue), system notification if a newer build's available on
   your channel. Doesn't auto-install.
8. **Real test coverage, from zero** (`5a58a4b`) — the Swift app had no automated tests at
   all outside the vendored Node core. Split pure logic (key formatting, the action/hotkey
   catalog, version/channel comparison, template rendering, handoff staleness math) into a
   new `ClaudeCommandCore` SPM library target so it's actually unit-testable — the
   executable can't be, since its top-level code has real side effects (`NSApplication`,
   socket bind, global hotkeys). Added 58 Swift tests + 17 shell tests (extracted
   `send-to-claude.sh`'s inline Python/expand_template into standalone testable files:
   `match-enrich-rule.py`, `send-to-claude-lib.sh`). **Found and fixed 2 real bugs in the
   process**: `Updater.swift`'s `isNewer` used `latest != cur` instead of a real
   newer-than check (a locally-built dev version ahead of the latest tag would be offered
   as a "downgrade"); the Templates preview picker only used a rule's friendly
   `displayName` when `pathPrefix` was set, so most rules showed a raw host instead
   ("mail.google.com" not "Gmail").
9. **CI** (`511a52a`, `c264235`) — GitHub Actions runs all three suites (Swift/Node/shell)
   on every push+PR. First run failed: macos-14's default Xcode ships Swift 5.10, but the
   FluidAudio dependency needs Swift 6 tools even though the tests themselves don't touch
   it (package resolution still walks the whole graph). Fixed with
   `maxim-lobanov/setup-xcode@latest-stable`.
10. **Structured-output result surfacing** (`8016648`) — if a background `claude -p` run's
    last non-empty stdout line matches `KEY=value` (the same contract a hand-rolled
    Shortcuts-style intake script would use), it's now picked up automatically as the
    submission's `result` — shown in the finish notification and the Command History row.
    No config needed, it's a convention. `runner.js`'s
    `extractResult()`.
11. **Real-world validation: "Post To Do"** — the user had an existing Apple Shortcut
    (`~/.claude/hooks/intake.sh`) that took freeform text → `claude -p` with a structured
    prompt → POSTed a task to a personal project-tracker API. Rebuilt that exact workflow
    as a Custom Handoff inside Command. Along the way: diagnosed that `claude` CLI
    was logged out (fixed via `claude /login` — separate from any of this app's code);
    discovered the intake script's hardcoded sync token was stale; discovered the *right*
    fix was registering the user's already-built `project-tracker` MCP server
    (`~/Claude-Code-Projects/claude-project-tracker/mcp-server`) with the local
    `claude` CLI (`claude mcp add project-tracker --scope user ...`) instead of curling the
    API directly with a token at all. This is now a real, working, tested Custom Handoff
    (F9, `isHandoff: true`, calls `mcp__project-tracker__create_task`).
12. **Custom Actions trigger-kind unification** (`6926cd3`) — `CustomAction.isShot: Bool`
    became `kind: ActionKind` (`text | screenshot | popup | voice`). Added two new trigger
    types: **popup** (`CustomActionTextEntryPanel` — a floating type-and-⌘⏎ box, replacing
    the old fixed "Text Handoff" action's own dedicated panel) and **voice** (routes
    through the same press/hold/double-tap state machine the built-in Dictate actions use;
    `DictMode.customAction(id:)`, `DictationOverlay.dispatchCustomAction`). The old fixed
    "Text Handoff" action, its settings-window fields, and the menu bar's "Text Entry…"
    item are gone — folded into `kind: .popup`.
13. **Shared body + multiple triggers** (`65bbbaf`) — one more layer of unification, driven
    directly by user feedback: "I'd want the same prompt to have multiple versions —
    popup, voice, screenshot — configured once." `CustomAction.kind` (a single trigger)
    became `triggers: [ActionTrigger]` — one prompt/skill/delivery config, any number of
    ways to fire it. Each trigger can optionally override auto-submit/session-mode/
    include-source (nil = inherit the action's default). Dispatch string format became
    `customtrigger:<actionID>:<triggerID>` (`triggerActionID`/`parseTriggerActionID`) —
    replaced the old 4-way `custom:`/`customshot:`/`customhandoff:`/`customshothandoff:`
    prefix explosion with one prefix, dispatch reads `trigger.kind` off the loaded record.
    `checkpoint-before-trigger-refactor` tag marks the commit right before this — a clean
    rollback point since it touched the hotkey dispatch code path everything else depends on.
14. **Claude and ChatGPT / Codex provider parity** (branch `codex/codex-support`) — added provider resolution
    at global, Custom Action, and trigger levels while preserving Claude as migration/default
    behavior. Foreground delivery routes to Claude Chat/Cowork/Code, ChatGPT general chat,
    or configured Codex workspace; background delivery selects `claude -p` or `codex exec -`, including Codex
    image attachments, `$skill` syntax, read-only/workspace-write presets, provider-tagged
    history, retries, diagnostics, Set Up probes, and schema-v2 settings. Existing bundle ID,
    support paths, legacy `cli` block, provider-less actions, and provider-less history remain
    compatible. Runtime paste and submit target the assistant process directly so backgrounded
    Electron windows cannot send keystrokes into the wrong app. ChatGPT uses the unified app's
    Quick Chat command; Codex uses `codex://threads/new` with a validated workspace `path`.
    New-task failures propagate nonzero status instead of logging success.

## Current state (alpha.8)

- **Test suites**: 100 Swift (`cd agent && swift test`), 56 Node
  (`cd vendor/claude-command-capture && node --test`), 41 shell (`./test/test-shell.sh`),
  plus docs link validation (`python3 ./test/test-docs.py`). All green. CI runs those
  checks plus a macOS release-asset smoke test (`./release.sh --skip-checks` and
  `./test/test-release-asset.sh`) on push/PR (`.github/workflows/test.yml`).
- **Provider parity**: Claude and Codex share selected-text, screenshot, popup, voice,
  dictation, Clipboard History, existing/new task, auto-submit, Context, Custom Action,
  background, history, retry, import/export, diagnostics, and Set Up paths. Claude-specific
  Chat/Cowork/Code controls stay capability-gated; Codex shows workspace instead.
- **Custom Actions** (Settings ▸ Shortcuts ▸ Custom Actions): each is now centered on a
  prompt/action body with default delivery (`Existing chat`, `New chat`, `Background`) and
  default destination (`Default`, `Chat`, `Cowork`, `Code`). Each trigger (text,
  screenshot, popup, voice) can override delivery and destination independently. Older
  `isHandoff`/`sessionMode` JSON still migrates forward.
  Two real ones exist on this dev machine right now: "Update Doc" (⌘F6, paste-mode) and
  "Post To Do" (F9, handoff-mode, calls the project-tracker MCP).
- **Built-in prompt editing**: Add/New/Go now show as prompt-centered groups in
  one Built-in Prompts card in Shortcuts, each with Selected text and Screenshot trigger
  rows plus a consistent pencil/chevron prompt editor. Their prompt bodies still persist
  through the existing `command-templates.json` file and `send-to-claude.sh` rendering
  path, but the visible editor moved out of the old Templates tab and into Shortcuts. The
  old Templates tab is now Context: preview plus enrichment rules. Settings default size
  was widened and the window now has a larger minimum size to avoid clipped shortcut fields.
- **Built-ins untouched**: add/comment/go/shotadd/shotcomment/shotgo/cliphistory/dictate/
  dictateadd still persist as the old flat `HotkeyBinding` model internally, but the UI
  now groups add/comment/go with their screenshot variants as prompt groups. Clipboard
  History's shortcut moved to Clipboard History; Dictate shortcuts moved to Dictation
  Settings.
- **Voice trigger**: now live-verified with real speech. A temporary "Voice Smoke Test"
  Custom Action was bound to `⌘F10` after `F8` collided with the built-in Add action.
  Holding the key, speaking, and releasing produced `mode: custom` dictation history
  entries and dispatched the transcript into the Custom Action paste path
  (`runWorker("custom")`, 54 captured bytes, new Claude session opened). The temporary
  action was removed afterward and hotkeys were reloaded.
- **Import / Export**: moved into About as one global flow. Export defaults to every
  section checked (shortcuts/prompts, templates/context rules, dictation vocabulary,
  background settings, app preferences). Import previews available sections from the selected
  JSON and lets the user choose keep/merge/overwrite per section. Legacy separate
  settings/templates/vocabulary export files remain readable by the global importer.
  The preview now shows imported counts per section before anything is applied. Merge logic
  lives in `ClaudeCommandCore/ImportMerge.swift` and is unit-tested, including the
  `docs.google.com` path-prefix split for Docs/Sheets/Slides. Handoff settings now respect
  merge mode too, preserving current keys while incoming keys win.
- **Command History**: the old Handoff History settings tab is now Command History.
  Background handoffs still load from the vendor submissions folder; foreground
  paste/new-chat commands now write small local records under
  `~/Library/Application Support/claude-command/command-history`. Launch failures are
  recorded there too, instead of only going to the log. Retention defaults to 7 days and
  also keeps handoff retention aligned when edited. The foreground history model and prune
  eligibility now live in `ClaudeCommandCore/HandoffModels.swift` with unit coverage.
- **Finish/docs polish**: README was rewritten around the current prompt-centered model,
  `docs/USER_GUIDE.md` now provides shareable end-user docs, and `docs/index.html` is a
  compact documentation landing page. About now links directly to the user guide. The menu
  Command History settings tab exposes Background Settings as the shared CLI configuration
  entry. `set-hotkeys.sh` now matches
  app defaults by leaving Go/Screenshot Go unbound instead of assigning extra F-key combos.
  The build now bundles the user guide so About opens local docs first and falls back to
  GitHub only when bundled docs are missing. A quick-reference doc was added and the About
  button now opens the bundled HTML docs landing page so users get navigable docs instead
  of raw Markdown. The build also bundles README so the local docs landing page's install
  link resolves inside the app bundle. `test/test-docs.py` now validates local Markdown and
  HTML links in README/docs so shareable documentation has a regression check. First-run
  onboarding copy now matches current defaults too: F8/Option-F8 and F7/Option-F7 are
  presented as Add/New paths, while Go stays an opt-in binding from Settings. A new
  `docs/EXAMPLES.md` gives copyable workflow setups for selected-text review, rewrites,
  screenshot review, voice-to-Code, background tasks, Google Docs context, and migration;
  docs validation now auto-discovers README plus every Markdown/HTML file under `docs/`.
  User-facing docs now also spell out local file locations for shortcuts/prompts,
  clipboard, dictation, command history, background logs, and background CLI settings,
  including the important distinction that background runs use the user's local Claude CLI.
  Fresh install docs no longer tell users to run the legacy `install-clipwatch.sh`; clipboard
  history is launched as a bundled subprocess by Command. `doctor.sh` was updated to
  check that bundled process and to use current Background/Command History naming.
  The docs site now has shareable HTML pages for the user guide, quick reference, workflow
  examples, privacy/local data, and background architecture, backed by one shared stylesheet
  and bundled into the app for offline About -> docs access. A release checklist now
  documents version shapes, preflight tests, `release.sh --publish`, updater validation,
  and rollback.
  `test/test-docs.py` now also checks the required HTML/CSS/Markdown docs assets and
  verifies `build-agent.sh` still copies Markdown, HTML, CSS, and SVG docs into the app
  bundle. A real `./release.sh --skip-checks` package run verified the built app and
  release zip contain the docs assets; `release.sh` now tells maintainers to rerun
  `./release.sh --publish` instead of hand-running raw tag/`gh release create` commands.
  Shortcuts polish continued by simplifying the Compose section copy, removing visible
  "Built-in" wording from that control surface, and hiding the repeated Selected
  text/Screenshot row labels while keeping icon tooltips.
  Support docs were added too: shareable Support HTML/Markdown now mirrors About's
  Report a Bug / Copy Diagnostic Info flow, and the repo has a matching GitHub bug
  report template. FAQ HTML/Markdown now covers first-run shortcut conflicts, why Go is
  unbound, inheritance, privacy, background failures, dictation cutoffs, imports, and bug
  reports. Changelog HTML/Markdown now gives user-facing alpha notes, current shortcut
  defaults, and known gaps separate from this internal status log. A fresh
  `./release.sh --skip-checks` run after these docs additions verified FAQ, Support, and
  Changelog assets are present in both `Command.app` and the release zip.
  About's "Open User Guide" fallback now opens the GitHub Pages docs site if bundled docs
  are missing, instead of raw GitHub Markdown. Another `./release.sh --skip-checks` run
  after the fallback change rebuilt the signed app and verified 23 docs assets in the app
  bundle plus the expected HTML/CSS/Markdown docs inside the release zip.
  GitHub Pages now has a dedicated deploy workflow for the `docs/` site, release docs link
  to the live Pages URLs, and the docs test guards the workflow plus Pages-safe homepage
  links so the shareable docs site cannot quietly drift back to local-only links.
  Quick Reference HTML is now kept in sync with the Markdown shortcut defaults (including
  Screenshot Go and Dictate -> Claude), docs tests guard those rows, and the dictation model
  alert points users to the current Dictation Settings tab instead of the old Dictation name.
  Clipboard History empty-state copy now uses the current Command brand spelling, and
  README/User Guide/Quick Reference shortcut-editing copy now distinguishes Shortcuts from
  Dictation Settings so users don't hunt in the wrong tab.
  Rendered HTML docs were brought back into parity with their Markdown sources: User Guide
  now lists every default shortcut, Examples includes Google Docs context and new-Mac import
  workflows, Changelog includes Dictate -> Claude plus current Command History/dictation/docs
  packaging notes, and docs tests guard those published-site rows.
  Settings copy got another finish pass: Compose now consistently says selected-text,
  new Custom Actions explain their seeded Selected text trigger, and Background Settings
  labels its global prompt fields as compatibility templates so users know Custom Actions
  use their own prompt text.
  Import/export now includes built-in compose auto-submit settings, creates parent folders
  before writing imported JSON, and labels the section as Background settings instead of
  Handoff settings. Docs and UI copy now say prompt settings rather than old templates.
  Release readiness was tightened: `release.sh` now verifies required bundled docs assets
  are present inside the release zip, not just that `Command.app` is at the zip top
  level. Release checklist HTML/Markdown and docs tests now cover that guard, and a fresh
  `./release.sh --skip-checks` dry run passed.
  First-run onboarding copy now matches the prompt-centered model: screenshot capture no
  longer implies every image goes straight into Claude, Accessibility describes copy/paste/
  submit/focus/global-shortcut needs, and Microphone mentions voice custom actions too.
  User Guide quick-start and HTML guide now mirror that permission wording.
  A mobile visual smoke pass found the HTML User Guide hero could clip on narrow widths;
  `docs/site.css` now hardens mobile title/prose widths, table wrapping, and horizontal
  overflow, and `test/test-docs.py` guards those responsive rules.
  Runtime URL capture now follows the browser policy too: Safari, Chrome, Brave, Chromium,
  and Arc are supported, while Edge-specific bundle handling is absent and test-guarded.
  Another naming pass cleaned the runtime notification title and source-capture comments so
  they say `Command` and Settings -> Context instead of the old split-brand/Templates
  labels, with docs tests guarding those strings.
  User update docs were added as a first-class shareable page (`updates.html`/`UPDATES.md`)
  covering About's update channels, Check for Updates, manual alpha install, backup/export
  before updating, failed updates, and rollback; User Guide, Support, and docs home now link
  to it, and docs tests guard the page plus Stable channel wording.
  README and FAQ now point at the same Updates doc too, and the docs homepage browser title
  says `Command Docs` instead of the narrower User Guide label.
  Rendered HTML docs now include uninstall steps instead of leaving them only in Markdown:
  Quick Action removal, main LaunchAgent removal, legacy clipwatch LaunchAgent cleanup, and
  app removal are linked from the docs home and guarded by docs tests.
  A dedicated Troubleshooting page (`troubleshooting.html`/`TROUBLESHOOTING.md`) now gives
  symptom-first fixes, log paths, command checks, and bug-report guidance. It is linked from
  README, docs home, User Guide, FAQ, and Support, and release packaging now requires it.
  About diagnostics now include update channel, default Claude destination, launch-at-login,
  menu-bar icon, and Dock icon state, so copied diagnostics match what Support/Updates asks
  users to provide. The update channel label now says Stable in app code instead of Prod,
  matching the user docs.
  Bug-report capture is now aligned too: About's prefilled GitHub issue body and the repo's
  issue template ask for update channel, trigger/workflow, shortcut, source app, default
  Claude destination, target update version, and copied diagnostic lines, with docs tests
  guarding those fields. About also passes GitHub's `template=bug_report.md` query
  parameter so Report a Bug opens the right issue template directly.
  Docs validation now checks local HTML/Markdown anchors too, so links like
  `guide.html#uninstall` and `USER_GUIDE.md#uninstall` fail release checks if the target
  section disappears.
  Menu-bar active dictation state is now a mega macOS-style privacy beacon
  with a 560pt minimum bright white capsule, near-black purple inner core, oversized white mic island, heavy five-bar white waveform, hover pulse, and live dot; the Settings/Quit static menu rows use
  plain custom views with fixed sizing, aligned shortcut columns, and native hover contrast.
  Release packaging now verifies every shareable bundled docs asset in the zip, including
  FAQ, changelog, privacy, support, release checklist, and icon-treatment SVGs, instead of
  checking only a representative subset. Release checklist docs mirror that full Pages
  review list.
  Docs accessibility now includes a site-wide "Skip to content" link, stable `#content`
  main landmarks, labeled section navigation, and visible keyboard focus styling, with
  docs tests guarding those pieces. The docs validator now enforces those accessibility
  landmarks across every HTML doc instead of sampling only the overview and guide.
  The validator also checks Markdown/HTML topic parity for paired docs (FAQ, Updates,
  Support, Troubleshooting, Release Checklist), which caught and fixed missing FAQ question
  headings plus a missing rendered Rollback section in the release checklist page.
  Shareable HTML docs now include per-page meta descriptions for cleaner link previews and
  search snippets; docs tests require exactly one sane-length description per HTML page.
  GitHub Pages deployment now runs `python3 ./test/test-docs.py` before upload and is
  triggered by docs validator changes too, so broken links, missing anchors, accessibility
  landmarks, missing docs assets, or Markdown/HTML parity drift cannot publish quietly.
  Pages docs now include a styled `404.html` fallback with routes back to the guide,
  quick reference, troubleshooting, support, and other high-traffic docs; release packaging
  and docs tests require that fallback page too.
  Pages docs now include `robots.txt` and `sitemap.xml`; the validator checks sitemap URLs
  against current public HTML pages, and build/release packaging copies/verifies TXT/XML
  docs assets alongside HTML/CSS/SVG/Markdown.
  Every HTML doc now declares a canonical GitHub Pages URL, and docs tests verify each
  canonical exactly matches the expected public URL (with the docs home canonicalized to
  the site root).
  Shareable HTML docs now include lightweight Open Graph/Twitter summary metadata
  (`og:site_name`, `og:type`, `twitter:card`) so copied docs links render more cleanly in
  preview surfaces, and docs tests require those tags on every HTML page.
  Another naming cleanup made the generated app bundle name/display name `Command`
  instead of the old split `Claude Command`, and Set Up diagnostics now say Clipboard
  History instead of Clipboard daemon. Docs tests guard those old visible labels.
  README now uses a scannable docs map table and links the full shareable set, including
  Privacy/local data and Background architecture, instead of hiding docs links in one long
  paragraph. Docs tests guard those entry points.
  Visible app/docs copy now says prompt text instead of prompt template for editable prompt
  fields, including built-in compose, custom actions, and compatibility background settings;
  tests guard the old visible field label.
  A real app bug was also fixed: `Permissions.swift` still looked for the old
  `com.claudecommand.agent` LaunchAgent label, so About's Launch at login toggle could read
  and write the wrong service state after the agent label was simplified to
  `com.claudecommand`.
- **Known gaps, not yet built**:
  - No UI to configure the `TASK_ID=`/`ERROR=` result-parsing *action* — the app surfaces
    the parsed line (notification/row/menu), but doesn't POST anywhere or run a follow-up
    step based on it. Flagged as an intentional scope boundary in
    `docs/BACKGROUND_TRIGGER_INTEGRATION.md`.
  - `capture-handoff.sh` + `send-to-claude.sh`'s `handoff)` case are now dead from
    Command's own UI (everything goes through `submit-cli.js --retry-prompt`
    instead) — kept only because they're still the vendor core's documented non-retry
    contract for other callers. Candidate for removal if nothing else needs that path.
- **Unresolved, blocked on the user**: a "gray circles under Clipboard History" visual bug
  mentioned early in this session — never located in the code across two passes, needs a
  screenshot or repro steps to move on.
- **Menu-bar recording state**: active dictation now uses a 560pt minimum bright white privacy
  capsule with a near-black purple inner core, oversized white microphone island,
  persistent live dot, hover pulse, divider, and heavy five-bar white waveform, closer to macOS
  mic/camera indicators. Test guards expect
  the current `activeIconWidth` wording so this stays visible and docs stay aligned.
- **Background result docs hardening**: User Guide and Quick Reference now explain the
  exact `KEY=value` result convention in user-facing terms: only the last non-empty stdout
  line is parsed, prose containing `TASK_ID=abc123` does not count, result text appears in
  notifications/Command History/diagnostics, and no follow-up action runs yet. User Guide
  now also documents background status meanings (`Running`, `Succeeded`, `Failed`,
  `Stalled`) plus retry/mark-failed/retention/log behavior. Docs validation guards these
  details, and the release zip was rebuilt/smoke-tested so bundled Help matches source.
- **Install/update requirement alignment**: README, Install Guide, and rendered install
  docs now say macOS 14+ to match `Package.swift`, and `build-agent.sh` now writes
  `LSMinimumSystemVersion` as `14.0` instead of the stale `13.0`. Updates docs now explain
  the real in-app updater behavior: channel filtering, attached app-zip selection,
  checksum sidecar ignoring, replacement of `~/Applications/Command.app`, quarantine
  clearing, restart, and manual-release fallback when no app zip is attached. Docs
  validation guards both the OS floor and updater wording. Release packaging and release
  smoke now also fail if `LSMinimumSystemVersion` drifts from `14.0`, so docs, app bundle,
  and GitHub asset metadata stay aligned. Release Checklist Markdown/HTML now names that
  minimum-macOS metadata gate alongside version, bundle ID, docs, README, runtime resources,
  checksum, and metadata-junk checks.
- **Doctor metadata checks**: `doctor.sh` now inspects both the built app and installed app
  for version, bundle ID, minimum macOS `14.0`, and bundled docs presence, in addition to
  executable presence, LaunchAgent Program path/socket, Clipboard History, Background runner,
  and dictation state files.
  Support Markdown/HTML now tells maintainers that `./doctor.sh` covers those metadata and
  bundled-doc checks before filing or triaging source-checkout issues.
- **Manual-launch restart fallback**: restart flows now create the Command LaunchAgent
  when needed and also hand off a detached reopen helper, so first-run permission restarts
  and updater restarts do not depend on downloaded users having already enabled Launch at login.
  Updates docs now call out that Launch at login is not required for Update Now to reopen the app.
- **Copy Diagnostic Info minimum macOS**: About diagnostics now include `Minimum macOS`
  directly from the app bundle's `LSMinimumSystemVersion`, and Support/Settings/
  Permissions/Privacy/Install/Quick Reference/Troubleshooting docs now name that field
  alongside app path, bundle ID, version, update channel/check status, logs, recent command
  summaries, Clipboard History errors, and dictation previews.
- **Release executable/signature smoke**: release asset smoke now extracts the zip and checks
  the packaged executable is present/executable, then reads codesign metadata to confirm the
  app bundle is a Mach-O app signed with identifier `com.claudecommand`. Release Checklist
  Markdown/HTML documents that executable/signature gate alongside docs and metadata checks.
- **Release checklist link parity**: rendered Release Checklist now matches Markdown source
  for repo-surface checks by linking Support, Contributing, Bug report, and Feature request
  directly; docs validation guards those URLs.
- **Release stale-doc guard docs**: Release Checklist Markdown/HTML now document that
  packaging checks bundled docs and README byte-for-byte against source, matching the new
  release smoke and release script stale-asset checks.
- **README release gate parity**: README Build/Test/Release now includes the same local
  package smoke commands as CI and release docs, and names docs/README parity in the
  local package check.
- **Changelog release gate parity**: Changelog Markdown/HTML now names bundled
  docs/README source parity and the current white waveform active-state treatment, matching
  release checks and app behavior.
- **Checksum wording polish**: Install and Updates docs now tell users to keep the
  `.zip.sha256` file in the same folder as the matching zip before running `shasum`, so
  manual update verification is less ambiguous.
- **Homepage/FAQ checksum parity**: README, docs home, and FAQ now say checksum files must
  stay beside their matching zip, with docs validation guarding that wording.
- **Docs asset coverage guard**: docs validation now compares every shareable file in
  `docs/` against `REQUIRED_DOC_ASSETS`, so new pages/assets cannot be added without
  bundling/release coverage. That caught and fixed missing bundling for
  `BACKGROUND_TRIGGER_INTEGRATION.md`.
- **User Guide uninstall safety**: User Guide Markdown/HTML now matches Uninstall Guide's
  tolerant LaunchAgent cleanup commands (`bootout ... || true`, `rm -f`) instead of older
  fail-noisy snippets.
- **Support copy polish**: visible Troubleshooting, Support, Install, Quick Reference,
  User Guide, and bug-report template copy now describes log files by product workflow
  ("shortcut actions", "app dispatch", "Clipboard History") instead of worker/agent/daemon
  labels. Docs validation guards those old visible labels.
- **Restart/setup wording polish**: Set Up, Troubleshooting, Quick Reference, Updates,
  User Guide, Privacy, and Uninstall copy now says Restart Command / Background
  service / App logs instead of user-facing agent/worker labels. Docs validation guards
  the old strings in app and shareable docs.
- **HTML docs validation**: docs quality checks now verify balanced structural tags
  (`html`, `body`, `main`, `section`, tables/lists, and table rows/cells) plus doctype
  on every rendered HTML page, catching malformed shipped docs before release.
- **Install checksum wording**: install and release HTML now name the exact
  `Command-*.zip.sha256` asset users see on GitHub Releases, not a generic
  `.sha256` file. Docs validation now rejects the old wording and self-checks for
  duplicate validator dictionary keys.
- **Support version wording**: Support docs now ask for the version shown in About or
  Copy Diagnostic Info instead of hardcoding the current alpha version as an example;
  docs validation rejects that stale exact alpha number on support pages.
- **Release publish docs gate**: normal `release.sh` runs now execute
  `python3 ./test/test-docs.py` before packaging/tagging, so broken docs links, metadata,
  rendered HTML structure, shared CSS, sitemap drift, or missing bundled-doc guards block
  publishing. `--skip-checks` remains the explicit local packaging bypass, and release
  docs/tests now describe and guard this behavior.
- **Report-a-bug trigger parity**: About's prefilled GitHub issue body now includes
  Dictation in the trigger/workflow list, matching the issue template and support docs.
  Docs validation guards the full trigger list.
- **Report-a-bug diagnostic parity**: About's prefilled GitHub issue body now mirrors
  Support and the issue template more closely: it warns users to review diagnostics before
  sharing, asks for raw-vs-processed Dictation History detail on voice bugs, and names the
  Clipboard History error log.
- **Issue chooser support routing**: GitHub issues now disable blank reports and route users
  to Install, Troubleshooting, Support, private security reporting, or the latest Alpha
  release before filing. Docs validation guards those contact links so repo support stays
  aligned with the published docs site and sensitive reports avoid public issues.
- **Root support policy**: the repo now has a GitHub-standard `SUPPORT.md` entry point that
  routes users to the canonical support checklist, troubleshooting, install help, latest
  Alpha release, and prefilled bug template. README and docs validation guard that support
  path.
- **Root security policy**: the repo now has a GitHub-standard `SECURITY.md` entry point
  telling users not to file public issues for vulnerabilities, exposed secrets, private
  logs, or sensitive diagnostics. It routes to GitHub private vulnerability reporting and
  the Privacy docs, and docs validation guards the policy links.
- **Sensitive-report routing in user docs**: Support and Privacy now explicitly route
  vulnerabilities, exposed secrets, private logs, and sensitive diagnostics to private
  vulnerability reporting instead of public issues. Docs validation guards both Markdown
  and rendered HTML copies.
- **Contributor entry point**: the repo now has a root `CONTRIBUTING.md` for local setup,
  runtime verification, CI/release test matrix, docs editing rules, support/security
  routing, and release commands. README links it and docs validation checks its core
  commands and policy links.
- **Pull request checklist**: the repo now has `.github/pull_request_template.md` prompting
  summary, user impact, docs parity, sensitive-report routing, release-note/checklist needs,
  and validation evidence. Contributor docs mention it and docs validation guards the
  template.
- **Feature request template**: the repo now has
  `.github/ISSUE_TEMPLATE/feature_request.md` for non-bug alpha feedback, capturing
  workflow, trigger, delivery, destination, auto-submit, Settings/menu/docs/import-export
  impact, and private security routing. Root Support, About's Request Feature button, and
  the release checklist link it, and docs validation guards it so feature asks do not drift
  into bug-only support.
- **About Request Feature docs parity**: Settings Reference, Quick Reference, and Install
  docs now list About's Request Feature control beside Report a Bug, so app docs match the
  new feedback button instead of describing only bug reports.
- **FAQ/release feedback parity**: FAQ now explains how to request features, and the
  release checklist now verifies feature request paths alongside bug reports and private
  security reporting.
- **Entry-point support wording**: docs home, User Guide, and Troubleshooting now use
  support/feedback wording where the path is broader than bug reports, while keeping
  Report a Bug guidance for actual bug reports. Docs validation now guards the new
  support-report phrasing and rejects stale bug-only entry-point copy.
- **Release asset feedback guard**: release zip smoke now checks bundled Support, FAQ, and
  Release docs for feature-request guidance, so packaged app docs cannot omit Request
  Feature even if source docs are correct.
- **Support fast-path feedback split**: root Support and shareable Support now tell users
  to use Report a Bug for bugs and Request Feature for non-bug workflow/docs/release asks,
  instead of making the first support path sound bug-only.
- **Guide/quick-reference support handoff**: rendered User Guide now points readers from
  Troubleshooting to Support for bugs, feature requests, and help requests, and Quick
  Reference describes Support as covering feature requests too. Docs validation guards both.
- **Release checklist repo-hygiene gate**: Release checklist Markdown/HTML now tells
  maintainers to review README, root Support/Security/Contributing docs, issue chooser,
  bug template, PR template, and GitHub repo surface after publishing. Docs validation
  guards those release checklist steps.
- **Alpha Limitations docs**: added `limitations.html` / `LIMITATIONS.md` as a user-facing
  expectations page for alpha changes, shortcut conflicts, permissions, dictation tail
  triage, background `claude -p` caveats, structured result limitations, update behavior,
  and security/reporting routes. It is linked from docs home, 404, Quick Reference, sitemap,
  side navigation, release checklist, and bundled-doc asset lists.
- **About Limitations entry point**: Settings -> About now includes an Alpha Limitations
  docs button with bundled-doc and GitHub Pages fallback. Settings Reference, Quick
  Reference, release checklist, and docs validation guard that in-app help entry.
- **Release smoke Limitations guard**: release asset smoke now explicitly checks bundled
  `release.html` includes the Alpha Limitations About docs-button checklist entry, not just
  the generic bundled-doc asset list.
- **Core navigation Limitations guard**: docs validation now requires every rendered page
  with side navigation to link Alpha Limitations, matching the rest of the core docs set.
- **Runtime verifier Limitations guard**: `script/build_and_run.sh --verify` now checks the
  bundled Alpha Limitations page alongside other high-traffic bundled docs before reporting
  runtime OK.
- **Bug report security redirect**: the public bug template and in-app Report Bug prefill
  now explicitly tell users not to include vulnerabilities, exposed secrets, private logs, or
  sensitive diagnostics in public issues, and point to private vulnerability reporting.
- **Diagnostic sharing caution**: About, Support, rendered Support, and the GitHub issue
  template now tell users to review copied diagnostics before sharing because log tails,
  recent command summaries, and recent dictation previews can contain sensitive or recent
  text. Docs validation guards the warning text.
- **Dictation stop feedback**: releasing the voice key now plays the stop sound immediately,
  but keeps the recording chip visible until tail capture, model finalization, transcript
  processing, and dispatch complete. Empty finalization hides through a no-text callback
  instead of leaving stale active state.
- **Dictation failure cleanup**: recorder failures now notify the overlay so async microphone,
  engine, or model-stream failures clear the active menu-bar chip instead of leaving a stuck
  recording state.
- **Settings sizing polish**: default Settings window now opens wider with a matching larger
  minimum size, and the Custom Action edit sheet uses shared layout constants with wider,
  aligned delivery/destination/submit controls so trigger rows have more room.
- **Clean release zips**: `release.sh` now uses `COPYFILE_DISABLE=1 ditto --norsrc`
  for packaging and fails if the zip contains AppleDouble `._*` or `__MACOSX` metadata
  entries, keeping installer assets clean for users.
- **Release checksums**: packaging now writes `Command-<version>.zip.sha256`,
  validates its format, and uploads it alongside the zip during `--publish`. Install docs
  show optional `shasum -a 256 -c` verification; README, docs home, FAQ, and Updates now
  mention the matching checksum file wherever they describe manual zip installs.
- **Public docs wording cleanup**: shareable user docs now avoid old Handoff naming and
  use Background/Command History language, while maintainer architecture docs keep
  "handoff" only for the imported core contract.
- **Icon treatment docs**: active-state visuals now have a shareable docs page
  (`icon-treatments.html` / `ICON_TREATMENTS.md`) that embeds the animated SVG previews,
  links from README/docs home, appears in sitemap/release checklist, and is release-guarded
  as a bundled docs asset.
- **Mega menu-bar recording beacon**: active dictation now uses a 560pt minimum
  bright white privacy capsule with a near-black purple inner core,
  oversized white mic island, hover pulse, large live dot, divider, and heavier five-bar white waveform so it reads
  more like macOS microphone/camera indicators on busy menu-bar backgrounds without
  becoming a long purple strip.
- **Default shortcut docs guard**: `test/test-docs.py` now parses `DEFAULT_BINDINGS`,
  `CommandAction` names, and `KEYCODE_NAMES` from Swift source, formats doc-facing shortcuts
  like `Option-F8` / `Unbound`, and verifies README plus docs default-shortcut tables line-by-line.
  This prevents future shortcut default changes from silently drifting across homepage, guide,
  quick reference, and changelog docs.
- **Built-in Compose docs guard**: docs validation now parses `BUILTIN_COMPOSE_ROWS`,
  `DEFAULT_BUILTIN_COMPOSE_SETTINGS`, and Swift action names to verify User Guide and Quick
  Reference Compose tables show the current input, delivery, and default auto-submit state.
  Quick Reference now uses the same explicit `Default submit` No/Yes wording as User Guide.
- **Private security report path**: About now has a dedicated **Private Security Report**
  button that opens GitHub private advisory creation. Support docs route vulnerabilities,
  exposed secrets, private logs, and sensitive diagnostics to that private path instead of
  public bug/feature issues, and docs validation guards the app button plus URL helper.
- **Release checklist support-action guard**: release checklist now tells maintainers to
  test About's **Copy Diagnostic Info**, **Report a Bug**, **Request Feature**, and
  **Private Security Report** actions after publishing, and docs validation guards that
  checklist wording.
- **About action docs parity**: root Support, Install, Settings Reference, and Quick
  Reference now document **Private Security Report** beside Copy Diagnostic Info / Bug /
  Feature actions, with docs validation guarding the private-advisory wording across
  Markdown and rendered HTML.
- **Background wording cleanup**: Command History deletion now says "background run"
  instead of "handoff record", and Background Settings labels legacy CLI capture fields
  without exposing `capture-handoff` wording. Docs validation guards those visible labels.
- **Full docs sidebar reachability**: every rendered docs page with side navigation now links
  to the full shareable docs set: overview, install, uninstall, guide, settings, quick
  reference, examples, FAQ, changelog, updates, permissions, privacy, troubleshooting,
  support, icon treatments, background architecture, and release checklist. Docs validation
  enforces those sidebar links.
- **Release checklist sidebar audit**: release checklist Markdown/HTML now tells maintainers
  to spot-check full sidebar navigation on published GitHub Pages docs after release, and
  docs validation guards that checklist step.
- **About Quick Reference entry point**: About now has a direct Quick Reference docs button
  beside Documentation, Settings Reference, Troubleshooting, Permissions, and Support.
  Install, Settings Reference, and release checklist docs now include that in-app help path,
  with docs validation guarding it.
- **Quick Reference help parity**: Quick Reference's own Help From The App table now lists
  the direct Quick Reference About button alongside Documentation, Settings Reference,
  Troubleshooting, Permissions, and Support, and docs validation guards that row.
- **Quick Reference full-docs coverage**: Quick Reference's Full Docs section now links the
  complete shareable docs set: install, uninstall, user guide, settings, updates,
  permissions, privacy, troubleshooting, support, examples, FAQ, changelog, icon
  treatments, background architecture, and release checklist. Rendered HTML and Markdown
  are both guarded by docs validation.
- **Markdown source-link hygiene**: FAQ Markdown now links to `PRIVACY.md` instead of the
  rendered `privacy.html`. Docs validation now rejects local `.html` links from Markdown
  source docs except the release checklist, where published Pages links are intentional.
- **Release packaging command clarity**: release checklist Markdown/HTML now include exact
  local verification commands for checksum validation, zip metadata scan, and bundled docs
  spot-check after `./release.sh --skip-checks`. Docs validation guards those commands and
  documents that a clean metadata scan returns no `rg` matches.
- **Release command clarity**: local release verification examples now use
  `Command-<version>.zip*` placeholders consistently so release docs and tests describe
  the same artifact shape.
- **Background Architecture rendered parity**: rendered `background.html` now carries the
  fuller structured background Custom Action worked example from the Markdown source,
  including Shortcuts setup, Background Settings, `TASK_ID=<id>`/`ERROR=<reason>`, and
  final-line parsing behavior. Docs validation guards those details.
- **Binary-first uninstall docs**: Uninstall Guide now starts with downloaded-app removal,
  including quitting Command, unloading LaunchAgent when present, removing the app,
  and treating Quick Action removal as source-only. Commands tolerate missing LaunchAgents,
  and docs validation guards Markdown/HTML parity.
- **Paste-clean uninstall command**: the Uninstall Guide quit command now also suppresses
  harmless "app is not running" failures with `2>/dev/null || true`, matching the
  LaunchAgent cleanup behavior and keeping copied uninstall blocks quiet.
- **Bundled-doc script wording**: build and release script comments now refer to About's
  docs buttons instead of the old "Open User Guide" flow, with docs validation guarding
  against that stale wording returning.
- **Release docs asset structural guard**: docs validation now parses `release.sh`'s
  `required_doc` loop and compares it against the canonical bundled docs asset list, so
  release packaging cannot silently skip a shareable doc even if the long literal guard
  drifts.
- **Bug-report template specificity**: GitHub bug template now asks whether the shortcut
  row is enabled/bound, whether another app or macOS owns that shortcut, whether delivery
  or destination overrides apply, and for background action status/result/log details.
  Docs validation guards those support fields.
- **Support shortcut workflow row**: Support Markdown/HTML now has a dedicated Shortcut /
  trigger workflow row asking whether the shortcut is enabled/bound in Settings and whether
  macOS or another app already owns it, matching the bug template and common hotkey issues.
- **Source doctor alignment**: `doctor.sh` now matches current product wording, checking
  Command LaunchAgent/app dispatch socket/Clipboard History instead of old
  agent/socket/watcher labels, and missing Quick Actions are noted as optional source-only
  Services rather than counted as a failed install.
- **Conditional Background diagnostics**: `doctor.sh` now counts configured Background
  actions before failing Node/vendor/CLI checks. Users with no Background delivery get
  optional notes instead of failed install noise; users with Background actions still get
  actionable failures.
- **Dedicated permissions docs**: added `permissions.html` / `PERMISSIONS.md` for
  Accessibility, Screen Recording, Microphone, Clipboard History, optional Quick Actions,
  TCC reset commands, and diagnostic-sharing cautions. README, docs home, install guide,
  user guide, quick reference, troubleshooting, sitemap, release checklist, release
  packaging, and docs validation now include it.
- **About permissions entry point**: About now has a direct Permissions docs button beside
  Documentation, Troubleshooting, and Support. Install, Quick Reference, and release
  checklist docs now include that in-app help path too.
- **About docs button layout**: the About docs buttons now use an adaptive grid, so
  Documentation, Troubleshooting, Permissions, and Support wrap cleanly instead of crowding
  in one row at narrower Settings widths.
- **Permissions nav coverage**: rendered docs side navigation now links to Permissions
  wherever it links to Install/Uninstall, and docs validation enforces that reachability.
- **Legacy Background fallback wording**: `capture-handoff.sh` and the compatibility
  `send-to-claude.sh handoff)` path now show Background/Command error messages
  instead of old Handoff/Claude Command wording. Docs validation guards those fallback
  script strings.
- **Settings reference docs**: added `settings.html` / `SETTINGS_REFERENCE.md` as a
  tab-by-tab map of Set Up, Shortcuts, Context, Command History, Clipboard History,
  Dictation, and About. README, docs home, user guide, quick reference, 404 fallback,
  sitemap, release checklist, release packaging, and docs validation now include it.
- **About Settings Reference entry point**: About now has a direct Settings Reference docs
  button beside Documentation, Troubleshooting, Permissions, and Support. Install,
  Quick Reference, and release checklist docs now include that in-app help path too.
- **Settings Reference nav coverage**: every rendered docs side navigation now links to
  Settings Reference alongside Install, Uninstall, and Permissions, and docs validation
  enforces that reachability.
- **Settings Reference Markdown coverage**: every shareable Markdown doc now links back to
  Settings Reference, and docs validation enforces that source-doc reachability too.
- **Changelog docs-set accuracy**: public changelog now names the current docs set,
  including Settings Reference, updates, permissions, troubleshooting, and icon treatments.
  Docs validation guards that release-note summary.
- **Dictation troubleshooting accuracy**: FAQ and Troubleshooting no longer tell users to
  change a non-existent stop/silence timing slider. They now explain that stop timing is
  app-tuned in alpha, clarify stop-sound vs final-dispatch behavior, tell users to compare
  raw vs processed text in Dictation History, and ask for diagnostics when reporting tail
  cutoff.
- **Support/bug-report specificity**: Support docs and GitHub issue template now ask for
  workflow-specific details, including Dictation History raw-vs-processed text for voice
  bugs, clipwatch errors for Clipboard History bugs, screenshot permission/capture mode,
  background run status/result/log, and update channel/target version.
- **Diagnostic copy now matches support asks**: Settings -> About -> Copy Diagnostic Info
  now includes `clipwatch.err`, recent command summaries, and the last three dictation
  records as truncated raw and processed previews, so voice/clipboard/background bug
  reports can include the evidence the Support page and issue template ask for.
- **About docs entry points**: the About tab now exposes three direct bundled-doc buttons:
  Documentation, Troubleshooting, and Support, each with GitHub Pages fallback if bundled
  HTML is missing. Release checklist wording now matches those buttons.
- **Set Up status in diagnostics**: Copy Diagnostic Info now includes live permission and
  component checks from Set Up plus dictation model status, so support reports include the
  state users were previously asked to inspect manually.
- **Quick reference help path**: Quick Reference now has a Help From The App section that
  names About's Documentation, Troubleshooting, Support, Copy Diagnostic Info, and Report a
  Bug buttons, plus links to Troubleshooting and Support Markdown sources.
- **Compose template storage coverage**: shared built-in Compose prompt storage now includes
  screenshot combinations (`shotadd`, `shotcomment`, `shotgo`) as well as selected-text
  combinations, so the edit popup matches the "one shared prompt" UI model.
- **Rendered User Guide Compose parity**: `docs/guide.html` now has the same Built-In
  Compose section as `USER_GUIDE.md`, including the six combinations and per-combination
  auto-submit note. Docs validation guards the rendered section so the Pages/bundled guide
  cannot drift from the Markdown source again.
- **Release README guard**: `release.sh` now verifies `Command.app/Contents/Resources/README.md`
  is present inside the zip, matching the build script's bundled README behavior. Release
  checklist docs and docs validation guard that packaging invariant.
- **Dedicated install docs**: added `install.html` / `INSTALL.md` for first-time alpha
  users, covering GitHub Release download, first launch, macOS permissions, Set Up checks,
  F-key conflicts, and source install. README, docs home, User Guide, Updates, sitemap,
  release checklist, release packaging, and docs validation now all include the install page.
- **Install routing polish**: 404 and Support now route users to the Install Guide instead
  of leaving first-time/manual install help split across release links and update docs.
- **Changelog install coverage**: alpha.6 changelog now names the Install Guide as part of
  the shareable docs set, with docs validation guarding the rendered release note.
- **Install help path**: Install Guide now tells first-time users where to find About's
  Documentation, Troubleshooting, Support, and Copy Diagnostic Info after setup, and docs
  validation guards that Markdown/HTML parity.
- **FAQ install entry**: FAQ now has a first-time install question pointing to the Install
  Guide, with Markdown/HTML parity and required-text checks.
- **Rendered HTML link hygiene**: docs validation now rejects body links from rendered
  HTML pages to Markdown files unless the link label is the explicit `Markdown source`
  nav item. FAQ now routes Install Guide readers to `install.html`, not `INSTALL.md`.
- **Update failure routing**: Updates and Troubleshooting now route failed-update/manual
  install recovery to the Install Guide instead of a bare GitHub Releases link, so users
  see first launch and permission checks too.
- **Stale update wording guard**: docs validation now rejects the old "manual install from
  GitHub Releases" recovery wording in Updates and Troubleshooting Markdown/HTML.
- **Install link in docs navigation**: every rendered docs page with side navigation now
  links to Install Guide, and docs validation enforces that `install.html` stays reachable.
- **Side-nav title consistency**: Icon Treatments now has the same `toc-title` treatment as
  other rendered docs pages, and docs validation enforces titled side navigation.
- **FAQ link-preview copy**: FAQ metadata and hero lead now mention install coverage, with
  docs validation guarding that the rendered page advertises first-time install help.
- **Optional Quick Actions clarity**: Set Up now treats missing right-click Services as
  optional instead of a broken binary install. README, Install Guide, Troubleshooting, and
  docs home now split binary install from source-only `./install-quick-action.sh` Services
  setup, with docs validation guarding the wording.
- **Binary-first support guidance**: in-app diagnostics and Support docs now tell downloaded
  users to restart/reinstall from the Install Guide before showing repo-only commands.
  Source-checkout commands remain documented for maintainers, with docs validation guarding
  the split.
- **Required-vs-optional setup wording**: Support and Install docs now say required Set Up
  items should be OK/red-free, while optional items only matter for workflows the user
  actually uses. This aligns docs with optional Quick Actions, Clipboard History, Microphone,
  and screenshot permissions.
- **Troubleshooting optional-state alignment**: the in-app Troubleshooting view no longer
  marks Clipboard History red when the feature is intentionally off; it only flags the
  watcher as broken when Clipboard History is enabled but not running.
- **Background notification wording**: user-facing background action failures now say
  "Background action failed" and "Background runner missing" instead of leaking the old
  Handoff terminology. Docs validation guards the old notification strings.
- **Public changelog polish**: shareable Changelog now uses "Alpha Notes" instead of
  internal "Known Gaps", and no longer exposes implementation-only legacy/background
  compatibility details. Docs validation guards against those old public strings.
- **Dedicated privacy source**: Privacy now has its own Markdown source (`PRIVACY.md`)
  instead of linking back to the User Guide. Privacy HTML/Markdown now list app preferences,
  LaunchAgent, app logs, background captures, and diagnostic-sharing cautions, and release
  packaging requires the Markdown asset.
- **Release checklist privacy alignment**: release checklist HTML/Markdown now explicitly
  names `PRIVACY.md` in docs review and bundled-asset verification, matching `release.sh`
  and docs validation.
- **Dedicated uninstall docs**: added `uninstall.html` / `UNINSTALL.md` for app removal,
  LaunchAgent cleanup, legacy clipboard watcher cleanup, optional local data removal, and
  verification commands. Home, README, User Guide, sitemap, release checklist, release
  packaging, and docs validation now include the uninstall page.
- **Uninstall link in docs navigation**: every rendered docs page with side navigation now
  links to Uninstall Guide, and docs validation enforces that `uninstall.html` stays
  reachable alongside Install Guide.
- **Quick Reference HTML parity**: rendered Quick Reference now includes the same high-value
  sections as the Markdown quick sheet: Prompt Model, Clipboard Picker, Background Result
  Contract, Import / Export, Local Data, and Full Docs. Docs validation guards those
  sections so the web/app-bundled page does not drift back to a thinner version.
- **User Guide HTML parity**: rendered User Guide now includes Context Rules, Clipboard
  History, Command History, and Privacy And Local Files sections, closing the biggest gap
  between Markdown docs and the app-bundled/GitHub Pages guide. Docs validation guards the
  sections and key local-data path.
- **FAQ exact-question parity**: rendered FAQ now preserves the exact trigger-row question
  wording for `—`, and docs validation guards every Markdown FAQ question in the rendered
  HTML page, including bug-report guidance.
- **Examples HTML parity**: rendered workflow examples now preserve the exact Markdown
  rewrite heading and include the More Detail link grid for User Guide, Settings Reference,
  Quick Reference, and Background Architecture. Docs validation guards every example section.
- **User Guide heading parity**: rendered User Guide now uses the same `Import And Export`
  and `Updating` headings as Markdown source, and docs validation checks those exact
  user-facing section names.
- **Install Next parity**: rendered Install Guide now includes the Markdown `Next` section
  with links to User Guide, Quick Reference, Permissions, and Troubleshooting; docs
  validation guards that final handoff section.
- **Changelog heading parity**: rendered Changelog now matches Markdown's `Defaults In This
  Alpha` section name, and docs validation guards the current defaults heading in both
  source and rendered docs.
- **Background architecture HTML parity**: rendered Background Architecture now includes
  the maintainer sections from Markdown: Stack decision, Architecture, New pieces, Data
  layout & contract, Source mapping nuance, Using it, Native UI, and structured background
  action flow. Docs validation guards those headings and key contract details.
- **Automatic heading parity guard**: `test/test-docs.py` now checks every paired Markdown
  section heading against its rendered HTML page, including Quick Reference and Changelog.
  Settings Reference HTML gained the missing Related Docs section discovered by that guard.
- **Rendered heading structure guard**: docs validation now requires each HTML docs page to
  have exactly one `<h1>` and no empty headings, catching malformed rendered pages that link
  checks alone would miss.
- **Rendered media asset guard**: docs validation now checks local HTML `src=` references
  in addition to links, so image/SVG previews such as the icon treatment animations cannot
  silently point at missing bundled assets.
- **Release checklist gate parity**: release checklist Markdown/HTML now name the current
  docs validation gates, including heading parity and local media asset checks, so the
  public ship checklist matches what `release.sh` enforces.
- **SVG preview validation**: docs validation now parses every `docs/*.svg` preview asset
  as XML and verifies the root element is SVG, catching broken icon-treatment visuals before
  release packaging.
- **Release page coverage**: release checklist Markdown/HTML now include Background
  Architecture and Release Checklist in the shareable docs review and GitHub Pages
  post-publish checks, matching the actual docs set and sitemap.
- **Release checklist coverage guard**: docs validation now automatically checks every
  public HTML docs page appears in both release checklist Markdown and rendered release
  page, so new docs cannot be added without post-publish review coverage.
- **Core side-nav coverage guard**: rendered docs sidebars now consistently link to core
  help pages (Overview, Install, Uninstall, User Guide, Settings Reference, Permissions,
  Troubleshooting, Support), and docs validation enforces that coverage for every page with
  a docs table of contents.
- **Shared CSS guard**: docs validation now verifies every rendered HTML page links
  `site.css`, checks CSS brace balance, requires the dark-mode/mobile/accessibility rules
  that keep the docs readable, and rejects negative letter spacing.
- **Source install docs cleanup**: README, docs home, and Install Guide now list
  `./build-agent.sh` + `./install-agent.sh` as the main source install path, with
  `./build-helper.sh` documented as an optional legacy SendHelper fallback. Docs
  validation rejects the old required three-command sequence.
- **Bundled docs opener reuse**: About docs buttons and Set Up's optional
  Right-click actions Learn button now share the same bundled-doc opener, so source-only
  help opens local `install.html` first and falls back to GitHub Pages only if bundled docs
  are missing.
- **Bundled docs anchor preservation**: `openHelpDoc(named:fragment:)` now preserves hash
  fragments for bundled local HTML docs, so Set Up's Right-click actions **Learn** button
  opens `install.html#source` locally instead of dropping users at the top of the Install
  Guide. Docs validation guards the `URLComponents` fragment path.
- **Menu-bar menu filtering docs**: Quick Reference Markdown/HTML now explains that the
  menu-bar menu only shows enabled, bound prompt/action shortcuts; unbound combinations
  such as Go stay editable in Settings but do not appear in the menu. Docs validation also
  guards `MenuBar.swift` against reintroducing dead Command History/Handoffs/Go menu rows.
- **About View on GitHub parity**: Settings Reference Markdown/HTML now documents About's
  **View on GitHub** control, and Release Checklist Markdown/HTML now tells maintainers to
  spot-check that button after publishing. Docs validation guards the Settings and Release
  docs coverage.
- **View on GitHub user-doc coverage**: Install Guide and Quick Reference Markdown/HTML now
  include About's **View on GitHub** control in their About/help tables too, so first-time
  setup docs, fast reference docs, Settings Reference, and Release Checklist all cover the
  same app surface. Docs validation guards those rows, and the release zip was rebuilt and
  smoke-tested with the updated bundled docs.
- **Changelog About-surface parity**: Changelog Markdown/HTML now names About's
  **View on GitHub** route alongside Report a Bug, Request Feature, Security Policy, and
  Private Security Report, so user-facing release notes match the current About tab.
  Docs validation guards both Markdown and rendered changelog copy, and the release zip
  was rebuilt/smoke-tested with the updated bundled changelog.
- **Contributor release command clarity**: `CONTRIBUTING.md` now shows
  `./release.sh --skip-checks` for local packaging smoke and `./release.sh --publish` for
  real releases from a clean `main` branch. Docs validation rejects the older ambiguous
  `./release.sh` / `./release.sh --publish` snippet.
- **Custom trigger add guard**: docs validation now parses `SettingsModel.addTrigger` and
  fails if it appends more than one `ActionTrigger`, protecting the Custom Action edit UI
  from duplicate trigger rows returning.
- **Rendered docs layout guard**: Alpha Limitations was the last rendered docs page using
  legacy `doc-layout` / `doc-toc` markup, so it could render unlike the rest of the help
  site while still passing sidebar link checks. It now uses shared `doc-wrap` / `toc`
  markup, and docs validation rejects legacy nav classes/labels on rendered docs pages.
- **Stable update-channel naming**: `UpdateChannel` now uses a `.stable` code case while
  preserving the stored raw value `"prod"` for existing preferences and release-tag
  compatibility. This keeps user/docs/app wording aligned on Alpha, Beta, and Stable
  without breaking saved update-channel settings.
- **README trust badges**: repo README now shows Test workflow, Pages workflow, latest
  prerelease, and MIT license badges at the top, with docs validation guarding those status
  links so the shareable repo surface advertises build/docs/release health.
- **About section clarity**: About now groups repository/docs buttons under
  **Help & Documentation** and diagnostic/reporting buttons under **Support & Reporting**.
  Settings Reference, Install Guide, and Quick Reference Markdown/HTML now name those
  sections, and docs validation guards the labels in both app code and docs.
- **Build warning audit**: repeated FluidAudio `benchmark.md` warning was traced to the
  dependency checkout, not Command's package target. No local package patch was made
  because editing `.build` would not be durable; build, package, and tests still pass.
- **Docs sidebar order guard**: every rendered docs page now includes the full shared docs
  navigation set in identical order, including its own current page. Docs validation now
  compares sidebar hrefs against `CORE_DOC_NAV_LINKS`, so future pages cannot quietly omit
  themselves or reorder the help map.
- **Docs sidebar label guard**: the last sidebar label drift (`Uninstall Guide` vs
  `Uninstall`) is fixed, and docs validation now checks the canonical sidebar label for
  every shared docs link as well as href order.
- **Docs page title guard**: rendered docs page `toc-title` values now match the canonical
  shared navigation labels. Short labels like Install/Alpha/Background/Release were expanded
  to Install Guide, Alpha Limitations, Background Architecture, and Release Checklist, and
  docs validation guards future drift.
- **Rendered anchor guard**: a full docs scan found no duplicate HTML ids or dead same-page
  hash links. Docs validation now enforces that every rendered page keeps ids unique and
  every `href="#..."` target present.
- **Markdown source link guard**: Icon Treatments now exposes its `ICON_TREATMENTS.md`
  source from the rendered sidebar, and docs parity validation now requires every paired
  rendered HTML page to include its matching `Markdown source` link.
- **Rendered image alt guard**: a rendered docs scan found no missing/empty image alt text.
  Docs validation now rejects any future `<img>` tag without non-empty `alt`, protecting
  icon-treatment previews and any future visual docs.
- **Markdown raw-URL guard**: a Markdown docs scan found no loose raw URLs outside code
  blocks. Docs validation now strips code blocks/Markdown links and rejects future raw
  `http(s)://` text so shareable source docs keep links clickable.
- **Bundled README badge smoke**: release-asset validation now checks the bundled README
  still includes Test workflow, Pages workflow, latest release, and MIT license badges,
  not only that README is byte-for-byte current.
- **Release smoke docs parity**: `test/test-release-asset.sh` now checks the same shareable
  docs asset set as `build-agent.sh` and `release.sh`, including Security Policy HTML and
  Markdown, with docs validation comparing all three lists to prevent quiet bundled-doc
  smoke drift.
- **Release checklist security parity**: Release Checklist Markdown and HTML now name
  `SECURITY.md` alongside `PRIVACY.md` in the local packaging proof, and docs validation
  guards that wording so security docs stay visible in ship criteria.
- **GitHub template link validation**: docs validation now includes
  `.github/ISSUE_TEMPLATE/*.md` and `.github/pull_request_template.md` in Markdown link and
  raw-URL checks, so public bug/feature/PR templates cannot silently ship broken support or
  security-reporting links.
- **About docs label guard**: docs validation now checks the visible
  **Settings -> About** docs button labels against canonical labels, not only their
  `openHelpDoc(named:)` targets, so app buttons cannot drift from docs/release-checklist
  wording while still linking somewhere valid.
- **Stable channel alpha-state docs**: README, FAQ, User Guide, Settings Reference, and
  Updates now say Stable is visible but unavailable until the first stable release exists,
  matching `PROD_AVAILABLE = false` and the disabled Stable segment in About.
- **Diagnostic shortcut summary**: Copy Diagnostic Info now includes built-in shortcut
  bindings plus custom action trigger bindings/delivery/destination/auto-submit state, so
  bug reports can answer whether a shortcut row was enabled and bound without manual
  screenshots. Support/Troubleshooting/Privacy/Permissions/Install docs and the bug
  template now mention that shortcut binding summary.
- **Background compatibility guard**: the old `capture-handoff.sh` bridge remains retained
  only as an external/raw-capture compatibility path; Command UI uses
  `submit-cli.js --retry-prompt`. `test/test-shell.sh` now covers missing-core failure plus
  a successful text capture handoff with context so future removal or edits are deliberate.
- **About docs parity guard**: docs validation now checks that every About help button label
  from `SettingsWindow.swift` appears in both Settings Reference and Quick Reference,
  Markdown and HTML. This keeps user-facing docs aligned when new bundled docs buttons are
  added or renamed.
- **Settings sidebar parity guard**: docs validation now parses Settings sidebar
  `tabButton` labels from `SettingsWindow.swift` and requires each label in Settings
  Reference Markdown and HTML, so tab renames cannot leave the public settings map stale.
- **Background docs terminology cleanup**: background integration docs now say prompt text,
  compatibility prompt fields, and background Custom Actions instead of stale prompt
  template / generic handoff phrasing. Docs validation guards the Markdown and rendered HTML
  against those old phrases.
- **Docs home task routing**: `docs/index.html` now includes a "Find Your Path" section
  that routes users by task: install/update, configure prompts, write prompt text, use
  voice, run background actions, or fix/report. Docs validation guards those cards and their
  anchors so the home page stays useful as the docs set grows.
- **README docs table guard**: docs validation now checks README's docs table against every
  public Markdown doc under `docs/` plus root Support/Security/Contributing files, excluding
  only internal `STATUS.md` and duplicate docs-site Support/Security mirrors. New shareable
  docs now fail validation until README gives users a route to them.
- **Docs home coverage guard**: docs validation now checks `docs/index.html` links every
  public HTML docs page except itself. New rendered docs cannot ship without a route from
  the docs home.
- **Docs home repo-trust routes**: docs home now links the contributor entry point beside
  README and private security reporting, and docs validation requires those repo-trust
  routes so public docs do not hide maintainer/contribution guidance.
- **Release checklist guard wording**: release docs now name the newer docs gates
  explicitly: docs-home coverage, README docs-table coverage, Settings sidebar parity, and
  Find Your Path task routing. Docs validation guards that checklist wording in both
  Markdown and HTML.
- **Release checklist About-docs parity guard**: docs validation now requires Release
  Checklist Markdown and HTML to include every About help button label from
  `SettingsWindow.swift`, so manual offline-doc release checks stay aligned with in-app
  docs buttons.
- **Release checklist docs-label parity guard**: docs validation now requires Release
  Checklist Markdown and HTML to include every shared docs navigation label plus the
  404 fallback, so post-publish review steps cannot drift from the public docs map while
  still listing the right files.
- **Docs home card-label parity guard**: docs validation now requires Overview cards for
  every shared rendered docs page to use the canonical navigation labels, so docs home,
  sidebar, and release checklist naming stay aligned.
- **README docs-table label parity guard**: README's public docs table now uses the same
  canonical names as the rendered docs navigation, and docs validation requires those
  labels for each Markdown source link.
- **Rendered docs-grid label parity guard**: Quick Reference and Examples docs cards now
  use canonical names like Privacy, Uninstall, and Background Architecture, and docs
  validation checks rendered docs grids for the same labels.
- **Rendered title/H1 label parity guard**: rendered docs page titles and H1s now match the
  canonical shared navigation labels, closing drift such as `Uninstall Guide`,
  `Command User Guide`, and `Workflow Examples`.
- **Release smoke bundled-label guard**: release asset validation now checks bundled HTML
  docs for canonical labels such as Uninstall, Privacy, Examples, and Background
  Architecture, giving package-level failures if stale bundled docs ship.
- **Markdown H1 label parity guard**: source Markdown docs now match the canonical rendered
  docs navigation labels too, including Background Architecture, so source docs, Pages,
  bundled help, and README docs maps stay aligned.
- **Active stale-label guard**: user-facing source and rendered docs now reject old privacy,
  uninstall, and background label variants in current help surfaces.
- **Root governance docs parity**: root `SUPPORT.md` and `SECURITY.md` now use
  Command-prefixed titles and canonical docs labels, and docs validation guards those
  repo entry points alongside the docs-site mirrors.
- **GitHub template support routing**: bug and feature request templates now route reporters
  to Support/Troubleshooting/Examples/Settings docs before filing, capture action names and
  auto-submit overrides, and docs validation guards those fields.
- **GitHub issue chooser label parity**: issue chooser contact links now use canonical
  labels like Install Guide, Troubleshooting, Support, Security Policy, and Private Security
  Report, with docs validation guarding those routes.
- **CI label polish**: GitHub Actions shell-test step now says prompt/context matching
  instead of the older template/enrich-rule phrasing, and docs validation guards the label.
- **PR template release-gate parity**: pull request template and release checklist now ask
  reviewers to check issue-template/chooser parity and bundled-doc release smoke when
  support/reporting, docs, or packaging changes.
- **Install/update download wording polish**: Install and Updates Markdown/HTML now say
  "Download the latest `Command-*.zip`" consistently, and docs validation rejects the
  rougher "Download latest" wording.
- **About support-surface parity guard**: docs validation now requires About's repository,
  support, diagnostics, reporting, update-check, and Import / Export labels to stay present
  in app code and the Settings Reference, Quick Reference, Install Guide, and Release
  Checklist docs. This keeps non-doc About controls from drifting while docs-button guards
  cover the bundled help grid.
- **Rendered HTML nesting guard**: docs validation now walks structural HTML tags with a
  stack in addition to simple open/close counts, so crossed or misnested table/section/nav
  markup cannot ship just because the tag counts balance.
- **HTML anchor collision guard**: docs validation now treats duplicate `id`/`name` anchor
  values as failures, so rendered docs cannot ship with ambiguous local links or broken
  section targets.
- **Legacy To-Do Quick Action URL capture**: `send-to-claude.sh` now maps old
  `ACTION=todo` Services calls into the background handoff path, resolves source URLs
  before the empty-capture abort, and uses the browser URL as captured text when no
  selected text was available. Shell tests cover the dry-run URL fallback so the
  right-click `Claude - To-Do` item does not become a dead menu row again.
- **compact solid-purple voice-lines icon**: active dictation now uses a compact active width
  with a pure purple rounded-square backing and four animated white bars. This keeps
  the stronger macOS mic/camera-style signal without the earlier wide badge, mic glyph,
  live dot, or pulse ring.
- **Pages workflow deployment guard**: docs validation now requires scoped Pages
  permissions, concurrency, GitHub Pages environment URL wiring, and docs quality checks
  before upload; the release checklist tells maintainers to spot-check that workflow.
- **To-Do URL troubleshooting**: Troubleshooting now documents selected-text precedence,
  browser-tab URL fallback, and where to confirm results in Command History -> Background;
  docs validation guards that row in Markdown and rendered HTML.
- **User Guide To-Do URL path**: User Guide and rendered guide now explain the optional
  source-install `Claude - To-Do` Service: selected text wins, otherwise supported browsers
  hand off the current tab URL, with results confirmed in Command History -> Background.
- **README To-Do URL path**: README source-install section now says what the optional
  `Claude - To-Do` Service does, including selected-text precedence, supported browser URL
  fallback, and Command History -> Background verification; docs validation guards it.
- **Quick Reference To-Do URL fix**: Quick Reference now includes a fast fix for missed
  To-Do URL capture: clear text selection, run `Claude - To-Do` from a supported browser,
  then inspect Command History -> Background. Docs validation guards Markdown and HTML.
- **Examples To-Do URL variant**: Examples now show the source-only right-click
  `Claude - To-Do` path beside the background task capture recipe, including selected-text
  behavior, supported browser URL fallback, and Command History -> Background result check.
- **FAQ To-Do precedence**: FAQ now answers why `Claude - To-Do` may send highlighted text
  instead of the browser URL and tells users to clear selection before using the Service for
  current-tab URL capture; docs validation guards Markdown and rendered HTML.
- **Command rename docs clarity**: Install, Updates, and Changelog now explicitly state
  that ClaudeCommand was renamed to Command, release assets are `Command-*.zip`, GitHub
  Pages lives under `/command/`, and compatibility IDs/paths intentionally remain
  `com.claudecommand` / `~/Library/Application Support/claude-command/` so alpha users
  keep permissions, shortcuts, history, background records, and exports. Docs validation
  guards both Markdown and rendered HTML copies.
- **FAQ compatibility-path clarity**: FAQ Markdown/HTML now answers why some local paths
  still say `claude-command` after the Command rename: they remain stable intentionally
  for macOS permissions, shortcuts, command history, background records, and exports.
  Docs validation guards the answer, and the release zip was rebuilt/smoke-tested with
  the updated bundled FAQ.
- **Export filename polish**: About -> Import / Export now defaults new exports to
  `command-export.json` instead of the old `claude-command-export.json`, and Settings
  Reference Markdown/HTML documents the new default filename. Docs validation guards the
  app string and docs copy; Swift tests, docs tests, shell tests, and release-asset smoke
  passed after rebuilding the signed package.
- **Permissions compatibility clarity**: Permissions Markdown/HTML now explains why
  `tccutil reset ... com.claudecommand` remains correct after the Command rename: the
  bundle identifier stays stable for existing alpha installs. Docs validation guards that
  note, and the release zip was rebuilt/smoke-tested with the updated bundled page.
- **Install migration anchor**: rendered Install Guide now gives the Existing Alpha
  Installs rename/migration note its own `#existing-alpha` section and sidebar link, so
  users updating from ClaudeCommand can jump directly to compatibility guidance. Docs
  validation guards the anchor and the release zip was rebuilt/smoke-tested with the
  updated bundled install page.
- **Release zip rename smoke guards**: release-asset validation now checks bundled
  Install, Permissions, FAQ, and Settings pages for the Command rename/migration anchor,
  stable `com.claudecommand` compatibility note, local-path compatibility FAQ answer, and
  `command-export.json` default. Docs validation guards those release smoke checks so
  packaged docs cannot quietly drift from current rename guidance.
- **Old public URL guard**: docs validation now rejects stale public
  `galbutnotgirl.github.io/claude-command` and `github.com/galbutnotgirl/claude-command`
  links across README, repo trust files, GitHub templates/workflows, and shareable docs,
  while keeping local compatibility paths such as `~/Library/Application Support/claude-command/`
  allowed.
- **Release checklist Pages rename check**: Release Checklist Markdown/HTML now makes
  canonical GitHub Pages URL review explicit: confirm `galbutnotgirl.github.io/command/`
  is the public base and no release/docs/repo surface routes users to the old
  `/claude-command/` Pages path. Docs validation guards that checklist item.
- **User Guide menu-bar reference**: User Guide Markdown/HTML now has a dedicated Menu Bar
  section explaining which prompt/action shortcuts appear, why unbound/disabled triggers
  stay hidden, how Stop/Cancel Dictation appears while recording, and where Settings/Quit
  live. Docs validation guards the section in both source and rendered help.
- **Quick Reference menu-bar cheat sheet**: Quick Reference Markdown/HTML now mirrors the
  same menu-bar visibility rules in compact form, including bound prompt/action shortcuts,
  Stop/Cancel Dictation, Settings, Quit Command, and hidden unbound/disabled triggers.
  Docs validation guards those quick-reference rows.
- **Settings import/export section map**: Settings Reference Markdown/HTML now documents
  each About -> Import / Export section (`Shortcuts and prompts`, `Prompt text and context
  rules`, `Dictation vocabulary`, `Background settings`, `App preferences`) plus Keep
  current/Merge/Overwrite behavior, so users can interpret import previews without jumping
  to the User Guide. Docs validation guards those labels and modes.
- **Import/export label polish**: visible About -> Import / Export section label now says
  `Prompt text and context rules` instead of `Prompt templates and context rules`, matching
  the app's current prompt-centered language. Settings Reference Markdown/HTML and docs
  validation use the same label; internal JSON keys remain compatible.
- **Public background wording cleanup**: README, FAQ, and User Guide now describe legacy
  `Claude - To-Do` Services URL capture as a background action, not a background handoff.
  Docs validation rejects the stale public phrase while keeping handoff terminology in
  internal architecture/compatibility docs.
- **Quick Reference built-in anchor**: rendered Quick Reference now has a sidebar jump and
  stable `#built-in-compose` section id for Built-In Compose, matching the Markdown section
  and making the cheat sheet easier to scan. Docs validation guards the anchor and section.
- **Icon Treatments anchor polish**: rendered Icon Treatments now has sidebar jumps and
  stable section ids for Current Recording Direction, Animated Previews, Options, and
  Implementation Notes, so visual review links can point directly at each treatment area.
  Docs validation guards those anchors.
- **Prompt-combination docs polish**: README, homepage, User Guide, Quick Reference, FAQ,
  Settings Reference, Changelog, Alpha Limitations, Troubleshooting, and Examples now
  describe built-in Compose as selected-text/screenshot combinations with delivery and
  auto-submit behavior, instead of leading with legacy Add/New/Go labels. Docs validation
  maps internal action ids to the public combination labels.
- **Support path polish**: root Support now points users to public GitHub Pages support,
  troubleshooting, and install pages first, while keeping a bundled Markdown docs link for
  repo/offline use. Rendered Support also has a sidebar jump for Feature Requests. Docs
  validation guards those support paths.
- **Security path polish**: root Security now points privacy/settings references to public
  GitHub Pages first while keeping bundled Markdown links for repo/offline use. Rendered
  Security also has a sidebar jump for Local Data Scope. Docs validation guards those
  security paths.
- **Issue-template docs routing**: bug and feature templates now route users to public
  GitHub Pages support, troubleshooting, install, examples, settings, and security docs
  before filing, instead of repo-relative Markdown paths. Docs validation guards those
  issue-template routes.
- **Docs home FAQ wording**: Pages home now describes FAQ coverage as auto-submit behavior
  instead of legacy Go behavior, keeping the first public landing page aligned with
  prompt-combination wording. Docs validation rejects the stale phrase.
- **Updates rename anchor**: rendered Updates now has a sidebar jump and stable
  `#rename-compatibility` section for the ClaudeCommand -> Command migration note,
  matching the Markdown heading. Docs validation guards the anchor and heading parity.
- **Rendered-doc section-link guard**: Examples, User Guide, Install Guide, Alpha
  Limitations, and Settings Reference now expose every H2 section through the sidebar.
  Docs validation now enforces that each rendered docs H2 section has an id and matching
  sidebar hash link.
- **Help URL fallback hardening**: About help links now use `URLComponents` for the
  GitHub Pages fallback as well as bundled local docs, so future fragments are encoded
  consistently when bundled docs are missing. Docs validation guards the fallback path.
- **Bundled Markdown security links**: shareable Privacy, Alpha Limitations, and Support
  Markdown now link to sibling `SECURITY.md` inside bundled docs instead of `../SECURITY.md`,
  so offline Markdown copies do not point outside the bundled docs folder. Docs validation
  rejects the stale parent-path links.
- **Release smoke routing guards**: release asset smoke now checks the bundled homepage
  auto-submit FAQ wording, rendered sidebar anchors for Updates/Security/Support, and
  bundled Markdown Security Policy sibling links, so packaged docs cannot drift from the
  latest finish-polish routing.
- **GitHub Pages rename handoff**: release checklist now calls out the standard
  `galbutnotgirl.github.io/command/` canonical Pages URL plus the explicit old
  `/claude-command/` compatibility decision: keep any old Pages project redirect-only to
  `/command/`, or disable it after confirming shared alpha links no longer need it. Docs
  validation guards the checklist text in both Markdown and rendered HTML.
- **Release smoke Pages-redirect guard**: release asset validation now checks bundled
  `release.html` for the old Pages redirect guidance too, so packaged app help cannot
  pass with stale rename instructions even when source docs are current.
- **FAQ preview wording polish**: rendered FAQ link-preview metadata now says
  auto-submit behavior instead of legacy Add/New/Go behavior, and docs validation rejects
  the stale phrase so social/search previews match the prompt-combination model.
- **Release smoke FAQ-preview guard**: release asset validation now checks bundled
  `faq.html` for the same auto-submit preview wording and rejects stale Add/New/Go preview
  metadata, giving package-level coverage for the user-facing FAQ link preview.
- **404 preview wording polish**: rendered 404 fallback metadata now says moved or
  mistyped docs links instead of rough "docs page for missing links" copy, and docs
  validation rejects the old phrase so stale or broken links still preview cleanly.
- **Release smoke 404-preview guard**: release asset validation now checks bundled
  `404.html` for the polished moved-or-mistyped wording and rejects the rough missing-links
  phrase, giving package-level coverage for the fallback page preview.
- **Site-wide metadata stale-term guard**: docs validation now checks every rendered HTML
  title, description, Open Graph description, and Twitter description against old public
  preview terms like Add/New/Go behavior, Handoff History, Claude Command, Templates, and
  Clipboard daemon, so link previews cannot drift back to pre-finish language.
- **404 FAQ card parity**: the 404 fallback page's FAQ card now mirrors the docs home FAQ
  scope, including auto-submit behavior and inheritance, so users who land on a stale link
  still see the current prompt-combination support path. Docs validation guards the card.
- **Release smoke 404 FAQ-card guard**: release asset validation now checks bundled
  `404.html` for that current FAQ card wording too, so package smoke covers stale-link
  recovery content, not only metadata.
- **Release smoke site-wide metadata guard**: release asset validation now scans every
  bundled HTML doc's title and preview metadata for stale public terms, mirroring the source
  docs validator at package level so bad link previews cannot ship inside the app bundle.
- **Overview local-development wording**: docs home now says Local development instead of
  Codex local development, keeping the public overview tool-neutral while still linking the
  `./script/build_and_run.sh --verify` maintainer path. Docs validation rejects the old
  tool-specific label.
- **Release smoke overview wording guard**: release asset validation now checks bundled
  `index.html` for neutral Local development wording and rejects the old Codex-specific
  label, so packaged public docs stay tool-neutral.
- **Install/build wording neutrality**: README plus Install Guide Markdown/HTML now say
  "For local development, use" for `./script/build_and_run.sh` instead of Codex app
  Run-button wording, keeping public source-build instructions editor-neutral. Docs
  validation rejects the old label.
- **Release smoke install/build wording guard**: release asset validation now checks bundled
  README and Install Guide for neutral local-development wording and rejects Codex-specific
  build labels, so packaged docs cannot regress after source copy is fixed.

## Next up (roughly in the order they came up)

1. **Decide whether to migrate built-in hotkey storage, not just UI grouping.** Compose now
   writes selected-text and screenshot prompt templates together, but still persists hotkeys
   via `command-hotkeys.json` internally. A deeper pass could migrate built-ins into the
   same `CustomAction`/trigger storage shape, but that would touch the most-used dispatch
   path more heavily.
2. **Gray-circles Clipboard History bug** — still needs a screenshot/repro from the user.
3. **Structured-output *action* layer** (optional, explicitly flagged as a gap, not
   started) — today the app shows a parsed `KEY=value` result but doesn't act on it. If
   ever wanted: probably a per-action or per-trigger "on result, do X" config, needs its
   own design pass rather than a bolt-on.
4. Minor cleanup candidate: `capture-handoff.sh`/`send-to-claude.sh`'s `handoff)` case —
   now covered as an external compatibility path; only remove after deciding that raw
   capture callers are no longer supported.

## Working conventions established this session

- **Always run the full verification loop** before calling something done: `swift build`
  → `swift test` → `./build-agent.sh` → `./install-agent.sh` → confirm a fresh PID
  (`pgrep -x Command` before/after) → for anything touching the vendor core, a live
  `node vendor/claude-command-capture/bin/submit-cli.js --retry-prompt` smoke test.
- **`gh auth switch --user galbutnotgirl` before every push** — the active `gh` account
  silently reverts to a different one (`gal-cstk`, no push access) between sessions.
- **Bump `VERSION` and run `./release.sh --publish`** after any user-facing change worth
  shipping — this session cut alpha.1 through alpha.6 incrementally rather than batching.
- **Real functional tests over synthetic ones where possible.** A synthetic
  `osascript key code` press reliably triggers Carbon hotkeys and is good enough to prove
  a *visible* effect (a window opening for the popup trigger); for anything with no visible
  UI (a background handoff), the CLI-level test (`submit-cli.js --retry-prompt` with the
  actual rendered prompt) is the trustworthy one — clean up test tasks created against the
  real project-tracker afterward (`mcp__project-tracker__update_task` → `status: archive`).
- **This file** — update it at the end of a session covering meaningful work, don't let it
  silently go stale.
