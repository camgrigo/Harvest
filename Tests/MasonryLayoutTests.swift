import XCTest
import CoreGraphics
@testable import Harvest

/// Tests the greedy two-column packing that drives the Explore feed's masonry (Grid) layout:
/// each item lands in whichever column is currently shorter, and order is preserved per column.
final class MasonryLayoutTests: XCTestCase {

    func testEmptyInputProducesEmptyColumns() {
        let (left, right) = balanceIntoColumns([Int]()) { _ in 100 }
        XCTAssertTrue(left.isEmpty)
        XCTAssertTrue(right.isEmpty)
    }

    func testSingleItemGoesLeft() {
        let (left, right) = balanceIntoColumns([42]) { _ in 100 }
        XCTAssertEqual(left, [42])
        XCTAssertTrue(right.isEmpty)
    }

    func testEqualHeightsAlternateColumns() {
        let (left, right) = balanceIntoColumns(Array(0..<6)) { _ in 100 }
        XCTAssertEqual(left, [0, 2, 4])
        XCTAssertEqual(right, [1, 3, 5])
    }

    func testGreedyPacksShortItemsUnderATallOne() {
        // A tall first card; the next three shorts should pile into the other column until the
        // heights even out (300 vs 100+100+100).
        let heights: [Int: CGFloat] = [0: 300, 1: 100, 2: 100, 3: 100]
        let (left, right) = balanceIntoColumns([0, 1, 2, 3]) { heights[$0]! }
        XCTAssertEqual(left, [0])
        XCTAssertEqual(right, [1, 2, 3])
    }

    func testOrderPreservedWithinEachColumn() {
        let (left, right) = balanceIntoColumns([10, 20, 30, 40, 50]) { _ in 50 }
        XCTAssertEqual(left, left.sorted())
        XCTAssertEqual(right, right.sorted())
        // Every input item appears exactly once across the two columns.
        XCTAssertEqual((left + right).sorted(), [10, 20, 30, 40, 50])
    }
}
