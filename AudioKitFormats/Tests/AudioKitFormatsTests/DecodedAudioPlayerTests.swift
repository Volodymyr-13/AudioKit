import AudioKit
import AudioKitFormats
import AVFAudio
import PCMDecoding
import XCTest

final class DecodedAudioPlayerTests: XCTestCase {
    func testPrepareBoundsDecodingForAnHourLongSource() throws {
        let source = SyntheticPCMSource(frameCount: 44_100 * 3_600)
        let player = try DecodedAudioPlayer(source: source, bufferFrameCapacity: 256, bufferCount: 3)
        defer { player.close() }

        try player.prepare()

        XCTAssertEqual(player.status, .prepared)
        XCTAssertEqual(player.currentFrame, 0, "Prefetch must not advance the audible position")
        XCTAssertEqual(player.duration, 3_600)
        let observation = source.observation
        XCTAssertGreaterThan(observation.decodedFrames, 0)
        XCTAssertLessThanOrEqual(observation.decodedFrames, 256 * 4)
        XCTAssertLessThanOrEqual(observation.readCount, 4)
        XCTAssertEqual(observation.maximumConcurrentAccess, 1)
    }

    func testOfflinePlaybackPreservesSamplesAcrossRefillsAndCompletesOnce() throws {
        let source = SyntheticPCMSource(frameCount: 4_099)
        let harness = try OfflinePlayerHarness(source: source)
        defer { harness.close() }
        let completed = expectation(description: "Final audio has drained")
        completed.assertForOverFulfill = true
        var completionCount = 0
        harness.player.completionHandler = {
            XCTAssertTrue(Thread.isMainThread)
            completionCount += 1
            completed.fulfill()
        }

        try harness.player.prepare()
        harness.player.play()
        let beforeLastFrame = try harness.render(frameCount: 4_098)
        XCTAssertEqual(completionCount, 0, "Decoder EOF must not finish playback before the final sample")
        let lastFrameAndTail = try harness.render(frameCount: 1 + 512)
        let output = zip(beforeLastFrame, lastFrameAndTail).map { $0.0 + $0.1 }

        assertSamples(output, sourceStart: 0, audioFrameCount: 4_099)
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(harness.player.status, .completed)
        XCTAssertEqual(harness.player.currentFrame, 4_099)
        XCTAssertEqual(source.observation.decodedFrames, 4_099)
        XCTAssertGreaterThan(source.observation.readCount, 4)
        XCTAssertLessThanOrEqual(source.observation.mainThreadReadCount, 4, "Only explicit preparation may read on the caller's thread")
        XCTAssertEqual(source.observation.maximumConcurrentAccess, 1)
        _ = try harness.render(frameCount: 256)
    }

    func testPauseResumesAtTheAudibleFrame() throws {
        let source = SyntheticPCMSource(frameCount: 8_192)
        let harness = try OfflinePlayerHarness(source: source)
        defer { harness.close() }
        harness.player.play()

        assertSamples(try harness.render(frameCount: 256), sourceStart: 0)
        assertPosition(harness.player, near: 256)
        harness.player.pause()
        let pausedFrame = harness.player.currentFrame
        XCTAssertEqual(harness.player.status, .paused)
        assertSilence(try harness.render(frameCount: 512))
        XCTAssertEqual(harness.player.currentFrame, pausedFrame)

        harness.player.play()
        assertSamples(try harness.render(frameCount: 512), sourceStart: 256)
        assertPosition(harness.player, near: 768)
    }

    func testPausedSeekDiscardsPrefetchedAudioAndStaysPaused() throws {
        let source = SyntheticPCMSource(frameCount: 16_384)
        let harness = try OfflinePlayerHarness(source: source)
        defer { harness.close() }
        harness.player.play()
        _ = try harness.render(frameCount: 128)
        harness.player.pause()

        try harness.player.seek(to: 10_003)

        XCTAssertEqual(harness.player.status, .paused)
        XCTAssertEqual(harness.player.currentFrame, 10_003)
        assertSilence(try harness.render(frameCount: 128))
        harness.player.play()
        assertSamples(try harness.render(frameCount: 512), sourceStart: 10_003)
        assertPosition(harness.player, near: 10_515)
    }

    func testPlayingSeekContinuesFromTheNewFrame() throws {
        let source = SyntheticPCMSource(frameCount: 16_384)
        let harness = try OfflinePlayerHarness(source: source)
        defer { harness.close() }
        harness.player.play()
        _ = try harness.render(frameCount: 384)

        try harness.player.seek(to: 7_013)

        XCTAssertEqual(harness.player.status, .playing)
        assertSamples(try harness.render(frameCount: 1_280), sourceStart: 7_013)
        assertPosition(harness.player, near: 8_293)
    }

    func testStopInvalidatesScheduledAudioAndReplaysFromTheBeginning() throws {
        let source = SyntheticPCMSource(frameCount: 1_025)
        let harness = try OfflinePlayerHarness(source: source)
        defer { harness.close() }
        var completionCount = 0
        harness.player.completionHandler = { completionCount += 1 }
        harness.player.play()
        _ = try harness.render(frameCount: 384)

        harness.player.stop()

        XCTAssertEqual(harness.player.status, .stopped)
        XCTAssertEqual(harness.player.currentFrame, 0)
        assertSilence(try harness.render(frameCount: 256))
        XCTAssertEqual(completionCount, 0, "Cancellation is not successful completion")
        harness.player.play()
        assertSamples(try harness.render(frameCount: 512), sourceStart: 0)
        XCTAssertEqual(completionCount, 0, "Old callbacks must not complete the new playback")
    }

    func testUnknownLengthUsesEOFAndDrainsItsFinalPartialBuffer() throws {
        let source = SyntheticPCMSource(frameCount: 765, reportsLength: false)
        let harness = try OfflinePlayerHarness(source: source)
        defer { harness.close() }
        let completed = expectation(description: "Unknown-length EOF drained")
        harness.player.completionHandler = { completed.fulfill() }
        XCTAssertNil(harness.player.frameLength)
        XCTAssertNil(harness.player.duration)

        harness.player.play()
        assertSamples(try harness.render(frameCount: 765 + 512), sourceStart: 0, audioFrameCount: 765)

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(harness.player.status, .completed)
        XCTAssertEqual(harness.player.currentFrame, 765)
        XCTAssertEqual(source.observation.decodedFrames, 765)
    }

    func testUnsupportedSeekDoesNotDiscardAUsablePreparedStream() throws {
        let source = SyntheticPCMSource(frameCount: 2_048, supportsSeeking: false)
        let harness = try OfflinePlayerHarness(source: source)
        defer { harness.close() }
        try harness.player.prepare()

        XCTAssertThrowsError(try harness.player.seek(to: 100))

        XCTAssertEqual(harness.player.status, .prepared)
        XCTAssertEqual(harness.player.currentFrame, 0)
        harness.player.play()
        assertSamples(try harness.render(frameCount: 512), sourceStart: 0)
    }

    func testInvalidSeekDoesNotDiscardTheCurrentPlayback() throws {
        let source = SyntheticPCMSource(frameCount: 4_096)
        let harness = try OfflinePlayerHarness(source: source)
        defer { harness.close() }
        harness.player.play()
        _ = try harness.render(frameCount: 128)

        XCTAssertThrowsError(try harness.player.seek(to: -1))
        XCTAssertThrowsError(try harness.player.seek(to: 4_097))

        XCTAssertEqual(harness.player.status, .playing)
        assertSamples(try harness.render(frameCount: 512), sourceStart: 128)
    }

    func testPrepareFailureIsReportedAndCloseIsIdempotent() throws {
        let source = SyntheticPCMSource(frameCount: 1_024, failOnRead: 0)
        let player = try DecodedAudioPlayer(source: source, bufferFrameCapacity: 256, bufferCount: 3)

        XCTAssertThrowsError(try player.prepare())
        XCTAssertEqual(player.status, .failed)
        player.close()
        player.close()

        XCTAssertEqual(player.status, .closed)
        XCTAssertEqual(source.observation.closeCount, 1)
        XCTAssertThrowsError(try player.prepare())
        XCTAssertThrowsError(try player.seek(to: 0))
    }

    func testNonseekableStreamReportsFailureWhenRestartWouldLoseAudio() throws {
        let source = SyntheticPCMSource(frameCount: 4_096, supportsSeeking: false)
        let harness = try OfflinePlayerHarness(source: source)
        defer { harness.close() }
        harness.player.play()
        _ = try harness.render(frameCount: 128)
        harness.player.stop()
        XCTAssertEqual(harness.player.status, .stopped)
        XCTAssertThrowsError(try harness.player.prepare())
        let failed = expectation(description: "A discarded nonseekable stream cannot restart")
        harness.player.errorHandler = { _ in
            XCTAssertTrue(Thread.isMainThread)
            failed.fulfill()
        }

        harness.player.play()

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(harness.player.status, .failed)
        assertSilence(try harness.render(frameCount: 128))
    }

    func testRefillFailureStopsPlaybackAndDoesNotReportCompletion() throws {
        let source = SyntheticPCMSource(frameCount: 8_192, failOnRead: 4)
        let harness = try OfflinePlayerHarness(source: source)
        defer { harness.close() }
        let failed = expectation(description: "Background read error reaches the control thread")
        failed.assertForOverFulfill = true
        var completionCount = 0
        harness.player.completionHandler = { completionCount += 1 }
        harness.player.errorHandler = { _ in
            XCTAssertTrue(Thread.isMainThread)
            failed.fulfill()
        }
        try harness.player.prepare()
        XCTAssertEqual(harness.player.status, .prepared)

        harness.player.play()
        _ = try harness.render(frameCount: 1_024)

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(harness.player.status, .failed)
        XCTAssertEqual(completionCount, 0)
        assertSilence(try harness.render(frameCount: 128))
    }

    func testEmptySourceCompletesWithoutRenderingAnySamples() throws {
        let source = SyntheticPCMSource(frameCount: 0)
        let harness = try OfflinePlayerHarness(source: source)
        defer { harness.close() }
        let completed = expectation(description: "Empty playback completes")
        harness.player.completionHandler = { completed.fulfill() }
        try harness.player.prepare()
        XCTAssertEqual(harness.player.status, .prepared)

        harness.player.play()

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(harness.player.status, .completed)
        XCTAssertEqual(harness.player.currentFrame, 0)
        assertSilence(try harness.render(frameCount: 128))
    }

    func testDecoderStarvationReportsUnderrunInsteadOfSilentlySkippingAudio() throws {
        let decodingBlocked = expectation(description: "Background read waits on the test gate")
        let gate = ReadGate { decodingBlocked.fulfill() }
        let source = SyntheticPCMSource(frameCount: 8_192, blockOnRead: 4, readGate: gate)
        let harness = try OfflinePlayerHarness(source: source)
        defer {
            gate.open()
            harness.close()
        }
        let failed = expectation(description: "The exhausted playback queue reports an underrun")
        harness.player.errorHandler = { error in
            XCTAssertTrue(Thread.isMainThread)
            guard let playerError = error as? DecodedAudioPlayerError,
                  case .bufferUnderrun = playerError else {
                XCTFail("Expected an underrun, received \(error)")
                failed.fulfill()
                return
            }
            failed.fulfill()
        }
        try harness.player.prepare()
        harness.player.play()
        // Deliberately avoid the worker barrier while its read is blocked.
        _ = try harness.render(frameCount: 512, synchronizingDecoder: false)
        wait(for: [decodingBlocked], timeout: 2)
        _ = try harness.render(frameCount: 2_048, synchronizingDecoder: false)

        gate.open()

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(harness.player.status, .failed)
        assertSilence(try harness.render(frameCount: 128))
    }

    func testPrematureEOFDoesNotSilentlyShortenAKnownLengthSource() throws {
        let source = SyntheticPCMSource(frameCount: 600, reportedFrameCount: 601)
        let player = try DecodedAudioPlayer(source: source, bufferFrameCapacity: 256, bufferCount: 3)
        defer { player.close() }

        XCTAssertThrowsError(try player.prepare()) { error in
            guard let playerError = error as? DecodedAudioPlayerError,
                  case .inconsistentFrameLength = playerError else {
                return XCTFail("Expected a length mismatch, received \(error)")
            }
        }

        XCTAssertEqual(player.status, .failed)
    }

    func testExtraDecodedFramesDoNotSilentlyExtendAKnownLengthSource() throws {
        let source = SyntheticPCMSource(frameCount: 600, reportedFrameCount: 599)
        let player = try DecodedAudioPlayer(source: source, bufferFrameCapacity: 256, bufferCount: 3)
        defer { player.close() }

        XCTAssertThrowsError(try player.prepare()) { error in
            guard let playerError = error as? DecodedAudioPlayerError,
                  case .inconsistentFrameLength = playerError else {
                return XCTFail("Expected a length mismatch, received \(error)")
            }
        }

        XCTAssertEqual(player.status, .failed)
    }

    private func assertPosition(
        _ player: DecodedAudioPlayer,
        near renderedFrame: AVAudioFramePosition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // AVAudioPlayerNode's lastRenderTime can identify the start of the most
        // recent quantum, so reported playback position may trail it by 64 frames.
        let currentFrame = player.currentFrame
        XCTAssertGreaterThanOrEqual(currentFrame, renderedFrame - 64, file: file, line: line)
        XCTAssertLessThanOrEqual(currentFrame, renderedFrame, file: file, line: line)
    }

    private func assertSamples(
        _ channels: [[Float]],
        sourceStart: Int,
        audioFrameCount: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(channels.count, 2, file: file, line: line)
        for (channel, samples) in channels.enumerated() {
            let count = audioFrameCount ?? samples.count
            for (offset, sample) in samples.enumerated() {
                let expected = offset < count
                    ? SyntheticPCMSource.sample(at: sourceStart + offset, channel: channel)
                    : 0
                if !sample.isFinite || abs(sample - expected) > 0.000_001 {
                    XCTFail("Channel \(channel), output frame \(offset): \(sample), expected \(expected)", file: file, line: line)
                    return
                }
            }
        }
    }

    private func assertSilence(_ channels: [[Float]], file: StaticString = #filePath, line: UInt = #line) {
        for samples in channels {
            XCTAssertTrue(samples.allSatisfy { abs($0) <= 0.000_001 }, file: file, line: line)
        }
    }
}

/// Drives the actual AudioKit graph without opening audio hardware. Small paced
/// slices give Apple's asynchronous scheduleBuffer completions time to reach the
/// decoder worker; offline rendering otherwise outruns a bounded streaming queue.
private final class OfflinePlayerHarness {
    let engine = AudioEngine()
    let player: DecodedAudioPlayer
    private let renderBuffer: AVAudioPCMBuffer

    init(source: PCMSource) throws {
        let sourceFormat = source.format
        player = try DecodedAudioPlayer(source: source, bufferFrameCapacity: 256, bufferCount: 3)
        renderBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 64)!
        engine.outputAudioFormat = sourceFormat
        try engine.avEngine.enableManualRenderingMode(.offline, format: sourceFormat, maximumFrameCount: 64)
        engine.output = player
        try engine.start()
        _ = player.avAudioNode.lastRenderTime
    }

    func render(frameCount: Int, synchronizingDecoder: Bool = true) throws -> [[Float]] {
        var result = Array(repeating: [Float](), count: Int(renderBuffer.format.channelCount))
        var remaining = frameCount
        while remaining > 0 {
            if synchronizingDecoder {
                _ = player.status
            }
            let count = AVAudioFrameCount(min(remaining, Int(renderBuffer.frameCapacity)))
            let status = try engine.avEngine.renderOffline(count, to: renderBuffer)
            guard status == .success, renderBuffer.frameLength == count else {
                throw RenderingError.unsuccessfulRender(status, renderBuffer.frameLength)
            }
            for channel in result.indices {
                result[channel].append(contentsOf: UnsafeBufferPointer(start: renderBuffer.floatChannelData![channel], count: Int(count)))
            }
            remaining -= Int(count)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
        }
        if synchronizingDecoder {
            _ = player.status
        }
        return result
    }

    func close() {
        player.close()
        engine.stop()
        engine.avEngine.disableManualRenderingMode()
    }

    private enum RenderingError: Error {
        case unsuccessfulRender(AVAudioEngineManualRenderingStatus, AVAudioFrameCount)
    }
}

private final class SyntheticPCMSource: PCMSource {
    struct Observation {
        var decodedFrames = 0
        var readCount = 0
        var closeCount = 0
        var mainThreadReadCount = 0
        var maximumConcurrentAccess = 0
    }

    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let frameLength: AVAudioFramePosition?
    let supportsSeeking: Bool
    private(set) var framePosition: AVAudioFramePosition = 0
    private let frameCount: Int
    private let failOnRead: Int?
    private let blockOnRead: Int?
    private let readGate: ReadGate?
    private let lock = NSLock()
    private var recorded = Observation()
    private var activeAccessCount = 0
    private var isClosed = false

    var observation: Observation {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    init(
        frameCount: Int,
        reportsLength: Bool = true,
        reportedFrameCount: Int? = nil,
        supportsSeeking: Bool = true,
        failOnRead: Int? = nil,
        blockOnRead: Int? = nil,
        readGate: ReadGate? = nil
    ) {
        self.frameCount = frameCount
        frameLength = reportsLength ? AVAudioFramePosition(reportedFrameCount ?? frameCount) : nil
        self.supportsSeeking = supportsSeeking
        self.failOnRead = failOnRead
        self.blockOnRead = blockOnRead
        self.readGate = readGate
    }

    func read(into buffer: AVAudioPCMBuffer) throws {
        beginAccess()
        defer { endAccess() }
        guard !isClosed else { throw SourceError.closed }
        lock.lock()
        let readIndex = recorded.readCount
        recorded.readCount += 1
        if Thread.isMainThread { recorded.mainThreadReadCount += 1 }
        lock.unlock()
        if readIndex == failOnRead { throw SourceError.injectedFailure }
        if readIndex == blockOnRead { readGate?.waitUntilOpened() }
        let count = min(Int(buffer.frameCapacity), frameCount - Int(framePosition))
        for channel in 0 ..< Int(format.channelCount) {
            for frame in 0 ..< count {
                buffer.floatChannelData![channel][frame] = Self.sample(at: Int(framePosition) + frame, channel: channel)
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        framePosition += AVAudioFramePosition(count)
        lock.lock()
        recorded.decodedFrames += count
        lock.unlock()
    }

    func seek(to frame: AVAudioFramePosition) throws {
        beginAccess()
        defer { endAccess() }
        guard !isClosed else { throw SourceError.closed }
        guard supportsSeeking, frame >= 0, frame <= AVAudioFramePosition(frameCount) else { throw SourceError.invalidSeek }
        framePosition = frame
    }

    func close() {
        beginAccess()
        defer { endAccess() }
        guard !isClosed else { return }
        isClosed = true
        lock.lock()
        recorded.closeCount += 1
        lock.unlock()
    }

    static func sample(at frame: Int, channel: Int) -> Float {
        let value = Float(frame % 127 + 1) / 256
        return channel == 0 ? value : -value
    }

    private func beginAccess() {
        lock.lock()
        activeAccessCount += 1
        recorded.maximumConcurrentAccess = max(recorded.maximumConcurrentAccess, activeAccessCount)
        lock.unlock()
    }

    private func endAccess() {
        lock.lock()
        activeAccessCount -= 1
        lock.unlock()
    }

    private enum SourceError: Error {
        case closed
        case invalidSeek
        case injectedFailure
    }
}

private final class ReadGate {
    private let semaphore = DispatchSemaphore(value: 0)
    private let onWait: () -> Void

    init(onWait: @escaping () -> Void) {
        self.onWait = onWait
    }

    func waitUntilOpened() {
        onWait()
        // A bounded gate keeps a failed assertion from hanging the entire suite.
        _ = semaphore.wait(timeout: .now() + 5)
    }

    func open() { semaphore.signal() }
}
