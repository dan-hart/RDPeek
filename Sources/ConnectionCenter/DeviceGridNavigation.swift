import SwiftUI

/// Arrow-key selection in the Connection Center grid, whose cards run left
/// to right in rows of an adaptive grid item.
enum DeviceGridNavigation {
    static let cardMinimumWidth: CGFloat = 230
    static let cardMaximumWidth: CGFloat = 320
    static let spacing: CGFloat = 18

    /// How many cards a row of `width` holds: as many as fit at their
    /// minimum width, which is how an adaptive grid item counts them.
    static func columnCount(forWidth width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (cardMinimumWidth + spacing)))
    }

    /// The card to select after moving `direction` from the one at `index`,
    /// or the first card when none is selected; nil when there are none.
    /// Left and right step through the cards in order, across rows; up and
    /// down move a row, down to the last card when the next row is shorter.
    /// A move past the grid's edge keeps the selection.
    static func index(
        after direction: MoveCommandDirection,
        from index: Int?,
        count: Int,
        columns: Int
    ) -> Int? {
        guard count > 0 else {
            return nil
        }
        guard let index, (0 ..< count).contains(index) else {
            return 0
        }
        let columns = max(columns, 1)
        switch direction {
        case .left:
            return max(index - 1, 0)
        case .right:
            return min(index + 1, count - 1)
        case .up:
            return index >= columns ? index - columns : index
        case .down:
            let isInLastRow = index / columns == (count - 1) / columns
            return isInLastRow ? index : min(index + columns, count - 1)
        @unknown default:
            return index
        }
    }
}
