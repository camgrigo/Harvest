import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

/// A sharable reference to the encrypted backup, written to a temp file.
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet (AirDrop, Messages, Mail, Save to Files, …) for the backup file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Backup & restore. Export the whole notebook as one passphrase-encrypted file; restore replaces
/// everything with a backup's contents. Everything is on-device and end-to-end private.
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase = ""
    @State private var shareItem: ShareItem?
    @State private var useFaceID = false
    @State private var isWorking = false
    @AppStorage("harvest.autoBackupEnabled") private var autoBackupEnabled = false

    @State private var importPassphrase = ""
    @State private var pendingImport: Data?
    @State private var showImporter = false
    @State private var showRestoreConfirm = false

    @State private var alertMessage: String?
    @State private var didRestore = false

    /// The user's reminder preferences, loaded from `UserDefaults` and saved whenever changed.
    @State private var policy = NotificationPolicyStore.load()

    private var defaultFilename: String {
        "Harvest-backup-\(DateFormatter.ymd.string(from: .now))"
    }

    var body: some View {
        NavigationStack {
            Form {
                remindersSection

                Section {
                    SecureField("Passphrase", text: $passphrase)
                        .textContentType(.password)
                    Toggle("Use Face ID to protect backup", isOn: $useFaceID)
                    Button {
                        export()
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Label("Export encrypted backup", systemImage: "lock.doc")
                        }
                    }
                    .disabled((!useFaceID && passphrase.count < 4) || isWorking)
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Your whole notebook is encrypted into one file. It stays on your device unless you share it — and can't be opened without the passphrase, so keep it somewhere safe.\(useFaceID ? " Face ID protects this backup; you'll still keep a passphrase as a fallback." : "")")
                }

                Section {
                    Toggle("Daily backup to iCloud Drive", isOn: $autoBackupEnabled)
                        .disabled(passphrase.count < 4)
                        .onChange(of: autoBackupEnabled) { _, on in
                            BackupService.setAutoBackupPassphrase(on ? passphrase : nil)
                            if on { HarvestApp.scheduleAutoBackupTask() }
                        }
                        .onChange(of: passphrase) { _, newValue in
                            if autoBackupEnabled { BackupService.setAutoBackupPassphrase(newValue) }
                        }
                } header: {
                    Text("Automatic backup")
                } footer: {
                    Text("When on, Service Day writes an encrypted daily backup to your iCloud Drive using the passphrase above. Needs iCloud Drive enabled.")
                }

                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Choose backup file…", systemImage: "tray.and.arrow.down")
                    }
                    if pendingImport != nil {
                        SecureField("Backup passphrase", text: $importPassphrase)
                            .textContentType(.password)
                        Button(role: .destructive) {
                            showRestoreConfirm = true
                        } label: {
                            Label("Replace everything with this backup", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(importPassphrase.isEmpty)
                    }
                } header: {
                    Text("Restore")
                } footer: {
                    Text("Restoring replaces all current people, territories, and notes with the backup's contents.")
                }
            }
            .onChange(of: policy) { _, newValue in
                NotificationPolicyStore.save(newValue)
            }
            .navigationTitle("Backup & Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                handleImportPick(result)
            }
            .confirmationDialog("Replace all data with this backup?",
                                isPresented: $showRestoreConfirm, titleVisibility: .visible) {
                Button("Replace everything", role: .destructive) { restore() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
            .alert("Backup", isPresented: Binding(get: { alertMessage != nil },
                                                  set: { if !$0 { alertMessage = nil } })) {
                Button("OK", role: .cancel) { if didRestore { dismiss() } }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    /// Reminders preferences: master switch and optional quiet hours.
    @ViewBuilder
    private var remindersSection: some View {
        Section {
            Toggle("Reminders", isOn: $policy.remindersEnabled)
            if policy.remindersEnabled {
                Toggle("Quiet hours", isOn: $policy.quietHoursEnabled)
                if policy.quietHoursEnabled {
                    Picker("From", selection: $policy.quietHoursStart) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(Self.hourLabel(hour)).tag(hour)
                        }
                    }
                    Picker("To", selection: $policy.quietHoursEnd) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(Self.hourLabel(hour)).tag(hour)
                        }
                    }
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Reminders that are overdue or due within the hour stay urgent; the rest are gentle so your Focus and notification summary can handle them. Quiet hours nudge a reminder to the morning instead of waking you.")
        }
    }

    /// "9:00 AM"-style label for an hour-of-day, using the device's locale.
    private static func hourLabel(_ hour: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour
        let date = Calendar.current.date(from: comps) ?? .now
        return date.formatted(.dateTime.hour().minute())
    }

    private func export() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let strategy: KeyDerivationStrategy = useFaceID ? .biometric : .passphrase(passphrase)
                let data = try await BackupService.makeBackup(context: context, strategy: strategy)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(defaultFilename).harvestbackup")
                try data.write(to: url, options: .atomic)
                shareItem = ShareItem(url: url)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func handleImportPick(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                pendingImport = try Data(contentsOf: url)
            } catch {
                alertMessage = error.localizedDescription
            }
        case .failure(let error):
            alertMessage = error.localizedDescription
        }
    }

    private func restore() {
        guard let data = pendingImport else { return }
        do {
            try BackupService.restore(from: data, passphrase: importPassphrase, into: context)
            didRestore = true
            pendingImport = nil
            importPassphrase = ""
            alertMessage = "Backup restored."
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

#if DEBUG
#Preview("Settings") {
    NavigationStack {
        SettingsView()
    }
    .modelContainer(PreviewData.container)
}

// ShareSheet is a UIActivityViewController wrapper; a static preview is low-value, so it's skipped.
#endif
