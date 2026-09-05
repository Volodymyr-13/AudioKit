import FallbackDecoders
import Foundation
import XCTest

/// Resource-free decoder contract checks. Actual file decoding is exercised by the
/// separate FormatCorpus integration suite using the user's real audio corpus.
final class APEPCMSourceTests: XCTestCase {
    func testRejectsRemoteURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/audio.ape"))
        XCTAssertThrowsError(try APEPCMSource(url: url))
    }

    func testRejectsMissingLocalFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ape")
        XCTAssertThrowsError(try APEPCMSource(url: url))
    }
}
