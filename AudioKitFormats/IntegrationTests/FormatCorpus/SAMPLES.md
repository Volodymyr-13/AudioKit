# Corpus sources and missing coverage

All audio inputs live in the separate sibling `AudioTest_FilesTypes` repository.
The original 21 files are unchanged. AudioKitFormats contains no audio payloads;
preparation copies the inputs into ignored resources for simulator testing.

## APE sample

Download [luckynight.ape](https://samples.ffmpeg.org/A-codecs/lossless/luckynight.ape)
from the FFmpeg sample archive into `AudioTest_FilesTypes/audio-test.ape`.
The downloaded bytes are unchanged; only the local filename differs.

- Size: 6,510,317 bytes; duration: 60.48 seconds.
- Stereo, 44,100 Hz, signed 16-bit PCM; 2,667,168 frames.
- SHA-256: `6a7b79a6d530e9847c18119d627bd43c8d27dcefb3ec7ec979b9b6306e34ac15`.
- The file matches the archive's published MD5, `ab078cadd6367ab132124cbc0ecb8005`.
- The [archive description](https://samples.ffmpeg.org/A-codecs/lossless/readme)
  identifies this as an excerpt of Lucky Night by Jody Marie Gnant, from
  Treasure Quest Soundtrack.

This is a public decoder-test sample, not a certification that every APE
variant is supported. No explicit audio redistribution license was found in
the source description. The FFmpeg software license does not license this
recording; it is excluded from the AudioKitFormats repository and package.

The original is already a one-minute excerpt. Smaller investigated FATE APE
cuts were truncated and failed strict decoding, so they were not used as valid
playback fixtures. Re-encoding a shortened APE would remove the independent
encoder provenance. The complete 6.51 MB original is retained instead.

The preparation script checks the pinned download hash and uses FFmpeg with
strict error checking to create an independent Float32 WAV reference. That
reference is temporary test data, not another encoded-format fixture.

## WavPack sample

Download [luckynight.wv](https://samples.ffmpeg.org/A-codecs/lossless/luckynight.wv)
from the same FFmpeg collection into AudioTest_FilesTypes/audio-test.wv.
It is the unchanged 6,605,816-byte original, with the same 60.48-second,
44,100 Hz, stereo 16-bit recording and 2,667,168 PCM frames as the APE.

- SHA-256: e94c946cbad31706815ce55426a8b60a9c16ba8827d3aa69854192903b7a1645.
- Published MD5: 79b26f9b8dd7281539986d3088dcb6fa.
- Independent strict FFmpeg decoding produces identical PCM for the two formats.
- No trimming or re-encoding; the same provenance and recording-rights limits
  described for APE apply.

The WavPack tests cover this lossless 16-bit stereo stream. Hybrid/WVC, mono,
other integer widths, Float32, multichannel and DSD have no public fixtures in
this corpus yet. Multichannel/DSD input is explicitly rejected by the initial
provider; WVC files are not opened. Those limitations are separate from support
for ordinary lossless WV.

## Missing format coverage

The corpus has no
Musepack MPC, True Audio TTA, Shorten SHN, Speex SPX, DSD DSF/DFF, or tracker
MOD/XM/IT/S3M samples. Those decoders are not implemented yet. Existing native
Vorbis, WMA, and TS samples can be reused when adding their fallback paths.

Removing generated APE files also removes dedicated mono, 8/24/32-bit integer,
and Float32 boundary fixtures. Current real-file APE coverage is stereo 16-bit;
other sample representations remain implementation capabilities needing their
own external test samples. The in-memory PCM player contract tests are retained.
