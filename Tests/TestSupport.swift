import XCTest

extension XCTestCase {
    /// A user-defaults suite of the test's own, removed when the test ends,
    /// so tests never read or write the app's real preferences.
    func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "rdpeek-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
