import SwiftUI
import SwiftData

/// Start/Stop timer with a live elapsed badge plus access to session history and the monthly
/// rollup. Designed to sit in the Calendar tab's bottom safe-area inset.
struct ServiceSessionControlView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ServiceSession.startAt, order: .reverse) private var allSessions: [ServiceSession]

    @State private var showHistory = false
    /// Drives the elapsed-time label and the Live Activity update tick.
    @State private var now: Date = .now

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var activeSession: ServiceSession? {
        allSessions.first { $0.endAt == nil && $0.deletedAt == nil }
    }

    private var elapsedString: String {
        guard let session = activeSession else { return "0:00" }
        let seconds = max(0, Int(now.timeIntervalSince(session.startAt)))
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    var body: some View {
        HStack {
            if let session = activeSession {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active session").font(.caption).foregroundStyle(.secondary)
                    Text(elapsedString).font(.system(.headline, design: .monospaced))
                        .monospacedDigit()
                }
                Spacer()
                Button(role: .destructive) { stop(session) } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else {
                Button { start() } label: {
                    Label("Start session", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button { showHistory = true } label: {
                    Label("Reports", systemImage: "chart.bar.doc.horizontal")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Session history and monthly report")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onReceive(tick) { date in
            now = date
            if let session = activeSession {
                SessionActivityManager.updateActivity(
                    elapsedSeconds: max(0, Int(date.timeIntervalSince(session.startAt))))
            }
        }
        .sheet(isPresented: $showHistory) { SessionHistoryView() }
    }

    private func start() {
        let session = ServiceSession()
        context.insert(session)
        context.saveIfPossible()
        SessionActivityManager.startActivity(sessionStartedAt: session.startAt)
    }

    private func stop(_ session: ServiceSession) {
        session.stop()
        context.saveIfPossible()
        SessionActivityManager.endActivity()
    }
}

/// Monthly rollup summary plus a list of completed sessions; swipe-to-delete soft-deletes.
struct SessionHistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ServiceSession.startAt, order: .reverse) private var allSessions: [ServiceSession]

    private var completed: [ServiceSession] {
        allSessions.filter { $0.endAt != nil && $0.deletedAt == nil }
    }

    private var stats: (year: Int, month: Int, hours: Double, count: Int) {
        SessionReportEngine.thisMonthStats(context: context)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                monthlySummary
                if completed.isEmpty {
                    ContentUnavailableView("No completed sessions", systemImage: "timer")
                        .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(completed) { SessionRow(session: $0) }
                            .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
        }
    }

    private var monthlySummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This month").font(.headline)
            HStack {
                VStack(alignment: .leading) {
                    Text("Sessions").font(.caption).foregroundStyle(.secondary)
                    Text("\(stats.count)").font(.title2.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Hours").font(.caption).foregroundStyle(.secondary)
                    Text(stats.hours.formatted(.number.precision(.fractionLength(1))))
                        .font(.title2.weight(.semibold)).monospacedDigit()
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { completed[index].markDeleted() }
        context.saveIfPossible()
    }
}

/// A single completed-session row: start time, end time, and duration.
struct SessionRow: View {
    let session: ServiceSession

    private var durationString: String {
        guard let seconds = session.durationSeconds else { return "—" }
        let hours = seconds / 3600, mins = (seconds % 3600) / 60
        return hours > 0 ? "\(hours) h \(mins) m" : "\(mins) m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.startAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .font(.headline)
                    if let endAt = session.endAt {
                        Text("Ended \(endAt.formatted(.dateTime.hour().minute()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(durationString)
                    .font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let territory = session.territory, !territory.name.isEmpty {
                Label(territory.name, systemImage: "map").font(.caption).foregroundStyle(.secondary)
            }
            if !session.notes.isEmpty {
                Text(session.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview("Session Control") {
    ServiceSessionControlView()
        .modelContainer(PreviewData.container)
}

#Preview("Session History") {
    NavigationStack {
        SessionHistoryView()
    }
    .modelContainer(PreviewData.container)
}

#Preview("Session Row") {
    List {
        SessionRow(session: PreviewData.session)
    }
    .modelContainer(PreviewData.container)
}
#endif
