import SwiftUI
import SwiftData

/// A simple running list of not-at-homes, built for adding fast while you walk the territory:
/// one big button drops the nearest address. Tracks how many times and when you last tried so
/// you can come back at a different time of day.
struct NotAtHomeListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \NotAtHome.createdAt, order: .reverse) private var doors: [NotAtHome]

    @StateObject private var location = CurrentLocationProvider()
    @State private var isAdding = false
    @State private var showDeniedAlert = false
    @State private var showManualAdd = false
    @State private var addedCount = 0

    var body: some View {
        NavigationStack {
            Group {
                if doors.isEmpty {
                    ContentUnavailableView(
                        "No not-at-homes yet",
                        systemImage: "door.left.hand.closed",
                        description: Text("Tap “Add nearest address” as you walk to log a door where no one answered.")
                    )
                } else {
                    List {
                        ForEach(doors) { door in
                            NotAtHomeRow(door: door)
                                .swipeActions(edge: .leading) {
                                    Button {
                                        door.markTriedAgain()
                                        context.saveIfPossible()
                                    } label: {
                                        Label("Tried again", systemImage: "arrow.clockwise")
                                    }
                                    .tint(.blue)
                                }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Not-at-Homes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showManualAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                addNearestButton
            }
            .sheet(isPresented: $showManualAdd) {
                ManualNotAtHomeSheet()
            }
            .alert("Location unavailable", isPresented: $showDeniedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Allow location access in Settings to add the nearest address, or use + to type one.")
            }
            .sensoryFeedback(.success, trigger: addedCount)
        }
    }

    private var addNearestButton: some View {
        Button {
            Task { await addNearest() }
        } label: {
            HStack(spacing: 8) {
                if isAdding {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "location.fill")
                }
                Text(isAdding ? "Finding address…" : "Add nearest address")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isAdding)
        .padding()
        .background(.bar)
    }

    private func addNearest() async {
        isAdding = true
        defer { isAdding = false }

        guard let location = await location.current() else {
            showDeniedAlert = true
            return
        }
        let coordinate = location.coordinate
        let address = await AddressGeocoder.address(for: coordinate)
        let door = NotAtHome(
            address: address.isEmpty ? "Dropped location" : address,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        context.insert(door)
        context.saveIfPossible()
        addedCount += 1
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { context.delete(doors[index]) }
        context.saveIfPossible()
    }
}

private struct NotAtHomeRow: View {
    let door: NotAtHome

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(door.address)
                .accessibilityIdentifier("notAtHome.address")
            HStack(spacing: 6) {
                Text("Tried \(door.attemptCount)×")
                Text("· last \(door.lastTriedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Fallback for adding a door by hand when location isn't available.
private struct ManualNotAtHomeSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Address", text: $address, axis: .vertical)
            }
            .navigationTitle("Add not-at-home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func add() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let door = NotAtHome(address: trimmed)
        context.insert(door)
        Task {
            // Best-effort pin so it could show on a map later; not required.
            if let coordinate = await AddressGeocoder.coordinate(for: trimmed) {
                door.latitude = coordinate.latitude
                door.longitude = coordinate.longitude
            }
            context.saveIfPossible()
        }
        context.saveIfPossible()
        dismiss()
    }
}
