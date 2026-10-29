import Security
import XCTest

final class KeychainErrorTests: XCTestCase {
    func testStatusDescriptionIncludesSystemMessage() throws {
        let message = try XCTUnwrap(SecCopyErrorMessageString(errSecItemNotFound, nil) as String?)

        XCTAssertEqual(
            KeychainError.unexpectedStatus(errSecItemNotFound).description,
            "Keychain error \(errSecItemNotFound): \(message)"
        )
    }
}
