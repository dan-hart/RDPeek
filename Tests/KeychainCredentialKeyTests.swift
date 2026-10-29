import RDPKit
import XCTest

final class KeychainCredentialKeyTests: XCTestCase {
    func testAccountNormalizesHostCase() throws {
        let upper = try XCTUnwrap(KeychainCredentialKey(identity: RDPConnectionIdentity(
            host: "WinBox", port: 3389, username: "anees", domain: ""
        )))
        let lower = try XCTUnwrap(KeychainCredentialKey(identity: RDPConnectionIdentity(
            host: "winbox", port: 3389, username: "anees", domain: ""
        )))

        XCTAssertEqual(upper.account, lower.account)
        XCTAssertEqual(upper.account, "anees@winbox:3389")
    }

    func testKeyRequiresUsername() {
        XCTAssertNil(KeychainCredentialKey(identity: RDPConnectionIdentity(
            host: "winbox", port: 3389, username: "", domain: ""
        )))
    }
}
