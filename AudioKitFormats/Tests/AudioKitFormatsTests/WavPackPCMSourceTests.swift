import FallbackDecoders
import Foundation
import XCTest

/// Resource-free contract checks. Actual file decoding is exercised by the
/// separate FormatCorpus integration suite using the user's real audio corpus.
final class WavPackPCMSourceTests: XCTestCase {
    func testRejectsRemoteURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/audio.wv"))
        XCTAssertThrowsError(try WavPackPCMSource(url: url))
    }

    func testRejectsMissingLocalFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wv")
        XCTAssertThrowsError(try WavPackPCMSource(url: url))
    }
}
