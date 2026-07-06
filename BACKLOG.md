# Backlog

Not built yet — recorded here for future work.

- **Update functionality** — in-app update flow (there's already `agent/Updater.swift` scaffolding that checks GitHub releases; needs the actual download/install/relaunch flow wired up).
- **Release functionality** — a repeatable release process (`release.sh` exists but needs review/hardening: version bump, build, sign, notarize?, tag, GitHub release upload).
- **Bug submissions** — a way for users to report bugs from inside the app (e.g. a menu item that opens a pre-filled GitHub issue, or a "Send Feedback" flow with logs attached).
