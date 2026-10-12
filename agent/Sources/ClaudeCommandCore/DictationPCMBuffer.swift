import AVFoundation
import CoreMedia

/// AVCapture owns sample-buffer bytes. Copy into float PCM owned by the ASR
/// pipeline before returning from its callback; never retain borrowed pointers.
public func copyDictationPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    let frames = CMSampleBufferGetNumSamples(sampleBuffer)
    guard frames > 0, frames <= 192_000,
          let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
    let format = AVAudioFormat(cmAudioFormatDescription: description)
    guard format.commonFormat == .pcmFormatFloat32,
          format.channelCount == 1, format.sampleRate > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
    ) == noErr else { return nil }
    return buffer
}
