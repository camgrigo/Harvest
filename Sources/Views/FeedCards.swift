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
    /// The card surface shared by the territory list cells: Liquid Glass over a soft tinted
    /// backdrop (glass alone is see-through), in a large continuous rounded rect — the iOS 27
    /// Siri tile look.
    func feedCardSurface() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.clear,
                         in: RoundedRectangle(cornerRadius: feedCardCornerRadius, style: .continuous))
            .background {
                LinearGradient(colors: [Color.accentColor.opacity(0.45),
                                        Color.accentColor.opacity(0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: feedCardCornerRadius, style: .continuous))
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
        // Liquid Glass frosts whatever sits behind it.
        Group {
            if let coordinate = person.coordinate {
                // Located: the Look Around photo fills the card; the text rides a clear-glass panel
                // pinned to the top, leaving the space below it open so a bit of the photo shows.
                ZStack(alignment: .top) {
                    RowLookAround(coordinate: coordinate, feather: false)
                    textPanel
                }
                .frame(maxWidth: .infinity, minHeight: heroHeight, alignment: .top)
            } else {
                // No photo: the clear-glass panel rides a soft theme-tinted gradient so the card
                // reads as a colored glass tile instead of see-through.
                textPanel
                    .background {
                        LinearGradient(colors: [person.theme.color.opacity(0.55),
                                                person.theme.color.opacity(0.22)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: feedCardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The name/status/headline on a clear Liquid Glass panel.
    private var textPanel: some View {
        content(onImage: true)
            .shadow(color: .black.opacity(0.55), radius: 4, x: 0, y: 1)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .glassEffect(.clear,
                         in: RoundedRectangle(cornerRadius: feedCardCornerRadius, style: .continuous))
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
            if topLabel != nil || distanceText != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let label = topLabel {
                        Text(label.text)
                            .foregroundStyle(onImage ? (person.isDue ? Color.red : Color.white.opacity(0.95))
                                                     : label.color)
                    }
                    Spacer(minLength: 0)
                    if let distanceText {
                        Text(distanceText)
                            .foregroundStyle(onImage ? Color.white.opacity(0.95) : Color.secondary)
                    }
                }
                .font(.caption.weight(.semibold))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Territory \(territory.name), \(territorySubtitle(territory))")
    }
}
