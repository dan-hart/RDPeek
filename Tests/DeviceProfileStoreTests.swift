import Foundation
import XCTest

final class DeviceProfileStoreTests: XCTestCase {
    private let storageKey = "device-profiles.v1"
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "device-profile-store-tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSaveAndDeleteRoundTrip() throws {
        let store = DeviceProfileStore(defaults: defaults)
        var device = DeviceProfile.makeNew(defaults: defaults)
        device.name = "Build Box"
        device.host = "build"

        try store.save(device)
        XCTAssertEqual(store.devices().map(\.id), [device.id])

        device.name = "Build Box 2"
        try store.save(device)
        XCTAssertEqual(store.devices().map(\.name), ["Build Box 2"])

        try store.delete(id: device.id)
        XCTAssertEqual(store.devices(), [])
    }

    func testMutationsThrowInsteadOfWipingUnreadableStore() throws {
        let store = DeviceProfileStore(defaults: defaults)
        var device = DeviceProfile.makeNew(defaults: defaults)
        device.name = "Keep Me"
        try store.save(device)

        // Simulate a corrupted or future-format blob the decoder rejects.
        let corruptBlob = Data("not json".utf8)
        defaults.set(corruptBlob, forKey: storageKey)

        XCTAssertEqual(store.devices(), [], "Reads degrade to empty for display")

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

    func testTouchLastConnectedWithUnknownIDDoesNotThrow() throws {
        let store = DeviceProfileStore(defaults: defaults)
        XCTAssertNoThrow(try store.touchLastConnected(id: UUID()))
    }
}
