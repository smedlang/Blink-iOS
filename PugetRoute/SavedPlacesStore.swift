import Foundation
import CoreLocation
import Combine

// MARK: - Stored types

/// One persisted place — display name plus coordinate. Used by both
/// `RecentPlace` (auto-tracked) and `Favorite` (explicitly saved).
/// Kept deliberately minimal: enough to fill a From/To field, nothing
/// else. We don't store the original search query because we want
/// repeat picks of the same destination to dedupe regardless of how
/// the user spelled it.
struct StoredPlace: Codable, Equatable, Hashable {
    let displayName: String
    let lat: Double
    let lon: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// De-dup key — `(lat, lon)` rounded to ~5 decimal places (~1 m
    /// precision). Apple Maps and OTP geocoders sometimes return the
    /// same address with sub-meter coord differences; normalizing here
    /// keeps "Pike Place Market" from showing up twice in recents
    /// because two pickers each picked it once.
    var matchKey: String {
        String(format: "%.5f,%.5f", lat, lon)
    }
}

/// One entry in the user's auto-tracked recents list.
struct RecentPlace: Codable, Equatable, Identifiable {
    let id: UUID
    let place: StoredPlace
    let pickedAt: Date

    init(id: UUID = UUID(), place: StoredPlace, pickedAt: Date = Date()) {
        self.id = id
        self.place = place
        self.pickedAt = pickedAt
    }
}

/// Kind of a saved favorite. Home and Work are first-class because
/// they're the two destinations every Seattle commuter uses constantly,
/// and giving them a fixed icon + position makes them instantly
/// recognizable in the empty state of the search sheet. `custom` is
/// reserved for a future iteration where users can save additional
/// favorites with their own labels (gym, school, etc.).
enum FavoriteKind: String, Codable {
    case home
    case work
}

/// One saved favorite.
struct Favorite: Codable, Equatable, Identifiable {
    let id: UUID
    var kind: FavoriteKind
    var place: StoredPlace

    init(id: UUID = UUID(), kind: FavoriteKind, place: StoredPlace) {
        self.id = id
        self.kind = kind
        self.place = place
    }

    /// User-facing label for the row.
    var label: String {
        switch kind {
        case .home: return "Home"
        case .work: return "Work"
        }
    }

    /// SF Symbol used in the search sheet's row.
    var iconName: String {
        switch kind {
        case .home: return "house.fill"
        case .work: return "briefcase.fill"
        }
    }
}

// MARK: - Store

/// Single source of truth for the user's recents and favorites. Backed
/// by `UserDefaults` (JSON-encoded `Data`) so values persist across
/// launches without the complexity of a real database. Marked
/// `@MainActor` because the only readers are SwiftUI views; reads and
/// writes are tiny so the synchronous main-thread cost is negligible.
///
/// Singleton (`SavedPlacesStore.shared`) because there's only ever one
/// user-state to track, and threading instances through every search-
/// flow view would be needless ceremony for a small app.
@MainActor
final class SavedPlacesStore: ObservableObject {
    static let shared = SavedPlacesStore()

    @Published private(set) var recents: [RecentPlace] = []
    @Published private(set) var favorites: [Favorite] = []

    /// Hard cap on the recents list. Big enough to surface the user's
    /// usual handful of destinations (commute spots, errands, the
    /// occasional new place) but small enough that the search-sheet
    /// empty state stays scannable. Older entries fall off via LRU.
    static let recentsCap = 10

    private let defaults: UserDefaults
    private static let recentsKey = "pugetroute.recents.v1"
    private static let favoritesKey = "pugetroute.favorites.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromDisk()
    }

    // MARK: - Recents

    /// Record a place the user just picked from search. If the same
    /// place (by `matchKey`) is already in recents, it gets bumped to
    /// the top rather than duplicated. Once the list is over capacity,
    /// the oldest entry falls off.
    ///
    /// We deliberately don't add to recents when the user picks an
    /// existing favorite — favorites are explicitly elevated and
    /// shouldn't crowd the auto-tracked list.
    func addRecent(_ place: StoredPlace) {
        var list = recents.filter { $0.place.matchKey != place.matchKey }
        list.insert(RecentPlace(place: place), at: 0)
        if list.count > Self.recentsCap {
            list = Array(list.prefix(Self.recentsCap))
        }
        recents = list
        saveRecents()
    }

    func clearRecents() {
        recents = []
        saveRecents()
    }

    // MARK: - Favorites

    var home: Favorite? { favorites.first(where: { $0.kind == .home }) }
    var work: Favorite? { favorites.first(where: { $0.kind == .work }) }

    /// Replace (or create) the Home favorite with the given place.
    func setHome(_ place: StoredPlace) {
        setFavorite(kind: .home, place: place)
    }

    /// Replace (or create) the Work favorite with the given place.
    func setWork(_ place: StoredPlace) {
        setFavorite(kind: .work, place: place)
    }

    /// Drop a favorite by id. Used by the long-press "Remove" menu.
    func remove(_ favorite: Favorite) {
        favorites.removeAll(where: { $0.id == favorite.id })
        saveFavorites()
    }

    private func setFavorite(kind: FavoriteKind, place: StoredPlace) {
        // One favorite per kind for Home/Work — replace any existing.
        favorites.removeAll(where: { $0.kind == kind })
        favorites.append(Favorite(kind: kind, place: place))
        saveFavorites()
    }

    /// True if the place is already saved as a favorite. Used to avoid
    /// adding a duplicate recent when the user picks their Home/Work
    /// from the favorites section.
    func isFavorited(_ place: StoredPlace) -> Bool {
        favorites.contains { $0.place.matchKey == place.matchKey }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        if let data = defaults.data(forKey: Self.recentsKey),
           let decoded = try? JSONDecoder().decode([RecentPlace].self, from: data) {
            recents = decoded
        }
        if let data = defaults.data(forKey: Self.favoritesKey),
           let decoded = try? JSONDecoder().decode([Favorite].self, from: data) {
            favorites = decoded
        }
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            defaults.set(data, forKey: Self.recentsKey)
        }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            defaults.set(data, forKey: Self.favoritesKey)
        }
    }
}
