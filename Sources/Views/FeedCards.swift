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
    /// Bounded so a long-lived session can't accumulate snapshots without limit (~120 stills ≈
    /// tens of MB). Eviction is a simple reset — the next scroll re-fills what's visible.
    private static let maxEntries = 120

    static func key(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
    }

    static func store(_ image: UIImage, for key: String) {
        if images.count >= maxEntries { images.removeAll(keepingCapacity: true) }
        images[key] = image
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
                LookAroundCache.store(loaded, for: key)
                image = loaded
            }
            didLoad = true
        }
    }

    /// Fetches a Look Around still where there's coverage, else falls back to a plain map snapshot,
    /// so a located card is never a blank box. Rendered off the main actor (both APIs are
    /// non-Sendable); `sending` lets the finished image cross back to the view safely.
    private nonisolated static func loadImage(
        at coordinate: CLLocationCoordinate2D
    ) async -> sending UIImage? {
        if let scene = try? await MKLookAroundSceneRequest(coordinate: coordinate).scene {
            let options = MKLookAroundSnapshotter.Options()
            options.size = CGSize(width: 600, height: 600)
            options.pointOfInterestFilter = .excludingAll
            if let snapshot = try? await MKLookAroundSnapshotter(scene: scene, options: options).snapshot {
                return snapshot.image
            }
        }
        // No Look Around coverage (common away from major streets) — show the map instead of nothing.
        return await mapSnapshot(at: coordinate)
    }

    /// A plain map still centered on the coordinate — the fallback when Look Around has no imagery.
    private nonisolated static func mapSnapshot(
        at coordinate: CLLocationCoordinate2D
    ) async -> sending UIImage? {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coordinate, latitudinalMeters: 350, longitudinalMeters: 350)
        options.size = CGSize(width: 600, height: 600)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
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
    var base: String
    if let worked = territory.lastWorkedAt {
        base = "\(doors) · last worked \(worked.formatted(.dateTime.weekday(.abbreviated)))"
    } else {
        base = n == 0 ? "No not-at-homes yet" : doors
    }
    if let days = territory.daysUntilDue() {
        let due: String
        switch days {
        case 0:    due = "Due today"
        case ..<0: due = days == -1 ? "Overdue 1d" : "Overdue \(-days)d"
        default:   due = "Due \(territory.dueDate!.formatted(.dateTime.month(.abbreviated).day()))"
        }
        base += " · \(due)"
    }
    return base
}

// MARK: - Card surface

/// Corner radius for the people/territory list cells — large and continuous, matching the
/// iOS 27 Siri tiles.
let feedCardCornerRadius: CGFloat = 30

private extension View {
    /// The card surface shared by the list cells: a solid rounded tile with a soft shadow, in the
    /// large continuous radius of the iOS 27 Siri tiles. Pass `glow: true` for a soft tint-colored
    /// halo instead of the neutral drop shadow (the territory card's identity-card look).
    func feedCardSurface(glow: Bool = false) -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: feedCardCornerRadius, style: .continuous))
            .shadow(color: glow ? Color.accentColor.opacity(0.25) : .black.opacity(0.10),
                    radius: glow ? 16 : 10, x: 0, y: glow ? 6 : 4)
    }

    /// Same tile, but with a Liquid Glass background instead of a solid fill (used by the person
    /// cells). Content sits on the glass; an embedded photo stays opaque over it.
    func feedCardGlassSurface() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular,
                         in: RoundedRectangle(cornerRadius: feedCardCornerRadius, style: .continuous))
    }
}

// MARK: - Feed cards (masonry)

/// A person card for the Explore masonry: a small status label, the name as a bold title, the
/// headline as a preview, and — when the visit is placed — a Look Around hero photo.
struct PersonGridCard: View {
    let person: Person
    let heroHeight: CGFloat

    var body: some View {
        // A Liquid Glass tile: the text up top, and — when the visit is placed — the Look Around
        // photo below it, rounded to the same corner radius as the card.
        VStack(alignment: .leading, spacing: 12) {
            content(onImage: false)
            if let coordinate = person.coordinate {
                RowLookAround(coordinate: coordinate, distanceText: nil, feather: false)
                    .frame(height: max(90, heroHeight - 110))
                    .clipShape(RoundedRectangle(cornerRadius: feedCardCornerRadius - 8,
                                                style: .continuous))
            }
        }
        .feedCardGlassSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// A clean, single VoiceOver readout for the card: name, status/due, and the gist.
    private var accessibilityText: String {
        var parts = [person.name]
        if let due = personDueText(person) { parts.append(due) }
        else if person.interest != .interested { parts.append(person.interest.label) }
        if !person.headline.isEmpty { parts.append(person.headline) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func content(onImage: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = topLabel {
                // Overdue shows an alarm glyph instead of the word; everything else is plain text.
                let isOverdue = label.text.hasPrefix("Overdue")
                Text(isOverdue
                     ? "\(Image(systemName: "alarm.fill")) \(label.text.replacingOccurrences(of: "Overdue ", with: ""))"
                     : "\(label.text)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(onImage ? (person.isDue ? Color.red : Color.white.opacity(0.95))
                                             : label.color)
            }
            // Name, with the interest status as a trailing inline glyph (leaf / book / pause) —
            // shown only when a status is set (".interested" reads as "None").
            Text(person.interest == .interested
                 ? "\(person.name)"
                 : "\(person.name) \(Image(systemName: person.interest.symbol))")
                .font(.title3.weight(.bold))
                .fontDesign(person.nameFont.design)
                .foregroundStyle(onImage ? Color.white : Color.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                // The status glyph is decorative; VoiceOver reads just the name (and the card's
                // composed label carries the status). Also keeps the name exactly matchable.
                .accessibilityLabel(person.name)
                .accessibilityIdentifier("personRow.name")
            if !person.studyLesson.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "book.fill")
                        .font(.caption2)
                    Text(lessonChipText)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(onImage ? Color.white.opacity(0.95) : Color.secondary)
            }
            if !person.headline.isEmpty {
                Text(person.headline)
                    .font(.subheadline)
                    .foregroundStyle(onImage ? Color.white.opacity(0.92) : Color.secondary)
                    .lineLimit(onImage ? 3 : 5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Lesson N" with the publication prefix when one is known.
    private var lessonChipText: String {
        let prefix = person.studyPublication.isEmpty ? "" : "\(person.studyPublication) — "
        return "\(prefix)Lesson \(person.studyLesson)"
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
                    .textCase(.uppercase)
                    .kerning(0.6)
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
        .feedCardSurface(glow: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Territory \(territory.name), \(territorySubtitle(territory))")
    }
}

#if DEBUG
#Preview("Person grid cards") {
    let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    ScrollView {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            PersonGridCard(person: PreviewData.person, heroHeight: 300)
            PersonGridCard(person: PreviewData.newPerson, heroHeight: 250)
            PersonGridCard(person: PreviewData.unlocatedPerson, heroHeight: 200)
        }
        .padding()
    }
    .modelContainer(PreviewData.container)
}

#Preview("Territory grid cards") {
    ScrollView {
        VStack(spacing: 12) {
            TerritoryGridCard(territory: PreviewData.territory, distanceText: "1.2 mi")
            TerritoryGridCard(territory: PreviewData.territory, distanceText: nil)
        }
        .padding()
    }
    .modelContainer(PreviewData.container)
}

#Preview("Look Around still") {
    RowLookAround(coordinate: PreviewData.sampleCoordinate, distanceText: "0.3 mi")
        .frame(height: 200)
        .padding()
}
#endif
