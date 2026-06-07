import SwiftUI
import MapKit
import CoreLocation

/// Pick a location by panning a map under a fixed center pin, instead of typing an address.
/// On confirm it reverse-geocodes the center and hands back both the coordinate and the address.
struct LocationPickerView: View {
    let initial: CLLocationCoordinate2D?
    var onPick: (CLLocationCoordinate2D, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition
    @State private var center: CLLocationCoordinate2D?
    @State private var address = ""
    @State private var looking = false

    init(initial: CLLocationCoordinate2D?,
         onPick: @escaping (CLLocationCoordinate2D, String) -> Void) {
        self.initial = initial
        self.onPick = onPick
        if let initial {
            _camera = State(initialValue: .region(MKCoordinateRegion(
                center: initial, latitudinalMeters: 400, longitudinalMeters: 400)))
            _center = State(initialValue: initial)
        } else {
            _camera = State(initialValue: .userLocation(fallback: .automatic))
            _center = State(initialValue: nil)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $camera)
                    .onMapCameraChange(frequency: .onEnd) { ctx in
                        let c = ctx.camera.centerCoordinate
                        center = c
                        Task { await reverseGeocode(c) }
                    }
                    .ignoresSafeArea(edges: .top)

                // Fixed center pin — its tip marks the chosen point.
                Image(systemName: "mappin")
                    .font(.system(size: 38))
                    .foregroundStyle(.red)
                    .shadow(radius: 2)
                    .offset(y: -19)
                    .allowsHitTesting(false)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Group {
                        if looking {
                            HStack(spacing: 6) { ProgressView(); Text("Looking up address…") }
                        } else if !address.isEmpty {
                            Text(address)
                        } else {
                            Text("Drag the map to place the pin")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                    Button {
                        confirm()
                    } label: {
                        Text("Use this location")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(center == nil)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Choose location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if let center { await reverseGeocode(center) }
            }
        }
    }

    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async {
        looking = true
        address = await AddressGeocoder.address(for: coordinate)
        looking = false
    }

    private func confirm() {
        guard let center else { return }
        onPick(center, address)
        dismiss()
    }
}
