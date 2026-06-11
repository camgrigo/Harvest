import SwiftUI
import SwiftData
import CoreLocation

/// Shown after you touch and hold a spot on the map: drop the pin onto a new return visit
/// or onto someone you already have.
struct LocationActionView: View {
    let coordinate: CLLocationCoordinate2D

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Person> { !$0.isArchived },
           sort: \Person.name) private var people: [Person]

    @State private var address = ""
    @State private var isLookingUp = true
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    if isLookingUp {
                        HStack { ProgressView(); Text("Looking up address…").foregroundStyle(.secondary) }
                    } else {
                        MapsLinkRow(title: address.isEmpty ? "Dropped pin" : address,
                                    coordinate: coordinate,
                                    directions: false)
                    }
                }

                Section("New return visit") {
                    TextField("Name", text: $newName)
                    Button("Create here") { createNew() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section("Assign to someone") {
                    if people.isEmpty {
                        Text("No one yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(people) { person in
                            Button {
                                assign(to: person)
                            } label: {
                                HStack {
                                    Text(person.name).foregroundStyle(.primary)
                                    Spacer()
                                    if person.coordinate != nil {
                                        Image(systemName: "mappin.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pin a location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                address = await AddressGeocoder.address(for: coordinate)
                isLookingUp = false
            }
        }
    }

    private func createNew() {
        let person = Person(name: newName.trimmingCharacters(in: .whitespaces), addressText: address)
        person.latitude = coordinate.latitude
        person.longitude = coordinate.longitude
        context.insert(person)
        context.saveIfPossible()
        dismiss()
    }

    private func assign(to person: Person) {
        person.latitude = coordinate.latitude
        person.longitude = coordinate.longitude
        if person.addressText.isEmpty { person.addressText = address }
        context.saveIfPossible()
        dismiss()
    }
}

#if DEBUG
#Preview("LocationActionView") {
    LocationActionView(coordinate: PreviewData.sampleCoordinate)
        .modelContainer(PreviewData.container)
}
#endif
