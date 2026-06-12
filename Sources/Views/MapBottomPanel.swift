import SwiftUI

/// A Find-My-style bottom panel: a rounded material card pinned to the bottom of the Map tab's
/// content, draggable between three detents. Unlike a modal `.sheet`, it lives *inside* the tab's
/// content area — which the TabView already insets above the floating tab bar — so the tab bar
/// stays visible and tappable above it (a modal sheet would cover it).
///
/// The drag gesture lives only on the grabber strip, so the embedded content scrolls normally.
struct MapBottomPanel<Content: View>: View {
    @ViewBuilder var content: Content

    enum Detent: CaseIterable { case collapsed, medium, large }

    @State private var detent: Detent = .collapsed
    @GestureState private var dragTranslation: CGFloat = 0

    /// Resting height for a detent within an available height `H`.
    private func height(_ d: Detent, in H: CGFloat) -> CGFloat {
        switch d {
        case .collapsed: 132
        case .medium:    H * 0.46
        case .large:     H * 0.92
        }
    }

    var body: some View {
        GeometryReader { geo in
            let H = geo.size.height
            let resting = height(detent, in: H)
            // Dragging up (negative translation) grows the panel; clamp to the detent range.
            let live = min(max(resting - dragTranslation, height(.collapsed, in: H)),
                           height(.large, in: H))

            VStack(spacing: 0) {
                grabber(H: H)
                content
            }
            .frame(maxWidth: .infinity)
            .frame(height: live, alignment: .top)
            .background(.regularMaterial,
                        in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20,
                                                   style: .continuous))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20,
                                              style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: detent)
            .animation(.interactiveSpring(response: 0.25), value: dragTranslation)
        }
    }

    /// The drag handle. The gesture is scoped here so the panel's content (a scrolling List) is
    /// free to scroll on its own.
    private func grabber(H: CGFloat) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.secondary)
                .frame(width: 40, height: 5)
                .padding(.vertical, 8)
            Color.clear.frame(height: 8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .updating($dragTranslation) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    let resting = height(detent, in: H)
                    // Snap toward where the gesture was headed, by predicted end position.
                    let predicted = resting - value.predictedEndTranslation.height
                    detent = Detent.allCases.min(by: {
                        abs(height($0, in: H) - predicted) < abs(height($1, in: H) - predicted)
                    }) ?? detent
                }
        )
    }
}
