# Command Release Test Plan

Use this matrix before publishing beta or stable builds. Automated checks are release
gates; manual checks cover macOS permissions, global input, and third-party app UI contracts
that cannot be proven reliably in CI.

## Automated Gate

Run from repository root on clean `main`:

```bash
cd agent && swift test
cd ../vendor/claude-command-capture && node --test
cd ../.. && ./test/test-shell.sh
./test/test-install-state.sh
./test/test-updater-swap.sh
./test/test-restart-app.sh
./test/test-release-policy.sh
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
./test/test-installed-restart.sh
./test/test-installed-runtime.sh
```

Restart test verifies socket acknowledgement, replacement launchd PID, recovered socket, preserved
UserDefaults, and no crash report. Runtime test then performs a 15-second idle soak with repeated
socket pings and verifies stable PID, bounded open descriptors, no new crash reports, and no new
fatal or SwiftUI cycle diagnostics. Override duration with `COMMAND_SOAK_SECONDS` for longer runs.

With Parakeet models cached on release Mac:

```bash
./test/test-dictation-model.sh
```

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
- Explicit Chat and Cowork destinations switch to requested surface or show clear failure.
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

## Current Evidence (2026-07-22)

- Automated local suites: 143 Swift, 58 Node, 50 shell, 25 install-state, 11 updater,
  9 restart-handoff, 7 release-policy, 70 static syntax/configuration, and 2 string-review;
  docs, Pages, provider contract, installed restart/runtime, and release asset pass.
- Settings pickers and toggles have explicit hidden accessibility labels, and static analysis
  rejects future empty labels. Full keyboard and VoiceOver traversal remains a manual gate.
- All 143 Swift tests also pass independently under AddressSanitizer and ThreadSanitizer.
- Installed `main@2317d29` passes a 60-second launchd/socket runtime soak with stable PID, 61/61
  socket pings, bounded descriptors, no new crashes, and no newly emitted critical diagnostics.
- Installed `main@034c0ad` passes a post-install 15-second soak with 16/16 pings, stable PID,
  flat descriptors, declining RSS, and no new crash or critical diagnostics.
- Installed restart regression passes socket-driven restart with a replacement launchd PID,
  responsive replacement socket, preserved UserDefaults sentinel, and no crash report.
- Legacy top-level settings, action, template, context, and standalone vocabulary imports are
  detected by testable core logic; dated export filenames use a fixed POSIX calendar format.
- Cached-model streaming probe rejects an empty synthesized fixture, then retains generated
  speech's distinctive final words after immediate stream drain and Parakeet `finish()`.
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
