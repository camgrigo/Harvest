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

    @State private var importPassphrase = ""
    @State private var pendingImport: Data?
    @State private var showImporter = false
    @State private var showRestoreConfirm = false

    @State private var alertMessage: String?
    @State private var didRestore = false

    @AppStorage("map.look") private var mapLook: MapLook = .standard

    private var defaultFilename: String {
        "Harvest-backup-\(DateFormatter.ymd.string(from: .now))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Map") {
                    Picker("Map look", selection: $mapLook) {
                        ForEach(MapLook.allCases) { look in
                            Text(look.label).tag(look)
                        }
                    }
                }
                Section {
                    SecureField("Passphrase", text: $passphrase)
                        .textContentType(.password)
                    Button {
                        export()
                    } label: {
                        Label("Export encrypted backup", systemImage: "lock.doc")
                    }
                    .disabled(passphrase.count < 4)
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Your whole notebook is encrypted with this passphrase into one file. It stays on your device unless you share it — and can't be opened without the passphrase, so keep it somewhere safe.")
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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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

    private func export() {
        do {
            let data = try BackupService.makeBackup(context: context, passphrase: passphrase)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(defaultFilename).harvestbackup")
            try data.write(to: url, options: .atomic)
            shareItem = ShareItem(url: url)
        } catch {
            alertMessage = error.localizedDescription
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
