import AppKit
import Foundation

private final class ReceiverDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private let outputURL: URL
    private let readyURL: URL
    private var window: NSWindow?
    private var textView: NSTextView?

    init(outputPath: String, readyPath: String) {
        outputURL = URL(fileURLWithPath: outputPath)
        readyURL = URL(fileURLWithPath: readyPath)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: window.contentView?.bounds ?? .zero)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = true
        textView.isSelectable = true
        textView.delegate = self
        window.contentView = textView
        window.title = "Command Dictation Delivery Check"
        window.isReleasedWhenClosed = false

        self.window = window
        self.textView = textView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        // Production probe activates receiver by bundle ID and verifies focus
        // before posting Command-V. Readiness only means window and editor exist;
        // requiring this background helper to steal focus during launch is flaky.
        DispatchQueue.main.async { [weak self] in self?.publishReady() }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        try? Data(textView.string.utf8).write(to: outputURL, options: .atomic)
    }

    private func publishReady() {
        guard let window, let textView else {
            NSApp.terminate(nil)
            return
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        try? Data().write(to: outputURL, options: .atomic)
        let pid = ProcessInfo.processInfo.processIdentifier
        try? Data("\(pid)\n".utf8).write(to: readyURL, options: .atomic)
    }
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: DictationPasteReceiver OUTPUT READY\n".utf8))
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
private let delegate = ReceiverDelegate(
    outputPath: CommandLine.arguments[1],
    readyPath: CommandLine.arguments[2]
)
app.delegate = delegate
app.run()
