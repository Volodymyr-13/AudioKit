import AudioKitFormats
import AVFAudio
import FallbackDecoders
import Foundation
import XCTest

final class WavPackPlaybackTests: XCTestCase {
    func testFullFilePlaybackMatchesIndependentReferenceAndCompletesAfterPCM() throws {
        let reference = try Corpus.open(Corpus.reference("audio-test.wv"))
        let source = try WavPackPCMSource(url: Corpus.original("audio-test.wv"))
        XCTAssertTrue(source.isLossless)
        let player = try DecodedAudioPlayer(source: source, bufferFrameCapacity: 4096, bufferCount: 4)
        let graph = try CorpusGraph(format: player.outputFormat, nodes: [player],
                                    synchronizeDecoding: { _ = player.status })
        defer { player.close(); graph.close() }
        XCTAssertEqual(player.outputFormat, reference.processingFormat)
        XCTAssertEqual(player.frameLength, reference.length)
        let completed = expectation(description: "All independently decoded WavPack samples rendered")
        completed.assertForOverFulfill = true
        var completionCount = 0
        player.completionHandler = {
            XCTAssertTrue(Thread.isMainThread)
            completionCount += 1
            completed.fulfill()
        }
        player.errorHandler = { XCTFail("WavPack playback failed: \($0)") }
        try player.prepare()
        player.play()

        let result = try compareUntilEOF(graph: graph, reference: reference,
                                         context: "WavPack vs independent reference", tolerance: 0) { frame, isFinal in
            if !isFinal {
                XCTAssertEqual(completionCount, 0, "WavPack completed while source PCM remained at frame \(frame)")
            }
        }
        try renderSilence(4096, graph: graph, context: "WavPack EOF")

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(result.frames, reference.length)
        XCTAssertGreaterThan(result.energy, 0)
        XCTAssertEqual(player.status, .completed)
        XCTAssertEqual(player.currentFrame, result.frames)
    }

    func testPauseSeekResumeAndRestartPreserveIndependentReferenceSamples() throws {
        let reference = try Corpus.open(Corpus.reference("audio-test.wv"))
        let player = try DecodedAudioPlayer(source: WavPackPCMSource(url: Corpus.original("audio-test.wv")))
        let graph = try CorpusGraph(format: player.outputFormat, nodes: [player],
                                    synchronizeDecoding: { _ = player.status })
        defer { player.close(); graph.close() }
        var completionCount = 0
        player.completionHandler = { completionCount += 1 }
        player.errorHandler = { XCTFail("WavPack controls failed: \($0)") }
        player.play()
        try compareFrames(8192, graph: graph, reference: reference, context: "WavPack initial frames")

        player.pause()
        let pausedFrame = player.currentFrame
        try renderSilence(2048, graph: graph, context: "Paused WavPack")
        XCTAssertEqual(player.currentFrame, pausedFrame)
        player.play()
        try compareFrames(8192, graph: graph, reference: reference,
                          context: "WavPack resumed frames", startingAt: 8192)

        let target = AVAudioFramePosition(player.outputFormat.sampleRate * 3) + 137
        try player.seek(to: target)
        reference.framePosition = target
        XCTAssertEqual(player.status, .playing)
        try compareFrames(AVAudioFramePosition(player.outputFormat.sampleRate * 2),
                          graph: graph, reference: reference, context: "WavPack seek", startingAt: target)
        XCTAssertEqual(completionCount, 0, "Seek must invalidate the outgoing playback generation")

        player.stop()
        XCTAssertEqual(player.currentFrame, 0)
        try renderSilence(2048, graph: graph, context: "Stopped WavPack")
        reference.framePosition = 0
        player.play()
        try compareFrames(8192, graph: graph, reference: reference, context: "WavPack restart")
        XCTAssertEqual(completionCount, 0)
    }

    func testWavPackAndAPEMixedSlotsRenderThreeSecondsAndPauseIndependently() throws {
        let wavPackReference = try Corpus.open(Corpus.reference("audio-test.wv"))
        let apeReference = try Corpus.open(Corpus.reference("audio-test.ape"))
        let wavPack = try DecodedAudioPlayer(source: WavPackPCMSource(url: Corpus.original("audio-test.wv")))
        let ape = try DecodedAudioPlayer(source: APEPCMSource(url: Corpus.original("audio-test.ape")))
        let format = wavPack.outputFormat
        XCTAssertEqual(ape.outputFormat, format)
        XCTAssertEqual(wavPackReference.processingFormat, format)
        XCTAssertEqual(apeReference.processingFormat, format)
        let graph = try CorpusGraph(format: format, nodes: [wavPack, ape], mixVolume: 0.5) {
            _ = wavPack.status
            _ = ape.status
        }
        defer { wavPack.close(); ape.close(); graph.close() }
        var completionCount = 0
        wavPack.completionHandler = { completionCount += 1 }
        ape.completionHandler = { completionCount += 1 }
        wavPack.errorHandler = { XCTFail("Mixed WavPack slot failed: \($0)") }
        ape.errorHandler = { XCTFail("Mixed APE slot failed: \($0)") }
        let framesPerSecond = AVAudioFramePosition(format.sampleRate)
        let offset = framesPerSecond * 3
        try ape.seek(to: offset)
        apeReference.framePosition = offset
        wavPack.play()
        ape.play()

        let first = try Corpus.buffer(format: format)
        let second = try Corpus.buffer(format: format)
        let expected = try Corpus.buffer(format: format)
        var energy = 0.0
        for secondIndex in 0 ..< 3 {
            if secondIndex == 1 { wavPack.pause() }
            if secondIndex == 2 { wavPack.play() }
            var remaining = framesPerSecond
            while remaining > 0 {
                let count = AVAudioFrameCount(min(remaining, 1024))
                if secondIndex != 1 {
                    try wavPackReference.read(into: first, frameCount: count)
                    XCTAssertEqual(first.frameLength, count)
                }
                try apeReference.read(into: second, frameCount: count)
                XCTAssertEqual(second.frameLength, count)
                expected.frameLength = count
                for channel in 0 ..< Int(format.channelCount) {
                    for frame in 0 ..< Int(count) {
                        let wavPackSample: Float = secondIndex == 1 ? 0 : first.floatChannelData![channel][frame]
                        expected.floatChannelData![channel][frame] = (wavPackSample + second.floatChannelData![channel][frame]) * 0.5
                    }
                }
                energy += try comparePCM(graph.render(count), expected, context: "WavPack + APE independent slots",
                                         frameOffset: AVAudioFramePosition(secondIndex) * framesPerSecond + framesPerSecond - remaining)
                remaining -= AVAudioFramePosition(count)
            }
            XCTAssertEqual(ape.status, .playing)
            XCTAssertEqual(wavPack.status, secondIndex == 1 ? .paused : .playing)
            XCTAssertEqual(completionCount, 0)
        }
        XCTAssertGreaterThan(energy, 0)
    }
}
