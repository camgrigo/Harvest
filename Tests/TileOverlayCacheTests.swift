import XCTest
import CoreLocation
@testable import Harvest

final class TileOverlayCacheTests: XCTestCase {

    func testTileURLBuildsSlippyPath() {
        let url = TileOverlayCache.tileURL(x: 4823, y: 6160, z: 14)
        XCTAssertEqual(url?.absoluteString, "https://tile.openstreetmap.org/14/4823/6160.png")
    }

    /// A region produces a square block of valid (non-negative, in-range) tile coordinates that
    /// includes the center tile.
    func testTilesForRegionCoversCenter() {
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
            radius: 500,
            identifier: "test")
        let tiles = TileOverlayCache.tilesForRegion(region, zoomLevel: 14)
        XCTAssertFalse(tiles.isEmpty)
        // Center tile for NYC at z14.
        let n = pow(2.0, 14.0)
        let cx = Int((-74.0060 + 180) / 360 * n)
        let latRad = 40.7128 * .pi / 180
        let cy = Int((1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n)
        XCTAssertTrue(tiles.contains { $0 == (cx, cy) })
        XCTAssertTrue(tiles.allSatisfy { $0.0 >= 0 && $0.1 >= 0 })
    }

    /// Extreme latitudes are clamped so we never feed NaN into the tile math.
    func testTilesForRegionClampsPoles() {
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: 89.9, longitude: 10),
            radius: 1000,
            identifier: "pole")
        let tiles = TileOverlayCache.tilesForRegion(region, zoomLevel: 12)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertTrue(tiles.allSatisfy { $0.0 >= 0 && $0.1 >= 0 })
    }
}
