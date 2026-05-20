import SwiftUI
import MapKit
import CoreLocation

/// Modal sheet that owns both the From and To fields for a route.
///
/// The main screen only shows "Where to?" — tapping it opens this sheet
/// with the From row pre-filled as "Your location" and the To row as the
/// active text field. The user can tap the From row to search for a
/// different start point, or tap the location button to snap it back to
/// their current GPS fix.
///
/// **Quick-pick shortcuts.** Below the From/To fields and on the same
/// chrome-tinted background, an inline `favoritesBar` shows two
/// compact pills for Home and Work — filled when set (tap → fills
/// active field; long-press → change/remove menu), outlined when unset
/// (tap → opens `SetFavoriteSheet` to assign). Below the bar, when the
/// search box is empty, the list shows up to 6 most-recent places the
/// user has picked. Recents are auto-tracked on every successful pick
/// (deduped by coord). "Your location" doesn't get its own row — the
/// location button next to the From field already covers that hand-off.
///
/// The sheet commits (dismisses + plans the trip) as soon as both
/// From and To have resolved coordinates.
struct PlaceSearchSheet: View {
    enum ActiveField { case from, to }

    let initialField: ActiveField
    @Binding var fromQuery: String
    @Binding var fromCoord: CLLocationCoordinate2D?
    @Binding var toQuery:   String
    @Binding var toCoord:   CLLocationCoordinate2D?
    let lastLocation: CLLocation?
    /// Called once both From and To have coordinates. The caller typically
    /// kicks off `planTrip()` here.
    var onCommit: () -> Void

    @StateObject private var manager = PlaceSearchManager()
    @ObservedObject private var store = SavedPlacesStore.shared
    @State private var active: ActiveField
    @State private var query: String = ""
    @State private var assigningFavoriteKind: FavoriteKind?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        initialField: ActiveField,
        fromQuery: Binding<String>,
        fromCoord: Binding<CLLocationCoordinate2D?>,
        toQuery:   Binding<String>,
        toCoord:   Binding<CLLocationCoordinate2D?>,
        lastLocation: CLLocation?,
        onCommit: @escaping () -> Void
    ) {
        self.initialField  = initialField
        self._fromQuery    = fromQuery
        self._fromCoord    = fromCoord
        self._toQuery      = toQuery
        self._toCoord      = toCoord
        self.lastLocation  = lastLocation
        self.onCommit      = onCommit
        self._active       = State(initialValue: initialField)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Both fields always visible at the top of the sheet.
                VStack(spacing: 8) {
                    fieldRow(
                        field: .from,
                        icon: "circle",
                        iconColor: .green,
                        text: fromQuery,
                        placeholder: "Your location"
                    )
                    fieldRow(
                        field: .to,
                        icon: "mappin",
                        iconColor: .red,
                        text: toQuery,
                        placeholder: "Where to?"
                    )
                    // Favorites quick-row sits inline with the search
                    // fields on the same chrome-tinted background, so
                    // Home/Work read as part of "specifying the
                    // endpoints" rather than as a list section. Two
                    // pills stay on a single line on every iPhone size.
                    favoritesBar
                }
                .padding()
                .background(Color(.secondarySystemBackground))

                List {
                    if query.isEmpty {
                        emptyStateContent
                    } else if manager.suggestions.isEmpty && !manager.isSearching {
                        Section {
                            Text("No matches.").foregroundColor(.secondary)
                        }
                    } else {
                        ForEach(manager.suggestions, id: \.self) { s in
                            Button {
                                pick(s)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    if !s.subtitle.isEmpty {
                                        Text(s.subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(active == .from ? "From" : "Where to?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
            .sheet(item: $assigningFavoriteKind) { kind in
                SetFavoriteSheet(kind: kind)
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Favorites bar (inline below search fields)

    /// Horizontal row of compact pills for Home and Work, anchored just
    /// below the From/To fields on the same chrome background. Both
    /// pills are always rendered; their visual state encodes whether
    /// the favorite is set:
    ///   - **Set:** filled accent-tinted pill, label is "Home" / "Work".
    ///     Tap fills the active From/To field. Long-press surfaces the
    ///     context menu (change address / remove).
    ///   - **Unset:** outlined pill, label is "Set Home" / "Set Work".
    ///     Tap opens `SetFavoriteSheet` to assign an address.
    ///
    /// Two pills fit comfortably on every iPhone width with the
    /// trailing Spacer pinning them to the leading edge.
    private var favoritesBar: some View {
        HStack(spacing: 8) {
            favoritePill(kind: .home)
            favoritePill(kind: .work)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func favoritePill(kind: FavoriteKind) -> some View {
        let fav = (kind == .home ? store.home : store.work)
        let isSet = fav != nil
        let label = isSet ? (kind == .home ? "Home" : "Work")
                          : (kind == .home ? "Set Home" : "Set Work")
        let iconName = isSet
            ? (kind == .home ? "house.fill" : "briefcase.fill")
            : (kind == .home ? "house" : "briefcase")

        let pill = Button {
            if let fav = fav {
                pickStored(fav.place)
            } else {
                assigningFavoriteKind = kind
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(.subheadline).bold()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundColor(isSet ? .accentColor : .secondary)
            .background(
                Capsule()
                    .fill(isSet
                          ? Color.accentColor.opacity(0.15)
                          : Color(.tertiarySystemBackground))
            )
            .overlay(
                Capsule().strokeBorder(
                    isSet ? Color.clear : Color.secondary.opacity(0.3),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)

        // Context menu only attached when set — otherwise an unset
        // pill's long-press would surface an empty menu, which iOS
        // renders inconsistently.
        if let fav = fav {
            pill.contextMenu {
                Section(fav.place.displayName) {
                    Button {
                        assigningFavoriteKind = kind
                    } label: {
                        Label("Change address", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        store.remove(fav)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        } else {
            pill
        }
    }

    // MARK: - Empty-state list

    /// Quick-pick sections shown when the active field's search box is
    /// empty. Favorites moved to the inline `favoritesBar` above the
    /// list, so the empty state is just the recents section. If recents
    /// is also empty (first-time user with no Home/Work set yet), the
    /// list is blank — the "Set Home"/"Set Work" pills above are the
    /// discoverability lever.
    @ViewBuilder
    private var emptyStateContent: some View {
        if !store.recents.isEmpty {
            Section("Recents") {
                ForEach(store.recents) { recent in
                    Button {
                        pickStored(recent.place)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock")
                                .foregroundColor(.secondary)
                                .frame(width: 22)
                            Text(recent.place.displayName)
                                .foregroundColor(.primary)
                                .lineLimit(2)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Field row

    @ViewBuilder
    private func fieldRow(
        field: ActiveField,
        icon: String,
        iconColor: Color,
        text: String,
        placeholder: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(iconColor)

            if active == field {
                // Active field is the live search text field.
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .focused($focused)
                    .onChange(of: query) { _, new in manager.search(new) }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                }
            } else {
                // Inactive field shows the committed value (or placeholder)
                // and swaps to become the active one when tapped.
                Button {
                    switchTo(field)
                } label: {
                    Text(text.isEmpty ? placeholder : text)
                        .foregroundColor(text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }

            // Quick "snap From to current location" shortcut.
            if field == .from {
                Button {
                    snapFromToCurrentLocation()
                } label: {
                    Image(systemName: "location.fill")
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(active == field ? Color(.systemBackground) : Color(.tertiarySystemBackground))
        .cornerRadius(10)
    }

    // MARK: - Actions

    private func switchTo(_ field: ActiveField) {
        active = field
        query = ""
        manager.search("")
        focused = true
    }

    private func snapFromToCurrentLocation() {
        guard let loc = lastLocation else { return }
        fromCoord = loc.coordinate
        fromQuery = "Your location"
        // If To is still empty, move focus there so the user can keep
        // typing without an extra tap.
        if toCoord == nil {
            switchTo(.to)
        } else {
            commit()
        }
    }

    /// Pick a typed-search suggestion. Resolves the autocomplete
    /// completion to a real coordinate, fills the active field, and
    /// records the place in recents (skipping anything already saved
    /// as a favorite — those are explicitly elevated and shouldn't
    /// pollute the auto-tracked list).
    private func pick(_ s: MKLocalSearchCompletion) {
        Task {
            if let (name, coord) = await manager.resolve(s) {
                await MainActor.run {
                    let place = StoredPlace(displayName: name, lat: coord.latitude, lon: coord.longitude)
                    if !store.isFavorited(place) {
                        store.addRecent(place)
                    }
                    fillActive(name: name, coord: coord)
                }
            }
        }
    }

    /// Pick an already-resolved place (favorite or recent). Bumps
    /// recents to the top via `addRecent` so the list stays in
    /// most-recently-used order; favorites don't pollute recents
    /// (they're already prominently shown above).
    private func pickStored(_ place: StoredPlace) {
        if !store.isFavorited(place) {
            store.addRecent(place)
        }
        fillActive(name: place.displayName, coord: place.coordinate)
    }

    /// Shared "fill the active From/To field with a name+coord"
    /// helper. Handles the focus-handoff to the other field if it's
    /// still empty, or commits the trip if both fields are now set.
    private func fillActive(name: String, coord: CLLocationCoordinate2D) {
        switch active {
        case .from:
            fromQuery = name
            fromCoord = coord
            if toCoord == nil { switchTo(.to) } else { commit() }
        case .to:
            toQuery = name
            toCoord = coord
            if fromCoord == nil { switchTo(.from) } else { commit() }
        }
    }

    private func commit() {
        dismiss()
        onCommit()
    }
}

// FavoriteKind needs to satisfy `Identifiable` for use as the `item:`
// binding on `.sheet(item:)`. Each kind is its own identity (one Home
// slot, one Work slot), so the rawValue is a stable id.
extension FavoriteKind: Identifiable {
    var id: String { rawValue }
}
