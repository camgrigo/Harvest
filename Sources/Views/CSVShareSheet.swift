import SwiftUI
import UniformTypeIdentifiers

/// A small sheet that offers a territory's address list as a `.csv` file via ShareLink.
/// The CSV is written to a temporary file so the share sheet hands targets a real `.csv`
/// document (email, Messages, AirDrop, or "Save to Files"). Everything stays on-device.
struct CSVShareSheet: View {
    let data: String
    let fileName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "tablecells")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)

                if let fileURL {
                    ShareLink(
                        item: fileURL,
                        subject: Text(fileName),
                        message: Text("Territory addresses and not-at-home list"),
                        label: { Label("Share CSV", systemImage: "square.and.arrow.up") }
                    )
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Text("Couldn't prepare the CSV file.")
                        .foregroundStyle(.secondary)
                }

                Text("Share via email, Messages, AirDrop, or save to Files. Everything stays on this device.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Export CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    /// A temp-file URL holding the CSV, named so targets recognize it as a spreadsheet.
    private var fileURL: URL? {
        let safeName = fileName.isEmpty ? "Territory.csv" : fileName
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do {
            try data.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
