import SwiftUI
import MapKit
import CoreLocation
import UIKit

// MARK: - Look Around thumbnail

/// In-memory cache of Look Around stills, keyed by rounded coordinate, so scrolling a row off
/// and back reuses the snapshot instead of re-fetching and flashing empty. Main-actor isolated,
/// so the cached `UIImage`s never cross an isolation boundary.
@MainActor
enum LookAroundCache {
    static var images: [String: UIImage] = [:]

    static func key(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
    }
}

/// A square Look Around still for a coordinate, loaded lazily and cached. The leading edge fades
/// to transparency (only when an image is present) so it blends into the glass row; an optional
/// distance badge sits bottom-trailing.
struct RowLookAround: View {
    let coordinate: CLLocationCoordinate2D
    var distanceText: String? = nil
    /// Leading edge fades to transparent so the still blends into a glass row. Off for hero images.
    var feather: Bool = true

    @State private var image: UIImage?
    @State private var didLoad = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .mask(
                            LinearGradient(
                                stops: feather
                                    ? [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.16)]
                                    : [.init(color: .black, location: 0),
                                       .init(color: .black, location: 1)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                    if let distanceText {
                        Text(distanceText)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .padding(8)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task {
            guard !didLoad else { return }
            let key = LookAroundCache.key(for: coordinate)
            if let cached = LookAroundCache.images[key] {
                image = cached
                didLoad = true
                return
            }
            if let loaded = await Self.loadImage(at: coordinate) {
                LookAroundCache.images[key] = loaded
                image = loaded
            }
            didLoad = true
        }
    }

    /// Fetches the scene and renders it to a still off the main actor (both are non-Sendable);
    /// `sending` lets the finished image cross back to the view safely.
    private nonisolated static func loadImage(
        at coordinate: CLLocationCoordinate2D
    ) async -> sending UIImage? {
        guard let scene = try? await MKLookAroundSceneRequest(coordinate: coordinate).scene else {
            return nil
        }
        let options = MKLookAroundSnapshotter.Options()
        options.size = CGSize(width: 400, height: 400)
        options.pointOfInterestFilter = .excludingAll
        guard let snapshot = try? await MKLookAroundSnapshotter(scene: scene, options: options).snapshot else {
            return nil
        }
        return snapshot.image
    }
}

// MARK: - Shared card text

/// Short "due" label for a person's next-visit date, shared by the list + grid cards.
func personDueText(_ person: Person) -> String? {
    guard let date = person.nextVisitDate else { return nil }
    let calendar = Calendar.current
    let days = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: .now),
        to: calendar.startOfDay(for: date)
    ).day ?? 0

    switch days {
    case 0:      return "Due today"
    case ..<0:   return days == -1 ? "Overdue 1d" : "Overdue \(-days)d"
    case 1:      return "Tomorrow"
    case 2...14: return "in \(days)d"
    default:     return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Door-count + "last worked" subtitle for a territory, shared by the list + grid cards.
func territorySubtitle(_ territory: Territory) -> String {
    let n = territory.doorCount
    let doors = n == 1 ? "1 not-at-home" : "\(n) not-at-homes"
    if let worked = territory.lastWorkedAt {
        return "\(doors) · last worked \(worked.formatted(.dateTime.weekday(.abbreviated)))"
    }
    return n == 0 ? "No not-at-homes yet" : doors
}

// MARK: - Person card

/// A scannable card for one person: a square Look Around still (with distance badge overlaid),
/// the name with a small status icon after it, a headline, and the reminder date at the bottom.
struct PersonCard: View {
    let person: Person
    let distanceText: String?

    private static let thumbWidth: CGFloat = 116

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(person.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("personRow.name")
                    if person.interest != .interested {
                        Image(systemName: person.interest.symbol)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .accessibilityLabel(person.interest.label)
                    }
                    Spacer(minLength: 0)
                }
                if !person.headline.isEmpty {
                    Text(person.headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let due = personDueText(person) {
                    Text(due)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(person.isDue ? .red : .secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let coordinate = person.coordinate {
                thumbnail(coordinate)
            }
        }
        .frame(minHeight: 96)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func thumbnail(_ coordinate: CLLocationCoordinate2D) -> some View {
        RowLookAround(coordinate: coordinate, distanceText: distanceText)
            .frame(width: Self.thumbWidth)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

// MARK: - Territory card

/// A scannable card for one territory: name with the territory glyph, a door count + "last worked"
/// subtitle, and a trailing glass tile (sized to match a person's thumbnail) with the distance
/// badge overlaid.
struct TerritoryCard: View {
    let territory: Territory
    let distanceText: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(territory.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image("Territory")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                Text(territorySubtitle(territory))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            tile
        }
        .padding(12)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16))
    }

    private var tile: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.tint.opacity(0.15))
                .frame(width: 84, height: 84)
                .overlay {
                    Image("Territory")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            if let distanceText {
                Text(distanceText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .padding(5)
            }
        }
    }
}

// MARK: - Grid (masonry) cards

/// Image-forward person card for the masonry grid: a Look Around hero on top (its height varies
/// per card to create the staggered look), then the name, headline, and due line below.
struct PersonGridCard: View {
    let person: Person
    let distanceText: String?
    let heroHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let coordinate = person.coordinate {
                RowLookAround(coordinate: coordinate, distanceText: distanceText, feather: false)
                    .frame(height: heroHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(person.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if person.interest != .interested {
                        Image(systemName: person.interest.symbol)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .accessibilityLabel(person.interest.label)
                    }
                    Spacer(minLength: 0)
                }
                if !person.headline.isEmpty {
                    Text(person.headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let due = personDueText(person) {
                    Text(due)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(person.isDue ? .red : .secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glassEffect(in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// Image-forward territory card for the masonry grid: a tinted glyph tile on top, then the name
/// and the door-count subtitle.
struct TerritoryGridCard: View {
    let territory: Territory
    let distanceText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Rectangle()
                    .fill(.tint.opacity(0.15))
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        Image("Territory")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                if let distanceText {
                    Text(distanceText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(territory.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image("Territory")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                Text(territorySubtitle(territory))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glassEffect(in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
