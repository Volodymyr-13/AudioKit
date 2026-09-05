import CryptoKit
import Foundation
import XCTest

final class CorpusIntegrityTests: XCTestCase {
    func testAllCorpusFilesAndIndependentReferencesHaveVerifiedContents() throws {
        let corpus = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Corpus"))
        let manifestURL = corpus.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return XCTFail("Prepare the private corpus first: python3 AudioKitFormats/Scripts/prepare-format-corpus.py")
        }
        let manifest = try JSONDecoder().decode(PreparedManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.schemaVersion, 2)
        let originals = manifest.files.filter { $0.kind == "original" }
        let expected = Set([
            "audio-test.aac", "audio-test.ac3", "audio-test.aif", "audio-test.aiff", "audio-test.alac", "audio-test.ape",
            "audio-test.flac", "audio-test.m4a", "audio-test.mp3", "audio-test.mp4", "audio-test.ogg",
            "audio-test.opus", "audio-test.ts", "audio-test.wav", "audio-test.wma", "audio-test.wv",
            "chapters-quicktime.m4a", "chapters-v23.mp3", "chapters-v24.mp3", "no-chapters.mp3",
            "replaygain-id3v2-01.mp3", "replaygain-id3v2-02.mp3", "samdivine-chapters-30m.m4a",
        ])
        XCTAssertEqual(Set(originals.map(\.name)), expected)
        XCTAssertEqual(originals.count, expected.count)
        XCTAssertEqual(manifest.files.count, expected.count + 2)
        for entry in manifest.files {
            XCTAssertFalse(entry.relativePath.hasPrefix("/"))
            XCTAssertFalse(entry.relativePath.split(separator: "/").contains(".."))
            let url = corpus.appendingPathComponent(entry.relativePath)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            var byteCount = 0
            while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
                byteCount += data.count
                digest.update(data: data)
            }
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, entry.sha256, entry.name)
            XCTAssertEqual(byteCount, entry.byteCount, entry.name)
        }
        let references = manifest.files.filter { $0.kind == "reference" }
        XCTAssertEqual(Set(references.map(\.name)), ["audio-test.ape.wav", "audio-test.wv.wav"])
        XCTAssertEqual(references.count, 2)
        for name in ["audio-test.ape", "audio-test.wv"] {
            let reference = try XCTUnwrap(references.first { $0.name == name + ".wav" })
            let original = try XCTUnwrap(originals.first { $0.name == name })
            XCTAssertEqual(reference.derivedFrom, original.relativePath)
            XCTAssertEqual(reference.sourceSHA256, original.sha256)
            XCTAssertEqual(reference.pcmFrames, 2_667_168)
        }
    }
}

private struct PreparedManifest: Decodable {
    let schemaVersion: Int
    let files: [Entry]

    struct Entry: Decodable {
        let name: String
        let relativePath: String
        let kind: String
        let sha256: String
        let byteCount: Int
        let derivedFrom: String?
        let sourceSHA256: String?
        let pcmFrames: Int?
    }
}
