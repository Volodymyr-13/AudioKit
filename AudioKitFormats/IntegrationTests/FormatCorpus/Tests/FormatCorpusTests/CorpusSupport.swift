import AudioKit
import AVFAudio
import Foundation
import XCTest

enum CorpusFailure: Error, CustomStringConvertible {
    case setup(String)
    case audio(String)

    var description: String {
        switch self {
        case let .setup(message):
            return "Corpus setup: \(message). Run python3 AudioKitFormats/Scripts/prepare-format-corpus.py from the AudioKit checkout."
        case let .audio(message): return message
        }
    }
}

enum Corpus {
    static let originalNames = [
        "audio-test.aac", "audio-test.ac3", "audio-test.aif", "audio-test.aiff", "audio-test.ape",
        "audio-test.alac", "audio-test.flac", "audio-test.m4a", "audio-test.mp3",
        "audio-test.mp4", "audio-test.ogg", "audio-test.opus", "audio-test.ts",
        "audio-test.wav", "audio-test.wma", "chapters-quicktime.m4a", "chapters-v23.mp3",
        "chapters-v24.mp3", "no-chapters.mp3", "replaygain-id3v2-01.mp3",
        "replaygain-id3v2-02.mp3", "samdivine-chapters-30m.m4a",
    ]

    static func url(_ relativePath: String) throws -> URL {
        guard let root = Bundle.module.url(forResource: "Corpus", withExtension: nil) else {
            throw CorpusFailure.setup("The test resource bundle has no Corpus directory")
        }
        let url = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CorpusFailure.setup("Missing \(relativePath)")
        }
        return url
    }

    static func original(_ name: String) throws -> URL { try url("Original/" + name) }

    static func reference(_ name: String) throws -> URL { try url("References/" + name + ".wav") }

    static func open(_ url: URL) throws -> AVAudioFile {
        // Exercise the same native initializer used by AudioPlayer.load(url:).
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.commonFormat == .pcmFormatFloat32,
              !file.processingFormat.isInterleaved else {
            throw CorpusFailure.audio("\(url.lastPathComponent): native decoder did not provide planar Float32")
        }
        return file
    }

    static func buffer(format: AVAudioFormat, capacity: AVAudioFrameCount = 1024) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw CorpusFailure.audio("Cannot allocate a \(capacity)-frame PCM buffer")
        }
        return buffer
    }
}

/// Hardware-free rendering with fixed-size buffers. Settings must be restored
/// because the native AudioPlayer inherits Node.outputFormat from AudioKit.Settings.
/// These tests run serially; do not enable XCTest parallel execution for this suite.
final class CorpusGraph {
    let engine: AudioEngine
    let format: AVAudioFormat
    let maximumFrameCount: AVAudioFrameCount = 1024
    private let nodes: [Node]
    private let output: AVAudioPCMBuffer
    private let previousFormat: AVAudioFormat
    private let synchronizeDecoding: () -> Void
    private var isClosed = false

    init(format: AVAudioFormat, nodes: [Node], mixVolume: Float = 1,
         synchronizeDecoding: @escaping () -> Void = {}) throws {
        self.format = format
        self.nodes = nodes
        self.synchronizeDecoding = synchronizeDecoding
        previousFormat = Settings.audioFormat
        Settings.audioFormat = format
        engine = AudioEngine()
        output = try Corpus.buffer(format: format)
        do {
            engine.outputAudioFormat = format
            try engine.avEngine.enableManualRenderingMode(.offline, format: format,
                                                          maximumFrameCount: maximumFrameCount)
            if nodes.count == 1 {
                engine.output = nodes[0]
            } else {
                let mixer = Mixer(nodes)
                mixer.outputFormat = format
                mixer.volume = mixVolume
                engine.output = mixer
            }
            try engine.start()
            for node in nodes {
                _ = node.avAudioNode.lastRenderTime
                if let native = node as? AudioPlayer { _ = native.playerNode.lastRenderTime }
            }
        } catch {
            engine.stop()
            Settings.audioFormat = previousFormat
            throw error
        }
    }

    /// The returned storage is reused by the next render, so compare it immediately.
    func render(_ frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard frameCount > 0, frameCount <= maximumFrameCount else {
            throw CorpusFailure.audio("Invalid render request: \(frameCount)")
        }
        synchronizeDecoding()
        var attempts = 0
        while true {
            let status = try engine.avEngine.renderOffline(frameCount, to: output)
            if status == .success, output.frameLength == frameCount { break }
            attempts += 1
            guard status == .cannotDoInCurrentContext, attempts < 10 else {
                throw CorpusFailure.audio("Offline render returned \(status), \(output.frameLength)/\(frameCount) frames")
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        // Offline rendering may outrun asynchronous scheduleBuffer completion.
        // One millisecond per 23ms of audio services refills without wall-time playback.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        synchronizeDecoding()
        return output
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        for node in nodes { node.stop() }
        engine.stop()
        engine.avEngine.disableManualRenderingMode()
        Settings.audioFormat = previousFormat
    }

    deinit { close() }
}

@discardableResult
func comparePCM(_ actual: AVAudioPCMBuffer, _ expected: AVAudioPCMBuffer,
                context: String, frameOffset: AVAudioFramePosition,
                tolerance: Float = 0.000_002) throws -> Double {
    guard actual.format == expected.format, actual.frameLength == expected.frameLength,
          let output = actual.floatChannelData, let reference = expected.floatChannelData else {
        throw CorpusFailure.audio("\(context): PCM format or frame count mismatch")
    }
    var energy = 0.0
    for channel in 0 ..< Int(actual.format.channelCount) {
        for frame in 0 ..< Int(actual.frameLength) {
            let sample = output[channel][frame]
            let original = reference[channel][frame]
            guard sample.isFinite, original.isFinite, abs(sample - original) <= tolerance else {
                throw CorpusFailure.audio("\(context): channel \(channel), frame \(frameOffset + Int64(frame)): rendered \(sample), reference \(original)")
            }
            energy += Double(sample) * Double(sample)
        }
    }
    return energy
}

func assertSilentPCM(_ buffer: AVAudioPCMBuffer, context: String) throws {
    guard let channels = buffer.floatChannelData else { throw CorpusFailure.audio("Missing Float32 channels") }
    for channel in 0 ..< Int(buffer.format.channelCount) {
        for frame in 0 ..< Int(buffer.frameLength) {
            let value = channels[channel][frame]
            guard value.isFinite, abs(value) <= 0.000_002 else {
                throw CorpusFailure.audio("\(context): expected silence, found \(value) in channel \(channel), frame \(frame)")
            }
        }
    }
}

/// Reads EOF instead of treating AVAudioFile.length as the number of decoded
/// frames. Compressed files can report a length that includes packet padding.
func compareUntilEOF(graph: CorpusGraph, reference: AVAudioFile, context: String,
                     tolerance: Float = 0.000_002,
                     afterChunk: (AVAudioFramePosition, Bool) -> Void = { _, _ in }) throws
    -> (frames: AVAudioFramePosition, energy: Double) {
    let buffer = try Corpus.buffer(format: reference.processingFormat)
    var total: AVAudioFramePosition = 0
    var energy = 0.0
    let declaredLength = reference.length
    let maximum = AVAudioFramePosition(reference.processingFormat.sampleRate * 120)
    while true {
        try reference.read(into: buffer)
        guard buffer.frameLength > 0 else { break }
        guard total + AVAudioFramePosition(buffer.frameLength) <= maximum else {
            throw CorpusFailure.audio("\(context): full-file test exceeded its two-minute guard; long files require snippets")
        }
        energy += try comparePCM(graph.render(buffer.frameLength), buffer,
                                 context: context, frameOffset: total, tolerance: tolerance)
        total += AVAudioFramePosition(buffer.frameLength)
        // AVAudioFile may throw a nilError if read again after its final partial
        // buffer. AC3/Vorbis can end before the declared, padded frame length.
        let isFinal = buffer.frameLength < buffer.frameCapacity || total >= declaredLength
        afterChunk(total, isFinal)
        if isFinal { break }
    }
    return (total, energy)
}

func compareFrames(_ frameCount: AVAudioFramePosition, graph: CorpusGraph, reference: AVAudioFile,
                   context: String, startingAt startFrame: AVAudioFramePosition = 0) throws {
    let buffer = try Corpus.buffer(format: reference.processingFormat)
    var remaining = frameCount
    while remaining > 0 {
        let requested = AVAudioFrameCount(min(remaining, AVAudioFramePosition(buffer.frameCapacity)))
        try reference.read(into: buffer, frameCount: requested)
        guard buffer.frameLength == requested else {
            throw CorpusFailure.audio("\(context): reference reached EOF before the requested window")
        }
        try comparePCM(graph.render(requested), buffer, context: context,
                       frameOffset: startFrame + frameCount - remaining)
        remaining -= AVAudioFramePosition(requested)
    }
}

func renderSilence(_ frameCount: AVAudioFramePosition, graph: CorpusGraph, context: String) throws {
    var remaining = frameCount
    while remaining > 0 {
        let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(graph.maximumFrameCount)))
        try assertSilentPCM(graph.render(count), context: context)
        remaining -= AVAudioFramePosition(count)
    }
}
