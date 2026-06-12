import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// PROTOTYPE: a territory's not-at-homes on a map instead of a list. Each placed door is a pin
/// (tinted by how worth-knocking-now it is); tapping empty map drops a new not-at-home there and
/// reverse-geocodes its address. Tap a pin to open its quick actions (tried again / answered /
/// delete). Doors without a coordinate aren't shown here — they still live in the list view.
struct TerritoryDoorsMap: View {
    @Bindable var territory: Territory
    /// Called when a door is answered, so the parent can present the promote sheet.
    var onAnswered: (NotAtHome) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition = .automatic
    @State private var selected: NotAtHome?
    @State private var locationManager = CLLocationManager()
    /// Brief "added" confirmation after a tap.
    @State private var justAdded = false

    private var placedDoors: [NotAtHome] {
        territory.sortedDoors.filter { $0.coordinate != nil }
    }
    private var unplacedCount: Int {
        territory.sortedDoors.count - placedDoors.count
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()

                    // The territory outline, if one was drawn/imported.
                    if territory.coordinates.count >= 3 {
                        MapPolygon(coordinates: territory.coordinates)
                            .foregroundStyle(.blue.opacity(0.12))
                            .stroke(.blue.opacity(0.7), lineWidth: 2)
                    }

                    // One pin per placed door. The Button consumes its own tap, so tapping a pin
                    // selects it while a tap on empty map (below) adds a new door.
                    ForEach(placedDoors) { door in
                        Annotation(door.address.isEmpty ? "New door" : door.address,
                                   coordinate: door.coordinate!) {
                            Button { selected = door } label: { pin(for: door) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .mapControls { MapUserLocationButton() }
                // Tap to add: convert the tap point to a coordinate and drop a not-at-home.
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        addDoor(at: coordinate)
                    }
                }
            }
            .overlay(alignment: .top) { hintBanner }
            .safeAreaInset(edge: .bottom) { selectedCard }
            .navigationTitle("Not-at-homes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear { locationManager.requestWhenInUseAuthorization() }
        }
    }

    // MARK: Pins

    private func pin(for door: NotAtHome) -> some View {
        Image(systemName: "house.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(7)
            .background(color(for: door), in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .shadow(radius: 2)
            .scaleEffect(selected == door ? 1.25 : 1)
            .animation(.spring(duration: 0.2), value: selected)
    }

    /// Tint by the return hint's priority — the doors most worth another knock stand out.
    private func color(for door: NotAtHome) -> Color {
        switch door.returnHint.priority {
        case 3...: return .red
        case 2:    return .orange
        case 1:    return .blue
        default:   return .gray
        }
    }

    // MARK: Banner + selected card

    private var hintBanner: some View {
        Text(justAdded ? "Added — knock and it logs the time"
                       : "Tap the map to drop a not-at-home")
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            .padding(.top, 8)
            .animation(.easeInOut, value: justAdded)
    }

    @ViewBuilder
    private var selectedCard: some View {
        if let door = selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(door.address.isEmpty ? "Locating…" : door.address)
                            .font(.headline).lineLimit(2)
                        Text("Tried \(door.attemptCount)× · last \(door.lastTriedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let hint = door.returnHint.text {
                            Label(hint, systemImage: door.returnHint.symbol)
                                .font(.caption2.weight(.medium)).foregroundStyle(.blue)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { selected = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 10) {
                    Button {
                        door.markTriedAgain(); territory.touch(); context.saveIfPossible()
                    } label: {
                        Label("Tried again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        // Hand back to the detail screen, which presents the promote sheet.
                        selected = nil; dismiss(); onAnswered(door)
                    } label: {
                        Label("Answered", systemImage: "person.fill.checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                    Button(role: .destructive) {
                        context.delete(door); context.saveIfPossible(); selected = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Add

    private func addDoor(at coordinate: CLLocationCoordinate2D) {
        let door = NotAtHome(address: "",
                             latitude: coordinate.latitude,
                             longitude: coordinate.longitude)
        door.territory = territory
        context.insert(door)
        territory.touch()
        context.saveIfPossible()
        selected = door
        withAnimation { justAdded = true }
        Task {
            let address = await AddressGeocoder.address(for: coordinate)
            if !address.isEmpty { door.address = address; context.saveIfPossible() }
            try? await Task.sleep(for: .seconds(2))
            withAnimation { justAdded = false }
        }
    }
}
