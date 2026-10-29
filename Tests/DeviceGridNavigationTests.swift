import SwiftUI
import XCTest

final class DeviceGridNavigationTests: XCTestCase {
    func testColumnCountMatchesWhatAnAdaptiveGridItemFits() {
        // Rows of 230-point cards 18 points apart.
        XCTAssertEqual(DeviceGridNavigation.columnCount(forWidth: 0), 1)
        XCTAssertEqual(DeviceGridNavigation.columnCount(forWidth: 477.9), 1)
        XCTAssertEqual(DeviceGridNavigation.columnCount(forWidth: 478), 2)
        XCTAssertEqual(DeviceGridNavigation.columnCount(forWidth: 725.9), 2)
        XCTAssertEqual(DeviceGridNavigation.columnCount(forWidth: 726), 3)
    }

    func testFirstMoveSelectsTheFirstCard() {
        for direction in [MoveCommandDirection.up, .down, .left, .right] {
            XCTAssertEqual(DeviceGridNavigation.index(after: direction, from: nil, count: 5, columns: 3), 0)
        }
        XCTAssertNil(DeviceGridNavigation.index(after: .down, from: nil, count: 0, columns: 3))
    }

    func testLeftAndRightStepAcrossRowsAndStopAtTheEnds() {
        // 0 1 2
        // 3 4
        XCTAssertEqual(DeviceGridNavigation.index(after: .right, from: 2, count: 5, columns: 3), 3)
        XCTAssertEqual(DeviceGridNavigation.index(after: .left, from: 3, count: 5, columns: 3), 2)
        XCTAssertEqual(DeviceGridNavigation.index(after: .left, from: 0, count: 5, columns: 3), 0)
        XCTAssertEqual(DeviceGridNavigation.index(after: .right, from: 4, count: 5, columns: 3), 4)
    }

    func testUpAndDownMoveARow() {
        // 0 1 2
        // 3 4
        XCTAssertEqual(DeviceGridNavigation.index(after: .down, from: 1, count: 5, columns: 3), 4)
        XCTAssertEqual(DeviceGridNavigation.index(after: .down, from: 2, count: 5, columns: 3), 4)
        XCTAssertEqual(DeviceGridNavigation.index(after: .down, from: 3, count: 5, columns: 3), 3)
        XCTAssertEqual(DeviceGridNavigation.index(after: .up, from: 4, count: 5, columns: 3), 1)
        XCTAssertEqual(DeviceGridNavigation.index(after: .up, from: 2, count: 5, columns: 3), 2)
    }
}
