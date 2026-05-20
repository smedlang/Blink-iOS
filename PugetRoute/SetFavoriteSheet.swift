import SwiftUI
import MapKit
import CoreLocation

/// Sub-modal that lets the user search for and pick an address to
/// assign to a Home or Work favorite slot. Reuses `PlaceSearchManager`
/// for autocomplete so the search behavior matches the main sheet
/// (Puget-Sound-biased results, point-of-interest support, etc.).
///
/// Presented as a sheet from `PlaceSearchSheet` when the user taps a
/// "Set Home" / "Set Work" row, or "Change address" from the long-
/// press menu on a filled favorite. On a successful pick, writes the
/// place into `SavedPlacesStore` and dismisses; tapping Cancel
/// dismisses without changes.
///
/// Why a separate sheet instead of inline state inside the parent
/// search sheet: the parent sheet already manages From/To context
/// plus the live search field. Layering "I'm currently assigning a
/// favorite" semantics on top of that turned out to require enough
/// state-shape branches to be worth its own component. Modal-on-modal
/// keeps each flow obvious.
struct SetFavoriteSheet: View {
    let kind: FavoriteKind

    @StateObject private var manager = PlaceSearchManager()
    @ObservedObject private var store = SavedPlacesStore.shared

    @State private var query: String = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                resultsList
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }

    // MARK: - Subviews

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: kind == .home ? "house.fill" : "briefcase.fill")
                .foregroundColor(.accentColor)
            TextField("Search for an address", text: $query)
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(10)
        .padding()
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private var resultsList: some View {
        List {
            if query.isEmpty {
                Section {
                    Text("Search by address, place name, or business — e.g. \"500 Pine St Seattle\" or \"Pike Place Market\".")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
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

    private var title: String {
        switch kind {
        case .home: return "Set Home"
        case .work: return "Set Work"
        }
    }

    // MARK: - Actions

    private func pick(_ completion: MKLocalSearchCompletion) {
        Task {
            guard let (name, coord) = await manager.resolve(completion) else { return }
            await MainActor.run {
                let place = StoredPlace(displayName: name, lat: coord.latitude, lon: coord.longitude)
                switch kind {
                case .home: store.setHome(place)
                case .work: store.setWork(place)
                }
                dismiss()
            }
        }
    }
}
