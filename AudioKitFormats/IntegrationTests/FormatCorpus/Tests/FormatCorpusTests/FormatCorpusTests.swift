import AudioKit
import AudioKitFormats
import AVFAudio
import FallbackDecoders
import Foundation
import XCTest

final class FormatCorpusTests: XCTestCase {
    func testNativeAACPlayback() throws { try verifyNative("audio-test.aac") }
    func testNativeAC3Playback() throws {
        try verifyNative("audio-test.ac3", requireCompletionAfterPCM: false)
    }
    func testNativeAIFPlayback() throws { try verifyNative("audio-test.aif") }
    func testNativeAIFFPlayback() throws { try verifyNative("audio-test.aiff") }
    func testNativeALACPlayback() throws { try verifyNative("audio-test.alac") }
    func testNativeFLACPlayback() throws { try verifyNative("audio-test.flac") }
    func testNativeM4APlayback() throws { try verifyNative("audio-test.m4a") }
    func testNativeMP3Playback() throws { try verifyNative("audio-test.mp3") }
    func testNativeMP4Playback() throws { try verifyNative("audio-test.mp4") }
    #if os(macOS)
    func testNativeOggVorbisPlayback() throws {
        try verifyNative("audio-test.ogg", requireCompletionAfterPCM: false)
    }

    func testNativeOggVorbisOfflineCompletionWaitsForFinalPCM() throws {
        let report = try verifyNative("audio-test.ogg", requireCompletionAfterPCM: false)
        // Keep PCM equality, EOF silence, and exactly-once delivery outside this
        // expected failure. A repaired native callback must make this test fail
        // its strict expectation, prompting removal of the documented exception.
        XCTExpectFailure("Known native AVAudioPlayerNode .dataRendered timing issue: macOS offline Ogg Vorbis completion arrives while PCM remains to render.") {
            XCTAssertNil(report.firstEarlyCompletionFrame,
                         "Native Ogg completion observed at \(String(describing: report.firstEarlyCompletionFrame)) of \(report.decodedFrames) decoded frames")
        }
    }
    #elseif os(iOS)
    func testNativeOggVorbisRejectedOnIOS() throws {
        let url = try Corpus.original("audio-test.ogg")
        XCTAssertThrowsError(try Corpus.open(url), "The iOS native provider currently rejects this Vorbis corpus file") { error in
            let nativeError = error as NSError
            XCTAssertEqual(nativeError.domain, "com.apple.coreaudio.avfaudio")
            XCTAssertEqual(nativeError.code, 1_685_348_671)
        }
    }
    #endif
    func testNativeOpusPlayback() throws { try verifyNative("audio-test.opus") }
    func testNativeWAVPlayback() throws { try verifyNative("audio-test.wav") }

    func testNativeAC3OfflineCompletionWaitsForFinalPCM() throws {
        let report = try verifyNative("audio-test.ac3", requireCompletionAfterPCM: false)
        // Only the aggregate timing assertion is expected to fail. Corrupt PCM,
        // missing completion, multiple callbacks, and render errors still fail.
        XCTExpectFailure("Known native AVAudioPlayerNode .dataRendered timing issue: macOS and iOS offline AC3 completion arrives while PCM remains to render.") {
            XCTAssertNil(report.firstEarlyCompletionFrame,
                         "Native AC3 completion observed at \(String(describing: report.firstEarlyCompletionFrame)) of \(report.decodedFrames) decoded frames")
        }
    }

    // Silent chapter fixtures are legitimate audio. Playback must preserve their
    // PCM and finish correctly; demanding nonzero energy would reject valid data.
    func testID3v23ChapterFilePlayback() throws { try verifyNative("chapters-v23.mp3", expectMusic: false) }
    func testID3v24ChapterFilePlayback() throws { try verifyNative("chapters-v24.mp3", expectMusic: false) }
    func testQuickTimeChapterFilePlayback() throws { try verifyNative("chapters-quicktime.m4a", expectMusic: false) }
    func testNoChapterFilePlayback() throws { try verifyNative("no-chapters.mp3", expectMusic: false) }
    func testReplayGainMetadataFile01Playback() throws { try verifyNative("replaygain-id3v2-01.mp3", expectMusic: false) }
    func testReplayGainMetadataFile02Playback() throws { try verifyNative("replaygain-id3v2-02.mp3", expectMusic: false) }

    func testLosslessFLACAndAIFFRenderExactlyLikeOriginalWAV() throws {
        for name in ["audio-test.flac", "audio-test.aiff"] {
            try verifyNative(name, referenceName: "audio-test.wav", tolerance: 0)
        }
    }

    func testAPEFullFilePlaybackMatchesIndependentReferenceAndCompletesOnce() throws {
        let reference = try Corpus.open(Corpus.reference("audio-test.ape"))
        let source = try APEPCMSource(url: Corpus.original("audio-test.ape"))
        let player = try DecodedAudioPlayer(source: source, bufferFrameCapacity: 4096, bufferCount: 4)
        let graph = try CorpusGraph(format: player.outputFormat, nodes: [player],
                                    synchronizeDecoding: { _ = player.status })
        defer { player.close(); graph.close() }
        XCTAssertEqual(player.outputFormat, reference.processingFormat)
        XCTAssertEqual(player.frameLength, reference.length)
        let completed = expectation(description: "All independent reference samples rendered through APE")
        completed.assertForOverFulfill = true
        var completionCount = 0
        player.completionHandler = {
            XCTAssertTrue(Thread.isMainThread)
            completionCount += 1
            completed.fulfill()
        }
        player.errorHandler = { XCTFail("APE playback failed: \($0)") }
        try player.prepare()
        player.play()

        let result = try compareUntilEOF(graph: graph, reference: reference, context: "APE vs independent reference", tolerance: 0) { frame, isFinal in
            if !isFinal { XCTAssertEqual(completionCount, 0, "APE completed with source PCM still pending at frame \(frame)") }
        }
        try renderSilence(4096, graph: graph, context: "APE EOF")

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(result.frames, reference.length)
        XCTAssertGreaterThan(result.energy, 0)
        XCTAssertEqual(player.status, .completed)
        XCTAssertEqual(player.currentFrame, result.frames)
    }

    func testAPESeekPauseResumeAndStopPreserveOriginalWAVSamples() throws {
        let reference = try Corpus.open(Corpus.reference("audio-test.ape"))
        let player = try DecodedAudioPlayer(source: APEPCMSource(url: Corpus.original("audio-test.ape")))
        let graph = try CorpusGraph(format: player.outputFormat, nodes: [player],
                                    synchronizeDecoding: { _ = player.status })
        defer { player.close(); graph.close() }
        var completions = 0
        player.completionHandler = { completions += 1 }
        player.errorHandler = { XCTFail("APE controls failed: \($0)") }
        player.play()
        try compareFrames(8192, graph: graph, reference: reference, context: "APE initial frames")
        player.pause()
        let pausedFrame = player.currentFrame
        try renderSilence(2048, graph: graph, context: "Paused APE")
        XCTAssertEqual(player.currentFrame, pausedFrame)
        player.play()
        try compareFrames(8192, graph: graph, reference: reference, context: "APE resume", startingAt: 8192)

        let target: AVAudioFramePosition = 143_327
        try player.seek(to: target)
        reference.framePosition = target
        XCTAssertEqual(player.status, .playing)
        try compareFrames(44_100 * 2, graph: graph, reference: reference, context: "APE seek", startingAt: target)
        XCTAssertEqual(completions, 0, "A canceled generation must not report EOF")
        player.stop()
        try renderSilence(2048, graph: graph, context: "Stopped APE")
        reference.framePosition = 0
        player.play()
        try compareFrames(8192, graph: graph, reference: reference, context: "APE restart")
        XCTAssertEqual(completions, 0)
    }

    func testNativePauseResumeAndSeekPreserveWAVContinuity() throws {
        let url = try Corpus.original("audio-test.wav")
        let reference = try Corpus.open(url)
        let playbackFile = try Corpus.open(url)
        let player = AudioPlayer()
        try player.load(file: playbackFile, buffered: false)
        let graph = try CorpusGraph(format: reference.processingFormat, nodes: [player])
        defer { graph.close() }
        var completions = 0
        player.completionHandler = { completions += 1 }
        player.play(completionCallbackType: .dataRendered)
        try compareFrames(8192, graph: graph, reference: reference, context: "Native initial frames")
        player.pause()
        let pausedTime = player.currentTime
        try renderSilence(2048, graph: graph, context: "Paused native player")
        XCTAssertEqual(player.currentTime, pausedTime)
        player.play(completionCallbackType: .dataRendered)
        try compareFrames(8192, graph: graph, reference: reference, context: "Native resume", startingAt: 8192)

        let targetTime = player.currentTime + 3
        let target = AVAudioFramePosition(targetTime * playbackFile.fileFormat.sampleRate)
        player.seek(time: 3)
        reference.framePosition = target
        XCTAssertEqual(player.status, .playing)
        try compareFrames(44_100 * 2, graph: graph, reference: reference, context: "Native seek", startingAt: target)
        XCTAssertEqual(completions, 0, "Seeking is not EOF")
        player.stop()
        try renderSilence(2048, graph: graph, context: "Stopped native player")
        reference.framePosition = 0
        player.play(completionCallbackType: .dataRendered)
        try compareFrames(8192, graph: graph, reference: reference, context: "Native restart")
        XCTAssertEqual(completions, 0)
    }

    func testNativeAndAPEMixedSlotsRenderThreeSecondsWithIndependentPause() throws {
        let wavURL = try Corpus.original("audio-test.wav")
        let nativeReference = try Corpus.open(wavURL)
        let apeReference = try Corpus.open(Corpus.reference("audio-test.ape"))
        let native = AudioPlayer()
        try native.load(file: Corpus.open(wavURL), buffered: false)
        let ape = try DecodedAudioPlayer(source: APEPCMSource(url: Corpus.original("audio-test.ape")))
        let format = ape.outputFormat
        let graph = try CorpusGraph(format: format, nodes: [native, ape], mixVolume: 0.5,
                                    synchronizeDecoding: { _ = ape.status })
        defer { ape.close(); graph.close() }
        let offset: AVAudioFramePosition = 44_100 * 3
        try ape.seek(to: offset)
        apeReference.framePosition = offset
        native.play(completionCallbackType: .dataRendered)
        ape.play()
        let first = try Corpus.buffer(format: format)
        let second = try Corpus.buffer(format: format)
        let expected = try Corpus.buffer(format: format)
        var energy = 0.0
        for secondIndex in 0 ..< 3 {
            if secondIndex == 1 { native.pause() }
            if secondIndex == 2 { native.play(completionCallbackType: .dataRendered) }
            var remaining: AVAudioFramePosition = 44_100
            while remaining > 0 {
                let count = AVAudioFrameCount(min(remaining, 1024))
                if secondIndex != 1 {
                    try nativeReference.read(into: first, frameCount: count)
                    XCTAssertEqual(first.frameLength, count)
                }
                try apeReference.read(into: second, frameCount: count)
                XCTAssertEqual(second.frameLength, count)
                expected.frameLength = count
                for channel in 0 ..< Int(format.channelCount) {
                    for frame in 0 ..< Int(count) {
                        let nativeSample: Float = secondIndex == 1 ? 0 : first.floatChannelData![channel][frame]
                        expected.floatChannelData![channel][frame] = (nativeSample + second.floatChannelData![channel][frame]) * 0.5
                    }
                }
                energy += try comparePCM(graph.render(count), expected, context: "Native + APE mixed slots",
                                         frameOffset: AVAudioFramePosition(secondIndex * 44_100) + 44_100 - remaining)
                remaining -= AVAudioFramePosition(count)
            }
            XCTAssertEqual(ape.status, .playing)
        }
        XCTAssertGreaterThan(energy, 0)
        XCTAssertEqual(native.status, .playing)
    }

    func testThirtyMinuteM4AHeadMiddleAndTailRenderWithoutWholeFileBuffering() throws {
        let url = try Corpus.original("samdivine-chapters-30m.m4a")
        let descriptor = try Corpus.open(url)
        let rate = descriptor.processingFormat.sampleRate
        let length = descriptor.length
        XCTAssertGreaterThan(Double(length) / rate, 1700)
        let window = AVAudioFramePosition(rate * 3)
        for requestedStart in [AVAudioFramePosition(0), length / 2, max(0, length - window)] {
            let reference = try Corpus.open(url)
            let playbackFile = try Corpus.open(url)
            let player = AudioPlayer()
            try player.load(file: playbackFile, buffered: false)
            let graph = try CorpusGraph(format: reference.processingFormat, nodes: [player])
            defer { graph.close() }
            let startTime = Double(requestedStart) / rate
            let actualStart = AVAudioFramePosition(startTime * playbackFile.fileFormat.sampleRate)
            let endTime = Double(min(length, actualStart + window)) / rate
            let actualEnd = AVAudioFramePosition(endTime * playbackFile.fileFormat.sampleRate)
            let frameCount = actualEnd - actualStart
            let completed = expectation(description: "30-minute M4A snippet at \(actualStart) completes")
            completed.assertForOverFulfill = true
            player.completionHandler = { completed.fulfill() }
            reference.framePosition = actualStart
            player.play(from: startTime, to: endTime, completionCallbackType: .dataRendered)
            // Independent AAC seeks can carry different decoder preroll. Compare
            // stable samples after 4096 frames; still render and validate that prefix.
            let scratch = try Corpus.buffer(format: reference.processingFormat)
            var warmup: AVAudioFramePosition = min(4096, frameCount)
            while warmup > 0 {
                let count = AVAudioFrameCount(min(warmup, 1024))
                try reference.read(into: scratch, frameCount: count)
                let rendered = try graph.render(count)
                for channel in 0 ..< Int(rendered.format.channelCount) {
                    for frame in 0 ..< Int(rendered.frameLength) {
                        XCTAssertTrue(rendered.floatChannelData![channel][frame].isFinite)
                    }
                }
                warmup -= AVAudioFramePosition(count)
            }
            try compareFrames(frameCount - min(4096, frameCount), graph: graph, reference: reference,
                              context: "30-minute M4A snippet at \(actualStart)", startingAt: actualStart + 4096)
            try renderSilence(4096, graph: graph, context: "M4A snippet end")
            wait(for: [completed], timeout: 2)
            XCTAssertEqual(player.status, .stopped)
            XCTAssertFalse(player.isBuffered)
        }
    }

    func testTransportStreamIsRejectedByCurrentNativeAndAPEProviders() throws {
        try verifyUnsupported("audio-test.ts")
    }

    func testWMAASFIsRejectedByCurrentNativeAndAPEProviders() throws {
        try verifyUnsupported("audio-test.wma")
    }

    @discardableResult
    private func verifyNative(_ name: String, referenceName: String? = nil,
                              expectMusic: Bool = true, tolerance: Float = 0.000_002,
                              requireCompletionAfterPCM: Bool = true) throws -> NativePlaybackReport {
        let reference = try Corpus.open(Corpus.original(referenceName ?? name))
        let playbackFile = try Corpus.open(Corpus.original(name))
        let declaredFrames = playbackFile.length
        let player = AudioPlayer()
        try player.load(file: playbackFile, buffered: false)
        let graph = try CorpusGraph(format: reference.processingFormat, nodes: [player])
        defer { graph.close() }
        XCTAssertEqual(playbackFile.processingFormat, reference.processingFormat)
        XCTAssertFalse(player.isBuffered)
        let completed = expectation(description: "\(name) audio rendered through AudioKit")
        completed.assertForOverFulfill = true
        var completionCount = 0
        player.completionHandler = {
            completionCount += 1
            completed.fulfill()
        }
        player.play(completionCallbackType: .dataRendered)

        var firstEarlyCompletionFrame: AVAudioFramePosition?
        let result = try compareUntilEOF(graph: graph, reference: reference, context: name, tolerance: tolerance) { frame, isFinal in
            if !isFinal, completionCount > 0, firstEarlyCompletionFrame == nil {
                firstEarlyCompletionFrame = frame
            }
        }
        // The schedule can include codec packet padding that AVAudioFile.read does
        // not return as PCM. It must be silent and must still finish the schedule.
        let padding = max(0, declaredFrames - result.frames)
        XCTAssertLessThanOrEqual(padding, AVAudioFramePosition(reference.processingFormat.sampleRate * 2), name)
        try renderSilence(padding + 4096, graph: graph, context: "\(name) EOF/padding")

        wait(for: [completed], timeout: 2)
        XCTAssertGreaterThan(result.frames, 0, name)
        if expectMusic { XCTAssertGreaterThan(result.energy, 0, "\(name) must render music, not merely open") }
        XCTAssertEqual(player.status, .stopped, name)
        if requireCompletionAfterPCM {
            XCTAssertNil(firstEarlyCompletionFrame,
                         "\(name) completed with source PCM still pending at frame \(String(describing: firstEarlyCompletionFrame))")
        }
        return NativePlaybackReport(decodedFrames: result.frames, firstEarlyCompletionFrame: firstEarlyCompletionFrame)
    }

    private func verifyUnsupported(_ name: String) throws {
        let url = try Corpus.original(name)
        XCTAssertThrowsError(try Corpus.open(url), "\(name): update the provider matrix if native support becomes available")
        XCTAssertThrowsError(try APEPCMSource(url: url), "An APE-only fallback must reject \(name)")
    }
}

private struct NativePlaybackReport {
    let decodedFrames: AVAudioFramePosition
    let firstEarlyCompletionFrame: AVAudioFramePosition?
}
