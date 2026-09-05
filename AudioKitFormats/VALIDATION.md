# Validation — 2026-09-05

The optional package adds APE decoding to the existing AudioKit graph. The
parent AudioKit sources, manifest, and dependency graph are unchanged. Work is
on dev/AudioKitFormats, based on AudioKit c358c15fdcdd0e78c4b4988f5c532c7cfb5c2eeb.
The SFB decoder-design donor is abb4e351c8dd870137b19723dea975f8804220c1.

## Current test inputs

All encoded audio comes from the separate AudioTest_FilesTypes repository:
21 existing files plus an unchanged public FFmpeg APE sample. Their prepared
copies and independent FFmpeg PCM references are ignored by Git. No audio
payload or encoder generator is included in AudioKitFormats. See
[the sample inventory](IntegrationTests/FormatCorpus/SAMPLES.md) for URLs,
checksums, provenance, and missing sample coverage.

The APE sample is 60.48 seconds, stereo 16-bit, 44.1 kHz, 2,667,168 frames. The
real-file decoder tests compare every sample with independent FFmpeg output,
then check chunk boundaries, seek/EOF, buffer validation, close, malformed
headers, truncated payloads, and corruption. Player tests exercise full-file
rendering and completion timing, pause/resume/stop/seek, and independent native
WAV + APE slots mixed in the real AudioKit graph.

Dedicated generated mono/8/24/32-bit/Float32 fixture tests were removed at the
user's request. Those APE representations remain implemented but are not
covered by the current real sample. The resource-free suite retains synthetic
PCM source tests for bounded buffering, transport, errors, underrun, and
completion generation; it does not create encoded audio files.

## APE step checks

- Resource-free suite: 18 tests on macOS and 18 on iOS Simulator, all passed.
- Real-file suite: 37 macOS tests, no unexpected failures, with two explicitly
  expected native completion-timing issues described below.
- iOS real-file suite: 36 tests, no unexpected failures, one expected native
  AC3 timing issue; xcodebuild exited 0 with TEST SUCCEEDED.
- macOS logs: /tmp/audiokit-ape-step-unit-final.log and
  /tmp/audiokit-ape-step-corpus-mac.log.
- iOS logs: /tmp/audiokit-ape-step-unit-ios-final.log and
  /tmp/audiokit-ape-step-corpus-ios.log. Corpus result bundle:
  /tmp/AudioKitFormats-APE-step-corpus.xcresult.
- Preparation verified all 22 input copies by SHA-256, with strict independent
  FFmpeg decoding and no modifications to the original 21 recordings.

Tests use AVAudioEngine offline rendering; none starts physical audio output.
The final buffer uses .dataRendered, while realtime playback uses
.dataPlayedBack. Offline results do not establish realtime output-completion
timing or performance. The deliberately stalled source may emit a test
semaphore QoS warning; that test verifies underrun reporting, not latency.

## Native format matrix

Observed on macOS 26.6.2 (25G83) and iPhone 17 Pro Sim / iOS 27.0:

| Supplied input | macOS | iOS Simulator |
| --- | --- | --- |
| AAC, AIF, AIFF, ALAC, FLAC, M4A, MP3, MP4, Opus, WAV | PCM playback passes | PCM playback passes |
| AC3 | PCM passes; early offline completion | PCM passes; early offline completion |
| Ogg/Vorbis | PCM passes; early offline completion | AVAudioFile rejects input (1685348671) |
| TS, WMA/ASF | Rejected | Rejected |

These results describe these files and OS versions, not every variant of each
format or the package's minimum supported OS versions. Metadata-bearing files
are playback tests, not chapter/ReplayGain parsing tests. The 30-minute M4A uses
bounded three-second head/middle/tail snippets. FLAC and AIFF still compare
exactly with all 698,194 frames of the user's original WAV.

Native .dataRendered callbacks arrived roughly 0.84 seconds early for AC3 on
both platforms and 0.76 seconds early for Vorbis on Mac while PCM continued to
match. A direct AVAudioPlayerNode reproduction without AudioKit confirmed the
AC3 behavior on macOS, with WAV as a passing control. Dedicated timing tests
use strict XCTExpectFailure around only the timing assertion; PCM errors,
missing/double callbacks, and APE timing remain ordinary failures. iOS Vorbis
has an explicit rejection test, not a runtime skip or a claimed playback pass.

An earlier corpus run lost its process to SIGTERM alongside a simulator-service
termination. Its initiator was not established; an unchanged full rerun passed.
No physical iPhone, Xcode GUI reopening, or device audio output was used.

## Xcode UI incident

An initially generated development workspace referenced an already-open local
package and caused an Xcode workspace conflict. Its remaining empty directory
then shadowed the Swift package and produced a missing-scheme error. That entire
generated workspace was removed. `xcodebuild -list` subsequently resolved both
dependencies and reported all four package schemes.

Further attempts to open the package in Xcode beta failed and Xcode aborted at
13:49:25. The crash report shows `SIGABRT` in Xcode's internal
`DVTTimeSlicedMainThreadWorkQueue` assertion handling. The exact underlying cause
is not established. The IDE was not restarted again after the user reported the
crash. UI opening is not verified; package compilation and tests were completed
separately on the command line.

## Remaining checks

Realtime device playback, startup/seek latency, energy, headphones/Bluetooth,
interruptions, background playback, engine recovery, and minimum OS versions
remain unverified. Stop/close this player before an external engine/node reset;
automatic recovery is outside the module. Anywhere routing, waveform/scrub and
lifecycle integration are not changed. Multichannel/DSD, other codecs, tvOS
runtime, publication, CI, and final application linkage size are not validated.

## Reproduction

From the AudioKit checkout:

```sh
swift test --package-path AudioKitFormats
python3 AudioKitFormats/Scripts/prepare-format-corpus.py
swift test --package-path AudioKitFormats/IntegrationTests/FormatCorpus
```

For iOS, run xcodebuild with AudioKitFormats-Package from AudioKitFormats and
AudioKitFormatCorpus-Package from IntegrationTests/FormatCorpus. Use an
installed iOS Simulator destination, -parallel-testing-enabled NO and
-collect-test-diagnostics never. See the corpus README for the exact command.
