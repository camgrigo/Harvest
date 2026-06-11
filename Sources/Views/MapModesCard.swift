import SwiftUI

/// The map-style chooser, modelled on Apple Maps' iOS 27 "Map Modes" card: a bottom-anchored
/// material panel with a title, a close button, and a row of labelled tiles (the selected one
/// outlined). Presented as an in-layer overlay by `ExploreView` (not a `.popover` or `.sheet`),
/// because the Map tab's bottom sheet — presented from `RootView` — would otherwise occlude it;
/// `ExploreView` steps that sheet aside via `MapModel.suppressSheet` while this card is up.
struct MapModesCard: View {
    @Binding var mapLook: MapLook
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Text("Map Modes").font(.headline)
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(.tertiary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }

            HStack(spacing: 14) {
                ForEach(MapLook.allCases) { look in
                    Button {
                        mapLook = look
                        onClose()
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: look.symbol)
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 64)
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
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

#if DEBUG
#Preview("Map Modes card") {
    ZStack(alignment: .bottom) {
        Color.green.opacity(0.3).ignoresSafeArea()
        MapModesCard(mapLook: .constant(.satellite)) {}
    }
}
#endif
