import AVFoundation
import AudioKit
import Foundation
import PCMDecoding

/// Streams a PCM source into an AudioKit graph with a fixed-size buffer pool.
///
/// The player takes exclusive ownership of `source`. Do not read, seek, or close
/// that source after passing it to this initializer. Controls and property reads
/// are serialized with decoding; call them from a control thread, never from an
/// audio render callback. `prepare()` may block while it fills the initial pool.
/// No decoder work runs in an AVAudioPlayerNode completion callback.
///
/// Attach this node to an AudioKit graph and start its engine before `play()`.
/// A stopped seekable source restarts at frame zero. A nonseekable source supports
/// pause/resume, but cannot restart after stop has discarded read-ahead audio.
/// If decoding falls behind playback, the player reports `bufferUnderrun` and
/// stops instead of continuing with a playback clock that includes missing audio.
public final class DecodedAudioPlayer: Node {
    public enum PlaybackStatus: Equatable {
        case stopped
        case prepared
        case playing
        case paused
        case completed
        case failed
        case closed
    }

    public let outputFormat: AVAudioFormat
    public let supportsSeeking: Bool
    public let bufferFrameCapacity: AVAudioFrameCount
    public let bufferCount: Int

    public var avAudioNode: AVAudioNode { playerNode }
    public var connections: [Node] { [] }
    public var isStarted: Bool { status == .playing }
    public var status: PlaybackStatus { withWorker { playbackStatus } }
    public var currentFrame: AVAudioFramePosition { withWorker { currentFrameLocked() } }
    public var currentTime: TimeInterval { Double(currentFrame) / outputFormat.sampleRate }
    public var frameLength: AVAudioFramePosition? { withWorker { knownFrameLength } }
    public var duration: TimeInterval? {
        frameLength.map { Double($0) / outputFormat.sampleRate }
    }

    /// Delivered on the main queue after the final audio buffer finishes playing.
    /// For an engine rendering offline, completion means its final sample has
    /// been rendered; there is no physical audio output to wait for.
    /// Stop, seek, close, or restarting playback cancels an undelivered callback.
    public var completionHandler: (() -> Void)? {
        get { withWorker { storedCompletionHandler } }
        set { withWorker { storedCompletionHandler = newValue } }
    }

    /// Reports errors from `play()` and background refill on the main queue.
    /// Errors from the throwing `prepare()` and `seek(to:)` methods are thrown
    /// directly instead. Stop, seek, and close cancel undelivered callbacks.
    public var errorHandler: ((Error) -> Void)? {
        get { withWorker { storedErrorHandler } }
        set { withWorker { storedErrorHandler = newValue } }
    }

    private struct Chunk {
        let buffer: AVAudioPCMBuffer
        let startFrame: AVAudioFramePosition
        var isFinal = false

        var endFrame: AVAudioFramePosition {
            startFrame + AVAudioFramePosition(buffer.frameLength)
        }
    }

    private let source: PCMSource
    private let playerNode = AVAudioPlayerNode()
    private let worker = DispatchQueue(label: "AudioKitFormats.DecodedAudioPlayer.decoding")
    private let workerKey = DispatchSpecificKey<Bool>()
    private var allBuffers: [AVAudioPCMBuffer]
    private var freeBuffers: [AVAudioPCMBuffer]
    private var readyChunks: [Chunk] = []
    private var lookahead: Chunk?
    private var scheduledBufferCount = 0
    private var playbackStatus: PlaybackStatus = .stopped
    private var generation: UInt64 = 0
    private var isPrepared = false
    private var reachedEOF = false
    private var hasReadSource = false
    private var cannotRestartSource = false
    private var isSourceClosed = false
    private var knownFrameLength: AVAudioFramePosition?
    private var decodeFrame: AVAudioFramePosition
    private var playbackStartFrame: AVAudioFramePosition
    private var restingFrame: AVAudioFramePosition
    private var scheduledEndFrame: AVAudioFramePosition
    private var lastError: Error?
    private var storedCompletionHandler: (() -> Void)?
    private var storedErrorHandler: ((Error) -> Void)?

    /// Allocates `bufferCount + 1` buffers, including one lookahead buffer used to
    /// distinguish decoder EOF from the moment the last sample finishes playing.
    public init(source: PCMSource,
                bufferFrameCapacity: AVAudioFrameCount = 4096,
                bufferCount: Int = 4) throws {
        let format = source.format
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              format.channelCount > 0,
              format.sampleRate.isFinite,
              format.sampleRate > 0 else {
            throw DecodedAudioPlayerError.unsupportedPCMFormat
        }
        guard bufferFrameCapacity > 0, bufferCount >= 2, bufferCount < Int.max else {
            throw DecodedAudioPlayerError.invalidBufferConfiguration
        }
        guard source.framePosition >= 0,
              source.frameLength.map({ $0 >= source.framePosition }) ?? true else {
            throw DecodedAudioPlayerError.invalidSourcePosition
        }

        var buffers: [AVAudioPCMBuffer] = []
        for _ in 0 ... bufferCount {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: bufferFrameCapacity) else {
                throw DecodedAudioPlayerError.bufferAllocationFailed
            }
            buffers.append(buffer)
        }

        self.source = source
        outputFormat = format
        supportsSeeking = source.supportsSeeking
        self.bufferFrameCapacity = bufferFrameCapacity
        self.bufferCount = bufferCount
        allBuffers = buffers
        freeBuffers = buffers
        knownFrameLength = source.frameLength
        decodeFrame = source.framePosition
        playbackStartFrame = source.framePosition
        restingFrame = source.framePosition
        scheduledEndFrame = source.framePosition
        worker.setSpecific(key: workerKey, value: true)
    }

    deinit {
        withWorker { closeLocked() }
    }

    /// Fills the bounded buffer pool without needing a running audio engine.
    /// Repeated calls are idempotent until playback is stopped or repositioned.
    public func prepare() throws {
        try withWorker {
            try validatePreparationLocked()
            do {
                try prepareLocked()
                if playbackStatus == .stopped { playbackStatus = .prepared }
            } catch {
                failLocked(error, notify: false)
                throw error
            }
        }
    }

    public func start() { play() }
    public func bypass() { stop() }

    /// Starts or resumes playback. If preparation is needed, this call waits for
    /// initial decoding; use `prepare()` beforehand to control that work's timing.
    public func play() {
        withWorker {
            guard playbackStatus != .playing, playbackStatus != .closed else { return }
            do {
                guard let engine = playerNode.engine else {
                    throw DecodedAudioPlayerError.notAttachedToEngine
                }
                guard engine.isRunning else {
                    throw DecodedAudioPlayerError.engineNotRunning
                }
                if playbackStatus == .completed {
                    try rewindLocked()
                }
                try validatePreparationLocked()
                try prepareLocked()
                playbackStatus = .playing
                try scheduleReadyChunksLocked()
                if reachedEOF, scheduledBufferCount == 0 {
                    completeLocked(at: decodeFrame)
                } else {
                    playerNode.play()
                }
            } catch {
                failLocked(error, notify: true)
            }
        }
    }

    public func pause() {
        withWorker {
            guard playbackStatus == .playing else { return }
            do {
                try checkForUnderrunLocked()
            } catch {
                failLocked(error, notify: true)
                return
            }
            restingFrame = currentFrameLocked()
            playerNode.pause()
            playbackStatus = .paused
        }
    }

    /// Clears queued audio and rewinds seekable sources to frame zero.
    public func stop() {
        withWorker {
            guard playbackStatus != .closed else { return }
            do {
                try rewindLocked()
            } catch {
                failLocked(error, notify: true)
            }
        }
    }

    /// Seeks to an absolute source frame and preloads audio from that position.
    /// Playing and paused states are preserved. A stopped player stays stopped.
    public func seek(to frame: AVAudioFramePosition) throws {
        try withWorker {
            guard playbackStatus != .closed else { throw DecodedAudioPlayerError.closed }
            guard supportsSeeking else { throw DecodedAudioPlayerError.seekingUnsupported }
            guard frame >= 0, knownFrameLength.map({ frame <= $0 }) ?? true else {
                throw DecodedAudioPlayerError.invalidSeekPosition
            }

            let previousStatus = playbackStatus
            invalidateLocked()
            do {
                try source.seek(to: frame)
                guard source.framePosition == frame else {
                    throw DecodedAudioPlayerError.invalidSourcePosition
                }
                resetPositionLocked(to: frame)
                cannotRestartSource = false
                lastError = nil
                try prepareLocked()
                switch previousStatus {
                case .playing:
                    playbackStatus = .playing
                    try scheduleReadyChunksLocked()
                    if reachedEOF, scheduledBufferCount == 0 {
                        completeLocked(at: decodeFrame)
                    } else {
                        playerNode.play()
                    }
                case .paused:
                    playbackStatus = .paused
                case .stopped:
                    playbackStatus = .stopped
                default:
                    playbackStatus = .prepared
                }
            } catch {
                failLocked(error, notify: false)
                throw error
            }
        }
    }

    /// Stops playback and releases the source. Safe to call more than once.
    public func close() {
        withWorker { closeLocked() }
    }

    private func withWorker<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: workerKey) == true {
            return try operation()
        }
        return try worker.sync(execute: operation)
    }

    private func validatePreparationLocked() throws {
        guard playbackStatus != .closed else { throw DecodedAudioPlayerError.closed }
        guard !cannotRestartSource else {
            throw DecodedAudioPlayerError.cannotRestartNonseekableSource
        }
        if playbackStatus == .failed, let lastError { throw lastError }
    }

    private func prepareLocked() throws {
        guard !isPrepared else { return }
        if lookahead == nil, !reachedEOF {
            lookahead = try readChunkLocked()
        }
        try fillAvailableSlotsLocked()
        isPrepared = true
    }

    private func readChunkLocked() throws -> Chunk? {
        guard let buffer = freeBuffers.popLast() else {
            throw DecodedAudioPlayerError.bufferPoolExhausted
        }
        buffer.frameLength = 0
        let startFrame = decodeFrame
        hasReadSource = true
        do {
            try source.read(into: buffer)
        } catch {
            freeBuffers.append(buffer)
            throw error
        }
        guard buffer.frameLength > 0 else {
            freeBuffers.append(buffer)
            guard knownFrameLength.map({ $0 == decodeFrame }) ?? true else {
                throw DecodedAudioPlayerError.inconsistentFrameLength
            }
            guard source.framePosition == decodeFrame else {
                throw DecodedAudioPlayerError.invalidSourcePosition
            }
            reachedEOF = true
            if knownFrameLength == nil { knownFrameLength = decodeFrame }
            return nil
        }
        let (endFrame, overflow) = startFrame.addingReportingOverflow(AVAudioFramePosition(buffer.frameLength))
        guard !overflow else {
            freeBuffers.append(buffer)
            throw DecodedAudioPlayerError.invalidSourcePosition
        }
        guard knownFrameLength.map({ endFrame <= $0 }) ?? true else {
            freeBuffers.append(buffer)
            throw DecodedAudioPlayerError.inconsistentFrameLength
        }
        guard source.framePosition == endFrame else {
            freeBuffers.append(buffer)
            throw DecodedAudioPlayerError.invalidSourcePosition
        }
        decodeFrame = endFrame
        return Chunk(buffer: buffer, startFrame: startFrame)
    }

    private func fillAvailableSlotsLocked() throws {
        while readyChunks.count + scheduledBufferCount < bufferCount,
              var current = lookahead {
            let next = try readChunkLocked()
            current.isFinal = next == nil
            readyChunks.append(current)
            lookahead = next
        }
    }

    private func scheduleReadyChunksLocked() throws {
        if !readyChunks.isEmpty { try checkForUnderrunLocked() }
        let currentGeneration = generation
        let callbackWorker = worker
        let isRenderingOffline = playerNode.engine.map {
            $0.isInManualRenderingMode && $0.manualRenderingMode == .offline
        } ?? false
        for chunk in readyChunks {
            scheduledBufferCount += 1
            scheduledEndFrame = chunk.endFrame
            // Intermediate buffers can be recycled as soon as the player has
            // consumed their data. Only the known last buffer waits for audible
            // completion, so output latency does not delay every refill. Offline
            // rendering has no device playback, so its final buffer instead
            // completes after rendering all its frames.
            let callbackType: AVAudioPlayerNodeCompletionCallbackType = chunk.isFinal
                ? (isRenderingOffline ? .dataRendered : .dataPlayedBack) : .dataConsumed
            playerNode.scheduleBuffer(chunk.buffer,
                                      completionCallbackType: callbackType) { [weak self] _ in
                // Upgrade the weak player only on its worker. If this callback
                // held its final strong reference, releasing it here could run
                // deinit/stop on AVAudioPlayerNode's own completion queue.
                callbackWorker.async { [weak self] in
                    self?.didFinishChunkLocked(chunk, generation: currentGeneration)
                }
            }
        }
        readyChunks.removeAll(keepingCapacity: true)
    }

    private func didFinishChunkLocked(_ chunk: Chunk, generation callbackGeneration: UInt64) {
        guard callbackGeneration == generation,
              playbackStatus == .playing || playbackStatus == .paused else { return }
        scheduledBufferCount -= 1
        freeBuffers.append(chunk.buffer)
        if chunk.isFinal {
            completeLocked(at: chunk.endFrame)
            return
        }
        do {
            try fillAvailableSlotsLocked()
            if playbackStatus == .playing { try scheduleReadyChunksLocked() }
        } catch {
            failLocked(error, notify: true)
        }
    }

    private func currentFrameLocked() -> AVAudioFramePosition {
        guard playbackStatus == .playing,
              let elapsed = elapsedPlaybackFramesLocked() else { return restingFrame }
        let available = max(0, scheduledEndFrame - playbackStartFrame)
        let offset = AVAudioFramePosition(min(Double(available), elapsed))
        let frame = playbackStartFrame + offset
        return knownFrameLength.map { min(frame, $0) } ?? frame
    }

    private func elapsedPlaybackFramesLocked() -> Double? {
        guard
              let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime >= 0,
              playerTime.sampleRate > 0 else { return nil }
        return Double(playerTime.sampleTime) * outputFormat.sampleRate / playerTime.sampleRate
    }

    private func checkForUnderrunLocked() throws {
        // Once the final chunk is scheduled, silence after scheduledEndFrame is
        // normal EOF drain. In all other cases the player must never advance past
        // the scheduled source range and then resume decoding on that same clock.
        guard playerNode.isPlaying,
              !reachedEOF || lookahead != nil || !readyChunks.isEmpty,
              let elapsed = elapsedPlaybackFramesLocked() else { return }
        let scheduledFrames = Double(scheduledEndFrame - playbackStartFrame)
        guard elapsed <= scheduledFrames + 0.5 else {
            throw DecodedAudioPlayerError.bufferUnderrun
        }
    }

    private func resetPositionLocked(to frame: AVAudioFramePosition) {
        decodeFrame = frame
        playbackStartFrame = frame
        restingFrame = frame
        scheduledEndFrame = frame
    }

    private func invalidateLocked() {
        generation &+= 1
        playerNode.stop()
        readyChunks.removeAll(keepingCapacity: true)
        lookahead = nil
        scheduledBufferCount = 0
        freeBuffers = allBuffers
        isPrepared = false
        reachedEOF = false
    }

    private func rewindLocked() throws {
        let positionBeforeStop = currentFrameLocked()
        invalidateLocked()
        if supportsSeeking {
            try source.seek(to: 0)
            guard source.framePosition == 0 else {
                throw DecodedAudioPlayerError.invalidSourcePosition
            }
            resetPositionLocked(to: 0)
            cannotRestartSource = false
        } else {
            cannotRestartSource = hasReadSource
            resetPositionLocked(to: positionBeforeStop)
        }
        lastError = nil
        playbackStatus = .stopped
    }

    private func completeLocked(at frame: AVAudioFramePosition) {
        restingFrame = frame
        playbackStatus = .completed
        let completedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let handler = self.withWorker { () -> (() -> Void)? in
                guard self.generation == completedGeneration,
                      self.playbackStatus == .completed else { return nil }
                return self.storedCompletionHandler
            }
            handler?()
        }
    }

    private func failLocked(_ error: Error, notify: Bool) {
        let position = currentFrameLocked()
        invalidateLocked()
        restingFrame = position
        lastError = error
        playbackStatus = .failed
        guard notify else { return }
        let failedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let handler = self.withWorker { () -> ((Error) -> Void)? in
                guard self.generation == failedGeneration,
                      self.playbackStatus == .failed else { return nil }
                return self.storedErrorHandler
            }
            handler?(error)
        }
    }

    private func closeLocked() {
        guard !isSourceClosed else { return }
        let position = currentFrameLocked()
        invalidateLocked()
        source.close()
        isSourceClosed = true
        restingFrame = position
        playbackStatus = .closed
        storedCompletionHandler = nil
        storedErrorHandler = nil
        allBuffers.removeAll()
        freeBuffers.removeAll()
    }
}

public enum DecodedAudioPlayerError: Error, LocalizedError {
    case unsupportedPCMFormat
    case invalidBufferConfiguration
    case bufferAllocationFailed
    case invalidSourcePosition
    case inconsistentFrameLength
    case bufferPoolExhausted
    case bufferUnderrun
    case notAttachedToEngine
    case engineNotRunning
    case seekingUnsupported
    case invalidSeekPosition
    case cannotRestartNonseekableSource
    case closed

    public var errorDescription: String? {
        switch self {
        case .unsupportedPCMFormat:
            return "The source must provide noninterleaved Float32 PCM with a valid sample rate and channel count."
        case .invalidBufferConfiguration:
            return "Use a nonzero buffer capacity and at least two playback buffers."
        case .bufferAllocationFailed:
            return "A PCM playback buffer could not be allocated."
        case .invalidSourcePosition:
            return "The source reported an invalid PCM frame position."
        case .inconsistentFrameLength:
            return "The source's decoded frame count does not match its declared length."
        case .bufferPoolExhausted:
            return "No free PCM buffer is available for decoding."
        case .bufferUnderrun:
            return "Decoding did not supply audio before the playback buffers ran out."
        case .notAttachedToEngine:
            return "Attach the player to an audio engine before playing."
        case .engineNotRunning:
            return "Start the audio engine before playing."
        case .seekingUnsupported:
            return "This PCM source does not support seeking."
        case .invalidSeekPosition:
            return "The requested frame is outside the source."
        case .cannotRestartNonseekableSource:
            return "A nonseekable source cannot restart after its queued audio has been discarded."
        case .closed:
            return "The player has been closed."
        }
    }
}
