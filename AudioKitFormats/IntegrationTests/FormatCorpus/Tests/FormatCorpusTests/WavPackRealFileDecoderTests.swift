import AVFAudio
import FallbackDecoders
import Foundation
import XCTest

/// Decoder contracts exercised with the downloaded, unchanged WavPack file. The WAV
/// reference is decoded independently by ffmpeg during corpus preparation.
final class WavPackRealFileDecoderTests: XCTestCase {
    func testNativeProviderRejectsTheWavPackSample() throws {
        let url = try Corpus.original("audio-test.wv")
        XCTAssertThrowsError(try AVAudioFile(forReading: url),
                             "Update the native/fallback matrix when this OS adds WavPack support")
    }

    func testChunkedReadMatchesIndependentReferenceAndRepeatedEOF() throws {
        let reference = try openReference()
        let source = try openSource()
        defer { source.close() }
        XCTAssertEqual(source.format, reference.processingFormat)
        XCTAssertEqual(source.frameLength, reference.length)
        XCTAssertGreaterThan(reference.length, 0)
        XCTAssertTrue(source.supportsSeeking)
        XCTAssertTrue(source.isLossless, "The downloaded corpus WV is an independent lossless stream")
        let output = try Corpus.buffer(format: source.format, capacity: 5003)
        let expected = try Corpus.buffer(format: reference.processingFormat, capacity: 5003)
        var position: AVAudioFramePosition = 0
        var energy = 0.0

        while position < reference.length {
            try source.read(into: output)
            let count = AVAudioFrameCount(min(5003, reference.length - position))
            XCTAssertEqual(output.frameLength, count)
            guard output.frameLength == count else {
                throw CorpusFailure.audio("WavPack stopped before its independently decoded reference")
            }
            try reference.read(into: expected, frameCount: count)
            energy += try comparePCM(output, expected, context: "Downloaded WavPack chunked decode",
                                     frameOffset: position, tolerance: 0)
            position += AVAudioFramePosition(count)
            XCTAssertEqual(source.framePosition, position)
        }
        for _ in 0 ..< 2 {
            try source.read(into: output)
            XCTAssertEqual(output.frameLength, 0)
            XCTAssertEqual(source.framePosition, position)
        }
        XCTAssertGreaterThan(energy, 0)
    }

    func testSeekAcrossDistantPositionsAndBackFromEOFMatchesReference() throws {
        let reference = try openReference()
        let source = try openSource()
        defer { source.close() }
        let length = reference.length
        let output = try Corpus.buffer(format: source.format, capacity: 137)
        let expected = try Corpus.buffer(format: reference.processingFormat, capacity: 137)
        let targets: [AVAudioFramePosition] = [
            0, min(5003, length), min(73_727, length), min(73_728, length),
            length / 2, max(0, length - 3), length, 0, min(1207, length),
        ]
        for target in targets {
            try source.seek(to: target)
            XCTAssertEqual(source.framePosition, target)
            try source.read(into: output)
            let count = AVAudioFrameCount(min(137, length - target))
            XCTAssertEqual(output.frameLength, count)
            if count > 0 {
                reference.framePosition = target
                try reference.read(into: expected, frameCount: count)
                try comparePCM(output, expected, context: "Downloaded WavPack seek",
                               frameOffset: target, tolerance: 0)
            }
        }
    }

    func testInvalidSeekPreservesTheNextDecodedSamples() throws {
        let reference = try openReference()
        let source = try openSource()
        defer { source.close() }
        let target = min(53, reference.length)
        try source.seek(to: target)
        XCTAssertThrowsError(try source.seek(to: -1))
        XCTAssertThrowsError(try source.seek(to: reference.length + 1))
        XCTAssertEqual(source.framePosition, target)
        let output = try Corpus.buffer(format: source.format, capacity: 128)
        let expected = try Corpus.buffer(format: reference.processingFormat, capacity: 128)
        try source.read(into: output)
        reference.framePosition = target
        try reference.read(into: expected, frameCount: output.frameLength)
        try comparePCM(output, expected, context: "WavPack after rejected seeks", frameOffset: target, tolerance: 0)
    }

    func testMismatchedBufferFailsWithoutAdvancing() throws {
        let reference = try openReference()
        let source = try openSource()
        defer { source.close() }
        let mismatched = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: source.format.sampleRate == 48_000 ? 44_100 : 48_000,
            channels: source.format.channelCount
        ))
        let invalid = try Corpus.buffer(format: mismatched, capacity: 128)
        XCTAssertThrowsError(try source.read(into: invalid))
        XCTAssertEqual(source.framePosition, 0)
        let output = try Corpus.buffer(format: source.format, capacity: 128)
        let expected = try Corpus.buffer(format: reference.processingFormat, capacity: 128)
        try source.read(into: output)
        try reference.read(into: expected, frameCount: output.frameLength)
        try comparePCM(output, expected, context: "WavPack after rejected buffer", frameOffset: 0, tolerance: 0)
    }

    func testCloseIsIdempotentAndReadAndSeekThenFail() throws {
        let source = try openSource()
        let buffer = try Corpus.buffer(format: source.format, capacity: 128)
        try source.read(into: buffer)
        XCTAssertGreaterThan(buffer.frameLength, 0)

        source.close()
        source.close()

        XCTAssertThrowsError(try source.read(into: buffer))
        XCTAssertEqual(buffer.frameLength, 0)
        XCTAssertThrowsError(try source.seek(to: 0))
    }

    func testTruncatedHeaderAndAudioPayloadReportErrorsInsteadOfEOF() throws {
        let original = try Data(contentsOf: Corpus.original("audio-test.wv"))
        let reference = try openReference()
        for bytes in [Data(original.prefix(24)), Data(original.prefix(original.count / 2))] {
            try withTemporaryWavPack(bytes) { url in
                let error = try decodingError(at: url, maximumFrames: reference.length)
                XCTAssertNotNil(error, "Truncated WavPack must report a decoder error, not successful EOF")
            }
        }
    }

    func testCorruptedCompressedAudioReportsAnErrorInsteadOfSilentPCM() throws {
        var bytes = try Data(contentsOf: Corpus.original("audio-test.wv"))
        let reference = try openReference()
        guard !bytes.isEmpty else { throw CorpusFailure.setup("The downloaded WavPack file is empty") }
        bytes[bytes.count / 2] ^= 0xff
        try withTemporaryWavPack(bytes) { url in
            let error = try decodingError(at: url, maximumFrames: reference.length)
            XCTAssertNotNil(error, "Corrupt WavPack must report an error instead of zero-filled audio or successful EOF")
        }
    }

    func testWavPackProviderRejectsTheRealWAVFile() throws {
        let url = try Corpus.original("audio-test.wav")
        XCTAssertThrowsError(try WavPackPCMSource(url: url))
    }

    private func openSource() throws -> WavPackPCMSource {
        try WavPackPCMSource(url: Corpus.original("audio-test.wv"))
    }

    private func openReference() throws -> AVAudioFile {
        try Corpus.open(Corpus.reference("audio-test.wv"))
    }

    private func withTemporaryWavPack(_ bytes: Data, body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wv")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    /// Only errors produced by opening/reading the decoder count as successful
    /// rejection. A test guard or a buffer allocation failure must not masquerade
    /// as a decoder error when malformed data causes unbounded output.
    private func decodingError(at url: URL, maximumFrames: AVAudioFramePosition) throws -> Error? {
        let source: WavPackPCMSource
        do {
            source = try WavPackPCMSource(url: url)
        } catch {
            return error
        }
        defer { source.close() }
        let buffer = try Corpus.buffer(format: source.format, capacity: 4096)
        var frames: AVAudioFramePosition = 0
        while frames <= maximumFrames {
            do {
                try source.read(into: buffer)
            } catch {
                return error
            }
            guard buffer.frameLength > 0 else { return nil }
            frames += AVAudioFramePosition(buffer.frameLength)
        }
        XCTFail("Malformed WavPack exceeded the original reference length without a decoder error")
        return nil
    }
}
