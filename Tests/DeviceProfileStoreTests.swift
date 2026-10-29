import Foundation
import XCTest

final class DeviceProfileStoreTests: XCTestCase {
    private let storageKey = "device-profiles.v1"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try makeIsolatedDefaults()
    }

    func testSaveAndDeleteRoundTrip() throws {
        let store = DeviceProfileStore(defaults: defaults)
        var device = DeviceProfile.makeNew(defaults: defaults)
        device.name = "Build Box"
        device.host = "build"

        try store.save(device)
        XCTAssertEqual(try store.devices().map(\.id), [device.id])

        device.name = "Build Box 2"
        try store.save(device)
        XCTAssertEqual(try store.devices().map(\.name), ["Build Box 2"])

        try store.delete(id: device.id)
        XCTAssertEqual(try store.devices(), [])
    }

    func testMutationsThrowInsteadOfWipingUnreadableStore() throws {
        let store = DeviceProfileStore(defaults: defaults)
        var device = DeviceProfile.makeNew(defaults: defaults)
        device.name = "Keep Me"
        try store.save(device)

        // Simulate a corrupted or future-format blob the decoder rejects.
        let corruptBlob = Data("not json".utf8)
        defaults.set(corruptBlob, forKey: storageKey)

        XCTAssertThrowsError(try store.devices(), "An unreadable list must not read as no PCs")

        var other = DeviceProfile.makeNew(defaults: defaults)
        other.name = "New PC"
        XCTAssertThrowsError(try store.save(other))
        XCTAssertThrowsError(try store.delete(id: device.id))
        XCTAssertThrowsError(try store.touchLastConnected(id: device.id))

        XCTAssertEqual(
            defaults.data(forKey: storageKey),
            corruptBlob,
            "A failed mutation must leave the stored blob untouched"
        )
    }

    func testMakeNewStartsFromNewDeviceSettings() {
        let fallback = DeviceProfile.makeNew(defaults: defaults)
        XCTAssertEqual(fallback.clipboardSharingEnabled, NewDeviceDefaults.clipboardSharingEnabled)
        XCTAssertEqual(fallback.audioPlaybackEnabled, NewDeviceDefaults.audioPlaybackEnabled)
        XCTAssertEqual(fallback.hideCertificateWarnings, NewDeviceDefaults.hideCertificateWarnings)
        XCTAssertEqual(fallback.timeoutSeconds, NewDeviceDefaults.timeoutSeconds)

        defaults.set(false, forKey: NewDeviceDefaults.clipboardSharingKey)
        defaults.set(true, forKey: NewDeviceDefaults.audioPlaybackKey)
        defaults.set(true, forKey: NewDeviceDefaults.hideCertificateWarningsKey)
        defaults.set(30, forKey: NewDeviceDefaults.timeoutSecondsKey)
        let configured = DeviceProfile.makeNew(defaults: defaults)

        XCTAssertFalse(configured.clipboardSharingEnabled)
        XCTAssertTrue(configured.audioPlaybackEnabled)
        XCTAssertTrue(configured.hideCertificateWarnings)
        XCTAssertEqual(configured.timeoutSeconds, 30)
    }

    func testTouchLastConnectedWithUnknownIDReturnsSortedList() throws {
        let store = DeviceProfileStore(defaults: defaults)
        for name in ["Zulu", "Alpha"] {
            var device = DeviceProfile.makeNew(defaults: defaults)
            device.name = name
            device.host = "\(name.lowercased()).example"
            try store.save(device)
        }

        XCTAssertEqual(try store.touchLastConnected(id: UUID()).map(\.name), ["Alpha", "Zulu"])
    }

    func testDecodesProfileWrittenByEarlierReleases() throws {
        let id = UUID()
        storeJSON("""
        [{"id": "\(id.uuidString)", "name": "Work", "host": "desk.example", "port": 3390,
          "username": "anees", "domain": "corp", "hideCertificateWarnings": true,
          "timeoutSeconds": 20, "clipboardSharingEnabled": false, "audioPlaybackEnabled": true,
          "rememberPassword": true, "accentHue": 0.25, "createdAt": 1000, "updatedAt": 2000,
          "lastConnectedAt": 3000}]
        """)

        let expected = DeviceProfile(
            id: id,
            name: "Work",
            host: "desk.example",
            port: 3390,
            username: "anees",
            domain: "corp",
            hideCertificateWarnings: true,
            timeoutSeconds: 20,
            clipboardSharingEnabled: false,
            audioPlaybackEnabled: true,
            rememberPassword: true,
            accentHue: 0.25,
            createdAt: Date(timeIntervalSinceReferenceDate: 1000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2000),
            lastConnectedAt: Date(timeIntervalSinceReferenceDate: 3000)
        )
        XCTAssertEqual(try DeviceProfileStore(defaults: defaults).devices(), [expected])
    }

    func testProfileWithOnlyIDAndHostDecodesWithDefaults() throws {
        let id = UUID()
        storeJSON(#"[{"id": "\#(id.uuidString)", "host": "desk.example"}]"#)

        let device = try XCTUnwrap(DeviceProfileStore(defaults: defaults).devices().first)
        XCTAssertEqual(device.id, id)
        XCTAssertEqual(device.host, "desk.example")
        XCTAssertEqual(device.name, "")
        XCTAssertEqual(device.port, 3389)
        XCTAssertEqual(device.username, "")
        XCTAssertEqual(device.domain, "")
        XCTAssertEqual(device.hideCertificateWarnings, NewDeviceDefaults.hideCertificateWarnings)
        XCTAssertEqual(device.timeoutSeconds, NewDeviceDefaults.timeoutSeconds)
        XCTAssertEqual(device.clipboardSharingEnabled, NewDeviceDefaults.clipboardSharingEnabled)
        XCTAssertEqual(device.audioPlaybackEnabled, NewDeviceDefaults.audioPlaybackEnabled)
        XCTAssertFalse(device.rememberPassword)
        XCTAssertTrue((0 ..< 1).contains(device.accentHue))
        XCTAssertNil(device.lastConnectedAt)
        // Stable across reads, so the card keeps its color.
        XCTAssertEqual(try DeviceProfileStore(defaults: defaults).devices().first, device)
    }

    func testUnreadableElementHidesOnlyItselfAndSurvivesSaves() throws {
        let store = DeviceProfileStore(defaults: defaults)
        var kept = DeviceProfile.makeNew(defaults: defaults)
        kept.host = "kept.example"
        try store.save(kept)
        // No host, and an id that is not a UUID.
        let unreadable: [String: Any] = [
            "id": "not-a-uuid",
            "port": 3389,
            "extra": ["nested": [1.5, true, NSNull()] as [Any]],
        ]
        var stored = try storedJSON()
        stored.insert(unreadable, at: 0)
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: storageKey)

        XCTAssertEqual(try store.devices().map(\.id), [kept.id])

        var added = DeviceProfile.makeNew(defaults: defaults)
        added.host = "added.example"
        try store.save(added)
        try store.delete(id: kept.id)

        XCTAssertEqual(try store.devices().map(\.id), [added.id])
        let elements = try storedJSON()
        XCTAssertEqual(elements.count, 2)
        XCTAssertTrue(
            elements.contains { NSDictionary(dictionary: unreadable).isEqual($0) },
            "The unreadable element must be written back unchanged"
        )
    }

    private func storeJSON(_ json: String) {
        defaults.set(Data(json.utf8), forKey: storageKey)
    }

    private func storedJSON() throws -> [Any] {
        let data = try XCTUnwrap(defaults.data(forKey: storageKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
    }
}
