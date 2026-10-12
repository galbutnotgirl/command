import XCTest
import AVFoundation
import CoreMedia
@testable import ClaudeCommandCore

final class DictationPCMBufferTests: XCTestCase {
    private func sample(bytes: [UInt8], format: AVAudioFormat, frames: Int) throws -> (CMSampleBuffer, CMBlockBuffer) {
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block
        ), noErr)
        let ownedBlock = try XCTUnwrap(block)
        XCTAssertEqual(bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: ownedBlock,
                                          offsetIntoDestination: 0, dataLength: bytes.count)
        }, noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(format.sampleRate)),
                                       presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = Int(format.streamDescription.pointee.mBytesPerFrame)
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: ownedBlock,
            formatDescription: format.formatDescription, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result
        ), noErr)
        return (try XCTUnwrap(result), ownedBlock)
    }

    func testCopiesRealFloatSamplesAndSurvivesSourceReuse() throws {
        let values: [Float] = [0.125, -0.5, 0.75, -0.25]
        let bytes = values.withUnsafeBytes { Array($0) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 24_000, channels: 1, interleaved: false))
        let (input, block) = try sample(bytes: bytes, format: format, frames: values.count)
        let copied = try XCTUnwrap(copyDictationPCMBuffer(input))
        XCTAssertEqual(copied.frameLength, 4)
        XCTAssertEqual(copied.format.sampleRate, 24_000)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block,
                                                offsetIntoDestination: 0, dataLength: bytes.count), noErr)
        let channel = try XCTUnwrap(copied.floatChannelData?[0])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channel, count: 4)), values)
    }

    func testRejectsIntegerAudioBeforeFeedingFloatOnlyASR() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 48_000, channels: 1, interleaved: false))
        let (input, _) = try sample(bytes: [1, 0, 2, 0], format: format, frames: 2)
        XCTAssertNil(copyDictationPCMBuffer(input))
    }
}
