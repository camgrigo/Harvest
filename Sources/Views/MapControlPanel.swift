import SwiftUI

/// The right-side control cluster on the Map tab (Apple Maps style): the map-style chooser, a
/// toggle for today's breadcrumb trail, and a "show everything" button. Sits at the bottom-trailing
/// corner, clear of the system map controls (which own the top-trailing corner) and just above the
/// collapsed bottom sheet. Owns its own look-chooser popover state; the map look and breadcrumb
/// visibility are bound to the parent so they persist via @AppStorage.
struct MapControlPanel: View {
    @Binding var mapLook: MapLook
    @Binding var showBreadcrumb: Bool
    /// Open the Map Modes card (presented by the parent so the bottom sheet can step aside).
    var onChooseStyle: () -> Void
    /// Re-frame the camera to show everyone (the opening overview).
    var onFrameAll: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onChooseStyle) { controlGlyph(mapLook.symbol) }
                .accessibilityLabel("Map style")
            Button { showBreadcrumb.toggle() } label: {
                controlGlyph(showBreadcrumb ? "point.topleft.down.curvedto.point.bottomright.up.fill"
                                            : "point.topleft.down.curvedto.point.bottomright.up")
            }
            .accessibilityLabel(showBreadcrumb ? "Hide today's trail" : "Show today's trail")
            Button { onFrameAll() } label: { controlGlyph("scope") }
                .accessibilityLabel("Show everything")
        }
        .padding(.trailing, 12)
        // Clear the collapsed bottom sheet (its smallest detent is 120pt) with a little breathing room.
        .padding(.bottom, 132)
    }

    private func controlGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

#if DEBUG
#Preview("MapControlPanel") {
    ZStack {
        Color.green.opacity(0.3).ignoresSafeArea()
        MapControlPanel(mapLook: .constant(.standard),
                        showBreadcrumb: .constant(false),
                        onChooseStyle: {},
                        onFrameAll: {})
    }
}
#endif
