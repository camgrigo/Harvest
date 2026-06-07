import SwiftUI
import Observation

/// Bounds of every feed card, keyed by the model's UUID, collected via `anchorPreference` so the
/// hero overlay can read the exact source frame of whichever card was tapped — resolved in the
/// reader's coordinate space (the sheet's), no per-row GeometryReader or fragile `.global`.
struct CardAnchorKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>],
                       nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// Publishes this card's bounds under `id` for the hero transition to read.
    func cardAnchor(_ id: UUID) -> some View {
        anchorPreference(key: CardAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

/// Drives the hand-rolled card → detail "magic move". `sourceID` is the tapped card (nil for a
/// map-pin tap → centered fallback), `progress` runs 0 (over the card) → 1 (full page), and
/// `presenting` gates the cosmetic overlay. Main-actor `@Observable`, mutated only on the main
/// actor (panel + ExploreView), so it's clean under strict concurrency.
@MainActor
@Observable
final class HeroState {
    var sourceID: UUID?
    var progress: CGFloat = 0
    var presenting = false

    func reset() {
        sourceID = nil
        progress = 0
        presenting = false
    }
}

/// Grows a view from `card` (source rect, container space) to fill `container`, rounding its
/// corners out and fading over the last 15% so the real page pushed underneath is revealed.
/// All motion comes from interpolating the single `progress` value.
struct HeroFrame: ViewModifier, Animatable {
    var progress: CGFloat
    let card: CGRect
    let container: CGSize

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = max(0, min(1, progress))
        let w = card.width + (container.width - card.width) * p
        let h = card.height + (container.height - card.height) * p
        let cx = card.midX + (container.width / 2 - card.midX) * p
        let cy = card.midY + (container.height / 2 - card.midY) * p
        content
            .frame(width: max(w, 1), height: max(h, 1))
            .clipShape(RoundedRectangle(cornerRadius: 16 * (1 - p), style: .continuous))
            .position(x: cx, y: cy)
            .opacity(p <= 0.85 ? 1 : Double(max(0, 1 - (p - 0.85) / 0.15)))
    }
}
