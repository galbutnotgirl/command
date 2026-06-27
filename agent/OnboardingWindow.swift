// OnboardingWindow.swift — first-run permission wizard. Shows automatically on
// launch whenever Accessibility or Screen Recording is missing. Starts with a
// welcome slide, then walks through each grant one at a time, auto-detects when
// Accessibility is granted, then restarts so grants take effect.

import Cocoa
import SwiftUI

let onboardingWindow = OnboardingWindowController()

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func showIfNeeded() {
        guard !axTrusted() || !screenRecordingOK() else { return }
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
        w.title = "Claude Command"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 560, height: 520))
        w.center()
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the onboarding wizard means the user opted out — quit entirely.
        // (Permissions are required for the app to function; no point running without them.)
        NSApp.terminate(nil)
    }
}

// ---- step enum --------------------------------------------------------------

enum OnbStep { case welcome, accessibility, screenRecording, microphone, done }

// ---- root view --------------------------------------------------------------

struct OnboardingView: View {
    let onDismiss: () -> Void

    @State private var step: OnbStep = .welcome
    @State private var polling: Timer? = nil
    @State private var countdown = 3
    @State private var screenRecordingDone = false   // user manually confirmed

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
                WelcomeStepView { withAnimation(.easeInOut(duration: 0.3)) { step = .accessibility } }
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .accessibility:
                // Request only → macOS shows its alert; the user opens System
                // Settings from that alert. The app never opens Settings itself.
                AccessibilityStepView(onRequest: { requestAccessibility() })
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                .onAppear { startPollingAccessibility() }
                .onDisappear { polling?.invalidate() }

            case .screenRecording:
                ScreenRecordingStepView(
                    onRequest: { requestScreenRecording() },
                    onDone: {
                        withAnimation(.easeInOut(duration: 0.3)) { step = .microphone }
                    }
                )
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .microphone:
                MicrophoneStepView(
                    onEnable: { requestMicAndSpeech() },
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.3)) { step = .done }
                        beginCountdown()
                    }
                )
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .done:
                DoneStepView(countdown: countdown)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            }

            Spacer()
        }
        .frame(width: 560, height: 520)
        .onDisappear { polling?.invalidate() }
    }

    // ── numbered step header (1 · 2 · 3 · 4)
    private var stepHeader: some View {
        HStack(spacing: 0) {
            stepChip(n: 1, label: "Accessibility",    active: step == .accessibility,   done: step == .screenRecording || step == .microphone || step == .done)
            connector(done: step == .screenRecording || step == .microphone || step == .done)
            stepChip(n: 2, label: "Screen Recording", active: step == .screenRecording, done: step == .microphone || step == .done)
            connector(done: step == .microphone || step == .done)
            stepChip(n: 3, label: "Microphone",       active: step == .microphone,      done: step == .done)
            connector(done: step == .done)
            stepChip(n: 4, label: "All set",          active: step == .done,            done: false)
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

    // ── Accessibility can be detected in-process (takes effect immediately)
    private func startPollingAccessibility() {
        polling?.invalidate()
        polling = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            guard axTrusted() else { return }
            polling?.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    step = screenRecordingOK() ? .done : .screenRecording
                }
                if step == .done { beginCountdown() }
            }
        }
    }

    private func beginCountdown() {
        countdown = 3
        polling = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            countdown -= 1
            if countdown <= 0 {
                t.invalidate()
                onDismiss()
                exit(0)     // LaunchAgent KeepAlive re-launches with fresh TCC grants live
            }
        }
    }
}

// ---- welcome slide ----------------------------------------------------------

struct WelcomeStepView: View {
    let onContinue: () -> Void

    @State private var keysAppeared = false

    private let previewKeys = ["F8", "⌘F8", "⌥F8", "F7", "⌘F7", "F6", "⌘F6"]

    private let features: [(icon: String, color: Color, label: String, detail: String)] = [
        ("bolt.fill",              .orange, "Instant Go",
         "Select text in any app → ⌘F8. Claude has it and auto-submits. Focus returns immediately."),
        ("camera.on.rectangle",    .purple, "Screenshot to Claude",
         "Drag to capture or press Space for a window. Image drops straight into Claude."),
        ("clock.arrow.circlepath", .blue,   "Clipboard History",
         "Every copy is saved. Press F6 for a searchable picker — paste into Claude or anywhere."),
        ("mic.fill",               .green,  "Live Dictation",
         "Speak to insert text at your cursor or open a new Claude session with your words."),
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
                Text("Direct line to Claude.")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 8)

            Text("Global hotkeys from any app — select, capture, dictate, or paste into Claude without switching windows.")
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

                Text("Two quick permissions unlock everything.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 44)
        .onAppear { withAnimation { keysAppeared = true } }
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
    @State private var requested = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "figure.wave")
                    .font(.system(size: 32)).foregroundColor(.blue)
            }

            Text("Allow Accessibility").font(.title2).bold()

            Text("Claude Command types into the Claude app on your behalf — pasting your selected text, pressing Return to submit, and returning focus to your previous app. macOS requires Accessibility access for this.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            // Mockup of what the user will see in System Settings
            SettingsMockup(
                appName: "Claude Command",
                description: "Find Claude Command in the list and flip the switch ON.",
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
                    Text("In the alert, choose Open System Settings, then flip the Claude Command switch ON.")
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                Button("Ask again") { onRequest() }
                    .buttonStyle(.bordered).controlSize(.small)
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
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(Color.purple.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "camera.on.rectangle")
                    .font(.system(size: 32)).foregroundColor(.purple)
            }

            Text("Allow Screen Recording").font(.title2).bold()

            Text("The Screenshot actions (F7 / Cmd-F7) capture your screen and drop the image straight into Claude. macOS requires Screen Recording access for this.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            SettingsMockup(
                appName: "Claude Command",
                description: "Find Claude Command in the list and flip the switch ON.",
                switchColor: .purple
            )

            if !requested {
                Button(action: { requested = true; onRequest() }) {
                    Label("Request Access", systemImage: "lock.open")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                VStack(spacing: 10) {
                    Text("In the alert, choose Open System Settings and enable Claude Command, then tap Continue.")
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Ask again") { onRequest() }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("Continue ->") { onDone() }
                            .buttonStyle(.borderedProminent).controlSize(.regular)
                    }
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
                Text("Accessibility").font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            Divider()

            // App row
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: "terminal").font(.system(size: 12)).foregroundColor(.accentColor))
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

// ---- microphone step --------------------------------------------------------

struct MicrophoneStepView: View {
    let onEnable: () -> Void
    let onContinue: () -> Void
    @State private var requested = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(Color.green.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "mic.fill")
                    .font(.system(size: 32)).foregroundColor(.green)
            }

            Text("Enable Microphone").font(.title2).bold()

            Text("Dictation lets you speak to insert text at your cursor or open a new Claude session with your words. This is optional — skip if you don't need it.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            if !requested {
                HStack(spacing: 12) {
                    Button(action: { requested = true; onEnable() }) {
                        Label("Enable Microphone", systemImage: "mic")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Skip") { onContinue() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            } else {
                VStack(spacing: 10) {
                    Text("Microphone enabled. Tap Continue to finish setup.")
                        .font(.subheadline).foregroundColor(.secondary)
                    Button("Continue ->") { onContinue() }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                }
            }
        }
        .padding(.horizontal, 40)
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
            Text("Both permissions granted. Claude Command is restarting so they take effect.")
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
