import AVFAudio
import CWavPackDecoder
import Foundation
import PCMDecoding

/// A local WavPack source producing noninterleaved Float32 PCM.
///
/// The source supports finite mono/stereo integer 8/16/24/32-bit and Float32
/// streams. DSD and multichannel streams are rejected. All operations must be
/// serialized by one owner and must run outside the audio render callback.
/// Each playback slot or independent waveform reader needs a separate instance.
public final class WavPackPCMSource: PCMSource {
    private let decoder: AKFWavPackDecoder

    public var format: AVAudioFormat { decoder.format }
    public var frameLength: AVAudioFramePosition? { decoder.frameLength }
    public var framePosition: AVAudioFramePosition { decoder.framePosition }
    public var supportsSeeking: Bool { true }

    /// Whether the supplied WV stream provides lossless audio by itself.
    public var isLossless: Bool { decoder.isLossless }

    /// Opens only the supplied WV file. Adjacent WVC correction files are not
    /// accessed, so a hybrid WV file is decoded as its lossy main stream.
    public init(url: URL) throws {
        decoder = try AKFWavPackDecoder(url: url)
    }

    /// Fills the caller's matching, positive-capacity buffer; zero frames means EOF.
    public func read(into buffer: AVAudioPCMBuffer) throws {
        try decoder.read(into: buffer)
    }

    /// Accepts source positions from zero through `frameLength`, including EOF.
    public func seek(to frame: AVAudioFramePosition) throws {
        try decoder.seek(to: frame)
    }

    /// Idempotently closes the decoder and releases its file descriptor.
    public func close() {
        decoder.close()
    }
}
