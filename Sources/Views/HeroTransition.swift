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

/// Drives the hand-rolled, symmetric card ⇄ detail "magic move". `sourceID` is the tapped card
/// (nil for a map-pin tap → centered fallback). `progress` runs 0 (over the card) → 1 (full
/// screen) on the way in and back to 0 on the way out — the same value powers both directions,
/// so forward and reverse are mirror images. Main-actor `@Observable`.
@MainActor
@Observable
final class HeroState {
    var sourceID: UUID?
    var progress: CGFloat = 0
}

/// Scales + fades a full-screen view from the `card` rect (progress 0) to identity (progress 1),
/// centered, aspect-preserving. The cross-fade hides the scale distortion at low progress, so the
/// real card behind shows through at the ends — making the move reversible without a separate
/// panel. All motion is one interpolated `progress`.
struct HeroScale: ViewModifier, Animatable {
    var progress: CGFloat
    let card: CGRect
    let container: CGSize

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = max(0, min(1, progress))
        let base: CGFloat = (container.width > 0 && container.height > 0
                             && card.width > 0 && card.height > 0)
            ? min(card.width / container.width, card.height / container.height) : 1
        let scale = base + (1 - base) * p
        let dx = (card.midX - container.width / 2) * (1 - p)
        let dy = (card.midY - container.height / 2) * (1 - p)
        content
            .scaleEffect(scale, anchor: .center)
            .offset(x: dx, y: dy)
            .opacity(Double(min(1, p * 2.4)))   // solid by ~42% in; fades the same way out
    }
}

/// Lets a detail view (hosted in the hero overlay, not a real push) ask the panel to play the
/// reverse hero instead of the no-op `@Environment(\.dismiss)`. Falls back to `dismiss` when the
/// view is presented some other way (e.g. the notification sheet).
struct HeroDismissAction: @unchecked Sendable {
    let action: () -> Void
    func callAsFunction() { action() }
}

private struct HeroDismissKey: EnvironmentKey {
    static let defaultValue: HeroDismissAction? = nil
}

extension EnvironmentValues {
    var heroDismiss: HeroDismissAction? {
        get { self[HeroDismissKey.self] }
        set { self[HeroDismissKey.self] = newValue }
    }
}
