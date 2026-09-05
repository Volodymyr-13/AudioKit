# AudioKitFormats

An optional AudioKit extension for audio files that need an external decoder.
Monkey's Audio (APE) and WavPack are exposed as local, seekable PCM sources.
The parent AudioKit package has no dependency on this package.

## Package boundaries

| Product | Responsibility | Dependencies |
| --- | --- | --- |
| `PCMDecoding` | Serialized PCM source contract | AVFAudio |
| `FallbackDecoders` | APE and WavPack decoding into planar Float32 PCM | PCMDecoding, CXXMonkeysAudio 12.13.0, wavpack-binary-xcframework 0.2.0 |
| `AudioKitFormats` | Bounded-buffer playback through an AudioKit Node | PCMDecoding, AudioKit |

The player does not depend on a particular codec. Providers are constructed
explicitly; importing a product does not register a decoder or change another
player's behavior. SFBAudioEngine's TagLib dependency, player, metadata-editing,
encoder/converter layers, and global decoder registry are not included. The
upstream MAC package retains its own container handling and bundled codec sources.

This directory is a separate Swift package so it can later be moved to its own
repository. It uses AudioKit's public Node API and declares AudioKit as a package
dependency. This directory's `Package.swift` is the package entry point. It
resolves AudioKit independently. See `VALIDATION.md` for the Xcode UI issue
encountered during development and the command-line validation that completed.

While it lives in this checkout, another local package can depend on
`.package(path: "../AudioKit/AudioKitFormats")` and select the `AudioKitFormats`
and `FallbackDecoders` products. A remote consumer will need this directory
published as a separate repository root; the parent AudioKit repository URL
continues to expose only the original AudioKit package.

The package has two external codec dependencies. Selecting only the player
product avoids linking the codec adapters, but does not promise to avoid SwiftPM
resolving/downloading dependencies declared by this manifest. Independent codec
packages can be split out when adding independently selectable formats.

## Usage

```swift
import AudioKit
import AudioKitFormats
import FallbackDecoders
import AVFAudio

let source = try APEPCMSource(url: fileURL)
let sampleRate = source.format.sampleRate
let player = try DecodedAudioPlayer(source: source)
let engine = AudioEngine()
engine.output = player // Or insert player into the existing effects/mixer graph.
try player.prepare()
try engine.start()
player.play()

// Seek is expressed in source frames.
try player.seek(to: AVAudioFramePosition(10 * sampleRate))
player.pause()
player.play()

// Release the decoder when the slot is discarded.
player.close()
engine.stop()
```

For WavPack, construct `WavPackPCMSource(url: fileURL)` and pass it to the same
player. It opens only that WV file; adjacent WVC correction files are not read.
Hybrid WV therefore plays its lossy main stream, exposed by `isLossless == false`.
Ordinary lossless WV remains lossless. Missing precision data in an initially
lossless stream is an error rather than a silent loss of fidelity.

Keep the player and engine alive for the duration of playback. Obtain format
information before handing a source to the player; after that handoff the player
exclusively owns the source. The example caches the sample rate before handoff
to calculate positions from seconds. Call transport methods outside the audio
render callback. `prepare` and `seek` can synchronously perform file I/O; use an
appropriate application control queue when startup latency matters.

Use the ordinary AudioKit `AudioPlayer` for files supported by `AVAudioFile`.
The extension does not patch `AudioPlayer.load(url:)`. A consumer chooses the
fallback during track preparation and keeps both paths in the same AudioKit
graph. File access errors, missing files, and corrupt input are errors, not a
reason to silently switch decoders. Queue, audio session, interruptions, routing,
and application lifecycle remain owned by the application.
Call `player.stop()` or `player.close()` before externally stopping/resetting
its AVAudioPlayerNode or rebuilding the engine, so cancelled callbacks are
invalidated. Automatic interruption, route-change, and engine-reset recovery
is not implemented by this package.

## Scope

- Local APE and WV input; PCM decoding and seek are independent of the playback graph.
- Float32 noninterleaved output; both bridges accept mono/stereo 8/16/24/32-bit
  integer and Float32 input. DSD and multichannel WavPack are rejected.
- Bounded decoded-audio buffering rather than loading an entire track into RAM.
- Play, pause/resume, stop, seek, close, and final-buffer completion.
- No network streaming, automatic format registry, looping, metadata editing,
  or automatic integration into Anywhere's waveform/scrub paths.
- iOS 15+, macOS 11+, tvOS 15+ are declared extension platforms. The parent
  AudioKit package retains its existing minimum platforms. Platform declarations
  are not substitutes for build and runtime validation.

## Development and validation

Run `swift test --package-path AudioKitFormats` from the parent checkout for the
self-contained tests of the PCM player and URL errors, without audio files. For the private real-file
corpus, use the separate [FormatCorpus suite](IntegrationTests/FormatCorpus/README.md).
It tests native AudioKit playback and both external decoders against actual recordings,
including independent decoded PCM references, transport controls, and mixed playback.
Both suites use offline rendering without physical audio output. See
`VALIDATION.md` for results and remaining integration checks. The command-line
workflow does not require reopening the Xcode GUI.

The codec bridges adapt the decoder boundary from SFBAudioEngine at
`abb4e351c8dd870137b19723dea975f8804220c1`. See `THIRD_PARTY_NOTICES.md` for
source provenance and dependency notices. Codec-library internals may allocate
their own decode buffers; the player's pool bound describes its PCM queue.
