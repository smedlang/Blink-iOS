import Foundation
import CoreLocation

/// In-memory, TTL-bounded LRU cache for OTP plan responses, keyed on the
/// inputs to a single planning query. Sized for a single user's session —
/// 50 entries comfortably covers ~16 distinct trips × 3 modes, the common
/// case being mode-pill toggling and time-picker / preference nudges where
/// the same trip is re-planned within seconds.
///
/// Why this exists
/// ---------------
/// `ContentView.planTrip()` already caches results across mode-pill switches
/// inside a single planTrip() invocation (see `modeItineraries`). That cache
/// is dropped as soon as the user changes anything that triggers a new
/// planTrip() — destination, preferences, time picker. Most of those changes
/// don't actually invalidate every mode's results: nudging the time picker
/// by a minute and back, or toggling preferences and back, fires three fresh
/// network queries needlessly. This cache catches those, and also catches
/// re-planning the same trip after a quick navigation away and back.
///
/// What it doesn't try to do
/// -------------------------
/// - No disk persistence. Itineraries reference real-time data (delays,
///   bikeshare availability) that's not safe to serve cold from a previous
///   session. Memory-only is the right tradeoff.
/// - No negative caching. A failed query is not stored — we'd rather retry
///   than confidently serve "no routes found" from a stale error.
/// - No partial / per-leg caching. Hits are at the (origin, dest, mode,
///   time-bucket, prefs) granularity; misses go all the way to the network.
///
/// Key design
/// ----------
/// Coordinates are rounded to 4 decimal places (~11m at Seattle's latitude).
/// GPS jitter on the user's "current location" is typically larger than that,
/// so rounding tighter would make the cache mostly miss; rounding looser
/// (3 decimals, ~110m) would risk returning a route that started a block away.
///
/// Time is bucketed to 60 seconds. For .leaveNow this means a second tap
/// within the same minute hits the same entry. For .leaveAt / .arriveBy the
/// user picks at minute granularity anyway, so the bucket is exact.
///
/// The `TimeKind` is part of the key so that "leave at 5pm" and "arrive by
/// 5pm" don't collide.
actor ItineraryCache {
    static let shared = ItineraryCache()

    /// How long a cached response is considered fresh. 60s is short enough
    /// that real-time delays haven't drifted meaningfully; long enough to
    /// cover the "user wiggles a control and expects instant feedback" case.
    private static let ttl: TimeInterval = 60

    /// Hard cap on entries. ~50 covers a heavy session without blowing up
    /// memory; each entry is a handful of KB at most.
    private static let capacity: Int = 50

    struct Key: Hashable {
        let fromLat: Int
        let fromLon: Int
        let toLat: Int
        let toLon: Int
        let mode: String
        let preference: String
        let timeKind: TimeKind
        let timeBucket: Int

        enum TimeKind: String, Hashable { case now, leaveAt, arriveBy }
    }

    private struct Entry {
        let value: [Itinerary]
        let storedAt: Date
    }

    private var entries: [Key: Entry] = [:]

    /// Keys in LRU order — front = least recently used, back = most recent.
    /// Kept as a parallel array rather than an OrderedDictionary to avoid
    /// pulling in swift-collections. At capacity 50, the O(n) removeAll for
    /// the move-to-back operation is irrelevant in practice.
    private var order: [Key] = []

    /// Returns a cached response if it exists and is still fresh; otherwise nil.
    /// Touches the entry on hit so it moves to the back of the LRU list.
    func get(_ key: Key) -> [Itinerary]? {
        guard let entry = entries[key] else { return nil }
        if Date().timeIntervalSince(entry.storedAt) > Self.ttl {
            // Expired — drop it on the way out so we don't keep checking.
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        // Move to back (most recently used).
        order.removeAll { $0 == key }
        order.append(key)
        return entry.value
    }

    /// Insert or replace a cached response. Evicts the oldest entries if
    /// the cache is over capacity.
    func set(_ key: Key, _ value: [Itinerary]) {
        entries[key] = Entry(value: value, storedAt: Date())
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    /// Drop everything. Exposed for tests, and a natural hook to wire into
    /// a manual "refresh" gesture if one is added later.
    func clear() {
        entries.removeAll()
        order.removeAll()
    }

    /// Current entry count. Exposed for tests / instrumentation.
    var count: Int { entries.count }
}

extension ItineraryCache.Key {
    /// 4-decimal rounding ≈ 11m precision at Seattle's latitude. Tight enough
    /// to distinguish meaningful destination changes; loose enough to absorb
    /// GPS jitter on "Your location."
    private static func coordBucket(_ coord: Double) -> Int {
        Int((coord * 10_000).rounded())
    }

    /// 60-second time bucket. Floors a Date to its containing minute.
    private static func minuteBucket(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 60)
    }

    /// Build a cache key from the same inputs that go into
    /// `RoutingClient.plan`. Keep this in sync with that signature — any
    /// new variable that affects the OTP query also has to be folded into
    /// the key, otherwise we'll serve a response computed for a different
    /// set of options.
    ///
    /// `preference` and `bikePreference` are folded into a single namespaced
    /// string based on which one actually drives the active mode. Bike-only
    /// routes are governed entirely by `bikePreference` (slope ↔ time
    /// triangle), so changes to the multimodal `RoutePreference` shouldn't
    /// bust the bike-only cache. Conversely, multimodal routes ignore
    /// `bikePreference`, so changes to it shouldn't bust those caches either.
    init(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        mode: TripMode,
        when: TimeTarget,
        preference: RoutePreference,
        bikePreference: BikePreference,
        bikePace: BikePace,
        bikeKind: BikeKind = .standard,
        bikeTransitFlavor: BikeTransitFlavor? = nil,
        useLime: Bool = false
    ) {
        let kind: TimeKind
        let stamp: Date
        switch when {
        case .leaveNow:        kind = .now;      stamp = Date()
        case .leaveAt(let d):  kind = .leaveAt;  stamp = d
        case .arriveBy(let d): kind = .arriveBy; stamp = d
        }
        // Pace is folded into the prefKey so changing the bike pace
        // setting always invalidates — bike speed materially changes the
        // OTP plan (different leg durations, sometimes different routes).
        // Transit-only trips ignore pace at the OTP layer but folding it
        // in is harmless and keeps the key simple.
        //
        // bikeKind is folded in for the same reason: e-bike vs standard
        // sends different bikeSpeed, triangle, and bikeReluctance to OTP,
        // so the resulting itineraries genuinely differ. Folding it into
        // the key means switching between Standard and E-bike gives each
        // a parallel cache rather than mutually evicting.
        //
        // bikeTransitFlavor matters only for the bike+transit query; we
        // fold it in there so the three parallel flavor queries each get
        // their own cache entry instead of stepping on each other.
        // Bike-only and transit-only ignore it.
        // `useLime` flips bike-only and bike+transit into Lime variants
        // (same TripMode case, different OTP modes argument). The cache
        // key must include it so a Lime-mode plan doesn't get served
        // out of an own-bike cache entry sharing the same OD/prefs.
        let limeSuffix = useLime ? ":lime" : ""
        let prefKey: String
        switch mode {
        case .bikeOnly:
            prefKey = "bike:\(bikePreference.rawValue):\(bikePace.rawValue):\(bikeKind.rawValue)\(limeSuffix)"
        case .bikeshare:
            // Bikeshare key prefix is distinct so we don't collide with
            // own-bike cache entries that share the same origin/dest +
            // bike preferences but route through a different leg shape
            // (walk-to-pickup → rental → walk-to-destination).
            prefKey = "bikeshare:\(bikePreference.rawValue):\(bikePace.rawValue):\(bikeKind.rawValue)"
        case .bikeTransit:
            let flavor = bikeTransitFlavor?.rawValue ?? "_"
            prefKey = "transit:\(preference.rawValue):\(bikePace.rawValue):\(bikeKind.rawValue):\(flavor)\(limeSuffix)"
        case .transitOnly:
            prefKey = "transit:" + preference.rawValue
        }
        self.init(
            fromLat:    Self.coordBucket(from.latitude),
            fromLon:    Self.coordBucket(from.longitude),
            toLat:      Self.coordBucket(to.latitude),
            toLon:      Self.coordBucket(to.longitude),
            mode:       mode.rawValue,
            preference: prefKey,
            timeKind:   kind,
            timeBucket: Self.minuteBucket(stamp)
        )
    }
}
