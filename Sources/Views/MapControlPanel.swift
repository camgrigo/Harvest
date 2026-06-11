import SwiftUI

/// The right-side control cluster on the Map tab (Apple Maps style): the map-style chooser, a
/// toggle for today's breadcrumb trail, and a "show everything" button. Sits just below the
/// system map controls. Owns its own look-chooser popover state; the map look and breadcrumb
/// visibility are bound to the parent so they persist via @AppStorage.
struct MapControlPanel: View {
    @Binding var mapLook: MapLook
    @Binding var showBreadcrumb: Bool
    /// Re-frame the camera to show everyone (the opening overview).
    var onFrameAll: () -> Void

    /// Whether the Maps-style "choose a look" panel is open.
    @State private var showLookChooser = false

    var body: some View {
        VStack(spacing: 12) {
            Button { showLookChooser = true } label: { controlGlyph(mapLook.symbol) }
                .popover(isPresented: $showLookChooser) {
                    lookChooser.presentationCompactAdaptation(.popover)
                }
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
        .padding(.top, 96)
    }

    private func controlGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    /// A row of selectable look tiles, mirroring the Maps "Choose Map" panel.
    private var lookChooser: some View {
        HStack(spacing: 14) {
            ForEach(MapLook.allCases) { look in
                Button {
                    mapLook = look
                    showLookChooser = false
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: look.symbol)
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(look.swatch.gradient,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(mapLook == look ? Color.accentColor : .clear,
                                                  lineWidth: 3)
                            }
                        Text(look.label)
                            .font(.caption)
                            .fontWeight(mapLook == look ? .semibold : .regular)
                            .foregroundStyle(mapLook == look ? Color.accentColor : .primary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
    }
}
