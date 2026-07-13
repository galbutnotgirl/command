// OnboardingWindow.swift — first-run permission wizard. Shows automatically on
// launch whenever Accessibility or Screen Recording is missing. Starts with a
// welcome slide, then walks through each grant one at a time, auto-detects when
// Accessibility is granted, then restarts so grants take effect.

import Cocoa
import SwiftUI
import Combine
import AVFoundation
import ClaudeCommandCore

let onboardingWindow = OnboardingWindowController()

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "onboardingCompleted") else { return }
        let providerSelected = UserDefaults.standard.bool(forKey: "onboardingPrimaryAssistantSelected")
        // Permissions already in place (prior install or update) and provider
        // already chosen — mark done, stay silent.
        guard !providerSelected || !axTrusted() || !screenRecordingOK() else {
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            return
        }
        show()
    }

    func show() {
        if window == nil { build() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let host = NSHostingController(rootView: OnboardingView(onDismiss: { [weak self] in
            self?.window?.close()
            applyDockPolicy()
        }))
        let w = NSWindow(contentViewController: host)
        w.title = "Command"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 560, height: 520))
        w.center()
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        // Don't terminate — app stays alive in the menu bar so the user can
        // re-open onboarding via Settings without launchd's KeepAlive kicking in.
        applyDockPolicy()
    }
}

// ---- step enum --------------------------------------------------------------

enum OnbStep { case welcome, assistant, accessibility, screenRecording, microphone, clipboard, done }

// ---- root view --------------------------------------------------------------

struct OnboardingView: View {
    let onDismiss: () -> Void

    @State private var step: OnbStep = .welcome
    @State private var countdown = 3
    // One always-on ticker drives both live grant-detection and the done-countdown.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome {
                stepHeader.padding(.top, 28).padding(.horizontal, 40)
            } else {
                Spacer().frame(height: 28)
            }

            Spacer()

            switch step {
            case .welcome:
                WelcomeStepView { withAnimation(.easeInOut(duration: 0.3)) { step = .assistant } }
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .assistant:
                PrimaryAssistantStepView(
                    onChoose: { preference in
                        applyPrimaryAssistantPreference(preference)
                        withAnimation(.easeInOut(duration: 0.3)) { advanceAfterAssistant() }
                    }
                )
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .accessibility:
                // Request only → macOS shows its alert; the user opens System
                // Settings from that alert. The app never opens Settings itself.
                AccessibilityStepView(
                    onRequest: { requestAccessibility() },
                    onContinue: { advanceFromAccessibility() }   // manual fallback if live-detect misses
                )
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .screenRecording:
                ScreenRecordingStepView(
                    onRequest: { requestScreenRecording() },
                    onDone: { withAnimation(.easeInOut(duration: 0.3)) { step = .microphone } }
                )
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .microphone:
                MicrophoneStepView(
                    onEnable: { requestMic() },
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.3)) { step = .clipboard }
                    }
                )
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .clipboard:
                ClipboardOptInStepView { enabled in
                    UserDefaults.standard.set(enabled, forKey: "cliphistoryEnabled")
                    if enabled { startClipwatch() } else { stopClipwatch() }
                    reregisterHotkeys()
                    countdown = 3
                    withAnimation(.easeInOut(duration: 0.3)) { step = .done }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .done:
                DoneStepView(countdown: countdown)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            }

            Spacer()
        }
        .frame(width: 560, height: 520)
        .onReceive(ticker) { _ in tick() }
    }

    // Compact progress header stays readable at every window width.
    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stepTitle).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Step \(stepNumber) of 6").font(.caption).foregroundColor(.secondary)
            }
            ProgressView(value: Double(stepNumber), total: 6)
                .progressViewStyle(.linear)
        }
    }

    private var stepNumber: Int {
        switch step {
        case .assistant: return 1
        case .accessibility: return 2
        case .screenRecording: return 3
        case .microphone: return 4
        case .clipboard: return 5
        case .done: return 6
        case .welcome: return 0
        }
    }

    private var stepTitle: String {
        switch step {
        case .assistant: return "Primary assistant"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .microphone: return "Microphone"
        case .clipboard: return "Clipboard History"
        case .done: return "Ready"
        case .welcome: return "Welcome"
        }
    }

    private func stepChip(n: Int, label: String, active: Bool, done: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : (active ? Color.accentColor : Color.gray.opacity(0.25)))
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                } else {
                    Text("\(n)").font(.system(size: 13, weight: .semibold))
                        .foregroundColor(active ? .white : .secondary)
                }
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(active ? .primary : .secondary)
        }
        .animation(.easeInOut, value: step)
    }

    private func connector(done: Bool) -> some View {
        Rectangle()
            .fill(done ? Color.green : Color.gray.opacity(0.25))
            .frame(height: 2)
            .padding(.bottom, 18)
            .animation(.easeInOut, value: step)
    }

    // Fires every second (whatever step we're on).
    private func tick() {
        switch step {
        case .accessibility:
            if axTrusted() { advanceFromAccessibility() }
        case .screenRecording:
            if screenRecordingOK() {
                withAnimation(.easeInOut(duration: 0.3)) { step = .microphone }
            }
        case .done:
            countdown -= 1
            if countdown <= 0 {
                UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                UserDefaults.standard.set(true, forKey: "postOnboardingOpenShortcuts")
                onDismiss()
                restartApp()
            }
        default:
            break
        }
    }

    private func advanceAfterAssistant() {
        if !axTrusted() { step = .accessibility }
        else if !screenRecordingOK() { step = .screenRecording }
        else { step = .microphone }
    }

    private func advanceFromAccessibility() {
        withAnimation(.easeInOut(duration: 0.3)) {
            if !screenRecordingOK() { step = .screenRecording }
            else { step = .microphone }
        }
    }
}

private func applyPrimaryAssistantPreference(_ preference: PrimaryAssistantPreference) {
    UserDefaults.standard.set(preference.provider.rawValue, forKey: "defaultProvider")
    UserDefaults.standard.set(preference.rawValue, forKey: "primaryAssistant")
    UserDefaults.standard.set(true, forKey: "onboardingPrimaryAssistantSelected")
    switch preference.provider {
    case .claude:
        UserDefaults.standard.set(preference.destination.rawValue, forKey: "claudeDestination")
    case .codex:
        UserDefaults.standard.set(preference.destination.rawValue, forKey: "codexDestination")
    }
    settingsModel.defaultProvider = preference.provider.rawValue
    settingsModel.claudeDestination = UserDefaults.standard.string(forKey: "claudeDestination") ?? settingsModel.claudeDestination
    settingsModel.codexDestination = UserDefaults.standard.string(forKey: "codexDestination") ?? settingsModel.codexDestination
}

// ---- welcome slide ----------------------------------------------------------

struct WelcomeStepView: View {
    let onContinue: () -> Void

    @State private var keysAppeared = false

    private let previewKeys = ["F8", "⌥F8", "F7", "⌥F7", "F6", "Home", "⌥Home"]

    private let features: [(icon: String, color: Color, label: String, detail: String)] = [
        ("bolt.fill",              .orange, "Prompt Shortcuts",
         "Select text in any app. Press Option-F8 to add it to selected assistant, or F8 to open a new session."),
        ("camera.on.rectangle",    .purple, "Screenshot to Claude",
         "Drag to capture or press Space for a window. Send screenshots to existing chat, new chat, or a custom action."),
        ("clock.arrow.circlepath", .blue,   "Clipboard History",
         "When enabled, copies stay local. Press F6 for a searchable picker — paste into assistant or anywhere."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // ── Key badge row ────────────────────────────────────────
            HStack(spacing: 7) {
                ForEach(Array(previewKeys.enumerated()), id: \.offset) { i, k in
                    KeyCapView(label: k)
                        .opacity(keysAppeared ? 1 : 0)
                        .offset(y: keysAppeared ? 0 : 8)
                        .animation(
                            .spring(response: 0.45, dampingFraction: 0.72)
                                .delay(Double(i) * 0.07),
                            value: keysAppeared
                        )
                }
            }
            .padding(.bottom, 18)

            // ── Headline ─────────────────────────────────────────────
            VStack(spacing: 3) {
                Text("Your Mac.")
                    .font(.system(size: 27, weight: .bold))
                Text("Direct line to Claude, ChatGPT, or Codex.")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 8)

            Text("Global hotkeys from any app — selected text, screenshots, clipboard history, and dictation without breaking flow.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)

            // ── Features ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                ForEach(features.indices, id: \.self) { i in
                    let f = features[i]
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(f.color.opacity(0.12))
                                .frame(width: 34, height: 34)
                            Image(systemName: f.icon)
                                .font(.system(size: 14))
                                .foregroundColor(f.color)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.label)
                                .font(.system(size: 13, weight: .semibold))
                            Text(f.detail)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.bottom, 22)

            // ── CTA ──────────────────────────────────────────────────
            VStack(spacing: 6) {
                Button(action: onContinue) {
                    Text("Get Started  →")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Two required permissions + optional microphone for dictation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 44)
        .onAppear { withAnimation { keysAppeared = true } }
    }
}

// ---- primary assistant step -------------------------------------------------

struct PrimaryAssistantStepView: View {
    let onChoose: (PrimaryAssistantPreference) -> Void

    private let icons: [PrimaryAssistantPreference: String] = [
        .claude: "sparkles",
        .chatgpt: "bubble.left.and.bubble.right",
        .codex: "chevron.left.forwardslash.chevron.right",
    ]

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(appPurple.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 30))
                    .foregroundColor(appPurple)
            }

            VStack(spacing: 6) {
                Text("Choose your primary AI").font(.title2).bold()
                Text("Choose where built-in shortcuts go by default. ChatGPT includes Chat and Codex destinations.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: 10) {
                ForEach(PrimaryAssistantPreference.allCases, id: \.self) { preference in
                    Button {
                        onChoose(preference)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(appPurple.opacity(0.12)).frame(width: 34, height: 34)
                                Image(systemName: icons[preference] ?? "sparkles")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(appPurple)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preference.label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text(preference.detail)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 420)
        }
        .padding(.horizontal, 40)
    }
}

struct ClipboardOptInStepView: View {
    let onContinue: (Bool) -> Void
    @State private var enabled = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.blue)
            }
            VStack(spacing: 7) {
                Text("Keep a clipboard history?").font(.title2).bold()
                Text("Optional. Command can save copied text and images locally for seven days. Nothing is uploaded by Command.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Enable Clipboard History", isOn: $enabled)
                .toggleStyle(.switch)
            Button("Continue") { onContinue(enabled) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.horizontal, 40)
    }
}

// ---- keyboard key cap -------------------------------------------------------

struct KeyCapView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 0, x: 0, y: 2)
            )
    }
}

// ---- accessibility step -----------------------------------------------------

struct AccessibilityStepView: View {
    let onRequest: () -> Void
    let onContinue: () -> Void
    @State private var requested = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "figure.wave")
                    .font(.system(size: 32)).foregroundColor(.blue)
            }

            Text("Allow Accessibility").font(.title2).bold()

            Text("Command uses Accessibility to copy selected text, paste into selected assistant, submit when requested, restore focus, and run global shortcuts from any app.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            // Mockup of what the user will see in System Settings
            SettingsMockup(
                appName: "Command",
                description: "Find Command in the list and flip the switch ON.",
                switchColor: .blue
            )

            if !requested {
                Button(action: { requested = true; onRequest() }) {
                    Label("Request Access", systemImage: "lock.open")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("In the alert, choose Open System Settings, then flip the Command switch ON. This screen advances on its own once it's on.")
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button("Ask again") { onRequest() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("I've enabled it ->") { onContinue() }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                }
            }
        }
        .padding(.horizontal, 40)
    }
}

// ---- screen recording step --------------------------------------------------

struct ScreenRecordingStepView: View {
    let onRequest: () -> Void
    let onDone: () -> Void
    @State private var requested = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "camera.on.rectangle")
                    .font(.system(size: 32)).foregroundColor(.blue)
            }

            Text("Allow Screen Recording").font(.title2).bold()

            Text("Screenshot actions (F7 / Option-F7) capture your screen for assistant prompts. macOS requires Screen Recording access for this.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            if !requested {
                SettingsMockup(
                    appName: "Command",
                    description: "Find Command in the list and flip the switch ON.",
                    switchColor: .blue,
                    paneName: "Screen Recording"
                )
                Button(action: { requested = true; onRequest() }) {
                    Label("Request Access", systemImage: "lock.open")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    // Step 1: flip the switch
                    VStack(spacing: 6) {
                        Text("1. Flip switch ON").font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                        SettingsMockup(
                            appName: "Command",
                            description: "",
                            switchColor: .blue,
                            paneName: "Screen Recording"
                        )
                        .frame(maxWidth: 220)
                    }
                    // Step 2: click Quit & Reopen
                    VStack(spacing: 6) {
                        Text("2. Click Quit & Reopen").font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                        QuitReopenMockup()
                            .frame(maxWidth: 200)
                    }
                }
                .frame(maxWidth: 460)

                HStack(spacing: 10) {
                    Button("Ask again") { onRequest() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("I've enabled it — restart") { onDone() }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                }
            }
        }
        .padding(.horizontal, 40)
    }
}

// ---- settings mockup --------------------------------------------------------
// A simplified illustration of the System Settings privacy panel so the user
// knows exactly what they're looking for and what to click.

struct SettingsMockup: View {
    let appName: String
    let description: String
    let switchColor: Color
    var paneName: String = "Accessibility"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Window chrome
            HStack(spacing: 6) {
                Circle().fill(Color.red.opacity(0.7)).frame(width: 10, height: 10)
                Circle().fill(Color.yellow.opacity(0.7)).frame(width: 10, height: 10)
                Circle().fill(Color.green.opacity(0.7)).frame(width: 10, height: 10)
                Spacer()
                Text("System Settings").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.gray.opacity(0.12))

            Divider()

            // Breadcrumb
            HStack(spacing: 4) {
                Text("Privacy & Security").font(.system(size: 10)).foregroundColor(.secondary)
                Text(">").font(.system(size: 10)).foregroundColor(.secondary)
                Text(paneName).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            Divider()

            // App row
            HStack(spacing: 10) {
                // The real app icon, so the row matches what the user sees in System Settings.
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(appName).font(.system(size: 12, weight: .medium))
                Spacer()
                // Toggle in ON state
                Capsule()
                    .fill(switchColor)
                    .frame(width: 34, height: 20)
                    .overlay(
                        Circle().fill(Color.white).frame(width: 16, height: 16)
                            .offset(x: 7)
                    )
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.yellow.opacity(0.08))   // subtle highlight on the row
            .overlay(
                RoundedRectangle(cornerRadius: 0)
                    .stroke(switchColor.opacity(0.3), lineWidth: 1)
            )

            // Arrow annotation
            HStack {
                Spacer()
                Image(systemName: "arrow.turn.right.up")
                    .font(.system(size: 11)).foregroundColor(switchColor)
                Text("Flip this switch ON")
                    .font(.system(size: 10, weight: .medium)).foregroundColor(switchColor)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        .frame(maxWidth: 340)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }
}

// ---- quit & reopen mockup ---------------------------------------------------
// Mirrors the macOS alert that appears after enabling Screen Recording for a
// running app — shows the user exactly what they'll see and what to click.

struct QuitReopenMockup: View {
    var body: some View {
        VStack(spacing: 0) {
            // Dialog body
            VStack(spacing: 8) {
                Text("macOS will ask:")
                    .font(.system(size: 9)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10).padding(.horizontal, 12)

                Text("\"Command\" may not be able to record until it is quit.")
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }

            Divider().padding(.top, 8)

            // Buttons
            VStack(spacing: 0) {
                // Quit & Reopen = the right choice — highlighted
                HStack {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 11)).foregroundColor(.blue)
                    Text("Quit & Reopen")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.blue)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundColor(.blue)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.blue.opacity(0.08))

                Divider()

                Text("Later")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }
}

// ---- microphone step view ---------------------------------------------------

struct MicrophoneStepView: View {
    let onEnable: () -> Void
    let onContinue: () -> Void
    @State private var requested = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var micGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill((micGranted ? Color.green : Color.purple).opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: micGranted ? "checkmark.circle.fill" : "mic.fill")
                    .font(.system(size: 36))
                    .foregroundColor(micGranted ? .green : .purple)
            }

            Text("Microphone access")
                .font(.title2).bold()

            Text("Optional — for on-device dictation via Parakeet TDT.\nSkip if you don't plan to use Dictate or voice custom actions.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            if micGranted {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.subheadline)
            } else if requested {
                Text("Allow access in the macOS alert, then continue.")
                    .font(.subheadline).foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                if !micGranted {
                    Button("Enable Microphone") {
                        requested = true
                        onEnable()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                if micGranted {
                    Button("Continue  →", action: onContinue)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button("Skip for now", action: onContinue)
                        .buttonStyle(.bordered).controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 44)
        .onReceive(ticker) { _ in
            if micGranted && requested { onContinue() }
        }
    }
}

// ---- done step view ---------------------------------------------------------

struct DoneStepView: View {
    let countdown: Int
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(Color.green.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 42)).foregroundColor(.green)
            }
            Text("You're all set!").font(.title2).bold()
            Text("Permissions granted. Command is restarting so they take effect.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text("Restarting in \(countdown)...")
                .font(.headline).foregroundColor(.accentColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 40)
    }
}
