import SwiftUI
import MapKit
import CoreLocation

/// Pick a location by panning a map under a fixed center pin. You can also tap the current-location
/// button to jump to where you are, or search for a place/address. On confirm it reverse-geocodes
/// the center and hands back both the coordinate and the address.
struct LocationPickerView: View {
    let initial: CLLocationCoordinate2D?
    var onPick: (CLLocationCoordinate2D, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition
    @State private var center: CLLocationCoordinate2D?
    @State private var address = ""
    @State private var looking = false
    @State private var visibleRegion: MKCoordinateRegion?
    /// Search field + its results (place/address lookup via MKLocalSearch).
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    /// Requested so the current-location button works and the blue dot shows.
    @State private var locationManager = CLLocationManager()

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
                Map(position: $camera) {
                    UserAnnotation()
                }
                .mapControls {
                    MapUserLocationButton()   // native "center on me" button
                    MapCompass()
                }
                .onMapCameraChange(frequency: .onEnd) { ctx in
                    visibleRegion = ctx.region
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
            // Search results drop down from the top over the map.
            .overlay(alignment: .top) {
                if !results.isEmpty { searchResults }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationTitle("Choose location")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search for a place or address")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .onChange(of: query) { _, q in if q.isEmpty { results = [] } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                locationManager.requestWhenInUseAuthorization()
                if let center { await reverseGeocode(center) }
            }
        }
    }

    // MARK: Search

    private var searchResults: some View {
        VStack(spacing: 0) {
            ForEach(results, id: \.self) { item in
                Button { select(item) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
                        Text(item.name ?? "Place").fontWeight(.medium).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 44)
            }
        }
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(.horizontal, 12)
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        searching = true
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let visibleRegion { request.region = visibleRegion }
        let response = try? await MKLocalSearch(request: request).start()
        results = response?.mapItems ?? []
    }

    private func select(_ item: MKMapItem) {
        let c = item.location.coordinate
        withAnimation(.easeInOut) {
            camera = .region(MKCoordinateRegion(
                center: c, latitudinalMeters: 400, longitudinalMeters: 400))
        }
        center = c
        results = []
        query = ""
        Task { await reverseGeocode(c) }
    }

    // MARK: Confirm / geocode

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Group {
                if looking {
                    HStack(spacing: 6) { ProgressView(); Text("Looking up address…") }
                } else if !address.isEmpty {
                    Text(address)
                } else {
                    Text("Drag the map, search, or tap the location button")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

            Button { confirm() } label: {
                Text("Use this location").frame(maxWidth: .infinity).fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(center == nil)
        }
        .padding()
        .background(.bar)
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
