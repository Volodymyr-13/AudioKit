import AVFAudio
import CAPEDecoder
import Foundation
import PCMDecoding

/// A seekable local Monkey's Audio source for an external PCM player or offline reader.
///
/// All operations, including `close()`, must be serialized by one owner. Decoding
/// and integer-to-float conversion perform file I/O and belong off the audio thread.
/// Each playback slot or waveform reader needs its own instance.
public final class APEPCMSource: PCMSource {
    private let decoder: AKFAPEDecoder

    public var format: AVAudioFormat { decoder.format }
    public var frameLength: AVAudioFramePosition? { decoder.frameLength }
    public var framePosition: AVAudioFramePosition { decoder.framePosition }
    public var supportsSeeking: Bool { true }

    /// Opens a local mono/stereo APE file and reports unsupported or damaged input as an error.
    public init(url: URL) throws {
        decoder = try AKFAPEDecoder(url: url)
    }

    /// Fills the caller's buffer, returning zero frames only at EOF.
    /// The buffer must have positive capacity and match `format`.
    public func read(into buffer: AVAudioPCMBuffer) throws {
        try decoder.read(into: buffer)
    }

    /// Accepts positions from zero through `frameLength`, including EOF.
    public func seek(to frame: AVAudioFramePosition) throws {
        try decoder.seek(to: frame)
    }

    /// Idempotently releases the decoder and file descriptor.
    public func close() {
        decoder.close()
    }
}
