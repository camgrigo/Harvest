import SwiftUI
import SwiftData
import CoreLocation

/// A quick inline composer for a new territory: just a name, with an optional "use my area"
/// toggle that stamps your current location as the territory's center. Created and handed back
/// immediately via `onCreated` so the caller can open it and start dropping doors.
struct AddTerritoryInline: View {
    @Environment(\.modelContext) private var context
    var onCreated: (Territory) -> Void
    var onCancel: () -> Void

    @State private var name = ""
    @State private var useMyArea = true
    @State private var creating = false
    @FocusState private var focused: Bool
    @StateObject private var locator = CurrentLocationProvider()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("New territory", systemImage: "map")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                Button("Cancel") { onCancel() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("Territory name", text: $name)
                .font(.body)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { create() }

            Toggle(isOn: $useMyArea) {
                Label("Use my area", systemImage: "location")
                    .font(.subheadline)
            }

            Button {
                create()
            } label: {
                Text(creating ? "Creating…" : "Create")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            .controlSize(.regular)
        }
        .padding(14)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16))
        .onAppear { focused = true }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !creating else { return }
        creating = true
        Task {
            var coord: CLLocationCoordinate2D?
            if useMyArea { coord = (await locator.current())?.coordinate }
            let territory = Territory(name: trimmed,
                                      latitude: coord?.latitude,
                                      longitude: coord?.longitude)
            context.insert(territory)
            context.saveIfPossible()
            creating = false
            onCreated(territory)
        }
    }
}

#if DEBUG
#Preview("Add territory inline") {
    AddTerritoryInline(onCreated: { _ in }, onCancel: {})
        .padding()
        .modelContainer(PreviewData.container)
}
#endif
