# Command Updates

Use this when updating alpha builds. For first-time installs, see [INSTALL.md](INSTALL.md).

## Update From The App

1. Open **Settings -> About**.
2. Choose update channel:
   - **Alpha**: earliest builds, most frequent changes.
   - **Beta**: pre-release builds intended for broader testing.
   - **Stable**: stable builds only; visible but unavailable until the first stable release exists.
3. Click **Check for Updates**.
4. If a version appears, click **Update Now**.

Command checks GitHub Releases for the newest build accepted by your channel. Alpha accepts alpha, beta, and stable tags; Beta accepts beta and stable tags; Stable accepts stable tags only once stable is enabled. The updater downloads the attached `Command-*.zip` asset, ignores checksum sidecar files, replaces `~/Applications/Command.app`, clears quarantine, and restarts. Launch at login is not required for the updater to reopen Command. Accessibility, Screen Recording, and Microphone grants should stay attached to the app.

If a release has no downloadable app zip attached, Command opens the release page for manual install.

## Rename Compatibility

Command was previously named ClaudeCommand. Updates now install `Command.app` and release assets named `Command-*.zip`. The bundle identifier and local support paths intentionally remain `com.claudecommand` and `~/Library/Application Support/claude-command/` so macOS permission grants, shortcuts, command history, background records, and exported settings survive the rename.

## Install Alpha Manually

For first-time details, see [Install Guide](INSTALL.md).

1. Open the [latest GitHub Release](https://github.com/galbutnotgirl/command/releases/latest).
2. Download the latest `Command-*.zip`.
3. Optional: download the matching `.zip.sha256` file into the same folder as the zip, then run `cd ~/Downloads && shasum -a 256 -c Command-*.zip.sha256`.
4. Quit Command if it is running.
5. Unzip and move `Command.app` to `~/Applications`.
6. Launch it and open **Settings -> Set Up** to confirm permissions/components.

## Before Updating

Export settings if you are testing many alpha builds:

1. Open **Settings -> About -> Import / Export**.
2. Click **Export**.
3. Keep all sections checked unless you want a smaller backup.
4. Save the JSON somewhere you can find again.

Export includes shortcuts, prompt settings, context rules, dictation vocabulary, background settings, and app preferences.

Incremental and in-app updates keep local Clipboard History in `~/.claude/state/cliphistory/`. Only explicit clean-install or uninstall cleanup removes it.

## If Update Fails

| Symptom | Fix |
|---|---|
| Update check says no releases | Confirm channel. Alpha sees alpha/beta/stable; Beta sees beta/stable; Stable stays unavailable until a stable release exists. |
| Download fails | Check network, then try manual install from [Install Guide](INSTALL.md). |
| App opens but shortcuts fail | Open **Settings -> Set Up**, confirm Accessibility, then restart Command. |
| Screenshot fails after update | Confirm Screen Recording permission, then restart Command. |
| Dictation fails after update | Confirm Microphone permission and model status in **Dictation Settings**. |

## Roll Back

1. Download older `Command-*.zip` from GitHub Releases.
2. Optional: verify it with the matching `.zip.sha256` file in the same folder.
3. Quit Command.
4. Replace `~/Applications/Command.app`.
5. Launch Command and open **Settings -> Set Up**.

Use **Settings -> About -> Import / Export**, then click **Import**, if you need to restore an exported settings JSON.

For the About update/import controls, see [Settings Reference](SETTINGS_REFERENCE.md).
