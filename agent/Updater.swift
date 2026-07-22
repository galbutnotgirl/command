// Updater.swift — check GitHub Releases for a newer build and install it.
//
// Flow:
//   1. check()    → GET release list, choose highest accepted SemVer for selected
//                   channel, compare with CFBundleShortVersionString, and surface
//                   "up to date" / "update available" / "failed" asynchronously.
//   2. install()  → download the release's .app zip, hand off to a detached
//                   swapper script that waits for us to quit, replaces the
//                   installed bundle atomically, validates it again, and reopens.
//
// No third-party framework (Sparkle): the app is ad-hoc/locally signed and built
// from source, so a plain Releases check keeps the trust model simple and the
// updater inert until a public repo + release actually exist.

import Foundation
import AppKit
import ClaudeCommandCore

// ── Single source of truth for the public repo this app lives in / updates from.
// Fill OWNER/REPO once the public repo exists; an empty owner disables updates
// gracefully (the UI shows "no update repo configured" instead of erroring).
let GH_OWNER = "galbutnotgirl"
let GH_REPO  = "command"
var GITHUB_REPO_URL: String { GH_OWNER.isEmpty ? "" : "https://github.com/\(GH_OWNER)/\(GH_REPO)" }
var DOCS_SITE_URL: String { GH_OWNER.isEmpty ? "" : "https://\(GH_OWNER).github.io/\(GH_REPO)/" }

// Where install-agent.sh puts the running app. The swapper replaces this path.
let INSTALL_PATH = (NSHomeDirectory() as NSString).appendingPathComponent("Applications/Command.app")

// Stable has no public release yet -> keep the Stable option disabled in the UI.
// Flip to true once a stable vX.Y.Z release is cut.
let PROD_AVAILABLE = false

func currentChannel() -> UpdateChannel {
    UpdateChannel(rawValue: UserDefaults.standard.string(forKey: "updateChannel") ?? "alpha") ?? .alpha
}
func setUpdateChannel(_ c: UpdateChannel) {
    UserDefaults.standard.set(c.rawValue, forKey: "updateChannel")
}

// ── Bug reporting ───────────────────────────────────────────────────────────
// GitHub's issue-form query params (title/body) pre-fill a new issue without
// any API/auth — same trust model as the rest of the updater (no third-party
// service, just the repo this app already lives in).
func reportBugURL() -> URL? {
    guard !GH_OWNER.isEmpty, !GH_REPO.isEmpty else { return nil }
    let version = currentAppVersion()
    let branch = (Bundle.main.infoDictionary?["ClaudeCommandGitBranch"] as? String) ?? ""
    let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
    let appPath = Bundle.main.bundlePath
    let channel = currentChannel().label
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    var body = """
    **Version:** \(version)\(branch.isEmpty ? "" : " (\(branch))")
    **Bundle ID:** \(bundleID)
    **App path:** \(appPath)
    **macOS:** \(osString)
    **Update channel:** \(channel)

    **Trigger / workflow:** Selected text / Screenshot / Popup / Voice / Dictation / Clipboard History / Background / Import / Export / Update
    **Shortcut:** 
    **Source app:** 
    **Assistant (Claude/ChatGPT/Codex):**
    **Destination or workspace:**
    **Target update version, if relevant:** 

    **What happened:**


    **What you expected:**


    **Steps to reproduce:**
    1.

    **Diagnostics:**
    Review copied diagnostics for sensitive log or recent-text content, then paste relevant lines from Settings -> About -> Copy Diagnostic Info.
    Do not use this public issue for vulnerabilities, exposed secrets, private logs, or sensitive diagnostic output. Use private vulnerability reporting instead: https://github.com/\(GH_OWNER)/\(GH_REPO)/security/advisories/new

    **Dictation / voice detail, if relevant:**
    Did Dictation History raw text or processed text lose the words? Was recording press-and-hold or locked?

    """
    body += "\n<!-- Logs, if relevant: ~/Library/Logs/claude-command.log (shortcut actions), "
    body += "~/.claude/logs/command-agent.err (app dispatch), ~/.claude/logs/clipwatch.err (Clipboard History), "
    body += "~/.claude/logs/attribution.log (clipboard/source attribution) -->\n"

    var comps = URLComponents(string: "https://github.com/\(GH_OWNER)/\(GH_REPO)/issues/new")!
    comps.queryItems = [
        URLQueryItem(name: "template", value: "bug_report.md"),
        URLQueryItem(name: "title", value: "Bug: "),
        URLQueryItem(name: "body", value: body),
    ]
    return comps.url
}

func requestFeatureURL() -> URL? {
    guard !GH_OWNER.isEmpty, !GH_REPO.isEmpty else { return nil }
    var comps = URLComponents(string: "https://github.com/\(GH_OWNER)/\(GH_REPO)/issues/new")!
    comps.queryItems = [
        URLQueryItem(name: "template", value: "feature_request.md"),
        URLQueryItem(name: "title", value: "Feature: "),
    ]
    return comps.url
}

func securityAdvisoryURL() -> URL? {
    guard !GH_OWNER.isEmpty, !GH_REPO.isEmpty else { return nil }
    return URL(string: "https://github.com/\(GH_OWNER)/\(GH_REPO)/security/advisories/new")
}

struct UpdateInfo: Sendable {
    let latestVersion: String
    let currentVersion: String
    let isNewer: Bool
    let releaseURL: String
    let downloadURL: String?    // zipped .app asset, if the release attaches one
    let notes: String
}

enum UpdateCheckResult: Sendable {
    case upToDate(current: String)
    case available(UpdateInfo)
    case failed(String)
}

func currentAppVersion() -> String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
}

private let COMMAND_BUNDLE_ID = "com.claudecommand"

func appDesignatedRequirement(at appPath: String) -> String? {
    let result = runShell("/usr/bin/codesign", ["-dr", "-", appPath])
    guard result.code == 0 else { return nil }
    for line in result.out.components(separatedBy: .newlines) {
        guard let marker = line.range(of: "designated => ") else { continue }
        let requirement = line[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !requirement.isEmpty { return requirement }
    }
    return nil
}

private func validateUpdateBundle(
    at appPath: String,
    expectedVersion: String,
    expectedRequirement: String
) -> String? {
    let infoPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
    guard let data = FileManager.default.contents(atPath: infoPath),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return "Update app is missing valid bundle metadata." }

    guard info["CFBundleIdentifier"] as? String == COMMAND_BUNDLE_ID else {
        return "Update app has wrong bundle identifier."
    }
    guard info["CFBundleShortVersionString"] as? String == expectedVersion else {
        return "Update app version does not match release metadata."
    }
    guard let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty else {
        return "Update app is missing executable metadata."
    }
    let executablePath = (appPath as NSString).appendingPathComponent("Contents/MacOS/\(executable)")
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
        return "Update app executable is missing."
    }

    let signature = runShell(
        "/usr/bin/codesign",
        ["--verify", "--deep", "--strict", "-R=\(expectedRequirement)", appPath]
    )
    guard signature.code == 0 else {
        return "Update signature does not match installed Command app."
    }
    return nil
}

// ── Daily background check ──────────────────────────────────────────────────
// Silent unless an update is actually available — then a system notification
// points at Settings → About, same place the manual "Check for Updates"
// button surfaces it. Doesn't auto-install: the user still clicks through.
private let AUTO_UPDATE_CHECK_INTERVAL: TimeInterval = 86400
private let AUTO_UPDATE_LAST_CHECK_KEY = "lastAutoUpdateCheckAt"
@MainActor private var _autoUpdateTimer: Timer?

@MainActor
func scheduleAutoUpdateCheck() {
    let last = UserDefaults.standard.double(forKey: AUTO_UPDATE_LAST_CHECK_KEY)
    let elapsed = Date().timeIntervalSince1970 - last
    // Never checked, or overdue: check soon after launch. Otherwise wait out
    // the rest of today's window so a relaunch doesn't reset the clock.
    let initialDelay = elapsed >= AUTO_UPDATE_CHECK_INTERVAL ? 20.0 : (AUTO_UPDATE_CHECK_INTERVAL - elapsed)
    DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) {
        runAutoUpdateCheck()
        _autoUpdateTimer?.invalidate()
        _autoUpdateTimer = Timer.scheduledTimer(withTimeInterval: AUTO_UPDATE_CHECK_INTERVAL, repeats: true) { _ in
            Task { @MainActor in runAutoUpdateCheck() }
        }
    }
}

@MainActor
private func runAutoUpdateCheck() {
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: AUTO_UPDATE_LAST_CHECK_KEY)
    Updater.shared.check { result in
        if case .available(let info) = result {
            notify("Update available", "Command v\(info.latestVersion) is ready — Settings → About to install.")
        }
    }
}

@MainActor
final class Updater {
    static let shared = Updater()
    private(set) var busy = false

    // ── 1. Check the newest release on the selected channel ──────────────────
    func check(_ completion: @escaping @MainActor @Sendable (UpdateCheckResult) -> Void) {
        let channel = currentChannel()
        guard !GH_OWNER.isEmpty, !GH_REPO.isEmpty else {
            completion(.failed("No update repo configured yet.")); return
        }
        // Pull the release list (newest-first) and filter by channel ourselves —
        // /releases/latest only ever returns the newest stable build.
        guard let url = URL(string: "https://api.github.com/repos/\(GH_OWNER)/\(GH_REPO)/releases?per_page=30") else {
            completion(.failed("Bad update URL.")); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Command", forHTTPHeaderField: "User-Agent")
        busy = true
        URLSession.shared.dataTask(with: req) { data, resp, err in
            Task { @MainActor in
                Updater.shared.busy = false
                if let err = err { completion(.failed(err.localizedDescription)); return }
                guard let http = resp as? HTTPURLResponse else { completion(.failed("No response.")); return }
                if http.statusCode == 404 { completion(.failed("No releases published yet.")); return }
                guard http.statusCode == 200, let data = data,
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    completion(.failed("Update check failed (HTTP \(http.statusCode)).")); return
                }
                // GitHub sorts by publish time, not SemVer. Filter compatible
                // channel releases, then choose highest version deterministically.
                let published = arr.filter { ($0["draft"] as? Bool) != true }
                let tags = published.compactMap { $0["tag_name"] as? String }
                let newestTag = newestAcceptedReleaseTag(from: tags, channel: channel)
                let match = published.first { ($0["tag_name"] as? String) == newestTag }
                guard let rel = match, let tag = rel["tag_name"] as? String else {
                    completion(.failed("No \(channel.label) release published yet.")); return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let cur = currentAppVersion()
                var dl: String? = nil
                if let assets = rel["assets"] as? [[String: Any]] {
                    let releaseAssets = assets.compactMap { asset -> ReleaseAssetInfo? in
                        guard let name = asset["name"] as? String,
                              let url = asset["browser_download_url"] as? String else { return nil }
                        return ReleaseAssetInfo(name: name, browserDownloadURL: url)
                    }
                    dl = downloadableZipAsset(from: releaseAssets)?.browserDownloadURL
                }
                let info = UpdateInfo(
                    latestVersion: latest,
                    currentVersion: cur,
                    // Strict newer-than, not just "different" — a locally-built dev
                    // version ahead of the last tagged release must never be offered
                    // as a "downgrade" back to that release.
                    isNewer: versionGreater(latest, cur),
                    releaseURL: (rel["html_url"] as? String) ?? GITHUB_REPO_URL,
                    downloadURL: dl,
                    notes: (rel["body"] as? String) ?? "")
                completion(info.isNewer ? .available(info) : .upToDate(current: cur))
            }
        }.resume()
    }

    // ── 2. Download + install ───────────────────────────────────────────────
    // status() fires on the main thread with progress text. done() fires once at
    // the end; on success the app quits and the swapper relaunches the new build.
    func install(_ info: UpdateInfo,
                 status: @escaping @MainActor @Sendable (String) -> Void,
                 done: @escaping @MainActor @Sendable (Bool, String) -> Void) {
        guard let dl = info.downloadURL, let url = URL(string: dl) else {
            if let u = URL(string: info.releaseURL) { NSWorkspace.shared.open(u) }
            done(false, "This release has no downloadable build attached. Opened the release page so you can grab it manually.")
            return
        }
        status("Downloading v\(info.latestVersion)…")
        busy = true
        URLSession.shared.downloadTask(with: url) { tmp, _, err in
            Task { @MainActor in Updater.shared.busy = false }
            guard let tmp = tmp, err == nil else {
                Task { @MainActor in done(false, "Download failed: \(err?.localizedDescription ?? "unknown error").") }
                return
            }
            // Move the download somewhere stable before the URLSession temp is reaped.
            let work = NSTemporaryDirectory() + "claudecommand-update"
            try? FileManager.default.removeItem(atPath: work)
            try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            let zipPath = work + "/update.zip"
            do { try FileManager.default.moveItem(atPath: tmp.path, toPath: zipPath) }
            catch { Task { @MainActor in done(false, "Could not stage download: \(error.localizedDescription)") }; return }

            Task { @MainActor in status("Unpacking…") }
            // ditto -xk unzips; the archive should contain Command.app at top level.
            let unzipDir = work + "/extracted"
            let (_, code) = runShell("/usr/bin/ditto", ["-xk", zipPath, unzipDir])
            let appNames = (try? FileManager.default.contentsOfDirectory(atPath: unzipDir))?
                .filter { $0.hasSuffix(".app") } ?? []
            guard code == 0, appNames == ["Command.app"] else {
                Task { @MainActor in done(false, "Update archive didn't contain an app bundle.") }
                return
            }
            let newApp = unzipDir + "/Command.app"
            guard let requirement = appDesignatedRequirement(at: Bundle.main.bundlePath) else {
                Task { @MainActor in done(false, "Could not verify installed Command signing identity.") }
                return
            }
            if let validationError = validateUpdateBundle(
                at: newApp,
                expectedVersion: info.latestVersion,
                expectedRequirement: requirement
            ) {
                Task { @MainActor in done(false, validationError) }
                return
            }
            Task { @MainActor in
                status("Installing… the app will restart.")
                if Updater.shared.handOffSwap(
                    newApp: newApp,
                    expectedVersion: info.latestVersion,
                    expectedRequirement: requirement
                ) {
                    done(true, "Updated to v\(info.latestVersion). Restarting…")
                    // Successful exit does not trigger launchd's restart-on-failure
                    // rule. Swapper reopens exactly once after verified replacement.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(0) }
                } else {
                    done(false, "Couldn't start the installer.")
                }
            }
        }.resume()
    }

    // Launch bundled detached swapper. Paths and signing requirement are argv,
    // never interpolated into shell source. Helper restores prior bundle on any
    // copy, metadata, executable, or signature failure.
    private func handOffSwap(
        newApp: String,
        expectedVersion: String,
        expectedRequirement: String
    ) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let swapPath = Bundle.main.path(forResource: "update-swap", ofType: "sh") else {
            NSLog("[updater] bundled update-swap.sh missing")
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [
            swapPath,
            "\(pid)",
            newApp,
            INSTALL_PATH,
            COMMAND_BUNDLE_ID,
            expectedVersion,
            expectedRequirement,
            "1",
        ]
        do { try p.run() } catch { NSLog("[updater] could not launch swapper: \(error)"); return false }
        return true
    }
}
