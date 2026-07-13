# Command FAQ

## How do I switch between Claude and Codex?

Choose **Default assistant** in **Settings -> Shortcuts**. Custom Actions and individual triggers can override it. Claude uses Chat/Cowork/Code destinations; Codex uses configured workspace. Set Up checks each app and CLI independently, and Command never silently falls back to other provider.

For background delivery, open **Command History -> Background Settings**. Claude and Codex have separate command, working-directory, and argument settings. Codex defaults to read-only execution until you explicitly choose Workspace changes.

## Why are auto-submit combinations unbound by default?

Auto-submit opens a new chat, presses Return, and restores focus. That is powerful, but it is easier to trigger accidentally than a draft-only combination. Bind **Selected text -> New chat + auto-submit** or **Screenshot -> New chat + auto-submit** in **Settings -> Shortcuts** when you want that behavior.

## What if F6/F7/F8 conflict with another app?

Open macOS **System Settings -> Keyboard** and enable standard function keys, or rebind Command shortcuts in **Settings -> Shortcuts** and **Settings -> Dictation Settings**.

Fresh defaults use F8/Option-F8 for selected text, F7/Option-F7 for screenshots, F6 for Clipboard History, and Home/Option-Home for built-in dictation. Built-in Dictate shortcuts live in **Dictation Settings**; voice prompt triggers live in **Shortcut Settings**.

## What do the built-in Compose combinations do?

| Combination | Result |
|---|---|
| Existing chat | Send captured content into the current Claude chat. |
| New chat | Open a new Claude chat and wait for your note. |
| New chat + auto-submit | Open a new Claude chat, auto-submit, and restore focus. |

## What does `—` mean in a trigger row?

`—` means "inherit." The trigger uses the prompt/action default delivery, destination, or submit setting.

## Does Command upload clipboard or dictation history?

No. Clipboard history and dictation history stay in local files. Background actions are different: they run your local Claude CLI, so access depends on your Claude CLI settings and allowed tools.

## Where is data stored?

See [Privacy](PRIVACY.md). Main locations:

- `~/.claude/state/`
- `~/.claude/state/cliphistory/`
- `~/Library/Application Support/DictationLab/`
- `~/Library/Application Support/claude-command/`

## Why do some local paths still say `claude-command`?

Command was previously named ClaudeCommand. Local support paths and the bundle identifier stay stable on purpose so macOS permissions, shortcuts, command history, background records, and exports keep working across alpha updates. User-facing app, repo, release asset, and GitHub Pages names are now Command.

## Why did a background action fail?

Open **Settings -> Command History -> Background**, expand failed run, and inspect log. Also check **Background Settings** for CLI command, working directory, and extra args.

## Why did Claude - To-Do send text instead of the URL?

Right-click Services prefer highlighted text. Clear the text selection first, then run **Claude - To-Do** from Safari, Chrome, Brave, Chromium, or Arc to send the current tab URL as a background action. Check **Command History -> Background** for the captured source.

## Why does dictation miss final words?

Voice input depends on stop timing and model finalization. In current alpha builds, stop timing is tuned inside the app rather than exposed as a slider. The stop sound means release was accepted; the menu-bar recording chip stays visible until tail capture, model finalization, and dispatch finish. If final words are cut off, release the key after the last word, then check **Dictation History** to see whether the raw transcript or processed transcript lost the tail. Include that detail plus diagnostics in a bug report.

## How do updates work?

Use **Settings -> About** to choose Alpha or Beta and run **Check for Updates**. Stable is visible but unavailable until the first stable release exists. See [Updates](UPDATES.md) for manual alpha installs, backup/export before updating, failed updates, and rollback.

## How do I install Command the first time?

Download the latest `Command-*.zip` from the [latest GitHub Release](https://github.com/galbutnotgirl/command/releases/latest), optionally verify it with the matching `.zip.sha256` file in the same folder, move `Command.app` to `~/Applications`, then open **Settings -> Set Up**. See [Install Guide](INSTALL.md) for first launch, permissions, setup checks, and source install.

## Can I move settings to another Mac?

Yes. Open **Settings -> About -> Import / Export**. Export sections from old Mac, then import on new Mac. Use **Merge** unless you intentionally want to replace local settings.

## What should I include in a bug report?

Use **Settings -> About -> Copy Diagnostic Info**, then **Report a Bug**. Include trigger, shortcut, expected result, actual result, and relevant diagnostic lines. For background actions, include full Command History log text when the summary is not enough.

## How should I request a feature?

Use **Settings -> About -> Request Feature** or the [Feature request template](https://github.com/galbutnotgirl/command/issues/new?template=feature_request.md). Include workflow, trigger type, delivery mode, destination, auto-submit preference, current workaround, and whether the request needs Settings UI, menu-bar behavior, docs/examples, import/export support, or release-note coverage.

For tab-by-tab Settings help, see [Settings Reference](SETTINGS_REFERENCE.md). For symptom-first fixes and log paths, see [Troubleshooting](TROUBLESHOOTING.md).
