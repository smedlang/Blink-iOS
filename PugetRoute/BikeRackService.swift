import Foundation
import CoreLocation
import MapKit

// MARK: - Model

/// One bike-parking entry returned by the signal-augment proxy's
/// `/api/bike-racks/near` endpoint. Source data is OSM
/// `amenity=bicycle_parking` extracted into `data/bike-racks.json` at
/// graph-build time. All optional fields are absent for racks where
/// OSM doesn't carry the corresponding tag — most casual sidewalk
/// stands are minimally tagged (just a coord), while transit-station
/// bike cages typically have capacity, type, and a name.
struct BikeRack: Decodable, Identifiable, Hashable {
    let lat: Double
    let lon: Double

    /// Number of bikes the rack can hold. Nil when OSM doesn't tag it.
    let capacity: Int?
    /// Rack class: "stands" (sidewalk U-stands), "lockers" (secure
    /// lockers), "building" (covered bike room), "rack" (generic), etc.
    /// Free-form OSM string — display in callouts as-is rather than
    /// trying to map onto a canonical iOS-side enum.
    let type: String?
    /// True when the rack is under cover (rain shelter). Nil when
    /// untagged in OSM, which is most racks.
    let covered: Bool?
    /// Access restriction: "yes" / "public" / "customers" / "private".
    /// We don't filter on this client-side; just surface it in the
    /// callout so the user knows.
    let access: String?
    /// Rack-specific name (rare). E.g. "King Street Station Bike
    /// Cage". When absent, callouts fall back to a generic "Bike
    /// parking".
    let name: String?
    /// Distance from the query point in meters. Computed by the proxy
    /// and shipped along so we can sort and label without a redundant
    /// haversine calc client-side.
    let distanceMeters: Double?

    var id: String {
        // (lat, lon) at 5-decimal precision is unique per rack and
        // stable across fetches — use as the Identifiable id rather
        // than introducing an OSM way/node id roundtrip.
        String(format: "%.5f,%.5f", lat, lon)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// One-line summary for the map-callout subtitle. Only includes
    /// fields that are actually populated, so a minimally-tagged rack
    /// just shows "Bike parking" with no subtitle clutter.
    var summary: String {
        var parts: [String] = []
        if let cap = capacity, cap > 0 {
            parts.append("\(cap) bike\(cap == 1 ? "" : "s")")
        }
        if let type, !type.isEmpty {
            // Replace OSM's underscore_separated values with spaces
            // for human reading: "bike_lockers" → "bike lockers".
            parts.append(type.replacingOccurrences(of: "_", with: " "))
        }
        if covered == true {
            parts.append("covered")
        }
        if let access, access != "yes" && access != "public" && !access.isEmpty {
            // Only call out access when it's restrictive — "yes" /
            // "public" is the default and not noteworthy.
            parts.append(access)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Service

/// Talks to the signal-augment proxy's bike-rack endpoint. Stateless;
/// no caching layer here because the iOS-side caller (`ContentView`'s
/// `.task(id: itinerary.id)`) is the natural place to gate refetches —
/// we only fetch once per itinerary selection, and the proxy's lookup
/// is sub-5-ms in-memory anyway.
enum BikeRackService {

    /// Endpoint URL relative to OTP's base. Reuses `RoutingClient.baseURL`
    /// so the call goes through the same Cloudflare Tunnel as plan() —
    /// no separate hostname to configure, no separate TLS to validate.
    private static var endpoint: URL {
        RoutingClient.baseURL.appendingPathComponent("api/bike-racks/near")
    }

    /// Default radii. Most destinations have a rack right out front
    /// or within ~half a block — 30 m catches that case without
    /// surfacing five racks the user has to scan past. The wider
    /// `fallbackRadius` only kicks in when the tight circle is empty,
    /// for less-tagged or outlying destinations where the closest
    /// rack is a block or two away. Tunable here in one place.
    static let primaryRadius: Int = 30
    static let fallbackRadius: Int = 100

    /// Fetch racks within `primaryRadius` meters of a coordinate. If
    /// the tight circle returns no results, retries at `fallbackRadius`
    /// so the user always sees *some* parking option when the
    /// destination has any nearby racks at all. Returns an empty array
    /// on failure (network error, proxy down, non-200 response, decode
    /// failure) — the rack annotations are an optional nice-to-have,
    /// never blocking trip planning.
    static func racksNear(_ coord: CLLocationCoordinate2D) async -> [BikeRack] {
        let close = await fetchAt(coord, radius: primaryRadius)
        if !close.isEmpty { return close }
        return await fetchAt(coord, radius: fallbackRadius)
    }

    /// Single-radius fetch — exposed for tests and for callers that
    /// want explicit control. Most code should use `racksNear` for the
    /// tight-then-loose default behavior.
    static func fetchAt(_ coord: CLLocationCoordinate2D, radius: Int) async -> [BikeRack] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(coord.latitude)),
            URLQueryItem(name: "lon", value: String(coord.longitude)),
            URLQueryItem(name: "radius", value: String(radius)),
        ]
        guard let url = components.url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                #if DEBUG
                print("[BikeRack] fetch HTTP \(http.statusCode) for \(coord.latitude),\(coord.longitude)")
                #endif
                return []
            }
            struct Response: Decodable { let racks: [BikeRack] }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.racks
        } catch {
            #if DEBUG
            print("[BikeRack] fetch failed: \(error)")
            #endif
            return []
        }
    }

    /// Fetch racks for every bike-leg endpoint in an itinerary,
    /// deduped by coordinate so a rack that's near two adjacent bike
    /// legs (e.g. boarding station also near a separate bike-only
    /// segment's endpoint) only appears once on the map.
    ///
    /// "Bike-leg endpoint" = the `to` coordinate of any leg whose mode
    /// is BICYCLE or BICYCLE_RENT. That's where the rider transitions
    /// off the bike, which is when knowing where to lock up matters.
    ///
    /// Each endpoint uses the tight-then-loose radius pattern (see
    /// `racksNear`): closest racks first, fall back to a wider search
    /// only when no nearby racks exist.
    static func racksForBikeLegEndpoints(_ itinerary: Itinerary) async -> [BikeRack] {
        let endpoints = itinerary.legs
            .filter { $0.mode == "BICYCLE" || $0.mode == "BICYCLE_RENT" }
            .map { $0.to.coordinate }
        guard !endpoints.isEmpty else { return [] }

        // Fetch all endpoints concurrently — typical itinerary has
        // 1-2 bike legs, so this is at most 2 parallel requests.
        var racks: [BikeRack] = []
        await withTaskGroup(of: [BikeRack].self) { group in
            for ep in endpoints {
                group.addTask {
                    await racksNear(ep)
                }
            }
            for await partial in group {
                racks.append(contentsOf: partial)
            }
        }

        // Dedupe by id (lat/lon at 5-decimal precision).
        var seen = Set<String>()
        var unique: [BikeRack] = []
        for r in racks {
            if seen.insert(r.id).inserted {
                unique.append(r)
            }
        }
        return unique
    }
}

// MARK: - Map annotation

/// MKMapView annotation backing a single bike-rack pin. Carries the
/// underlying `BikeRack` so the renderer can build a callout with
/// capacity / type / covered status.
final class BikeRackAnnotation: MKPointAnnotation {
    var rack: BikeRack?
}
