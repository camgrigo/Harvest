import SwiftUI
import SwiftData
import CoreLocation
import PhotosUI
import UIKit

/// Create a territory by photographing its card. Take (or pick) a photo, OCR the do-not-call
/// list, review/correct the detected addresses, then create the territory — the scanned image is
/// attached and each address is geocoded so the territory finds its place on the map.
struct ScanTerritoryView: View {
    var onCreated: (Territory) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case choose, recognizing, review }

    @State private var stage: Stage = .choose
    @State private var pickedImage: UIImage?
    @State private var name = ""
    @State private var candidates: [TextRecognizer.Line] = []

    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .choose:      chooser
                case .recognizing: recognizing
                case .review:      review
                }
            }
            .navigationTitle("Scan territory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if stage == .review {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { create() }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            ImagePicker(sourceType: .camera) { image in
                handlePicked(image)
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    handlePicked(ui)
                }
                photoItem = nil
            }
        }
    }

    // MARK: Stages

    private var chooser: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Scan a territory card")
                .font(.title3.weight(.semibold))
            Text("Take a photo of the card's do-not-call list. The addresses are read on-device and used to place the territory on the map.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showCamera = true } label: {
                        Label("Take photo", systemImage: "camera.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button { showLibrary = true } label: {
                    Label("Choose photo", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.top, 8)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recognizing: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Reading the card…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var review: some View {
        Form {
            Section("Territory name") {
                TextField("e.g. 12-A or Oak St", text: $name)
            }

            if let img = pickedImage {
                Section {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .frame(maxWidth: .infinity)
                }
            }

            Section {
                if candidates.isEmpty {
                    Text("No addresses detected. You can still create the territory and add them later.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($candidates) { $line in
                        HStack(spacing: 10) {
                            Button {
                                line.looksLikeAddress.toggle()
                            } label: {
                                Image(systemName: line.looksLikeAddress ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(line.looksLikeAddress ? Color.accentColor : .secondary)
                            }
                            .buttonStyle(.plain)
                            TextField("Address", text: $line.text)
                        }
                    }
                }
            } header: {
                Text("Do-not-call addresses")
            } footer: {
                Text("Toggle off anything that isn't an address. Selected lines are saved as do-not-calls and used to locate the territory.")
            }
        }
    }

    // MARK: Flow

    private func handlePicked(_ image: UIImage) {
        pickedImage = image
        showCamera = false
        stage = .recognizing
        Task {
            let lines = await TextRecognizer.recognize(image)
            candidates = TextRecognizer.addressCandidates(from: lines)
            stage = .review
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let territory = Territory(name: trimmed.isEmpty ? "Scanned territory" : trimmed)
        if let img = pickedImage {
            territory.mapImageData = img.jpegData(compressionQuality: 0.8)
        }
        context.insert(territory)

        let chosen = candidates
            .filter { $0.looksLikeAddress }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var inserted: [DoNotCall] = []
        for address in chosen {
            let dnc = DoNotCall(address: address)
            context.insert(dnc)
            dnc.territory = territory
            inserted.append(dnc)
        }
        context.saveIfPossible()

        // Geocode each do-not-call in the background; the territory's pin follows their centroid.
        Task {
            for dnc in inserted {
                if let c = await AddressGeocoder.coordinate(for: dnc.address) {
                    dnc.latitude = c.latitude
                    dnc.longitude = c.longitude
                }
            }
            context.saveIfPossible()
        }

        onCreated(territory)
        dismiss()
    }
}

// (ImagePicker now lives in Sources/Views/ImagePicker.swift, shared with the territory screen.)
