import AVFoundation
import ClaudeCommandCore
import FluidAudio
import Foundation

private actor TranscriptTracker {
    private var last = ""
    func update(_ text: String) { last = text }
    func value() -> String { last }
}

private func normalized(_ text: String) -> String {
    text.lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .joined(separator: " ")
}

@main
enum DictationModelProbe {
    static func main() async {
        guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 else {
            FileHandle.standardError.write(Data("usage: DictationModelProbe AUDIO_FILE EXPECTED_FINAL_WORDS [GAIN]\n".utf8))
            exit(64)
        }

        let audioURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let expected = normalized(CommandLine.arguments[2])
        let gain = CommandLine.arguments.count == 4 ? Float(CommandLine.arguments[3]) ?? 1 : 1
        guard gain > 0, gain <= 1 else {
            FileHandle.standardError.write(Data("GAIN must be greater than 0 and no more than 1\n".utf8))
            exit(64)
        }
        let modelDirectory = AsrModels.defaultCacheDirectory(for: .v3)

        do {
            guard AsrModels.modelsExist(at: modelDirectory) else {
                throw NSError(
                    domain: "DictationModelProbe", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Parakeet v3 models are not cached at \(modelDirectory.path)"]
                )
            }

            let models = try await AsrModels.load(from: modelDirectory, version: .v3)
            let manager = SlidingWindowAsrManager(config: .default)
            try await manager.loadModels(models)
            try await manager.startStreaming(source: .microphone)

            let tracker = TranscriptTracker()
            let updateTask = Task {
                for await update in await manager.transcriptionUpdates {
                    await tracker.update(update.text)
                }
            }

            let file = try AVAudioFile(forReading: audioURL)
            let format = file.processingFormat
            while file.framePosition < file.length {
                let remaining = file.length - file.framePosition
                let capacity = AVAudioFrameCount(min(Int64(4096), remaining))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                    throw NSError(
                        domain: "DictationModelProbe", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Could not allocate audio buffer"]
                    )
                }
                try file.read(into: buffer, frameCount: capacity)
                if gain < 1, let channels = buffer.floatChannelData {
                    for channel in 0..<Int(buffer.format.channelCount) {
                        for frame in 0..<Int(buffer.frameLength) {
                            channels[channel][frame] *= gain
                        }
                    }
                }
                await manager.streamAudio(buffer)
            }

            let final = try await manager.finish()
            let partial = await tracker.value()
            updateTask.cancel()
            let best = preferredDictationTranscript(final: final, lastPartial: partial)
            print("final=\(final)")
            print("lastPartial=\(partial)")
            print("preferred=\(best)")
            print("gain=\(gain)")

            guard normalized(best).contains(expected) else {
                FileHandle.standardError.write(Data("missing expected final words: \(expected)\n".utf8))
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("dictation probe failed: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }
}
