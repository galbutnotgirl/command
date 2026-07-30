# Command Release Test Plan

Use this matrix before publishing beta or stable builds. Automated checks are release
gates; manual checks cover macOS permissions, global input, and third-party app UI contracts
that cannot be proven reliably in CI.

## Automated Gate

Run from repository root on clean `main`:

```bash
./test/test-regression-impact.sh
python3 ./test/test-regression-impact.py --base HEAD^
python3 ./test/test-regression-contracts.py
(cd agent && swift test)
(cd agent && swift test --filter DictationDeliveryPipelineTests)
(cd agent && swift test --filter DictationInsertProbeTests)
swift build --package-path agent --product CommandClipboardWatcher
./test/test-clipboard-watcher.sh
(cd vendor/claude-command-capture && node --test)
./test/test-shell.sh
./test/test-build-transaction.sh
./test/test-release-transaction.sh
./test/test-install-state.sh
python3 ./test/test-installed-state-preservation.py
./test/test-updater-swap.sh
./test/test-restart-app.sh
./test/test-release-policy.sh
python3 ./test/test-regression-attestation.py
./test/test-regression-attestation.sh
./test/test-static-analysis.sh
python3 ./test/test-docs.py
python3 ./test/test-pages.py
python3 ./test/test_string_review.py
./release.sh --skip-checks
./test/test-release-asset.sh
./doctor.sh
```

With installed Claude and ChatGPT apps available:

```bash
./test/test-assistant-contract.sh
```

With Command installed and running under launchd:

```bash
./test/test-installed-hotkeys.sh
./test/test-installed-dictation.sh
./test/test-installed-restart.sh
./test/test-installed-hotkeys.sh
./test/test-installed-dictation.sh
./test/test-installed-runtime.sh
```

`qualify-installed-build.sh` snapshots persisted Command defaults plus eleven owned settings and
history artifacts before build. It compares same state immediately after incremental install and
again after restart/runtime probes. Semantic JSON hashing ignores harmless key-order rewrites while
any setting, shortcut, action, context, vocabulary, background configuration, or history mutation
fails qualification without printing private values.

Restart test verifies socket acknowledgement, replacement launchd PID, recovered socket, preserved
UserDefaults, and no crash report. Runtime test then performs a 15-second idle soak with repeated
socket pings and verifies stable PID, bounded open descriptors, no new crash reports, and no new
fatal or SwiftUI cycle diagnostics. Override duration with `COMMAND_SOAK_SECONDS` for longer runs.
Installed hotkey test compares configured Carbon aliases with successful registrations, requires
trusted enabled event tap, and injects tagged HID events that callback swallows before dispatch.
Running before and after restart catches dead input hooks without firing user actions.
Installed dictation test performs repeated raw microphone-buffer captures and one production
lifecycle through trigger, model stream, recorder, stop-tail drain, ASR finish, and clean terminal
health without changing history. Tagged Fn down/up next travels through installed HID event tap and
voice action routing into diagnostic capture. A known transcript then passes through production
final-text delivery into general pasteboard, activates a focused AppKit field, posts Command-V,
and must arrive exactly; prior clipboard contents and app focus must be restored. Test then stalls
startup before its first audio buffer,
releases the trigger while startup remains unresolved, and requires one warning, one automatic
reset, complete resource cleanup, and an immediate production retry. Three later failure/retry
cycles inject faults after live microphone buffers, verifying every capture resource releases and
session IDs keep increasing.
Run on both sides of restart to catch process-local state bugs.
Physical-key dispatch remains a manual check. Focused delivery tests prove selected raw text reaches
processing, history preparation, and dispatch exactly once; blank processor output falls back to raw
speech. Cached final-word fixtures now pass model output through same decision and delivery code.

With Parakeet models cached on release Mac:

```bash
./test/test-dictation-model.sh
```

`release.sh --publish` runs this Parakeet probe automatically and refuses `--skip-checks`. Known critical failures and required proof are tracked in [`test/regression-contracts.json`](test/regression-contracts.json); `test-regression-contracts.py` fails when evidence or release wiring disappears.

Each tracked regression must cite at least two distinct evidence files and at least one
release-executed integration proof. Multiple methods in one unit-test file do not count as
independent proof. Editing `test/regression-contracts.json` alone also cannot satisfy runtime
impact coverage; a matching behavior test must change with runtime code.

Full `release.sh` gates create `regression-gates-attestation.json` only after every required
test passes, then sign it inside app. Local installer, in-app updater, and detached swapper
verify commit, branch marker, version, suite, and gate list before replacing installed app.
`build-agent.sh` alone produces unqualified artifact and cannot be installed by default.

[`test/regression-impact.json`](test/regression-impact.json) owns every runtime Swift, JavaScript, and shell file. CI compares full pushed or pull-request range and fails when touched runtime areas lack matching test changes. Release preflight repeats impact audit across every change since latest version tag.

Before release-candidate packaging, run memory and data-race instrumentation in isolated build
directories so sanitizer flags never contaminate normal products:

```bash
cd agent
swift test --scratch-path /tmp/command-asan --sanitize=address
swift test --scratch-path /tmp/command-tsan --sanitize=thread
```

Pass criteria: every command exits 0, release zip checksum exists, worktree remains clean,
and GitHub Test, Pages, and Pages deployment workflows pass for release commit.

## Manual Gate

Run on supported macOS version with built-in keyboard and configured external keyboard.
Preserve user settings for incremental tests. Use clean install only for onboarding section.

### Dictation

- Enable Dictation, hold configured Fn/Home key, speak through key release, and verify complete
  final words paste at cursor.
- Repeat with short speech below ignore-duration threshold; verify nothing is inserted.
- Repeat near threshold and with silence/filler; verify no phantom transcript.
- Verify first start cue and stop cue have comparable volume after cold app launch.
- Change binding among Fn, Home, Command, and Option; verify saved label and actual trigger.
- Verify left/right arrow keys never trigger dictation.
- Verify Dictate to Assistant routes to selected assistant and disabled rows never fire.

### Claude

- Existing conversation: selected text and screenshot paste into current conversation.
- New conversation: selected text and screenshot open new conversation before paste.
- Recent destination preserves current Chat/Cowork location.
- Chat/Cowork opens Claude's shared conversation surface.
- Auto-submit sends once; disabled auto-submit leaves prompt editable.

### ChatGPT

- Existing conversation pastes into current ChatGPT conversation.
- New conversation uses Quick Chat and leaves prompt editable when auto-submit is off.
- Codex with valid Git workspace opens workspace task and receives prompt.
- Codex with missing/non-Git workspace opens projectless task and receives prompt.
- App launch, field detection, or workspace launch failures surface visibly and enter history.

### Custom Actions And Background

- Fire selected-text, screenshot, popup, and voice triggers for one action.
- Verify action defaults and per-trigger delivery/destination/submit overrides.
- Run Claude and Codex background actions; verify success/failure, result, retry, and history.
- Verify URL selection is retained in prompt and background capture.
- Verify disabled/unbound actions do not appear in menu and do not fire.

### Clipboard And History

- Confirm Clipboard History is off after fresh install and only starts after opt-in.
- Copy text, URL, and image; search/filter without toolbar or search-field layout shift.
- Open selected history item into Claude and ChatGPT; verify correct destination.
- Confirm Command and Clipboard retention default to seven days and pruning respects setting.

### Import And Export

- Export all sections; verify filename includes date and file contains current settings.
- Import same file and verify preview reports same/added/changed counts accurately.
- Test Keep current, Merge, and Overwrite per section.
- Import legacy settings/templates/vocabulary files and verify intelligent migration.
- Verify canceled import makes no changes and failed import reports actionable error.

### Clean Install And Onboarding

- Back up settings, quit Command, remove app data and Command TCC grants, then install latest
  build to `~/Applications/Command.app`.
- Verify one Command app appears in launchers/search and first launch opens onboarding.
- Choose Claude or ChatGPT; verify Codex is presented as part of ChatGPT.
- Verify Accessibility, Screen Recording, and optional Microphone flow resumes after restart.
- Opt in/out of Dictation and Clipboard History; verify persisted choices after relaunch.
- Complete onboarding; verify Settings opens focused on Shortcut Settings with defaults.
- Run incremental update afterward; verify onboarding state, custom settings, vocabulary,
  actions, history, and TCC grants remain intact.

### Packaging And Trust

- Sign with `Developer ID Application`, notarize, staple, and run Gatekeeper assessment.
- Download release zip in browser, verify SHA-256, install, and launch without bypass steps.
- Run in-app update from previous release and verify rollback on simulated invalid package.

### Accessibility

- Navigate onboarding, Settings sidebar, Shortcuts, Custom Action editing, Import, Clipboard
  History, and Dictation Settings using keyboard and VoiceOver only.
- Verify every picker, toggle, icon button, key-binding field, and status indicator announces a
  specific purpose, current value or state, and disabled state where applicable.
- Verify focus order follows visual order, sheets return focus to their opener, and no control
  requires pointer input.

## Current Evidence (2026-07-30)

- Automated local suites: 231 Swift, 58 Node, 188 shell, 17 build-transaction,
  17 release-transaction, 41 install-state, 14 updater, 9 restart-handoff,
  9 installed-state preservation, 9 release-policy, 94 static syntax/configuration, and 2 string-review;
  docs, Pages, provider contract, installed restart/runtime, and release asset pass.
- Twenty-seven tracked regressions have 86 source/test evidence links; fourteen dictation regressions
  retain 46 links. Every contract spans at least two files, includes release-executed integration
  evidence, and has runtime evidence, CI enforcement, and public-release
  enforcement. Latest session health is
  persisted through start, model load, listening, first buffer, finish, and terminal outcome.
- Settings pickers and toggles have explicit hidden accessibility labels, and static analysis
  rejects future empty labels. Full keyboard and VoiceOver traversal remains a manual gate.
- App builds assemble and sign in a same-volume staging directory. A reproduced locked-Keychain
  signing failure left the previous signed `Command.app` byte-identical and removed all staging
  files; an ad-hoc success run replaced the staged build cleanly with no leftovers.
- Release zip and checksum are also staged and committed as a pair only after validation and
  optional notarization complete; interrupted or failed packaging restores prior assets.
- AddressSanitizer and ThreadSanitizer pass all 231 Swift tests after current recorder,
  midstream-watchdog, installed insert-delivery, owned-buffer, async-stream, and event-dispatch
  changes. Rerun both after future recorder, async stream, or shared-state changes.
- Current accessibility-label build passes a 60-second launchd/socket runtime soak with stable
  PID, 61/61 socket pings, flat 50 open descriptors, declining RSS, no new crashes, and no newly
  emitted critical diagnostics.
- Installed restart regression passes socket-driven restart with a replacement launchd PID,
  responsive replacement socket, preserved UserDefaults sentinel, and no crash report.
- Installed dictation watchdog coverage injects both a zero-buffer startup stall and a silent
  production-tap stall after live buffers, before and after restart. Each failure must warn once,
  reset once, release every capture resource, preserve PID/history, and pass an immediate retry.
- Legacy top-level settings, action, template, context, and standalone vocabulary imports are
  detected by testable core logic; dated export filenames use a fixed POSIX calendar format.
- Cached-model streaming probe retains generated final words after immediate release, a one-second
  pause, and quiet 18% volume input. Public release preflight now requires this probe and rejects
  `--skip-checks`.
- Menu visibility logic has direct unit coverage: only enabled bindings with a nonzero keycode
  appear in menu; disabled and unbound rows remain Settings-only.
- Microphone tap frames are deep-copied before crossing the async transcription stream, preventing
  AVAudioEngine buffer reuse from changing audio while Parakeet reads it. Isolated strict-concurrency
  diagnostics no longer report the recorder's non-Sendable buffer transfer.
- Installed ChatGPT 26.707.72221 and Claude 1.24012.0 contract check passes 9/9:
  registered URL schemes, packaged shortcut resources, and Claude Chat/Cowork/Code `/new`
  handlers match routes without driving either app's interface.
- Installed Codex projectless route passed non-submitting live smoke test.
- Prompt delivery through Quick Chat and Claude destinations, full live dictation matrix, clean
  onboarding, and full VoiceOver traversal remain manual release gates.
- Developer ID/notarization remains blocked until valid Apple signing identity and notary
  Keychain profile are available. Ad hoc signing cannot remove Gatekeeper download warning.
- Full Swift 6 strict-concurrency migration remains post-release engineering work: current SDK
  diagnostics still flag legacy AppKit globals/controllers even though normal Swift 5 release builds
  and tests pass. Run strict diagnostics with a separate `--scratch-path` so flags do not pollute
  normal SwiftPM products.
