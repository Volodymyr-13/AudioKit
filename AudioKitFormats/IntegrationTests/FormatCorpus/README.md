# Real-file format tests

This opt-in Swift package exercises the private `AudioTest_FilesTypes` corpus
through the local AudioKit checkout and the optional AudioKitFormats package.
Ordinary AudioKitFormats tests remain independent of these recordings.

## Prepare

From the AudioKit checkout:

```sh
swift package --package-path AudioKitFormats resolve
python3 AudioKitFormats/Scripts/prepare-format-corpus.py
```

The source defaults to `../AudioTest_FilesTypes`. Use `--source /path/to/corpus`
to select another copy of the same corpus. Python 3.9+, `ffprobe`, and `ffmpeg`
must be available. The required downloaded APE sample is documented in
[SAMPLES.md](SAMPLES.md).

Preparation copies all 22 corpus files without modifying them, verifies SHA-256,
and independently decodes the APE with FFmpeg into a PCM reference WAV. No
encoded audio is generated. Local resource copies, decoded references, and the
manifest are ignored by Git. The manifest records hashes and formats. Tests fail with setup
instructions if these resources are missing; missing fixtures are not skips.

## Run

```sh
swift test --package-path AudioKitFormats/IntegrationTests/FormatCorpus
cd AudioKitFormats/IntegrationTests/FormatCorpus
xcodebuild -scheme AudioKitFormatCorpus-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Sim' \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
```

Use an installed simulator destination. These commands do not require opening
the Xcode GUI. Do not enable parallel tests: the graph harness temporarily sets
AudioKit's process-wide audio format and restores it after each graph.

The package explicitly selects the local parent AudioKit. Current SwiftPM emits
an identity-override warning because AudioKitFormats also declares a remote
AudioKit dependency; resolution must show `AudioKit @ local` for this suite.

## What the results mean

Rendering uses AVAudioEngine's offline mode and real AudioKit nodes, with PCM
comparisons against a separately opened native reference. It exercises decoding
and the playback graph without starting physical audio output. It does not
establish speaker/Bluetooth behavior, realtime scheduling, or device support.

The full 30-minute file is tested through bounded snippets. Short chapter
fixtures intentionally contain silence; ReplayGain fixtures may legitimately
decode above amplitude 1. Native compressed-file lengths can include codec
padding, so tests distinguish declared length from decoded samples.

APE PCM is compared with a reference decoded independently by FFmpeg. Native
format tests check AudioKit scheduling against AVAudioFile; they do not provide
an independent validation of Apple's codecs. TS and WMA are explicit rejection
cases for this playback path, not successful playback tests. These expectations
describe the supplied files and tested OS versions, not every file sharing an
extension. On the tested iOS Simulator, Vorbis is another explicit rejection
case; macOS has a corresponding playback test.

Two dedicated native callback regressions document early offline completion:
AC3 on macOS/iOS, and Vorbis on macOS. They use strict `XCTExpectFailure` only for
the completion-timing assertion. All PCM comparisons and other assertions must
still pass. These are known unresolved behaviors, not fixed defects; an
unexpected pass also fails and asks for the exception to be reviewed. The APE
path has no expected-failure exemptions.

See [VALIDATION.md](../../VALIDATION.md) for recorded results.
