import SwiftUI
import MapKit
import CoreLocation

/// A tappable row that opens an address or coordinate in Apple Maps. Used anywhere we show
/// a location so you can jump straight to directions without retyping the address.
struct MapsLinkRow: View {
    var title: String = "Open in Apple Maps"
    var address: String = ""
    var coordinate: CLLocationCoordinate2D?
    var directions: Bool = true

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: open) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !address.isEmpty, address != title {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } icon: {
                Image(systemName: "map.fill")
            }
        }
    }

    private func open() {
        if let coordinate {
            let item = MKMapItem(
                location: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
                address: nil
            )
            item.name = address.isEmpty ? title : address
            item.openInMaps(launchOptions: directions
                ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
                : nil)
        } else if !address.isEmpty {
            let query = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "http://maps.apple.com/?q=\(query)") { openURL(url) }
        }
    }
}

/// A tappable row that navigates to a person's page. Must live inside a `NavigationStack`.
struct PersonLinkRow: View {
    let person: Person

    var body: some View {
        NavigationLink {
            PersonDetailView(person: person)
        } label: {
            PersonRowContent(person: person)
        }
    }
}

/// The shared row layout for a person: interest icon, name, one-line gist, and a due date.
struct PersonRowContent: View {
    let person: Person

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .accessibilityIdentifier("personRow.name")
                if !person.headline.isEmpty {
                    Text(person.headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if let due = person.nextVisitDate {
                    Text(due.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.caption)
                        .foregroundStyle(person.isDue ? .red : .secondary)
                }
            }
        } icon: {
            Image(systemName: person.interest.symbol)
        }
    }
}
