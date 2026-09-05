#!/usr/bin/env python3
"""Copy AudioTest_FilesTypes into ignored test resources; decode PCM references.

Requires Python 3.9+, ffmpeg and ffprobe. No encoded audio is generated, and the
source corpus is only read. Reference WAVs are decoded independently by FFmpeg,
never by the decoder under test. Replacements are staged and reversible.
"""

import argparse
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

NATIVE_FILES = frozenset({
    "audio-test.aac", "audio-test.ac3", "audio-test.aif", "audio-test.aiff",
    "audio-test.alac", "audio-test.flac", "audio-test.m4a", "audio-test.mp3",
    "audio-test.mp4", "audio-test.ogg", "audio-test.opus", "audio-test.ts",
    "audio-test.wav", "audio-test.wma", "chapters-quicktime.m4a",
    "chapters-v23.mp3", "chapters-v24.mp3", "no-chapters.mp3",
    "replaygain-id3v2-01.mp3", "replaygain-id3v2-02.mp3",
    "samdivine-chapters-30m.m4a",
})
FALLBACK_FILES = {"audio-test.ape": "ape"}
FALLBACK_HASHES = {"audio-test.ape": "6a7b79a6d530e9847c18119d627bd43c8d27dcefb3ec7ec979b9b6306e34ac15"}
PACKAGE_ROOT = Path(__file__).resolve().parents[1]
CORPUS_ROOT = PACKAGE_ROOT / "IntegrationTests/FormatCorpus/Tests/FormatCorpusTests/Corpus"


def run(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{Path(str(arguments[0])).name} failed ({result.returncode}):\n"
                           + (result.stderr or result.stdout).strip())
    return result


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inventory(source):
    if not source.is_dir():
        raise ValueError(f"The source corpus does not exist: {source}")
    expected = NATIVE_FILES | FALLBACK_FILES.keys()
    missing = sorted(name for name in expected if not (source / name).is_file())
    if missing:
        raise ValueError("Missing corpus files: " + ", ".join(missing)
                         + ". See IntegrationTests/FormatCorpus/SAMPLES.md for source links.")
    unexpected = sorted(path.name for path in source.iterdir()
                        if path.is_file() and not path.name.startswith(".")
                        and path.suffix.lower() not in {".md", ".txt", ".json"}
                        and path.name not in expected)
    if unexpected:
        raise ValueError("Update the test matrix for new corpus files: " + ", ".join(unexpected))
    return [source / name for name in sorted(expected)]


def probe(path, ffprobe):
    result = run([ffprobe, "-v", "warning", "-select_streams", "a:0", "-show_entries",
                  "format=duration,format_name:stream=codec_name,sample_rate,channels,"
                  "bits_per_sample,bits_per_raw_sample,duration,duration_ts,time_base",
                  "-of", "json", str(path)])
    information = json.loads(result.stdout)
    streams = information.get("streams", [])
    if not streams:
        raise ValueError(f"No audio stream in {path.name}")
    stream = streams[0]
    raw_duration = stream.get("duration")
    if raw_duration in {None, "N/A"}:
        raw_duration = information.get("format", {}).get("duration")
    duration = float(raw_duration) if raw_duration not in {None, "N/A"} else None
    if duration is None or not math.isfinite(duration) or duration <= 0:
        raise ValueError(f"No valid duration for {path.name}")
    result_data = {
        "codec": stream["codec_name"],
        "container": information.get("format", {}).get("format_name"),
        "sampleRate": int(stream["sample_rate"]), "channels": int(stream["channels"]),
        "duration": duration,
    }
    bits = stream.get("bits_per_raw_sample") or stream.get("bits_per_sample")
    if bits and bits != "N/A" and int(bits) > 0:
        result_data["bitsPerSample"] = int(bits)
    if stream.get("duration_ts") is not None and stream.get("time_base"):
        frames = int(stream["duration_ts"]) * Fraction(stream["time_base"]) * result_data["sampleRate"]
        if frames.denominator == 1:
            result_data["pcmFrames"] = int(frames)
    if result.stderr.strip():
        result_data["probeWarnings"] = result.stderr.strip()
    return result_data


def install_staged(stage):
    # Derived belonged to the removed APE encoder. Retire only that generated
    # directory; preserve the checked-in README and the read-only source corpus.
    names = ["Original", "References", "manifest.json", "Derived"]
    previous = stage / "Previous"
    previous.mkdir()
    for name in names:
        if (CORPUS_ROOT / name).is_symlink():
            raise ValueError(f"Refusing to replace a symlink: {CORPUS_ROOT / name}")
    installed, backed_up = [], []
    try:
        for name in names:
            destination = CORPUS_ROOT / name
            if destination.exists():
                os.replace(destination, previous / name)
                backed_up.append(name)
            if (stage / name).exists():
                os.replace(stage / name, destination)
                installed.append(name)
    except BaseException:
        for name in reversed(installed):
            target = CORPUS_ROOT / name
            shutil.rmtree(target) if target.is_dir() else target.unlink()
        for name in backed_up:
            os.replace(previous / name, CORPUS_ROOT / name)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path,
                        default=PACKAGE_ROOT.parent.parent / "AudioTest_FilesTypes")
    args = parser.parse_args()
    source = args.source.expanduser().resolve()
    if source == CORPUS_ROOT.resolve() or CORPUS_ROOT.resolve() in source.parents:
        raise ValueError("The source must be outside the generated resources")
    files = inventory(source)
    ffprobe, ffmpeg = shutil.which("ffprobe"), shutil.which("ffmpeg")
    if not ffprobe or not ffmpeg:
        raise ValueError("ffprobe and ffmpeg must be available on PATH")
    if CORPUS_ROOT.is_symlink():
        raise ValueError("The corpus resource root must not be a symlink")
    CORPUS_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".prepare-corpus-", dir=CORPUS_ROOT.parent) as staging:
        stage = Path(staging)
        original, references = stage / "Original", stage / "References"
        original.mkdir()
        references.mkdir()
        entries = []
        for path in files:
            before = sha256(path)
            if path.name in FALLBACK_HASHES and before != FALLBACK_HASHES[path.name]:
                raise ValueError(f"Public sample hash differs: {path.name}; review the source and update the pinned fixture deliberately")
            copied = original / path.name
            shutil.copyfile(path, copied)
            if sha256(copied) != before or sha256(path) != before:
                raise ValueError(f"Source changed while copying {path.name}")
            entry = {"name": path.name, "relativePath": "Original/" + path.name,
                     "kind": "original", "sha256": before, "byteCount": copied.stat().st_size}
            entry.update(probe(copied, ffprobe))
            entries.append(entry)
            if path.name not in FALLBACK_FILES:
                continue
            if entry["codec"] != FALLBACK_FILES[path.name] or entry["channels"] not in {1, 2}:
                raise ValueError(f"Unexpected fallback fixture format: {path.name}")
            if entry["duration"] > 120:
                raise ValueError(f"Fallback fixture exceeds the bounded two-minute test: {path.name}")
            reference = references / (path.name + ".wav")
            run([ffmpeg, "-nostdin", "-v", "error", "-xerror", "-err_detect", "crccheck+explode", "-i", str(copied), "-map", "0:a:0",
                 "-vn", "-c:a", "pcm_f32le", "-rf64", "auto", str(reference)])
            reference_entry = {"name": reference.name, "relativePath": "References/" + reference.name,
                               "kind": "reference", "sha256": sha256(reference),
                               "byteCount": reference.stat().st_size,
                               "derivedFrom": entry["relativePath"], "sourceSHA256": entry["sha256"]}
            reference_entry.update(probe(reference, ffprobe))
            if reference_entry.get("pcmFrames", 0) <= 0:
                raise ValueError(f"No exact reference PCM length for {path.name}")
            if any(reference_entry[key] != entry[key] for key in ["sampleRate", "channels"]):
                raise ValueError(f"Reference format differs from source: {path.name}")
            entries.append(reference_entry)
        manifest = {"schemaVersion": 2, "preparedAt": datetime.now(timezone.utc).isoformat(),
                    "sourceDirectory": str(source),
                    "referenceDecoder": run([ffmpeg, "-version"]).stdout.splitlines()[0],
                    "files": entries}
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
        install_staged(stage)
    print(f"Verified {len(files)} byte-identical source files; decoded {len(FALLBACK_FILES)} independent PCM reference(s).")
    print("No encoded fixtures were generated. Source files were unchanged; prepared resources remain ignored by Git.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Corpus preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
