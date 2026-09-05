# Local real-file corpus

Run `python3 AudioKitFormats/Scripts/prepare-format-corpus.py` from the AudioKit
checkout to prepare these resources from the sibling `AudioTest_FilesTypes`
directory. Use `--source /absolute/path` to select another copy of that corpus.

`Original/`, `References/`, and `manifest.json` are prepared local test inputs
and are ignored by Git. Originals are copied unchanged. FFmpeg independently
decodes fallback files to reference PCM WAVs. No encoded audio is generated,
and no files in the source corpus are modified.

These private recordings must not be added to a public PR or release. The normal
AudioKitFormats unit tests use separate, generated signals and do not need them.
