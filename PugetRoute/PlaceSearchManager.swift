import Foundation
import MapKit
import CoreLocation

/// Live autocomplete for place names / addresses, biased to Puget Sound.
/// Wraps MKLocalSearchCompleter (free, no API key) and publishes suggestions
/// as the user types.
@MainActor
final class PlaceSearchManager: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {

    @Published var suggestions: [MKLocalSearchCompletion] = []
    @Published var isSearching = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        // Bias results toward the Puget Sound region so "Broadway" resolves to
        // Capitol Hill rather than Manhattan.
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
            span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2)
        )
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            suggestions = []
            isSearching = false
            return
        }
        isSearching = true
        completer.queryFragment = trimmed
    }

    /// Resolve an autocomplete suggestion into an actual coordinate.
    /// MKLocalSearchCompletion only contains strings; a follow-up MKLocalSearch
    /// is needed to get the lat/lon.
    func resolve(_ completion: MKLocalSearchCompletion) async -> (String, CLLocationCoordinate2D)? {
        let req = MKLocalSearch.Request(completion: completion)
        do {
            let resp = try await MKLocalSearch(request: req).start()
            guard let item = resp.mapItems.first else { return nil }
            let displayName = item.name ?? completion.title
            return (displayName, item.placemark.coordinate)
        } catch {
            return nil
        }
    }

    // MARK: - MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.suggestions = results
            self.isSearching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.suggestions = []
            self.isSearching = false
        }
    }
}
