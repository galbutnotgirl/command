import XCTest
@testable import ClaudeCommandCore

final class DictationAudioExecutorTests: XCTestCase {
    @MainActor
    func testSlowNativeOpenLeavesMainActorResponsive() async throws {
        let worker = DictationAudioExecutor(label: "test.audio.slow-open")
        let began = expectation(description: "native open began")
        let finished = expectation(description: "native open completed")
        let operation = Task {
            try await worker.perform {
                XCTAssertFalse(Thread.isMainThread)
                began.fulfill()
                Thread.sleep(forTimeInterval: 0.25)
                finished.fulfill()
                return 7
            }
        }
        await fulfillment(of: [began], timeout: 1)
        // This main-actor work must finish while the native call is blocked.
        let start = Date()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.15)
        let result = try await operation.value
        XCTAssertEqual(result, 7)
        await fulfillment(of: [finished], timeout: 1)
    }

    func testCleanupWaitsBehindNativeOpenAndErrorsDoNotPoisonQueue() async throws {
        let worker = DictationAudioExecutor(label: "test.audio.order")
        let began = expectation(description: "open began")
        let release = DispatchSemaphore(value: 0)
        worker.enqueue {
            began.fulfill()
            _ = release.wait(timeout: .now() + 1)
        }
        await fulfillment(of: [began], timeout: 1)
        enum OpenError: Error { case unavailable }
        release.signal()
        do {
            _ = try await worker.perform { throw OpenError.unavailable }
            XCTFail("Expected native failure")
        } catch OpenError.unavailable { }
        let cleaned = try await worker.perform { true }
        XCTAssertTrue(cleaned)
    }
}
