import AVFAudio

/// A finite or streaming source of decoded audio, independent of any playback engine.
///
/// One owner must serialize all access, including position reads and close. A source
/// and its mutable buffers are not Sendable. Passing a source to a player transfers
/// exclusive ownership to that player until it closes the source.
public protocol PCMSource: AnyObject {
    /// Fixed Float32, noninterleaved PCM format, valid for the lifetime of the source.
    var format: AVAudioFormat { get }

    /// Total frames, or nil when the stream's length is unknown. Zero means empty.
    var frameLength: AVAudioFramePosition? { get }

    /// Position of the next frame to decode, not the audible playback position.
    var framePosition: AVAudioFramePosition { get }

    var supportsSeeking: Bool { get }

    /// Fill up to the buffer's capacity in the source format. Set frameLength to the
    /// frames actually read. A zero-length result means EOF, never temporary starvation.
    /// Perform file I/O and decoding outside the audio render callback.
    func read(into buffer: AVAudioPCMBuffer) throws

    /// Position the next read at a frame in 0...frameLength, including EOF when known.
    /// Negative, out-of-range, or unsupported seeks must throw.
    func seek(to frame: AVAudioFramePosition) throws

    /// Release file/decoder resources. Repeated calls are harmless; reads then throw.
    func close()
}
