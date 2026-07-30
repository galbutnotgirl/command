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

        publishReadyWhenFocused(attemptsRemaining: 60)
    }

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        try? Data(textView.string.utf8).write(to: outputURL, options: .atomic)
    }

    private func publishReadyWhenFocused(attemptsRemaining: Int) {
        guard let window, let textView else {
            NSApp.terminate(nil)
            return
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        guard NSApp.isActive,
              window.isKeyWindow,
              textView.window?.firstResponder === textView else {
            guard attemptsRemaining > 1 else {
                NSApp.terminate(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.publishReadyWhenFocused(attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }
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
