import SwiftUI
import MapKit
import CoreLocation
import UIKit

// MARK: - Per-person style

/// The typeface a person's name is shown in — chosen on their page.
enum PersonFont: String, CaseIterable, Identifiable {
    case serif, system, rounded, monospaced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .serif:      "Serif"
        case .system:     "System"
        case .rounded:    "Rounded"
        case .monospaced: "Mono"
        }
    }
    var design: Font.Design {
        switch self {
        case .serif:      .serif
        case .system:     .default
        case .rounded:    .rounded
        case .monospaced: .monospaced
        }
    }
}

/// A per-person color theme — tints their card's frame and status label.
enum PersonTheme: String, CaseIterable, Identifiable {
    case classic, ocean, forest, sunset, grape, rose, slate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .classic: "Classic"
        case .ocean:   "Ocean"
        case .forest:  "Forest"
        case .sunset:  "Sunset"
        case .grape:   "Grape"
        case .rose:    "Rose"
        case .slate:   "Slate"
        }
    }
    var color: Color {
        switch self {
        case .classic: .accentColor
        case .ocean:   .teal
        case .forest:  .green
        case .sunset:  .orange
        case .grape:   .purple
        case .rose:    .pink
        case .slate:   Color(.systemGray)
        }
    }
}

extension Person {
    var nameFont: PersonFont { PersonFont(rawValue: nameFontRaw) ?? .serif }
    var theme: PersonTheme { PersonTheme(rawValue: themeRaw) ?? .classic }
}

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

/// A square Look Around still for a coordinate, loaded lazily and cached. An optional distance
/// badge sits bottom-trailing. `feather` fades the leading edge (used by the old side thumbnail);
/// the feed's hero images turn it off.
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
                    Rectangle().fill(.quaternary)
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
        options.size = CGSize(width: 600, height: 600)
        options.pointOfInterestFilter = .excludingAll
        guard let snapshot = try? await MKLookAroundSnapshotter(scene: scene, options: options).snapshot else {
            return nil
        }
        return snapshot.image
    }
}

// MARK: - Shared card text

/// Short "due" label for a person's next-visit date, shared by the feed cards.
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

/// Door-count + "last worked" subtitle for a territory, shared by the feed cards.
func territorySubtitle(_ territory: Territory) -> String {
    let n = territory.doorCount
    let doors = n == 1 ? "1 not-at-home" : "\(n) not-at-homes"
    if let worked = territory.lastWorkedAt {
        return "\(doors) · last worked \(worked.formatted(.dateTime.weekday(.abbreviated)))"
    }
    return n == 0 ? "No not-at-homes yet" : doors
}

// MARK: - Card surface

private extension View {
    /// The opaque, softly shadowed card surface shared by the Explore feed cards — modeled on the
    /// iOS 26 Siri/Notes masonry: a solid rounded tile that lifts off the sheet with a gentle shadow.
    func feedCardSurface(borderColor: Color = Color.primary.opacity(0.06),
                         borderWidth: CGFloat = 0.5) -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Feed cards (masonry)

/// A person card for the Explore masonry: a small status label, the name as a bold title, the
/// headline as a preview, and — when the visit is placed — a Look Around hero photo.
struct PersonGridCard: View {
    let person: Person
    let distanceText: String?
    let heroHeight: CGFloat

    var body: some View {
        if let coordinate = person.coordinate {
            // Located visit: the Look Around photo fills the whole card; text layers on top over a
            // top-down scrim and carries a soft shadow so it stays legible on bright/busy photos.
            content(onImage: true)
                .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 1)
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: heroHeight, alignment: .topLeading)
                .background {
                    ZStack {
                        RowLookAround(coordinate: coordinate, feather: false)
                        // A top-weighted scrim: dark behind the text up top, fading toward the
                        // bottom so more of the Look Around photo stays visible on the taller cards.
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.80), location: 0),
                                .init(color: .black.opacity(0.38), location: 0.45),
                                .init(color: .black.opacity(0.16), location: 1.0),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(person.theme.color.opacity(0.85), lineWidth: 2.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        } else {
            // No photo: a solid text tile, framed in the person's theme color.
            content(onImage: false)
                .feedCardSurface(borderColor: person.theme.color.opacity(0.55), borderWidth: 1.5)
        }
    }

    @ViewBuilder
    private func content(onImage: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if topLabel != nil || distanceText != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let label = topLabel {
                        Text(label.text)
                            .foregroundStyle(onImage ? (person.isDue ? Color.red : Color.white.opacity(0.95))
                                                     : (person.isDue ? Color.red : person.theme.color))
                    }
                    Spacer(minLength: 0)
                    if let distanceText {
                        Text(distanceText)
                            .foregroundStyle(onImage ? Color.white.opacity(0.95) : Color.secondary)
                    }
                }
                .font(.caption.weight(.semibold))
            }
            Text(person.name)
                .font(.title3.weight(.bold))
                .fontDesign(person.nameFont.design)
                .foregroundStyle(onImage ? Color.white : Color.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("personRow.name")
            if !person.headline.isEmpty {
                Text(person.headline)
                    .font(.subheadline)
                    .foregroundStyle(onImage ? Color.white.opacity(0.92) : Color.secondary)
                    .lineLimit(onImage ? 3 : 5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Top meta line: the due date (red when due/overdue) or, failing that, the interest status.
    private var topLabel: (text: String, color: Color)? {
        if let due = personDueText(person) {
            return (due, person.isDue ? .red : .secondary)
        }
        if person.interest != .interested {
            return (person.interest.label, .secondary)
        }
        return nil
    }
}

/// A territory card for the Explore masonry: an accent "Territory" label (territories have no
/// photo), the name as a bold title, and the door-count subtitle as a preview.
struct TerritoryGridCard: View {
    let territory: Territory
    let distanceText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image("Territory")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .accessibilityHidden(true)
                Text("Territory")
                Spacer(minLength: 0)
                if let distanceText {
                    Text(distanceText).foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)

            Text(territory.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Text(territorySubtitle(territory))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .feedCardSurface()
    }
}
