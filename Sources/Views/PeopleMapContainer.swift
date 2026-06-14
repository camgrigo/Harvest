import SwiftUI

/// Which way the combined People tab is showing its people + territories.
enum PeopleViewMode: String, CaseIterable {
    case list, map
}

/// The combined People tab: the same people/territories shown either as the list (masonry) or on
/// the map, toggled by the view-switcher menu. The map model is held here so its state (camera,
/// selection, route) survives switching back and forth.
struct PeopleMapContainer: View {
    @AppStorage("peopleViewMode") private var mode: PeopleViewMode = .list
    @State private var mapModel = MapModel()

    var body: some View {
        switch mode {
        case .list: PeoplePanelContent(mode: $mode)
        case .map:  ExploreView(model: mapModel, mode: $mode)
        }
    }
}

/// The Grid/List-style switcher: a menu with Map and List options (a checkmark marks the current).
/// Reused by the list (in its toolbar) and the map (as a floating control).
struct ViewModeMenu: View {
    @Binding var mode: PeopleViewMode

    var body: some View {
        Menu {
            Picker("View", selection: $mode) {
                Label("Map", systemImage: "map").tag(PeopleViewMode.map)
                Label("List", systemImage: "list.bullet").tag(PeopleViewMode.list)
            }
        } label: {
            Image(systemName: "line.3.horizontal")
        }
        .accessibilityLabel("Switch view")
    }
}
