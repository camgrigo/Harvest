import Foundation
import MapKit
import CoreLocation

/// Best-effort offline map support, scoped to a single region.
///
/// HONEST LIMITATION: Apple's MapKit first-party tiles cannot be freely cached to disk for offline
/// use (per the MapKit EULA). So this does NOT make Apple Maps work offline. Instead it:
///   • prefetches OpenStreetMap raster tiles for a chosen region into an in-memory, session-only
///     cache, and
///   • can vend an `MKTileOverlay` that draws those tiles.
/// Tiles already fetched stay available if you later go offline, but NEW tiles still need network.
/// Nothing is persisted to disk. For true unlimited offline maps you'd need Mapbox or an
/// enterprise tile agreement — FLAGGED.
@MainActor
final class TileOverlayCache {
    static let shared = TileOverlayCache()

    /// Session-only cache of tile data keyed by tile URL. Never written to disk.
    private var cachedTiles: [String: Data] = [:]
    private let session = URLSession(configuration: .ephemeral)

    private init() {}

    /// Number of tiles currently held in memory (for UI/diagnostics).
    var cachedTileCount: Int { cachedTiles.count }

    /// An `MKTileOverlay` backed by the OSM raster tiles. Add it as a map overlay to render the
    /// cached/offline layer. It does not replace Apple's base map content. The overlay is seeded
    /// with a snapshot of the current session cache so already-fetched tiles draw immediately.
    func makeOverlay() -> MKTileOverlay {
        let overlay = CachedTileOverlay(urlTemplate: Self.tileURLTemplate, seed: cachedTiles)
        overlay.canReplaceMapContent = false
        overlay.minimumZ = 10
        overlay.maximumZ = 18
        return overlay
    }

    /// Prefetch the tiles covering `region` at one zoom level into the in-memory cache.
    /// Throttled and cancellation-aware. Returns the number of tiles successfully fetched.
    @discardableResult
    func prefetchTiles(for region: CLCircularRegion, zoomLevel: Int = 14) async -> Int {
        let tiles = Self.tilesForRegion(region, zoomLevel: zoomLevel)
        var fetched = 0
        for (x, y) in tiles {
            if Task.isCancelled { break }
            guard let url = Self.tileURL(x: x, y: y, z: zoomLevel) else { continue }
            if cachedTiles[url.absoluteString] != nil { continue }
            if let (data, _) = try? await session.data(from: url) {
                cachedTiles[url.absoluteString] = data
                fetched += 1
            }
            try? await Task.sleep(nanoseconds: 50_000_000)   // 50ms throttle, gentle on the network
        }
        return fetched
    }

    /// Clear the in-memory cache.
    func clearCache() { cachedTiles.removeAll() }

    // MARK: - Tile math (pure, testable)

    /// OpenStreetMap raster tiles — open data, cacheable in-session. We deliberately do NOT touch
    /// Apple's proprietary tiles here.
    nonisolated static let tileURLTemplate = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"

    nonisolated static func tileURL(x: Int, y: Int, z: Int) -> URL? {
        URL(string: tileURLTemplate
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)"))
    }

    /// The (x, y) tile coordinates covering a circular region at a zoom level (slippy-map scheme).
    nonisolated static func tilesForRegion(_ region: CLCircularRegion, zoomLevel: Int) -> [(Int, Int)] {
        let n = pow(2.0, Double(zoomLevel))
        let center = region.center
        let clampedLat = max(-85.0, min(85.0, center.latitude))
        let centerX = Int((center.longitude + 180) / 360 * n)
        let latRad = clampedLat * .pi / 180
        let centerY = Int((1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n)

        let radiusDegrees = region.radius / 111_000   // rough: 1° latitude ≈ 111 km
        let tileDelta = max(1, Int((radiusDegrees * n / 360).rounded(.up)))

        var tiles: [(Int, Int)] = []
        let maxIndex = Int(n) - 1
        for x in (centerX - tileDelta)...(centerX + tileDelta) {
            for y in (centerY - tileDelta)...(centerY + tileDelta) {
                guard x >= 0, x <= maxIndex, y >= 0, y <= maxIndex else { continue }
                tiles.append((x, y))
            }
        }
        return tiles
    }
}

/// An `MKTileOverlay` that serves from a snapshot of the session cache when a tile has already
/// been fetched, falling back to the network otherwise. `loadTile` is called off the main thread,
/// so the snapshot is captured at creation and guarded by a lock — no main-actor hop here.
private final class CachedTileOverlay: MKTileOverlay {
    private let lock = NSLock()
    private var tiles: [String: Data]

    init(urlTemplate: String?, seed: [String: Data]) {
        self.tiles = seed
        super.init(urlTemplate: urlTemplate)
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let url = self.url(forTilePath: path)
        let key = url.absoluteString
        lock.lock()
        let cached = tiles[key]
        lock.unlock()
        if let cached {
            result(cached, nil)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            if let data, let self {
                self.lock.lock()
                self.tiles[key] = data
                self.lock.unlock()
            }
            result(data, error)
        }.resume()
    }
}
