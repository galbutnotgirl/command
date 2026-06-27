import Foundation

// Config helpers used by SpeechEngine and DictationOverlay.
// Kept here so the dictation stack compiles independently of SettingsWindow.
func readDictationSilenceTimeout() -> Double {
    if let v = readCommandConfig()["dictationSilenceTimeout"] as? Double, v >= 0.5 { return v }
    return 1.5
}

func whisperPostProcessEnabled() -> Bool {
    readCommandConfig()["whisperPostProcess"] as? Bool ?? false
}

func whisperAvailable() -> Bool {
    return whisperPath() != nil
}

func whisperPath() -> String? {
    for p in ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli",
              "/opt/homebrew/bin/whisper", "/usr/local/bin/whisper"] {
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return nil
}

func runWhisper(audioURL: URL) -> String? {
    guard let bin = whisperPath() else { return nil }

    let promptPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".claude/state/dictation-vocab-prompt.txt")
    let prompt = (try? String(contentsOfFile: promptPath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    var args = [audioURL.path, "--model", "base", "--output-txt", "--no-timestamps", "-f", "txt"]
    if !prompt.isEmpty { args += ["--prompt", prompt] }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()

    do {
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return cleanWhisperOutput(out)
    } catch { return nil }
}

private func cleanWhisperOutput(_ raw: String) -> String {
    let lines = raw.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { line -> String in
            // Strip leading timestamp bracket like "[00:00:00.000 --> 00:00:02.000]  text"
            if line.hasPrefix("["), let end = line.range(of: "]  ") {
                return String(line[end.upperBound...])
            }
            return line
        }
    return lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
}
