import SwiftUI
import SwiftData

/// Soft-deleted notes for a person, kept for 30 days. Swipe to restore or delete permanently.
struct RecentlyDeletedView: View {
    @Bindable var person: Person
    @Environment(\.modelContext) private var context

    var body: some View {
        List {
            Section {
                ForEach(person.recentlyDeletedEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text)
                        if let deletedAt = entry.deletedAt {
                            Text("Deleted \(deletedAt.formatted(date: .abbreviated, time: .omitted)) · \(daysLeft(deletedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .leading) {
                        Button { restore(entry) } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleteNow(entry) } label: {
                            Label("Delete Now", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("Notes are kept here for 30 days, then permanently deleted.")
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if person.recentlyDeletedEntries.isEmpty {
                ContentUnavailableView(
                    "Nothing here",
                    systemImage: "trash",
                    description: Text("Deleted notes appear here for 30 days, then they're gone.")
                )
            }
        }
    }

    private func restore(_ entry: JournalEntry) {
        entry.deletedAt = nil
        context.saveIfPossible()
    }

    private func deleteNow(_ entry: JournalEntry) {
        context.delete(entry)
        context.saveIfPossible()
    }

    private func daysLeft(_ deletedAt: Date) -> String {
        let purge = Calendar.current.date(byAdding: .day, value: 30, to: deletedAt) ?? deletedAt
        let days = Calendar.current.dateComponents([.day], from: .now, to: purge).day ?? 0
        return days <= 0 ? "removing soon" : "\(days)d left"
    }
}
