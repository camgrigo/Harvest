import SwiftUI
import SwiftData

/// The door lists for a territory: the do-not-call list (when present) and the not-at-home list
/// you build as you walk. Rendered as List sections inside `TerritoryDetailView`. Tapping or
/// swiping "Answered" on a door hands it back to the parent via `onAnswered`, which presents the
/// promote sheet.
struct TerritoryDoorsSection: View {
    @Bindable var territory: Territory
    /// Called when a door is answered — the parent presents the AnsweredSheet for it.
    var onAnswered: (NotAtHome) -> Void

    @Environment(\.modelContext) private var context

    /// Doors ordered so the ones most worth knocking now (clear time suggestion, fewer attempts)
    /// rise to the top — without disturbing `Territory.sortedDoors` (used by the cards elsewhere).
    private var doors: [NotAtHome] {
        territory.sortedDoors.sorted { a, b in
            let pa = a.returnHint.priority, pb = b.returnHint.priority
            if pa != pb { return pa > pb }
            if a.attemptCount != b.attemptCount { return a.attemptCount < b.attemptCount }
            return a.lastTriedAt > b.lastTriedAt
        }
    }
    private var doNotCalls: [DoNotCall] { territory.sortedDoNotCalls }

    var body: some View {
        if !doNotCalls.isEmpty { doNotCallSection }
        notAtHomeSection
    }

    private var doNotCallSection: some View {
        Section("Do not call") {
            ForEach(doNotCalls) { dnc in
                Label {
                    Text(dnc.address)
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.red)
                }
            }
            .onDelete(perform: deleteDoNotCalls)
        }
    }

    private var notAtHomeSection: some View {
        Section(doNotCalls.isEmpty ? "" : "Not-at-homes") {
            if doors.isEmpty {
                Text("No not-at-homes yet. Tap “Add nearest address” or type one below as you walk.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(doors) { door in
                    NotAtHomeRow(door: door)
                        .contentShape(Rectangle())
                        .onTapGesture { onAnswered(door) }
                        .swipeActions(edge: .leading) {
                            Button {
                                door.markTriedAgain(); territory.touch(); context.saveIfPossible()
                            } label: {
                                Label("Tried again", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                            Button {
                                door.decrementTry(); context.saveIfPossible()
                            } label: {
                                Label("Undo try", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.gray)
                            .disabled(door.attemptCount <= 1)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteDoor(door)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                onAnswered(door)
                            } label: {
                                Label("Answered", systemImage: "person.fill.checkmark")
                            }
                            .tint(.green)
                        }
                }
            }
        }
    }

    private func deleteDoor(_ door: NotAtHome) {
        context.delete(door)
        context.saveIfPossible()
    }

    private func deleteDoNotCalls(_ offsets: IndexSet) {
        for index in offsets { context.delete(doNotCalls[index]) }
        context.saveIfPossible()
    }
}

/// One door row: address, attempt count + last-tried, and a best-time-to-return hint.
struct NotAtHomeRow: View {
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

            if let hint = door.returnHint.text {
                Label(hint, systemImage: door.returnHint.symbol)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("notAtHome.hint")
            }
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview("Doors section") {
    List {
        TerritoryDoorsSection(territory: PreviewData.territory) { _ in }
    }
    .modelContainer(PreviewData.container)
}

#Preview("Not-at-home row") {
    List {
        NotAtHomeRow(door: PreviewData.door)
    }
    .modelContainer(PreviewData.container)
}
#endif
