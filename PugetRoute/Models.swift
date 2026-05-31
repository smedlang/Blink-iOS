import Foundation
import CoreLocation

// MARK: - Trip mode (what the user picks in the UI)

enum TripMode: String, CaseIterable, Identifiable {
    case bikeTransit = "Bike + Transit"
    case bikeOnly    = "Bike only"
    case bikeshare   = "Lime"
    case transitOnly = "Transit only"

    var id: String { rawValue }

    /// OTP2 GraphQL `transportModes` argument. The `qualifier: RENT` on
    /// the bikeshare entry tells OTP to plan a rental leg (free-floating
    /// Lime in Seattle) — origin walk → pickup → rental ride → walk to
    /// destination. Comes back as `mode: BICYCLE` with `rentedBike: true`
    /// on the leg, not `mode: BICYCLE_RENT`.
    ///
    /// `bikeTransit` is `[BICYCLE, TRANSIT]` only — no `WALK`. We
    /// tried adding `WALK` (with and without `qualifier: ACCESS`)
    /// hoping OTP would use walking to transfer between buses at
    /// different physical stops in the same hub (e.g., a 200ft walk
    /// between bays at Issaquah Transit Center to chain the 554 with
    /// the 208). It did not help — OTP refuses to model "walk the
    /// bike between stops" regardless of mode set, so adding `WALK`
    /// was a no-op. The actual blocker is at the graph layer: OTP's
    /// transit-transfer edges are pre-computed walk-only, so transfers
    /// requiring movement between different stops are invisible to
    /// the planner once BICYCLE is in modes. See
    /// `tasks/otp-bike-transfer-edges.md` for the backend fix
    /// (adding `BICYCLE` to `transit.transferRequests` in OTP's
    /// `router-config.json` and rebuilding the graph).
    var otpTransportModes: [[String: String]] {
        switch self {
        case .bikeTransit: return [["mode": "BICYCLE"], ["mode": "TRANSIT"]]
        case .bikeOnly:    return [["mode": "BICYCLE"]]
        case .bikeshare:   return [["mode": "BICYCLE", "qualifier": "RENT"]]
        case .transitOnly: return [["mode": "WALK"], ["mode": "TRANSIT"]]
        }
    }
}

// MARK: - Route preference

/// How the user wants OTP to weight its options. Maps to OTP's
/// `walkReluctance` / `bikeReluctance` parameters. Bike routing always uses
/// the `TRIANGLE` optimizer with a high `slopeFactor` — Seattle has plenty
/// of 10%+ blocks, and we never want to send a rider up one of them to
/// catch a bus if a gentler path exists.
enum RoutePreference: String, CaseIterable, Identifiable {
    case fastest      = "Fastest"
    case lessActive   = "Less biking/walking"

    var id: String { rawValue }

    /// Multiplier applied to the cost of walking. Higher = avoid walks.
    /// OTP's default is 2.0.
    var walkReluctance: Double {
        switch self {
        case .fastest:     return 2.0
        case .lessActive:  return 8.0
        }
    }

    /// Multiplier applied to the cost of biking. Higher = avoid bike legs.
    var bikeReluctance: Double {
        switch self {
        case .fastest:     return 2.0
        case .lessActive:  return 8.0
        }
    }

    /// OTP2's bike optimizer. We always send `TRIANGLE` so we can supply
    /// explicit safety / slope / time weights via `bikeTriangle`.
    var bikeOptimize: String { "TRIANGLE" }

    /// Triangle weights (must sum to 1.0) that drive OTP's bike cost model.
    /// Slope is intentionally the heaviest component — avoiding a steep
    /// climb is almost always worth a few extra blocks of flatter riding,
    /// especially when the rider is heading *to* transit with gear.
    /// Safety stays meaningful so we still prefer protected lanes when the
    /// terrain is similar. Time is kept low since raw minute savings over
    /// a hill are rarely worth the hill.
    var bikeTriangle: [String: Double] {
        switch self {
        case .fastest:
            return ["safetyFactor": 0.3,  "slopeFactor": 0.5,  "timeFactor": 0.2]
        case .lessActive:
            // "Less active" riders care even more about avoiding climbs.
            return ["safetyFactor": 0.25, "slopeFactor": 0.65, "timeFactor": 0.1]
        }
    }
}

// MARK: - Bike-only preference

/// How OTP should weight a bike-only trip. Independent of `RoutePreference`,
/// which governs walk / bike / transit tradeoffs for multimodal trips — for
/// a pure-bike route the only meaningful knob is the slope ↔ time balance
/// inside the OTP triangle. Splitting this out from `RoutePreference` lets
/// the user pick "Less biking/walking" for transit trips without that
/// implicitly making bike-only routes flatter (and longer) too.
enum BikePreference: String, CaseIterable, Identifiable {
    case faster      = "Faster"
    case lessEffort  = "Less effort"
    case safer       = "Safer"

    var id: String { rawValue }

    /// Always TRIANGLE so we control the safety / slope / time weights.
    var bikeOptimize: String { "TRIANGLE" }

    /// Triangle weights (must sum to 1.0). The three flavors are deliberately
    /// pulled toward different corners of the triangle so OTP's bike router
    /// actually returns distinct paths when alternatives exist:
    ///
    /// - `.faster`     — time wins. Short, direct routes even if they're a
    ///                    little hilly or use a busier street.
    /// - `.lessEffort` — slope wins. Flattest plausible path even if it's
    ///                    longer; happily takes a detour to skip a hill.
    /// - `.safer`      — safety wins. Prefers protected lanes / quiet
    ///                    streets, willing to add distance to find them.
    ///
    /// Three queries with these weights, fired in parallel and merged with
    /// metric-level dedup, surface 1–3 distinct corridor choices in most of
    /// Seattle. Flat / single-corridor trips collapse back to one option.
    var bikeTriangle: [String: Double] {
        switch self {
        case .faster:
            return ["safetyFactor": 0.3, "slopeFactor": 0.2, "timeFactor": 0.5]
        case .lessEffort:
            return ["safetyFactor": 0.2, "slopeFactor": 0.7, "timeFactor": 0.1]
        case .safer:
            // Pure safety. We ratcheted up from 0.6 → 0.85 → 1.0 in testing
            // because each step still chose Eastlake/Lakeview for the
            // Belltown→UW classic ride; only at safety=1.0 does OTP cleanly
            // surface the Westlake Protected Bike Lane + Burke-Gilman that
            // a Seattle cyclist would actually take. With slope=0 and
            // time=0 OTP doesn't try to keep trips short or flat — that's
            // fine here because (a) the graph-level edge costs already
            // discourage gratuitous hills/distance, and (b) the merge step
            // dedupes against the .faster and .lessEffort results, so on
            // trips where pure-safety produces something silly we still
            // surface a sensible alternative.
            return ["safetyFactor": 1.0, "slopeFactor": 0.0, "timeFactor": 0.0]
        }
    }

    /// Bike-only trips still pick up brief walk-the-bike segments at the
    /// start/end. We hold both reluctances at OTP defaults so they don't
    /// dominate the cost — the triangle is what does the real work here.
    var walkReluctance: Double { 2.0 }
    var bikeReluctance: Double { 2.0 }
}

// MARK: - Bike+transit flavor (internal)

/// Internal flavor used to fire multiple bike+transit queries in parallel and
/// surface alternatives that board at different transit stops.
///
/// OTP solves bike+transit as a single shortest-path problem with a
/// generalized cost: `bike_seconds × bikeReluctance + wait + in_vehicle +
/// walk_seconds × walkReluctance`. The choice of boarding stop emerges
/// implicitly — it picks whichever (origin → bike → stop → bus → walk →
/// dest) combination has the lowest total cost. With a single query the
/// user only ever sees OTP's one favorite, even when a small change in the
/// bike↔transit balance would surface a meaningfully different stop.
///
/// We fire three queries with different `bikeReluctance` and merge the
/// results, deduping by boarding-stop sequence. The user ends up with up
/// to three options:
///   - `.bikeMore` — bike further to a closer-in stop (often a faster bus
///     leg with a longer bike ride to a flatter / better-served stop)
///   - `.balanced` — OTP's default behavior at the user's preference
///   - `.bikeLess` — bike less, board the closest viable stop, possibly
///     with a longer in-vehicle leg
///
/// The user doesn't pick a flavor; merge surfaces all distinct ones and
/// the UI badges the non-default flavors so they can see *why* there are
/// multiple options.
enum BikeTransitFlavor: String, CaseIterable {
    case bikeMore  = "bike-more"
    case balanced  = "balanced"
    case bikeLess  = "bike-less"

    /// Multiplier applied to the user's `RoutePreference.bikeReluctance`.
    /// Multiplying preserves the user's intent — a `.lessActive` user gets
    /// less biking overall, but still sees variation across flavors:
    ///
    ///   `.fastest`     (base 2.0): 1.0 / 2.0 / 3.0
    ///   `.lessActive`  (base 8.0): 4.0 / 8.0 / 12.0
    ///
    /// Values were picked so the most-bike flavor sits at parity with
    /// in-vehicle time (1.0) for the default user, which is what gives OTP
    /// permission to bike further to a better stop.
    var bikeReluctanceMultiplier: Double {
        switch self {
        case .bikeMore:  return 0.5
        case .balanced:  return 1.0
        case .bikeLess:  return 1.5
        }
    }

    /// User-facing label for the badge. `.balanced` returns nil so we don't
    /// badge OTP's default — only the alternatives that exist *because* we
    /// fanned out the query.
    var badgeLabel: String? {
        switch self {
        case .bikeMore:  return "More bike"
        case .balanced:  return nil
        case .bikeLess:  return "Less bike"
        }
    }
}

// MARK: - Bike pace (rider speed)

/// How fast the user actually rides. Sent to OTP as the `bikeSpeed`
/// parameter on the plan query and used client-side when we project
/// remaining time during navigation. OTP's default is 5.0 m/s (≈11.2 mph),
/// which is a moderate commuter pace; many real riders are noticeably
/// faster, which makes OTP's reported durations and ETAs run long.
///
/// Speeds in m/s are exact; the mph values shown to the user are derived.
enum BikePace: String, CaseIterable, Identifiable, Codable {
    case casual    // 10 mph — relaxed cruiser
    case moderate  // 11.2 mph — OTP default
    case brisk     // 12.9 mph — fit commuter (≈15% over default)
    case fast      // 14.5 mph — fast commuter / road bike

    var id: String { rawValue }

    /// What we send to OTP as `bikeSpeed`, AND what the client uses for
    /// its own per-leg duration math (see `Leg.estimatedDurationSeconds`).
    /// Moderate is the default and is set to 11.2 mph (5.0 m/s), which
    /// matches OTP's own default — a calibrated flat-speed estimate for
    /// a typical urban commuter across cities. Earlier this was 12.0
    /// mph, which felt fast in practice once hill and signal penalties
    /// stacked on top. Dropping to the OTP default makes our estimated
    /// durations match what other transit/cycling apps show.
    var metersPerSecond: Double {
        switch self {
        case .casual:   return 4.5    // 10.1 mph
        case .moderate: return 5.0    // 11.2 mph (default — matches OTP's own)
        case .brisk:    return 5.75   // 12.9 mph
        case .fast:     return 6.5    // 14.5 mph
        }
    }

    /// User-facing mph rounded to one decimal for the picker labels.
    var mph: Double {
        // 1 m/s = 2.23694 mph
        (metersPerSecond * 2.23694 * 10).rounded() / 10
    }

    var label: String {
        switch self {
        case .casual:   return "Casual"
        case .moderate: return "Moderate"
        case .brisk:    return "Brisk"
        case .fast:     return "Fast"
        }
    }

    var blurb: String {
        switch self {
        case .casual:   return "Cruising — coasting hills, no rush."
        case .moderate: return "OTP's default — typical commuter pace."
        case .brisk:    return "Fit commuter — about 15% faster than the default."
        case .fast:     return "Strong rider — light hybrid or road bike."
        }
    }
}

// MARK: - Bike kind (standard vs e-bike)

/// What kind of bike the user is riding. Orthogonal to `BikePace` — pace
/// is "how hard you pedal," kind is "what's helping you pedal." An
/// e-bike's motor assist materially changes three things relative to a
/// standard bike, and we model all three here so the user only picks
/// once:
///
/// 1. **Cruising speed.** Class-2/3 e-bikes hold ~18 mph all day with
///    minimal rider effort. We override `BikePace.metersPerSecond` with
///    a fixed value when the user selects electric — pace becomes
///    motor-determined, not rider-determined.
/// 2. **Hill cost.** Our per-meter climb penalty (3.9 s/m on a standard
///    bike) drops to ~1 s/m on an e-bike; the motor flattens steep
///    blocks that would otherwise add minutes per climb.
/// 3. **Routing preferences.** An e-bike rider is more willing to take
///    a direct hilly route than a flat detour, so the OTP bike triangle
///    weights shift from slope-aware toward time-aware, and bike
///    reluctance drops (an e-biker more readily bikes a longer leg
///    instead of waiting for a transit transfer).
///
/// Standard returns `nil` for the override hooks so the existing
/// preference-derived values pass through unchanged.
enum BikeKind: String, CaseIterable, Identifiable, Codable {
    case standard
    case electric

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard bike"
        case .electric: return "E-bike"
        }
    }

    var blurb: String {
        switch self {
        case .standard: return "Pedal-only — pace below controls your cruising speed."
        case .electric: return "Motor-assisted — fixed 18 mph cruising, hills no longer add time."
        }
    }

    var icon: String {
        switch self {
        case .standard: return "bicycle"
        case .electric: return "bolt.fill"
        }
    }

    /// Effective bike speed sent to OTP and used in client-side duration
    /// math. For standard bikes, defers to the user's `BikePace` pick.
    /// For e-bikes, overrides pace with a fixed 18 mph (8.05 m/s) — the
    /// motor's flat-speed cruise, not the rider's pace.
    func metersPerSecond(pace: BikePace) -> Double {
        switch self {
        case .standard: return pace.metersPerSecond
        case .electric: return 8.05  // 18 mph
        }
    }

    /// User-facing speed in mph, used for the e-bike pace-row label
    /// where the pace picker is hidden.
    func mph(pace: BikePace) -> Double {
        (metersPerSecond(pace: pace) * 2.23694 * 10).rounded() / 10
    }

    /// Seconds added per meter climbed in the client-side duration
    /// recalc (see `ElevationService.stampClientBikeDurations`). The
    /// e-bike value isn't zero — the motor still works harder on
    /// climbs and a small time cost reflects that — but it's roughly a
    /// quarter of the standard-bike penalty.
    var climbSecondsPerMeter: Double {
        switch self {
        case .standard: return 3.9
        case .electric: return 1.0
        }
    }

    /// OTP triangle override. Standard returns nil so the existing
    /// `BikePreference` / `RoutePreference` triangle passes through.
    /// Electric overrides with a quick-favoring weighting that matches
    /// how e-bike riders actually pick routes: time first, safety
    /// secondary, slope barely a factor.
    var triangleOverride: [String: Double]? {
        switch self {
        case .standard: return nil
        case .electric:
            // Weights must sum to 1.0. Matches OTP triangle convention
            // shared with BikePreference.bikeTriangle.
            return ["safetyFactor": 0.15, "slopeFactor": 0.05, "timeFactor": 0.80]
        }
    }

    /// OTP bikeReluctance override. Standard returns nil (preference
    /// drives it). Electric returns a low value so multimodal trips
    /// prefer biking a longer stretch over an extra transfer — the
    /// "I'd rather just keep going than wait for a bus" instinct that's
    /// stronger when biking is cheaper per minute.
    var bikeReluctanceOverride: Double? {
        switch self {
        case .standard: return nil
        case .electric: return 1.5
        }
    }
}

// MARK: - When the user wants to travel

/// How the user wants us to interpret the selected `Date`.
/// - `leaveNow`: ignore the date, use "now" on every query
/// - `leaveAt`:  plan a trip that *departs* at the given time
/// - `arriveBy`: plan a trip that *arrives* by the given time
enum TimeTarget: Hashable {
    case leaveNow
    case leaveAt(Date)
    case arriveBy(Date)

    /// What OTP's `arriveBy` argument should be.
    var arriveBy: Bool {
        if case .arriveBy = self { return true }
        return false
    }

    /// The reference date to send to OTP. `.leaveNow` resolves to "now".
    var date: Date {
        switch self {
        case .leaveNow:         return Date()
        case .leaveAt(let d):   return d
        case .arriveBy(let d):  return d
        }
    }

    /// Short chip label.
    var chipLabel: String {
        switch self {
        case .leaveNow:        return "Leave now"
        case .leaveAt(let d):  return "Depart " + Self.timeFmt.string(from: d)
        case .arriveBy(let d): return "Arrive by " + Self.timeFmt.string(from: d)
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}

// MARK: - Response types (mirror OTP2's plan() GraphQL schema)

struct PlanResponse: Decodable {
    let data: PlanData?
    struct PlanData: Decodable { let plan: Plan }
    struct Plan: Decodable { let itineraries: [Itinerary] }
}

struct Itinerary: Decodable, Identifiable {
    // OTP doesn't return an id; we synthesise one. Flavor is folded into the
    // id so a faster + less-effort pair with otherwise-identical timestamps
    // and leg counts (rare but possible) don't collapse into one row.
    var id: String {
        let flavor = bikeFlavor.map { "-\($0.rawValue)" } ?? ""
        let tflav  = transitFlavor.map { "-\($0.rawValue)" } ?? ""
        return "\(startTime)-\(endTime)-\(legs.count)\(flavor)\(tflav)"
    }
    // These are `var` rather than `let` so a mid-trip reroute (see
    // `TripNavigationView.performReroute`) can splice fresh bike/walk legs
    // into the itinerary without rebuilding it from scratch. Outside of
    // that one call site the values are written exactly once (by the
    // synthesized Decodable init) and treated as immutable.
    var duration: Int          // seconds
    var walkDistance: Double   // meters
    var startTime: Int64       // epoch millis
    var endTime: Int64
    var legs: [Leg]

    /// Set client-side by `RoutingClient.plan` for bike-only queries to mark
    /// which `BikePreference` this itinerary was computed under. Nil for
    /// multimodal itineraries (and any bike-only itinerary from a call site
    /// that doesn't tag — e.g. tests). Used by the UI to badge the "less
    /// effort" alternative when it survives the climb-reduction filter.
    var bikeFlavor: BikePreference? = nil

    /// Set for bike+transit itineraries to mark which flavor of the
    /// fanned-out query produced them. Used by the UI to badge "More bike"
    /// vs "Less bike" alternatives that survive the boarding-stop dedup.
    /// Nil for `.balanced` results and for non-bike+transit itineraries —
    /// no badge is rendered in those cases.
    var transitFlavor: BikeTransitFlavor? = nil

    /// Total climb across all bike legs, in meters. Populated by `planTrip()`
    /// after `ElevationService.profile()` resolves for each bike leg, so this
    /// is nil immediately post-decode and gets stamped on a moment later.
    /// Drives the elevation-adjusted duration (see `effectiveDurationSeconds`).
    var climbMeters: Double? = nil

    /// Custom keys so the auto-synthesized Decodable init only decodes what
    /// OTP returns; `bikeFlavor` and `climbMeters` keep their default of nil
    /// and are set by the planner after decode.
    private enum CodingKeys: String, CodingKey {
        case duration, walkDistance, startTime, endTime, legs
    }
}

struct Leg: Decodable, Identifiable {
    var id: String { "\(startTime)-\(mode)" }
    let mode: String           // "BICYCLE", "BUS", "RAIL", "WALK", ...
    let startTime: Int64
    let endTime: Int64
    let distance: Double
    // Realtime fields are `var` so the navigation view can refresh them
    // periodically without touching anything else about the leg. We never
    // re-pick the bus mid-trip (see TripNavigationView.refreshRealtime),
    // we just copy the latest delay/cancellation status onto the existing
    // leg so the boarding card and ETA reflect what's actually happening.
    var realTime: Bool?
    var realtimeState: String?   // SCHEDULED, UPDATED, CANCELED, ADDED, MODIFIED
    var arrivalDelay: Int?       // seconds (positive = late, negative = early)
    var departureDelay: Int?     // seconds
    /// True when this leg uses a rented vehicle (Lime bikeshare in
    /// Seattle). OTP reports rental legs with `mode: "BICYCLE"` plus
    /// this flag — not as `mode: "BICYCLE_RENT"` — so anywhere we
    /// want "this is a rental, render distinctly" we read `isRental`,
    /// not the mode string. Nil = absent from the response (treated
    /// as false).
    let rentedBike: Bool?
    let from: Place
    let to: Place
    let legGeometry: Geometry
    let route: RouteInfo?
    let headsign: String?
    let steps: [WalkStep]?
    /// Stops the bus passes through between `from` (boarding) and `to`
    /// (alighting), excluding both endpoints. Populated for transit legs
    /// when OTP returns it; nil for walk/bike legs and when the field is
    /// absent. Rendered as small dots along the transit polyline so the
    /// user can see every stop the bus makes — useful for picking which
    /// stop to actually get off at, and for understanding why a leg has
    /// the duration it does.
    let intermediateStops: [Place]?

    /// Total climb in meters across this leg's polyline. Populated by
    /// `planTrip()` for bike legs after `ElevationService.profile()`
    /// resolves; nil for walk/transit legs and for bike legs whose
    /// elevation fetch hasn't returned yet.
    var climbMeters: Double? = nil

    /// Max grade percent (over the rolling ~80 m window) observed
    /// along this leg's polyline. Stamped alongside `climbMeters` by
    /// `ElevationService.stampClientBikeDurations`. Used by
    /// `Itinerary.hasSteepBikeLeg` to catch bimodal routes whose
    /// average grade dilutes the steep portion below the avg-grade
    /// threshold (e.g., flat waterfront + short Queen Anne wall).
    /// Nil for walk/transit legs and for bike legs whose elevation
    /// hasn't resolved yet.
    var maxGradePercent: Double? = nil

    /// Client-computed duration for this leg, in seconds. For bike
    /// legs we ignore OTP's `(endTime - startTime)` and use our own
    /// model: `distance / bikePace.metersPerSecond + climb * 3.9`.
    /// OTP's value is governed by a flat speed scalar that doesn't
    /// reflect the user's pace setting on top of slope, and stamping
    /// our own number here lets every display site (chip, row total,
    /// pill, ETA) read a consistent value without threading pace
    /// through every call site. Nil before planTrip stamps it; the
    /// accessors below fall back to OTP's raw value in that case.
    var estimatedDurationSeconds: Int? = nil

    /// Fraction of this leg's polyline covered by OSM ways tagged
    /// `lit=yes`, on a 0.0–1.0 scale. Injected by the signal-augment
    /// proxy for bike legs only — walk/transit legs leave this nil.
    /// Used by the "Well-lit" badge logic in itinerary list rendering:
    /// after sunset, an itinerary whose distance-weighted bike-leg
    /// litFraction crosses a threshold (see `Itinerary.litBadgeQualifies`)
    /// gets a quiet badge in the row. Nil indicates either a non-bike
    /// leg or that the proxy was unavailable when the response was
    /// served — the badge logic treats nil as "unknown, don't badge."
    var litFraction: Double? = nil

    /// When the dedup merge collapses two itineraries that board at
    /// the same stop sequence but use different bus lines (1 Line vs
    /// 2 Line, both pickup at Westlake → both alight at U-District),
    /// the collapsed siblings' `RouteInfo` values land here on the
    /// surviving canonical leg. The leg's primary `route` reflects
    /// the earliest-departing variant; `alternativeRoutes` lists the
    /// others. UI surfaces both: chip reads "1 Line / 2 Line",
    /// detail view says "Take 1 Line or 2 Line." Empty / nil on
    /// every leg that didn't come through the dedup-merge path.
    var alternativeRoutes: [RouteInfo] = []

    /// Departure times (epoch ms) for each entry in `alternativeRoutes`,
    /// indexed in the same order. The canonical leg keeps its own
    /// `startTime` for the primary route. The detail view uses these
    /// to render "or 8:14" suffix on the boarding-time line when the
    /// alternative departs noticeably later than the primary.
    var alternativeStartTimes: [Int64] = []

    /// Custom CodingKeys so Codable only decodes the fields OTP returns.
    /// `climbMeters` and `estimatedDurationSeconds` are populated by
    /// the planner after decode and aren't expected from the GraphQL
    /// payload. `litFraction` IS expected — the proxy injects it as a
    /// top-level field on each bike leg's JSON regardless of whether
    /// the GraphQL query asked for it.
    private enum CodingKeys: String, CodingKey {
        case mode, startTime, endTime, distance
        case realTime, realtimeState, arrivalDelay, departureDelay
        case rentedBike
        case from, to, legGeometry, route, headsign, steps
        case intermediateStops
        case litFraction
    }

    /// Convenience: true when this is a Lime / bikeshare rental leg.
    /// Reads `rentedBike` rather than `mode` because OTP returns rental
    /// legs as `mode: "BICYCLE"` and uses the boolean to distinguish.
    var isRental: Bool { rentedBike ?? false }

    /// Assembled per-leg elevation profile derived from this leg's
    /// `steps`. The OTP GTFS GraphQL schema exposes `elevationProfile`
    /// on `step`, not directly on `Leg`, so we build the leg-level
    /// view by concatenating each step's per-step samples and shifting
    /// each sample's distance by the cumulative distance through prior
    /// steps. Returns nil if the leg has no steps (transit legs) or if
    /// no step has elevation data (out of DEM coverage), which causes
    /// `ElevationService.profile(for:)` to fall through to Open-Meteo.
    var assembledElevationProfile: [ElevationProfileSample]? {
        guard let steps, !steps.isEmpty else { return nil }
        var out: [ElevationProfileSample] = []
        var offset: Double = 0
        for step in steps {
            if let profile = step.elevationProfile, !profile.isEmpty {
                for s in profile {
                    out.append(ElevationProfileSample(
                        distance: offset + s.distance,
                        elevation: s.elevation
                    ))
                }
            }
            offset += step.distance
        }
        return out.isEmpty ? nil : out
    }
}

/// One sample on an OTP-provided per-leg elevation profile.
/// `distance` is meters along the leg from `from`; `elevation` is
/// meters above sea level. Samples are not uniformly spaced — they
/// land at OSM way vertices the leg traverses.
struct ElevationProfileSample: Decodable, Equatable {
    let distance: Double
    let elevation: Double
}

/// Real-time status of a transit leg, rolled up into a single tag we can render.
enum RealTimeStatus {
    case unknown          // no RT at all (walk/bike, or feed unavailable)
    case scheduled        // RT feed active but no update for this trip
    case onTime           // live + within ±60s of schedule
    case late(Int)        // live, running late by N minutes
    case early(Int)       // live, running early by N minutes
    case canceled
}

/// Turn-by-turn step within a walk or bike leg.
struct WalkStep: Decodable {
    let distance: Double            // meters
    let relativeDirection: String?  // LEFT, RIGHT, CONTINUE, HARD_LEFT, ...
    let absoluteDirection: String?  // NORTH, EAST, ...
    let streetName: String?
    let lat: Double
    let lon: Double

    /// Per-step elevation samples from OTP, computed against the DEM
    /// (`seattle_elevation.tif`) at graph build time. Each sample is
    /// `(distance from the start of THIS step in meters, elevation in
    /// meters above sea level)`. Step-level rather than leg-level
    /// because that's where OTP's GTFS GraphQL schema exposes it; the
    /// leg-level view is assembled by `Leg.assembledElevationProfile`,
    /// which offsets each step's distance by the cumulative distance
    /// through prior steps.
    let elevationProfile: [ElevationProfileSample]?

    /// Number of OSM `highway=traffic_signals` nodes within ~30 m of
    /// this step's coordinates. Populated by the signal-augment proxy
    /// that sits between the iOS app and OTP — *not* by OTP itself,
    /// which has no concept of signals on its routing edges. Nil when
    /// the proxy is bypassed (e.g. iOS pointed straight at OTP); in
    /// that case `ElevationService.stampClientBikeDurations` falls
    /// back to the flat per-street-mile penalty.
    ///
    /// See `otp-setup/proxy/main.py` for the augmentation logic and
    /// `otp-setup/extract-traffic-nodes.py` for how the underlying
    /// signals.json is built from OSM.
    let signalCount: Int?

    /// Number of OSM `highway=stop` nodes within ~30 m of this step's
    /// coordinates. Same source / same nil semantics as `signalCount`.
    let stopCount: Int?

    /// Number of OSM `highway=give_way` nodes within ~30 m of this
    /// step's coordinates. Same source / same nil semantics as
    /// `signalCount`.
    let yieldCount: Int?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Human-readable instruction, e.g. "Turn right onto Pine St".
    var instruction: String {
        let verb: String
        switch relativeDirection ?? "CONTINUE" {
        case "LEFT":        verb = "Turn left"
        case "RIGHT":       verb = "Turn right"
        case "HARD_LEFT":   verb = "Sharp left"
        case "HARD_RIGHT":  verb = "Sharp right"
        case "SLIGHTLY_LEFT":  verb = "Bear left"
        case "SLIGHTLY_RIGHT": verb = "Bear right"
        case "UTURN_LEFT", "UTURN_RIGHT": verb = "Make a U-turn"
        case "DEPART":      verb = "Head out"
        case "CONTINUE":    verb = "Continue"
        case "CIRCLE_CLOCKWISE", "CIRCLE_COUNTERCLOCKWISE": verb = "Take the roundabout"
        case "ELEVATOR":    verb = "Take the elevator"
        default:            verb = "Continue"
        }
        if let street = streetName, !street.isEmpty, street != "road" {
            return verb == "Continue" ? "Continue on \(street)" : "\(verb) onto \(street)"
        }
        return verb
    }

    /// SF Symbol name to represent the turn.
    var icon: String {
        switch relativeDirection ?? "CONTINUE" {
        case "LEFT":        return "arrow.turn.up.left"
        case "RIGHT":       return "arrow.turn.up.right"
        case "HARD_LEFT":   return "arrow.uturn.left"
        case "HARD_RIGHT":  return "arrow.uturn.right"
        case "SLIGHTLY_LEFT":  return "arrow.up.left"
        case "SLIGHTLY_RIGHT": return "arrow.up.right"
        case "UTURN_LEFT", "UTURN_RIGHT": return "arrow.uturn.up"
        case "CIRCLE_CLOCKWISE", "CIRCLE_COUNTERCLOCKWISE": return "arrow.triangle.2.circlepath"
        case "ELEVATOR":    return "arrow.up.and.down"
        default:            return "arrow.up"
        }
    }
}

struct Place: Decodable {
    let name: String
    let lat: Double
    let lon: Double
    /// OTP vertex category. Values we care about: "BIKESHARE" marks a
    /// rental pickup or drop-off point (used to render a Lime-green
    /// pin distinct from regular stop dots). "NORMAL", "TRANSIT" and
    /// others exist but we don't currently branch on them. Nil when
    /// the field is absent from the response (older OTP or queries
    /// that don't request it).
    let vertexType: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// True if this endpoint is a bikeshare pickup or drop-off vertex.
    var isBikeshareVertex: Bool { vertexType == "BIKESHARE" }
}

struct Geometry: Decodable {
    /// Encoded polyline, Google format, precision 5.
    let points: String
}

struct RouteInfo: Decodable {
    let shortName: String?
    let longName: String?
}

// MARK: - Convenience

extension Itinerary {

    // MARK: - Elevation-adjusted duration
    //
    // OTP's `duration` is computed against a flat-speed assumption (default
    // 5 m/s ≈ 11.2 mph) — its routing graph doesn't bend the per-meter time
    // when the road goes uphill. For Seattle, where a downtown-to-Capitol-
    // Hill trip can climb 100m in a mile, the OTP-only number consistently
    // *understates* a hilly trip. We patch this up client-side: for each
    // meter of total climb across all bike legs, add a fixed time penalty.
    //
    // Why 6 s/m: a moderate cyclist climbs at ~600 vertical meters per hour,
    // so each meter of ascent costs ~6 s of *extra* clock time over the
    // flat-speed baseline. 100 m of climb → 10 min extra, which roughly
    // matches lived experience on the Capitol Hill / Queen Anne climbs.
    //
    // This is added strictly to the BIKE component of the trip — transit
    // legs aren't affected by elevation, and walk legs are short enough
    // that the same penalty would over-correct. We don't subtract anything
    // for descents: a fast downhill doesn't make a hilly route faster than
    // a flat one in any meaningful way (you still need to climb back).

    /// Seconds of additional clock time per meter of climb, on top of
    /// the flat-speed time `(distance / bikePace)`. 3.9 s/m corresponds
    /// to a sustained climb pace of ~925 m/hour for the *vertical*
    /// component, which lines up with a strong recreational rider's
    /// observed pace on Seattle's steeper segments (Madison, James,
    /// Galer). It's intentionally less aggressive than the previous 6
    /// s/m: that was tuned against OTP's flat estimate as a soft sort-
    /// time penalty, but now the same number is the *displayed* time
    /// adjustment, and a heavier penalty consistently overestimated
    /// hilly trips.
    static let climbSecondsPerMeter: Double = 3.9

    /// **Fallback** per-mile penalty for the street portion of a bike
    /// leg, used only when the signal-augment proxy isn't in front of
    /// OTP and `WalkStep.signalCount` is therefore nil. Sized for an
    /// average Seattle street (~5 signals/mile × ~9 sec average wait).
    /// When the proxy is deployed and per-step counts are present,
    /// `secondsPerTrafficSignal` / `secondsPerStopSign` /
    /// `secondsPerYield` below take over and produce a more accurate
    /// per-leg estimate based on actual OSM intersection counts.
    static let signalPenaltySecondsPerMile: Double = 45

    /// Average wait at a signaled intersection on a bike, in seconds.
    /// Modeled on a typical Seattle bike-relevant signal — ~75 s cycle
    /// with ~45 s red for the cross/bike approach: P(red on arrival)
    /// ≈ 0.6, expected wait given red ≈ 22 s → ~13 s average wait,
    /// plus ~2 s deceleration/acceleration ≈ 15 s. Bumped up from a
    /// prior value of 9 s after comparing OTP-predicted bike times
    /// against actual rider data; the old number consistently
    /// under-estimated downtown/Capitol Hill trips with high signal
    /// counts. Still tunable — this is the constant most worth
    /// empirically calibrating as more trip-completion data arrives.
    static let secondsPerTrafficSignal: Double = 15

    /// Average time lost at a stop sign for a bike. Always a full stop
    /// (legally; many riders Idaho-stop, but reservations on time
    /// estimates being optimistic mean we account for the lawful case).
    /// Quick to clear once stopped, hence shorter than a signal.
    static let secondsPerStopSign: Double = 4

    /// Average time lost at a yield / give_way for a bike. Often
    /// rolled-through with no real stop; small deceleration penalty.
    static let secondsPerYield: Double = 2

    // MARK: - Lit-badge logic
    //
    // The proxy injects `litFraction` (0.0–1.0) on each bike leg —
    // fraction of the leg's polyline covered by OSM `lit=yes` ways.
    // We aggregate to itinerary-level by distance-weighting across
    // bike legs, then surface a "Well-lit" badge after sunset when
    // the weighted fraction crosses a threshold.

    /// Threshold above which we consider an itinerary "well-lit
    /// enough" to badge. Calibrated against typical Seattle bike
    /// routes: a route on Westlake + the Burke-Gilman scores around
    /// 0.85–0.95 (both corridors are tagged lit=yes end-to-end), while
    /// a residential side-street route scores 0.20–0.40. Anywhere
    /// above 0.70 means the rider is on lit infrastructure for most
    /// of the trip, with at most a few unlit connector blocks.
    static let litBadgeThreshold: Double = 0.7

    /// Distance-weighted average of `litFraction` across all bike legs.
    /// Nil when there are no bike legs with a populated litFraction
    /// (transit-only trips, walk-only trips, or proxy-down responses).
    /// Walk and transit legs are excluded from both numerator and
    /// denominator — they don't have lit data and including them
    /// would dilute the bike-leg signal we actually care about.
    var litFractionWeighted: Double? {
        var totalDistance: Double = 0
        var totalWeighted: Double = 0
        var sawAny = false
        for leg in legs {
            let isBike = leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT"
            guard isBike, let f = leg.litFraction, leg.distance > 0 else { continue }
            sawAny = true
            totalDistance += leg.distance
            totalWeighted += f * leg.distance
        }
        guard sawAny, totalDistance > 0 else { return nil }
        return totalWeighted / totalDistance
    }

    /// True if any portion of this trip falls *past sunset* — either
    /// departure or arrival is post-evening-twilight per
    /// `Solar.isPastSunset`. Used by the sort comparator in `planTrip`
    /// to apply a lit-fraction bonus, by the "% lit" summary row in
    /// the itinerary card, and by the Well-lit badge.
    ///
    /// Deliberately uses post-sunset (NOT the broader `Solar.isDark`)
    /// so pre-dawn trips don't trigger lit-aware UI. A 5 AM departure
    /// arriving at 7 AM in summer technically starts in the dark, but
    /// the user reserves the lighting badge / discount for evening
    /// rides only. Same semantic across all three call sites for
    /// consistency.
    var isTripDark: Bool {
        let start = Date(timeIntervalSince1970: TimeInterval(startTime) / 1000)
        let end = Date(timeIntervalSince1970: TimeInterval(endTime) / 1000)
        return Solar.isPastSunset(at: start) || Solar.isPastSunset(at: end)
    }

    /// True when this itinerary should display the "Well-lit" badge.
    /// Two conditions must both hold:
    ///   - The itinerary's bike-leg portion is mostly on lit
    ///     infrastructure (litFractionWeighted ≥ litBadgeThreshold)
    ///   - The trip is past sunset (`isTripDark`) — i.e., either
    ///     departure or arrival falls after today's evening civil
    ///     twilight.
    ///
    /// Note: we delegate the time check to `isTripDark`, which uses
    /// `Solar.isPastSunset` (NOT the broader `Solar.isDark`). Pre-dawn
    /// trips are intentionally excluded — the badge is reserved for
    /// "biking after the sun went down today," which is the evening
    /// case riders mentally map onto "need lit streets." Early-morning
    /// rides that happen to start before sunrise don't get the badge
    /// even though they're technically in darkness.
    var litBadgeQualifies: Bool {
        guard let frac = litFractionWeighted, frac >= Self.litBadgeThreshold
        else { return false }
        return isTripDark
    }

    /// Climb-penalty seconds for this itinerary, or 0 if the elevation
    /// fetch hasn't completed (or this is a transit-only trip with no
    /// bike legs). Kept as a separate signal — used as a soft tie-break
    /// in the sort comparators below, but no longer folded into the
    /// displayed duration. Per-leg chips use OTP's raw bike time and
    /// the leftmost trip total used to inflate by this penalty, which
    /// produced visibly inconsistent numbers ("60 min" chip / "1h 6 min"
    /// row total). Show OTP's faster bike time everywhere instead.
    var climbPenaltySeconds: Int {
        guard let m = climbMeters, m > 0 else { return 0 }
        return Int((m * Self.climbSecondsPerMeter).rounded())
    }

    /// Duration we render to the user everywhere — list rows, mode
    /// pills, detail sheet, leg chips — summed from each leg's
    /// `displayDurationSeconds`. For bike legs that's our own
    /// (distance / pace + climb * 3.9 s/m) estimate once stamped; for
    /// walk/transit it's OTP's timestamp delta. Falls back to OTP's
    /// itinerary-level `duration` when no legs are present (defensive
    /// — shouldn't happen in practice).
    var effectiveDurationSeconds: Int {
        // Wall-clock duration from the reconciled timeline — covers
        // transit realtime delays and waits at stops, not just the
        // sum of per-leg stamped durations. Falls back to the
        // legacy sum-of-displayDurationSeconds (then OTP's itinerary
        // `duration`) if the timeline is somehow empty.
        let timeline = effectiveTimeline()
        if let first = timeline.first, let last = timeline.last {
            return max(0, Int(last.endDate.timeIntervalSince(first.startDate)))
        }
        let summed = legs.map(\.displayDurationSeconds).reduce(0, +)
        return summed > 0 ? summed : duration
    }

    var durationMinutes: Int { effectiveDurationSeconds / 60 }

    /// "24 min" if under an hour, "1 h 12 min" otherwise.
    var formattedDuration: String { Self.formatMinutes(durationMinutes) }

    /// Shared formatter used by both the itinerary header total and the
    /// per-leg duration chips. Avoids the bug where the trip header
    /// showed "1 h 7 min" correctly but a 67-min bike leg chip displayed
    /// "67 min". Both surfaces now read from this one helper.
    static func formatMinutes(_ total: Int) -> String {
        if total < 60 { return "\(total) min" }
        let h = total / 60
        let m = total % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    var summary: String {
        var parts: [String] = []
        if bikeMinutes > 0 { parts.append("\(bikeMinutes) min bike") }
        // Elevation: surface total climb in feet across all bike legs
        // when it's worth noting (≥10 m / ~33 ft). Used to be ≥30 m,
        // but the detail-page header had no climb info on moderate
        // trips, which masked the fact that elevation data was even
        // available. 10 m still hides trivially-flat downtown trips.
        // `climbMeters` per-leg is stamped by ElevationService after
        // planTrip; this may be 0 on the very first render before the
        // elevation fetch resolves — UI updates once it lands.
        let totalClimb = legs.compactMap { $0.climbMeters }.reduce(0, +)
        if totalClimb >= 10 {
            let feet = Int((totalClimb * 3.28084).rounded())
            parts.append("↗ \(feet) ft")
        }
        // Hill-warning flag: "steep" for any leg with ≥5% avg grade
        // over ≥500 m or peak windowed grade ≥10% (catches the
        // bimodal case where a short Queen Anne / James / Madison
        // wall is mixed with flat sections); "moderate hills" for
        // 3-5% avg or 6-10% peak when not already steep. Same
        // thresholds as the per-leg HillBadge so trip-level and
        // per-leg labels agree.
        if hasSteepBikeLeg {
            parts.append("steep")
        } else if hasModerateBikeLeg {
            parts.append("moderate hills")
        }
        // Transit lines: name them ("D Line", "540", "Link") instead of
        // a generic "N transit" count. The per-leg rows below in the
        // detail view already show full line+headsign; the summary just
        // surfaces the short names so the header reads at a glance.
        // Falls back to "transit" for legs missing a route name.
        let transitNames = legs.compactMap { leg -> String? in
            guard leg.isTransit else { return nil }
            return leg.route?.shortName ?? leg.route?.longName ?? "transit"
        }
        if !transitNames.isEmpty {
            parts.append(transitNames.joined(separator: " + "))
        }
        return parts.joined(separator: " • ")
    }

    /// True if any bike leg in this itinerary qualifies as "steep" —
    /// either the leg's average grade is ≥5% (the long-distance hill
    /// case: climb out of downtown into Capitol Hill, ascend Madison)
    /// **or** its peak windowed grade is ≥10% (the bimodal case: flat
    /// waterfront plus a short Queen Anne wall, where averaging would
    /// dilute the wall below 5%). Peak grade is read from each leg's
    /// `maxGradePercent`, stamped by
    /// `ElevationService.stampClientBikeDurations` alongside
    /// `climbMeters`. Returns false while elevation is still loading
    /// so the summary doesn't flicker.
    ///
    /// The 10% peak threshold matches the per-leg `HillBadge.steep`
    /// classifier in `ElevationProfile.difficulty`, so trip-level
    /// "steep" and per-leg-badge "steep red" are saying the same
    /// thing about the same data.
    var hasSteepBikeLeg: Bool {
        for leg in legs {
            guard leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT" else { continue }
            if let peak = leg.maxGradePercent, peak >= 10 { return true }
            guard let climb = leg.climbMeters, climb > 0,
                  leg.distance >= 500 else { continue }
            let avgGrade = climb / leg.distance
            if avgGrade >= 0.05 { return true }
        }
        return false
    }

    /// True if any bike leg qualifies as "moderate hill" but doesn't
    /// already qualify as steep — either avg grade in 3–5% over a
    /// ≥500 m bike leg, or peak windowed grade in 6–10%. Matches the
    /// `HillBadge.hilly` classifier in `ElevationProfile.difficulty`
    /// so trip-level "moderate" and per-leg "hilly orange" agree.
    /// Returns false if `hasSteepBikeLeg` is already true — steep
    /// wins; we don't double-label a trip "Steep + Moderate."
    var hasModerateBikeLeg: Bool {
        guard !hasSteepBikeLeg else { return false }
        for leg in legs {
            guard leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT" else { continue }
            if let peak = leg.maxGradePercent, peak >= 6 { return true }
            guard let climb = leg.climbMeters, climb > 0,
                  leg.distance >= 500 else { continue }
            let avgGrade = climb / leg.distance
            if avgGrade >= 0.03 { return true }
        }
        return false
    }

    /// Total time spent biking, in whole minutes — sums each bike
    /// leg's `displayDurationSeconds`, so once `planTrip()` has stamped
    /// our client-computed durations the summary already includes pace
    /// and slope. Falls back to OTP's timestamps for any leg where the
    /// estimate hasn't been stamped yet.
    var bikeMinutes: Int {
        let secs = legs
            .filter { $0.mode == "BICYCLE" || $0.mode == "BICYCLE_RENT" }
            .reduce(0) { $0 + $1.displayDurationSeconds }
        return secs / 60
    }

    /// Total biking distance across all legs, in miles.
    var bikeMiles: Double {
        legs.filter { $0.mode == "BICYCLE" || $0.mode == "BICYCLE_RENT" }
            .reduce(0) { $0 + $1.distance } / 1609.34
    }

    /// First leg's reconciled start time from `effectiveTimeline()` —
    /// for trips that begin with a walk/bike access leg, this is
    /// the back-anchored "leave by" time, not OTP's raw `startTime`
    /// (which is what OTP would have you start at to hit the bus
    /// schedule at its flat-speed assumption). All display sites
    /// (the option card's time range, the trip-detail header, the
    /// past-start filter, the refresh-stale check) read off this so
    /// they agree with the trip-detail body. Falls back to OTP's
    /// raw startTime if the timeline is somehow empty (defensive —
    /// happens only on legs.count == 0).
    var startDate: Date {
        effectiveTimeline().first?.startDate
            ?? Date(timeIntervalSince1970: TimeInterval(startTime) / 1000)
    }

    /// True if this itinerary has already arrived (endTime in the past)
    /// at the moment the property is read. We key off arrival rather
    /// than departure on purpose: a trip that left 5 min ago but
    /// arrives in 10 min is still catchable in practice, so it's not
    /// "past" from the user's POV. Used by ItineraryRow to mute the
    /// row visually and by ItineraryDetailView to disable the GO
    /// button — past trips show up in the list as a record of what
    /// the schedule looked like, but they can't be started.
    var isPast: Bool {
        Date(timeIntervalSince1970: TimeInterval(endTime) / 1000) < Date()
    }

    /// OTP's reported end time (no elevation adjustment). Kept for the
    /// transit-leg boarding/alighting UI which compares against scheduled
    /// times — those have to stay anchored to OTP's clock, not ours.
    var rawEndDate: Date { Date(timeIntervalSince1970: TimeInterval(endTime) / 1000) }

    /// End time used for "arriving 4:30 PM" labels. Now identical to
    /// `rawEndDate` — we used to inflate by the climb penalty so the
    /// arrival matched the inflated duration, but the duration is now
    /// shown raw, so the arrival is shown raw too. Keep this property
    /// (rather than collapsing call sites onto `rawEndDate`) so the
    /// distinction stays visible if we ever bring slope-adjusted ETAs
    /// back behind a setting.
    var endDate: Date {
        effectiveTimeline().last?.endDate
            ?? startDate.addingTimeInterval(TimeInterval(effectiveDurationSeconds))
    }

    /// "3:45 PM → 4:30 PM"
    var timeRange: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "\(f.string(from: startDate)) → \(f.string(from: endDate))"
    }

    /// Per-leg start/end timestamps reconciled into a single
    /// timeline. Resolves the inconsistency where the trip detail
    /// page used to mix three different time sources — OTP-raw
    /// scheduled times for leg ranges, client-stamped durations for
    /// duration labels, and realtime-adjusted times for transit
    /// board/alight blocks — which made the numbers contradict each
    /// other (bike "8 min" labeled across a "6:41 PM → 6:53 PM" 12-
    /// minute span, transit alight at 7:07 PM followed by the next
    /// bike leg starting at 7:01 PM, etc.).
    ///
    /// Single forward pass:
    /// - Transit legs anchor to `leg.effectiveStartDate` /
    ///   `effectiveEndDate` — realtime-delay-adjusted scheduled times.
    ///   Buses don't wait for the rider, so they hold their schedule.
    /// - Walk/bike legs start at the previous leg's end (or `anchor`
    ///   for the first leg) and run for `leg.displayDurationSeconds`
    ///   (pace + climb stamped). The user can't bend transit times,
    ///   but their own legs honor the user's actual pace.
    /// - `waitBefore` is the gap between the previous leg's end and
    ///   this leg's start. Positive = wait at the stop. **Negative**
    ///   = bike pace would have the user arrive *after* the bus
    ///   departs (a "missed connection") — UI surfaces this as a
    ///   warning row so it's honest rather than silently lying.
    ///
    /// `anchor`:
    /// - **nil** (Preview / browsing): the FIRST walk/bike leg is
    ///   *back-anchored* from the next transit's scheduled
    ///   departure — i.e., its end = next-transit.start, its start
    ///   = that minus the leg's stamped duration. Gives the rider a
    ///   "leave by X to catch the bus on time" reading instead of
    ///   "arrive at the stop and wait 10 min." Mid-trip walk/bike
    ///   legs (between two transits, or after the last transit)
    ///   forward-chain from the previous leg's end so any waits
    ///   surface at the next transit boarding — that's where the
    ///   user is actually standing around in real life.
    /// - **Date()** (live nav): every leg forward-chains from the
    ///   anchor, because the user has already started moving — we
    ///   can't time-travel them back to leave later.
    ///
    /// Either way: transit legs hold their realtime-adjusted
    /// schedule (`effectiveStartDate / effectiveEndDate`). Buses
    /// don't wait for the rider.
    func effectiveTimeline(anchor: Date? = nil) -> [LegTimeline] {
        let n = legs.count
        guard n > 0 else { return [] }

        var starts = Array<Date?>(repeating: nil, count: n)
        var ends   = Array<Date?>(repeating: nil, count: n)

        // 1. Anchor every transit leg to its realtime schedule.
        for i in 0..<n where legs[i].isTransit {
            starts[i] = legs[i].effectiveStartDate
            ends[i]   = legs[i].effectiveEndDate
        }

        // 2. Walk/bike legs.
        for i in 0..<n {
            if starts[i] != nil { continue }

            // First leg, Preview mode (no anchor): back-anchor from
            // the next transit so the trip starts as late as
            // possible while still catching the bus, **minus a small
            // buffer** so the user arrives a couple minutes early
            // rather than sprinting to catch a bus that's pulling
            // up. The buffer falls in the "wait at the stop" window
            // and matches typical recommended arrival timing for
            // local transit. Cascades backward through any preceding
            // walk/bike legs in the same access chunk.
            let busBoardingBuffer: TimeInterval = 120
            if i == 0, anchor == nil {
                let nextTransit = (1..<n).first { legs[$0].isTransit }
                if let t = nextTransit, let transitStart = starts[t] {
                    var endAt = transitStart.addingTimeInterval(-busBoardingBuffer)
                    for k in stride(from: t - 1, through: 0, by: -1) {
                        ends[k] = endAt
                        let dur = TimeInterval(legs[k].displayDurationSeconds)
                        starts[k] = endAt.addingTimeInterval(-dur)
                        endAt = starts[k]!
                    }
                    continue
                }
            }

            // All other walk/bike legs: forward-chain from previous
            // leg's end, then `anchor`, then the leg's own raw
            // start time (last-resort fallback).
            let s = (i > 0 ? ends[i - 1] : nil) ?? anchor ?? legs[i].startDate
            starts[i] = s
            ends[i]   = s.addingTimeInterval(TimeInterval(legs[i].displayDurationSeconds))
        }

        // 3. Build the result + compute waitBefore from finalized
        //    starts/ends.
        var out: [LegTimeline] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let s = starts[i] ?? Date()
            let e = ends[i]   ?? s
            let waitBefore: TimeInterval
            if i > 0, let prevEnd = ends[i - 1] {
                waitBefore = s.timeIntervalSince(prevEnd)
            } else {
                waitBefore = 0
            }
            out.append(LegTimeline(
                index: i,
                startDate: s,
                endDate: e,
                waitBefore: waitBefore
            ))
        }
        return out
    }
}

/// One leg's place on the reconciled `Itinerary.effectiveTimeline`.
/// See the docs there for how each field is derived.
struct LegTimeline {
    /// Position in the itinerary's `legs` array — handy for
    /// zipping the timeline back with legs at render time.
    let index: Int
    let startDate: Date
    let endDate: Date
    /// Gap from the previous leg's end to this leg's start.
    /// - `> 60`: surface as a "wait X min" row before the leg
    ///   (typically before a transit boarding).
    /// - `~0`: continuous; no gap to show.
    /// - `< 0`: **missed connection** — the previous walk/bike leg
    ///   would, at the user's stamped pace, end after this transit
    ///   leg has already departed. UI should flag.
    let waitBefore: TimeInterval

    var missedConnection: Bool { waitBefore < 0 }

    /// Wall-clock duration (`endDate - startDate`) in seconds.
    /// Use this for the per-leg "X min" label so duration label
    /// and time-range label always agree.
    var durationSeconds: Int { Int(endDate.timeIntervalSince(startDate)) }
    var durationMinutes: Int { max(0, durationSeconds / 60) }
}

extension Leg {
    var isTransit: Bool {
        !["WALK", "BICYCLE", "BICYCLE_RENT"].contains(mode)
    }

    var displayName: String {
        if let r = route?.shortName ?? route?.longName, !r.isEmpty {
            return headsign.map { "\(r) → \($0)" } ?? r
        }
        return mode.capitalized
    }

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startTime) / 1000) }
    var endDate:   Date { Date(timeIntervalSince1970: TimeInterval(endTime)   / 1000) }

    /// Realtime-adjusted boarding time. For transit legs with a
    /// populated `departureDelay` (seconds, from the proxy's
    /// 30 s realtime refresh loop), this is `startDate` shifted by
    /// the delay — so a bus that becomes 5 min late shows that
    /// 5 min later. For walk/bike legs and transit legs without a
    /// realtime delay populated, this equals `startDate`.
    var effectiveStartDate: Date {
        let delaySec = TimeInterval(departureDelay ?? 0)
        return Date(timeIntervalSince1970: TimeInterval(startTime) / 1000 + delaySec)
    }

    /// Realtime-adjusted alight / arrival time. Same shape as
    /// `effectiveStartDate`, using `arrivalDelay` and `endTime`. Used by
    /// the live-nav bottom card so the "X min remaining" countdown on
    /// the bus stays honest as delays accumulate mid-ride.
    var effectiveEndDate: Date {
        let delaySec = TimeInterval(arrivalDelay ?? 0)
        return Date(timeIntervalSince1970: TimeInterval(endTime) / 1000 + delaySec)
    }

    /// "4:54 PM" — hour+minute only.
    var startTimeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: startDate)
    }

    /// Hour+minute formatted `effectiveStartDate` (boarding time with
    /// realtime delay folded in). Same format as `startTimeString` so
    /// the swap is visually drop-in at display sites.
    var effectiveStartTimeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: effectiveStartDate)
    }

    /// Hour+minute formatted `effectiveEndDate` (alighting time with
    /// realtime delay folded in).
    var effectiveEndTimeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: effectiveEndDate)
    }

    /// Boarding line for a transit leg, e.g.
    /// "4:54 PM from Denny Way & Queen Anne Ave N".
    /// Returns nil for walk/bike legs.
    var boardingLine: String? {
        guard isTransit else { return nil }
        return "\(startTimeString) from \(from.name)"
    }

    /// Secondary line for a walk/bike leg, formatted to match the transit
    /// boarding line: "4:22 PM · 8 min · 1.3 mi". Returns nil for transit.
    var activityLine: String? {
        guard !isTransit else { return nil }
        var parts: [String] = [startTimeString, "\(durationMinutes) min"]
        if let d = distanceString { parts.append(d) }
        return parts.joined(separator: " · ")
    }

    /// "h:mm a" formatted arrival time for this leg.
    var endTimeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: endDate)
    }

    /// Whole-second duration we display for this leg. For bike legs this
    /// is the client-computed estimate (distance / pace + climb * 3.9
    /// s/m) when it has been stamped on, otherwise OTP's raw timestamps.
    /// For walk/transit it's always OTP's raw timestamps — walk speed
    /// is fixed and transit time is schedule-driven.
    var displayDurationSeconds: Int {
        if let est = estimatedDurationSeconds { return est }
        return max(0, Int((endTime - startTime) / 1000))
    }

    /// Integer-minute duration of this leg, derived from
    /// `displayDurationSeconds` so chips and totals stay consistent.
    var durationMinutes: Int {
        max(1, displayDurationSeconds / 60)
    }

    /// Short distance string, e.g. "0.3 mi" or "1.2 mi". Hidden for < 50 m.
    var distanceString: String? {
        let miles = distance / 1609.34
        if miles < 0.03 { return nil }
        return miles < 0.1
            ? String(format: "%.2f mi", miles)
            : String(format: "%.1f mi", miles)
    }

    /// Rolled-up realtime status for this leg.
    var realtimeStatus: RealTimeStatus {
        guard isTransit else { return .unknown }
        if realtimeState == "CANCELED" { return .canceled }

        // Prefer the larger-magnitude of arrival vs departure delay so the
        // user sees whichever is more impactful.
        let candidates: [Int] = [arrivalDelay, departureDelay].compactMap { $0 }
        let delaySec: Int? = candidates.max(by: { abs($0) < abs($1) })

        guard realTime == true || realtimeState == "UPDATED" else {
            return .scheduled
        }
        let secs = delaySec ?? 0
        if abs(secs) < 60 { return .onTime }
        let mins = Int((Double(abs(secs)) / 60.0).rounded())
        return secs > 0 ? .late(mins) : .early(mins)
    }
}
