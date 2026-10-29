import RDPKit
import XCTest

final class TrustedCertificateStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "trusted-certificate-store-tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDifferentCertificateFromTrustedHostIsChanged() throws {
        let store = makeStore()
        XCTAssertFalse(store.isChanged(certificate("aa"), port: 3389))

        try store.trust(XCTUnwrap(RDPServerCertificateTrustKey(host: "Desktop.Example", port: 3389, sha256: "AA")))

        XCTAssertFalse(store.isChanged(certificate("aa"), port: 3389))
        XCTAssertTrue(store.isChanged(certificate("bb"), port: 3389))
        XCTAssertTrue(store.isChanged(certificate(nil), port: 3389))
        XCTAssertFalse(store.isChanged(certificate("bb", trusted: true), port: 3389))
        XCTAssertFalse(store.isChanged(certificate("bb"), port: 3390))
        XCTAssertFalse(store.isChanged(certificate("bb", host: "other.example"), port: 3389))
    }

    func testTrustingNewCertificateForHostReplacesOldOne() throws {
        let store = makeStore()
        try store.trust(XCTUnwrap(RDPServerCertificateTrustKey(host: "desktop.example", port: 3389, sha256: "aa")))
        try store.trust(XCTUnwrap(RDPServerCertificateTrustKey(host: "desktop.example", port: 3390, sha256: "aa")))

        try store.trust(XCTUnwrap(RDPServerCertificateTrustKey(host: "desktop.example", port: 3389, sha256: "bb")))

        XCTAssertTrue(store.isChanged(certificate("aa"), port: 3389))
        XCTAssertFalse(store.isChanged(certificate("bb"), port: 3389))
        XCTAssertTrue(store.isTrusted(host: "desktop.example", port: 3390, sha256: "aa"))
    }

    func testCertificateNobodyTrustsIsRefusedUntilUserTrustsIt() throws {
        let store = makeStore()
        XCTAssertEqual(store.refusal(of: certificate("aa"), port: 3389, acceptsUntrusted: false), .untrusted)
        XCTAssertEqual(store.refusal(of: certificate(nil), port: 3389, acceptsUntrusted: false), .untrusted)
        XCTAssertNil(store.refusal(of: certificate("aa", trusted: true), port: 3389, acceptsUntrusted: false))
        // Hide certificate warnings lets an untrusted certificate through.
        XCTAssertNil(store.refusal(of: certificate("aa"), port: 3389, acceptsUntrusted: true))

        try store.trust(XCTUnwrap(RDPServerCertificateTrustKey(host: "desktop.example", port: 3389, sha256: "aa")))

        XCTAssertNil(store.refusal(of: certificate("aa"), port: 3389, acceptsUntrusted: false))
        XCTAssertEqual(store.refusal(of: certificate("bb"), port: 3389, acceptsUntrusted: false), .changed)
        // ...but never a certificate that replaced one the user trusted.
        XCTAssertEqual(store.refusal(of: certificate("bb"), port: 3389, acceptsUntrusted: true), .changed)
    }

    private func makeStore() -> TrustedCertificateStore {
        TrustedCertificateStore(defaults: defaults)
    }

    private func certificate(
        _ sha256: String?,
        host: String = "desktop.example",
        trusted: Bool = false
    ) -> RDPServerCertificateInfo {
        RDPServerCertificateInfo(trusted: trusted, sha256: sha256, warnings: [], host: host)
    }
}
