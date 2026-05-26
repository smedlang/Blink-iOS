import SwiftUI
import CoreLocation

// MARK: - Trip planning pipeline
//
// This file holds the "kick off the OTP queries, merge results, stamp client
// durations, dedupe by stop sequence" flow. It's an extension on ContentView
// rather than a free service object because it reads/writes a fair amount of
// view state (fromCoord, toCoord, isLoading, errorMessage, modeItineraries,
// when, preference, bikePace) and untangling all of that into a separate
// observable would be a much bigger change. The split here is purely about
// keeping ContentView.swift readable; the static helpers below have no view-
// state dependencies and could be lifted into a dedicated TripPlanner type
// later if the file gets large enough to warrant it.

extension ContentView {

    // MARK: - Filtering helpers

    /// Drop pure-walk / pure-bike alternatives for transit-involving modes,
    /// keeping input order. OTP sometimes returns a walk-only itinerary in
    /// the transit-only response (fallback when no transit works); we hide
    /// those unless they're the only option available.
    ///
    /// Input order is preserved on purpose — for bike-involving modes the
    /// caller has already re-ranked by (duration + climb penalty), so we
    /// don't want to stomp that with a duration-only re-sort here.
    static func filterForMode(_ its: [Itinerary], mode: TripMode) -> [Itinerary] {
        guard mode == .bikeTransit || mode == .transitOnly else {
            return its
        }
        let withTransit = its.filter { it in
            it.legs.contains(where: { $0.isTransit })
        }
        return withTransit.isEmpty ? its : withTransit
    }

    /// Order itineraries by the user's "best" criterion given the
    /// active time target:
    ///
    /// - `.leaveNow` / `.leaveAt` → earliest arrival first ("get
    ///   there soonest"). The user picked a depart time, so the most
    ///   useful ranking is which option lands them at the destination
    ///   first.
    /// - `.arriveBy` → latest arrival first (i.e., closest to the
    ///   deadline). The user has a fixed arrival target; the option
    ///   that arrives nearest the deadline minimizes waiting around
    ///   at the destination. Past-start filtering (`filterPastStarts`)
    ///   runs *after* this sort and drops anything the user can no
    ///   longer catch, so the resulting top option is the catchable
    ///   one with the latest arrival.
    ///
    /// Uses `Itinerary.endDate` (defined as
    /// `startDate + effectiveDurationSeconds`), which folds in our
    /// client-side pace + climb stamping — sorting by realistic
    /// arrival rather than OTP's optimistic duration.
    static func sortByArrival(_ its: [Itinerary], when: TimeTarget) -> [Itinerary] {
        switch when {
        case .arriveBy:
            return its.sorted { $0.endDate > $1.endDate }
        case .leaveNow, .leaveAt:
            return its.sorted { $0.endDate < $1.endDate }
        }
    }

    /// Take the top 2 from an already-arrival-sorted list, plus the
    /// single fastest-by-duration item if it isn't already one of
    /// those two. Returns up to 3 itineraries.
    ///
    /// The point: the user usually wants "what's the next thing I can
    /// catch" (top 2 by arrival), but sometimes total trip time matters
    /// more — a trip that departs 30 min from now but takes 40 min beats
    /// one that departs now and takes 90 min. Surfacing both criteria
    /// in the same short list lets the user pick between the two
    /// trade-offs without scrolling through alternatives.
    ///
    /// Expects the input to already be sorted by arrival time (per
    /// `sortByArrival`). The first two elements of the result are the
    /// soonest pair; the optional third is the fastest from the whole
    /// pool, included only when it's distinct from the first two
    /// (since otherwise it'd duplicate). For arrive-by queries the
    /// input is sorted descending by arrival, so "top 2 soonest" means
    /// "top 2 closest to deadline" — still the right interpretation
    /// of "best two arrival times."
    static func pickSoonestAndFastest(_ its: [Itinerary]) -> [Itinerary] {
        var result = Array(its.prefix(2))
        guard let fastest = its.min(by: {
            $0.effectiveDurationSeconds < $1.effectiveDurationSeconds
        }) else {
            return result
        }
        if !result.contains(where: { $0.id == fastest.id }) {
            result.append(fastest)
        }
        return result
    }

    /// Drop itineraries the user can no longer realistically start. OTP
    /// happily returns options whose `startTime` is in the past — typical when
    /// the user is asking "arrive by 5pm" but it's already 4:55 and the only
    /// way to make it would have been to leave 10 minutes ago. Showing those
    /// is worse than showing nothing: tapping one and looking at the timeline
    /// is just confusing.
    ///
    /// We use a 60-second grace so a query that returns "leave at 4:59:30"
    /// when it's currently 4:59:45 still shows up — those are still
    /// catchable in practice, and the alternative (filtering them) is more
    /// annoying than tolerating a couple seconds of drift.
    static func filterPastStarts(_ its: [Itinerary]) -> [Itinerary] {
        let cutoff = Date().addingTimeInterval(-60)
        return its.filter { $0.startDate >= cutoff }
    }

    /// Collapse itineraries that use the same boarding stations into a
    /// single row, *merging* alternate route options into the canonical
    /// itinerary rather than dropping them. If three itineraries all
    /// start by walking to Westlake Station — one on the 1-Line, one on
    /// the 2-Line, one on the E Line — they all show up as one row
    /// "walk to Westlake, take 1 Line / 2 Line / E Line," with each
    /// transit leg's `alternativeRoutes` array carrying the non-primary
    /// route names. The user picks whichever comes first when they get
    /// to the platform.
    ///
    /// Canonical pick: earliest-departing variant. That's the trip the
    /// user would actually catch given they're standing at the stop;
    /// later variants surface as "or X:XX" hints in the detail view.
    ///
    /// Trips that board at a genuinely different station stay as
    /// separate options. Walk/bike-only trips (no transit legs) never
    /// merge against each other.
    static func dedupeByTransitStops(_ its: [Itinerary]) -> [Itinerary] {
        // Group itineraries by their boarding-stop key. Preserve first-
        // seen order across keys so the merged output keeps the same
        // top-down ordering as input (the input is already sorted by
        // effectiveDurationSeconds at this point).
        var orderedKeys: [String] = []
        var bucketsByKey: [String: [Itinerary]] = [:]
        for (i, it) in its.enumerated() {
            let stops = it.legs
                .filter { $0.isTransit }
                .map { normalizeStop($0.from.name) }
            let key = stops.isEmpty ? "none-\(i)" : stops.joined(separator: "|")
            if bucketsByKey[key] == nil {
                bucketsByKey[key] = []
                orderedKeys.append(key)
            }
            bucketsByKey[key]?.append(it)
        }

        // For each bucket: pick the earliest-departing itinerary as
        // canonical, then fold the others' transit-leg route info into
        // the canonical's matching legs as `alternativeRoutes`.
        var result: [Itinerary] = []
        for key in orderedKeys {
            guard let bucket = bucketsByKey[key], !bucket.isEmpty else { continue }
            if bucket.count == 1 {
                result.append(bucket[0])
                continue
            }
            // Sort by departure time ascending; canonical = earliest.
            let sorted = bucket.sorted { $0.startTime < $1.startTime }
            var canonical = sorted[0]
            for sibling in sorted.dropFirst() {
                canonical = mergeTransitAlternatives(into: canonical, from: sibling)
            }
            result.append(canonical)
        }
        return result
    }

    /// Walk both itineraries' legs in parallel; for each pair where
    /// the canonical leg is transit and the sibling leg is also
    /// transit with a different route (by gtfsId / shortName), append
    /// the sibling's route info to `canonical.legs[i].alternativeRoutes`
    /// and its startTime to `alternativeStartTimes`. Walk/bike legs and
    /// transit legs with identical routes are left alone — the
    /// canonical version already represents the rider's experience for
    /// those.
    ///
    /// Defensive: if the leg counts don't match, only zip up to the
    /// shorter list. In practice itineraries grouped under the same
    /// boarding-stop key have the same leg structure (same walk-bike-
    /// transit-walk shape), so a length mismatch would be surprising
    /// but shouldn't crash.
    private static func mergeTransitAlternatives(
        into canonical: Itinerary,
        from sibling: Itinerary
    ) -> Itinerary {
        var merged = canonical
        let pairCount = min(canonical.legs.count, sibling.legs.count)
        for i in 0..<pairCount {
            let canLeg = canonical.legs[i]
            let sibLeg = sibling.legs[i]
            guard canLeg.isTransit, sibLeg.isTransit else { continue }
            // Skip if both legs are on literally the same route — the
            // canonical already covers it.
            if routesEqual(canLeg.route, sibLeg.route) { continue }
            // Skip if the sibling's route is already in the alternatives
            // list (defensive — three+ siblings on the same stop key
            // could otherwise duplicate).
            if let sibRoute = sibLeg.route,
               merged.legs[i].alternativeRoutes.contains(where: { routesEqual($0, sibRoute) }) {
                continue
            }
            if let sibRoute = sibLeg.route {
                merged.legs[i].alternativeRoutes.append(sibRoute)
                merged.legs[i].alternativeStartTimes.append(sibLeg.startTime)
            }
        }
        return merged
    }

    /// Two RouteInfos count as the same route if their shortName or
    /// longName matches. shortName preferred since it's the rider-
    /// facing identifier ("1 Line", "545"); fall back to longName when
    /// shortName is absent (some WSF ferry routes). Both-nil counts as
    /// equal so we don't dedupe walk-only legs into transit alternatives.
    private static func routesEqual(_ a: RouteInfo?, _ b: RouteInfo?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a = a, let b = b else { return false }
        if let sa = a.shortName, let sb = b.shortName, !sa.isEmpty, !sb.isEmpty {
            return sa == sb
        }
        return a.longName == b.longName
    }

    /// Stop names from GTFS can vary ("Westlake Station", "Westlake Sta",
    /// "Westlake Sta - Bay 1"). Normalize to improve dedup accuracy.
    static func normalizeStop(_ name: String) -> String {
        let lowered = name.lowercased()
        // Drop bay/platform suffixes so "Westlake Sta - Bay 1" and
        // "Westlake Sta - Bay 3" collapse to the same station.
        let trimmed = lowered
            .replacingOccurrences(of: #"\s*-\s*bay\s*\d+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*platform\s*\d+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "station", with: "sta")
            .trimmingCharacters(in: .whitespaces)
        return trimmed
    }

    // MARK: - Plan trip

    /// Plan trips for all three modes in parallel and cache each result in
    /// `modeItineraries`. The visible list (`itineraries`) is derived from
    /// whichever mode is currently active — switching pills in `modeBar` just
    /// re-reads the cache instead of re-hitting the network.
    func planTrip() {
        guard fromCoord != nil, toCoord != nil else { return }
        isLoading = true
        errorMessage = nil

        // Snapshot the current plan inputs so late-returning parallel queries
        // can be ignored if the user has already changed destination or time.
        let startedWhen = when
        let startedPref = preference
        let startedPace = bikePace
        let startedKind = bikeKind

        Task {
            // Refresh the "Your location" coord with a live fix before
            // planning. CoreLocation responds in ~1 s; the wait is
            // imperceptible next to the multi-second OTP roundtrip, and
            // it stops us from planning from a stale launch-time coord
            // after the user has biked a few blocks.
            if fromQuery == "Your location" {
                if let fresh = await location.freshOneShot() {
                    fromCoord = fresh.coordinate
                }
            }
            guard let startedFrom = fromCoord, let startedTo = toCoord else {
                isLoading = false
                return
            }
            // Bike+transit fires three flavors in parallel, varying the bike
            // reluctance OTP applies on top of the user's preference. OTP's
            // generalized cost (bike_seconds × bikeReluctance + wait + ride)
            // makes the boarding-stop choice highly sensitive to that one
            // weight: at the default reluctance OTP often picks a closer
            // stop with a longer/slower ride, even when biking a few extra
            // blocks to a different stop would catch a faster bus. Firing
            // .bikeMore (0.5×) / .balanced (1.0×) / .bikeLess (1.5×) gives
            // OTP three different cost frontiers to optimize against, and
            // we merge the results so the user sees the alternative
            // boarding-stop trips alongside the default one.
            // Snapshot the Lime toggle so a flip mid-query doesn't have
            // the bike pills firing a mix of own-bike and Lime calls.
            // When `useLime` is on, every BICYCLE entry in OTP's
            // transportModes argument gets `qualifier: RENT` — making
            // bike-only into Lime-only and bike+transit into Lime+transit
            // (see `RoutingClient.plan`).
            let startedUseLime = self.useLime
            async let btMoreBike = Self.safePlan(
                from: startedFrom, to: startedTo,
                mode: .bikeTransit, when: startedWhen, preference: startedPref,
                bikePace: startedPace, bikeKind: startedKind, bikeTransitFlavor: .bikeMore,
                useLime: startedUseLime
            )
            async let btBalanced = Self.safePlan(
                from: startedFrom, to: startedTo,
                mode: .bikeTransit, when: startedWhen, preference: startedPref,
                bikePace: startedPace, bikeKind: startedKind, bikeTransitFlavor: .balanced,
                useLime: startedUseLime
            )
            async let btLessBike = Self.safePlan(
                from: startedFrom, to: startedTo,
                mode: .bikeTransit, when: startedWhen, preference: startedPref,
                bikePace: startedPace, bikeKind: startedKind, bikeTransitFlavor: .bikeLess,
                useLime: startedUseLime
            )
            // Bike-only fires three flavors in parallel — faster (time-
            // priority), less-effort (slope-priority), safer (safety-
            // priority). The user doesn't pick a flavor; we merge afterwards
            // and dedupe routes that converge to the same path, so on
            // single-corridor trips you see one option and on trips with
            // multiple viable bike paths you see all of them.
            async let boFaster = Self.safePlan(
                from: startedFrom, to: startedTo,
                mode: .bikeOnly, when: startedWhen, preference: startedPref,
                bikePreference: .faster, bikePace: startedPace, bikeKind: startedKind,
                useLime: startedUseLime
            )
            async let boFlat = Self.safePlan(
                from: startedFrom, to: startedTo,
                mode: .bikeOnly, when: startedWhen, preference: startedPref,
                bikePreference: .lessEffort, bikePace: startedPace, bikeKind: startedKind,
                useLime: startedUseLime
            )
            async let boSafer = Self.safePlan(
                from: startedFrom, to: startedTo,
                mode: .bikeOnly, when: startedWhen, preference: startedPref,
                bikePreference: .safer, bikePace: startedPace, bikeKind: startedKind,
                useLime: startedUseLime
            )
            async let to = Self.safePlan(
                from: startedFrom, to: startedTo,
                mode: .transitOnly, when: startedWhen, preference: startedPref,
                bikePace: startedPace, bikeKind: startedKind
            )

            let (btMoreRes, btBalRes, btLessRes, fastRes, flatRes, saferRes, toRes) =
                await (btMoreBike, btBalanced, btLessBike, boFaster, boFlat, boSafer, to)

            // Merge the three bike+transit flavor sets. See `mergeBikeTransit`
            // for the dedup rules — it keeps one entry per unique boarding-
            // stop sequence, with `.balanced` winning ties so the badge only
            // appears on routes that the default flavor wouldn't have shown.
            let btMerged = Self.mergeBikeTransit(flavorSets: [
                (.balanced, btBalRes  ?? []),
                (.bikeMore, btMoreRes ?? []),
                (.bikeLess, btLessRes ?? []),
            ])
            // Match the bikeOnly convention: pass nil when nothing came back
            // so the mode pill shows "—" instead of an empty list.
            let btRes: [Itinerary]? = btMerged.isEmpty ? nil : btMerged

            // Merge the three bike-only candidate sets. See `mergeBikeOnly`
            // for the dedup rules — it removes routes that converge to the
            // same path across flavors but keeps everything else, so the
            // user sees as many distinct alternatives as actually exist.
            let boRes = await Self.mergeBikeOnly(flavorSets: [
                (.faster,     fastRes  ?? []),
                (.lessEffort, flatRes  ?? []),
                (.safer,      saferRes ?? []),
            ])

            // Stamp client-computed bike durations onto every bike leg in
            // each mode, using the user's pace + per-leg climb. After this
            // step, `Itinerary.effectiveDurationSeconds` (and everything
            // derived from it — chips, totals, pill, ETA) reflects pace
            // and slope rather than OTP's flat-speed estimate. The
            // helper also stamps total `climbMeters` on each itinerary
            // for downstream ranking.
            async let btRanked: [Itinerary]? = {
                guard let r = btRes else { return nil }
                let stamped = await ElevationService.stampClientBikeDurations(r, pace: startedPace, kind: startedKind)
                // Drop itineraries that would have the rider arrive at
                // the Ballard Locks bike/pedestrian crossing while the
                // gates are closed (outside 7 AM – 9 PM). The walk-the-
                // bike time penalty is already folded into stamping for
                // routes that DO use the crossing within open hours.
                let openOnly = stamped.filter { !BallardLocks.shouldDropForClosedCrossing($0) }
                // Order by realistic arrival time: soonest first for
                // leave-now / depart-at, closest-to-deadline first for
                // arrive-by. Uses post-stamping endDate so the ranking
                // matches what the UI shows.
                return Self.sortByArrival(openOnly, when: startedWhen)
            }()
            // Bike-only ordering: lane fraction wins only when the
            // difference is meaningful (≥15 percentage points). Within
            // 15 points, the routes are functionally equivalent on
            // safety/comfort and we fall through to dark-aware
            // duration — which factors in litFraction at night and
            // raw duration during the day.
            //
            // Earlier this used hard buckets at 25/50/75% which
            // produced a "bucket cliff" — a 52%-lane route ranked
            // above a 48%-lane one despite being functionally
            // identical, often pushing a meaningfully faster (and
            // sometimes better-lit) alternative into second place.
            // Threshold-based comparison eliminates the cliff while
            // still preferring genuinely-better-laned routes.
            async let boRanked: [Itinerary]? = {
                if boRes.isEmpty { return nil }
                let stamped = await ElevationService.stampClientBikeDurations(boRes, pace: startedPace, kind: startedKind)
                let openOnly = stamped.filter { !BallardLocks.shouldDropForClosedCrossing($0) }
                return openOnly.sorted { a, b in
                    let aLane = bikeLaneFraction(a)
                    let bLane = bikeLaneFraction(b)
                    // Meaningful lane gap → higher-lane route wins.
                    if abs(aLane - bLane) > 0.15 {
                        return aLane > bLane
                    }
                    // Lane coverage is similar enough → fall through
                    // to dark-aware time (lit-discounted at night).
                    return darkAwareSortSeconds(a) < darkAwareSortSeconds(b)
                }
            }()
            let (btFinal, boFinal) = await (btRanked, boRanked)

            // Only apply results if the inputs haven't changed underneath us.
            await MainActor.run {
                guard
                    self.fromCoord?.latitude == startedFrom.latitude,
                    self.fromCoord?.longitude == startedFrom.longitude,
                    self.toCoord?.latitude == startedTo.latitude,
                    self.toCoord?.longitude == startedTo.longitude
                else { return }

                var dict: [TripMode: [Itinerary]] = [:]
                if let r = btFinal { dict[.bikeTransit] = Self.dedupeByTransitStops(Self.filterForMode(r, mode: .bikeTransit)) }
                if let r = boFinal { dict[.bikeOnly]    = Self.dedupeByTransitStops(Self.filterForMode(r, mode: .bikeOnly)) }
                // Transit-only has no bike legs, so no elevation re-rank is
                // needed — sort purely by duration. effectiveDuration falls
                // back to OTP duration when climbMeters is nil, so this is
                // equivalent to sorting on `.duration` here, just expressed
                // through the same accessor everything else uses.
                if let r = toRes {
                    // Transit-only: same arrival-time ordering as
                    // bike+transit — soonest arrival for depart-at /
                    // leave-now, closest-to-deadline for arrive-by.
                    // `effectiveDurationSeconds` collapses to OTP's raw
                    // duration on transit-only legs (no bike stamping),
                    // so `endDate` is equivalent to OTP's reported
                    // arrival time here.
                    let sorted = Self.sortByArrival(r, when: startedWhen)
                    dict[.transitOnly] = Self.dedupeByTransitStops(Self.filterForMode(sorted, mode: .transitOnly))
                }

                // For arrive-by queries, OTP returns options whose start time
                // is in the past — i.e., trips the user can no longer board.
                // Drop those before they confuse the list. Keep track of
                // whether we filtered anything out so we can hint at the user
                // when *all* options were unreachable.
                var anyUnreachable = false
                if case .arriveBy = startedWhen {
                    for m in Array(dict.keys) {
                        guard let list = dict[m] else { continue }
                        let filtered = Self.filterPastStarts(list)
                        if filtered.count != list.count { anyUnreachable = true }
                        if filtered.isEmpty {
                            // Drop modes that now have nothing left so the
                            // mode pills accurately show "—" instead of a
                            // blank pill.
                            dict.removeValue(forKey: m)
                        } else {
                            dict[m] = filtered
                        }
                    }
                }

                // Cap each mode's list. Mode-specific logic:
                //
                // - Bike+transit and transit-only: 2 soonest by arrival
                //   + the fastest by duration if distinct (see
                //   `pickSoonestAndFastest`). Up to 3 items. Surfaces
                //   the two axes the user actually cares about ("catch
                //   the next one" and "shortest total trip") instead
                //   of just the top 3 by one criterion.
                // - Bike-only: keep the first 3 from the mode's own
                //   ranking (lane coverage + dark-aware time). The
                //   user's bike-route decision isn't usually
                //   arrival-time-driven, so the soonest-plus-fastest
                //   mix doesn't apply.
                //
                // Runs after `filterPastStarts` so a "fastest" pick
                // never references an already-departed trip.
                for m in Array(dict.keys) {
                    guard let list = dict[m] else { continue }
                    switch m {
                    case .bikeTransit, .transitOnly:
                        dict[m] = Self.pickSoonestAndFastest(list)
                    default:
                        if list.count > 3 {
                            dict[m] = Array(list.prefix(3))
                        }
                    }
                }

                self.modeItineraries = dict
                self.updateCurrentItineraries()

                if dict.isEmpty {
                    if anyUnreachable {
                        self.errorMessage = "Too late to make this arrival time. Try a later arrival or earlier departure."
                    } else {
                        self.errorMessage = "No routes found."
                    }
                }
                self.isLoading = false
            }
        }
    }

    /// Non-throwing wrapper around `RoutingClient.plan` so `async let` can run
    /// all three mode queries without `try await`. Returns `nil` when the
    /// query errors out — that mode's pill will show "—" instead.
    /// `bikePreference` is only consulted for bike-only mode.
    static func safePlan(
        from f: CLLocationCoordinate2D,
        to t: CLLocationCoordinate2D,
        mode: TripMode,
        when: TimeTarget,
        preference: RoutePreference,
        bikePreference: BikePreference = .faster,
        bikePace: BikePace = .moderate,
        bikeKind: BikeKind = .standard,
        bikeTransitFlavor: BikeTransitFlavor? = nil,
        useLime: Bool = false
    ) async -> [Itinerary]? {
        do {
            return try await RoutingClient.plan(
                from: f, to: t, mode: mode, when: when,
                preference: preference, bikePreference: bikePreference,
                bikePace: bikePace, bikeKind: bikeKind,
                bikeTransitFlavor: bikeTransitFlavor,
                useLime: useLime
            )
        } catch {
            // Surface the actual failure in DEBUG so a query change that
            // breaks parsing (or a backend that's down) doesn't silently
            // collapse to "No routes found." Production swallows it as
            // before — the user still sees the empty-result message.
            #if DEBUG
            print("[safePlan] \(mode) \(bikeTransitFlavor.map(String.init(describing:)) ?? "-") failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Merge logic

    /// Merge the bike-only candidate sets that came back from each
    /// `BikePreference` query (`.faster`, `.lessEffort`, `.safer`). The
    /// goal is to surface every meaningfully distinct alternative without
    /// rendering near-duplicates that just differ in OTP cost-rounding.
    ///
    /// Two itineraries are treated as the same route — and the second one
    /// dropped — when their duration, total bike-leg climb, AND total bike
    /// distance all match within tolerance. That triple has to converge for
    /// a true duplicate; if any one of them differs meaningfully (a flatter
    /// detour, a longer protected-lane corridor, a faster direct shot)
    /// both routes survive and the user sees them as separate options.
    ///
    /// Iteration order is the order of the `flavorSets` argument, which is
    /// also the priority for keeping the flavor tag: a route that appears
    /// first under `.faster` keeps its `.faster` tag (no badge), while a
    /// route that only shows up under `.lessEffort` or `.safer` keeps that
    /// tag and gets the corresponding badge in the UI.
    ///
    /// Climb is fetched via `ElevationService.profile`, which memoizes per
    /// encoded polyline — second-time-around merges of the same trip are
    /// essentially free.
    static func mergeBikeOnly(
        flavorSets: [(BikePreference, [Itinerary])]
    ) async -> [Itinerary] {
        let all = flavorSets.flatMap { $0.1 }
        if all.isEmpty { return [] }

        // Dedup tolerances. Tight enough that genuinely distinct corridors
        // (different streets, even similar ride length) both survive;
        // loose enough that the same corridor priced two ways under
        // different triangles collapses to one row.
        let durTolSec = 60                     // ±1 minute
        let climbTolMeters: Double = 10        // ±33 ft
        let distTolMiles: Double = 0.1         // ±~160 m

        // Compute total bike-leg climb for every candidate, in parallel.
        // Pass the Leg (not just polyline) so ElevationService.profile(for:)
        // can use OTP's per-leg elevationProfile when present, only
        // falling back to Open-Meteo for legs that exit DEM coverage.
        var climbById: [String: Double] = [:]
        await withTaskGroup(of: (String, Double).self) { group in
            for it in all {
                group.addTask {
                    var c: Double = 0
                    for leg in it.legs where leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT" {
                        if let p = try? await ElevationService.profile(for: leg) {
                            c += p.climbMeters
                        }
                    }
                    return (it.id, c)
                }
            }
            for await (id, c) in group { climbById[id] = c }
        }

        var unique: [Itinerary] = []
        for (_, set) in flavorSets {
            for it in set {
                let c = climbById[it.id] ?? 0
                let isDup = unique.contains { other in
                    let oc = climbById[other.id] ?? 0
                    return abs(other.duration - it.duration) <= durTolSec
                        && abs(oc - c) <= climbTolMeters
                        && abs(other.bikeMiles - it.bikeMiles) <= distTolMiles
                }
                if !isDup {
                    // Stamp the measured climb onto the itinerary so the
                    // elevation-adjusted duration (Itinerary.effectiveDuration
                    // Seconds) reflects this trip's hills everywhere it's
                    // displayed — list rows, mode pills, detail header, the
                    // navigation arrival countdown.
                    var copy = it
                    copy.climbMeters = c
                    unique.append(copy)
                }
            }
        }

        // Drop near-mileage substitutes that lose on bike-lane coverage.
        // If two routes come within 5% of each other on total bike-miles
        // they're effectively the same trip from the rider's perspective
        // — one is just routed onto worse streets. Surfacing both wastes
        // a row in the list. We compare every pair so the result doesn't
        // depend on iteration order, and we require a real (≥5 pp) lane
        // fraction gap to drop a route, otherwise small step-name noise
        // could discard a legitimate alternative. Within a tied lane
        // fraction (within epsilon), neither is dropped — let the sort
        // below handle the order.
        let mileageRatioTol: Double = 0.05   // ≤ 5% total bike-mile delta
        let laneFracEpsilon: Double = 0.05   // ≥ 5 pp lane% advantage
        let laneFracById: [String: Double] = Dictionary(
            uniqueKeysWithValues: unique.map { ($0.id, bikeLaneFraction($0)) }
        )
        var dropIds = Set<String>()
        for i in unique.indices {
            if dropIds.contains(unique[i].id) { continue }
            for j in unique.indices where i != j {
                if dropIds.contains(unique[j].id) { continue }
                let mi = unique[i].bikeMiles
                let mj = unique[j].bikeMiles
                let denom = max(mi, mj)
                guard denom > 0 else { continue }
                let mileageRatio = abs(mi - mj) / denom
                if mileageRatio > mileageRatioTol { continue }
                let li = laneFracById[unique[i].id] ?? 0
                let lj = laneFracById[unique[j].id] ?? 0
                if lj - li > laneFracEpsilon {
                    dropIds.insert(unique[i].id)
                    break
                }
            }
        }
        if !dropIds.isEmpty {
            unique.removeAll { dropIds.contains($0.id) }
            #if DEBUG
            print("[bikeOnly] dropped \(dropIds.count) near-mileage / lower-lane% candidates")
            #endif
        }

        // Final ranking: routes that spend more of their bike distance on
        // dedicated bike infrastructure float to the top, even if they're a
        // little longer. The user explicitly asked for "mostly bike lanes"
        // to be the primary signal — fastest-time alone wasn't surfacing
        // the protected-corridor options when a slightly faster street
        // route existed in parallel.
        //
        // We bucket the bike-lane fraction (>=75% / 50–75% / 25–50% / <25%)
        // so a small noise difference (e.g., 73% vs 76%) doesn't reorder
        // routes — only meaningful infra differences do. Within a bucket
        // we tiebreak on the elevation-adjusted duration, which is the
        // same number the UI displays — so a route showing as "25 min"
        // never ranks below a route showing as "23 min" within the same
        // bucket.
        unique.sort { a, b in
            let aBucket = bikeLaneBucket(bikeLaneFraction(a))
            let bBucket = bikeLaneBucket(bikeLaneFraction(b))
            if aBucket != bBucket { return aBucket > bBucket }
            return a.effectiveDurationSeconds < b.effectiveDurationSeconds
        }

        #if DEBUG
        // One-line-per-candidate dump so we can see why a route ranked
        // where it did. For each candidate, prints duration / climb /
        // bike-lane bucket / fraction / a sampling of step street names
        // (top 3 by distance). Look here if a route you expected ("ride
        // the Westlake cycletrack to the Burke-Gilman") doesn't surface
        // at the top — if its fraction is low, the matcher missed names
        // OTP returned; if the route isn't in the list at all, OTP didn't
        // return it under any of the three flavor queries and the fix is
        // server-side (graph weights / numItineraries) instead of here.
        for (idx, it) in unique.enumerated() {
            let frac = bikeLaneFraction(it)
            let bucket = bikeLaneBucket(frac)
            let climb = climbById[it.id] ?? 0
            let topNames = it.legs
                .filter { $0.mode == "BICYCLE" || $0.mode == "BICYCLE_RENT" }
                .flatMap { $0.steps ?? [] }
                .sorted { $0.distance > $1.distance }
                .prefix(3)
                .map { "\($0.streetName ?? "?")(\(Int($0.distance))m)" }
                .joined(separator: ", ")
            let mins = it.duration / 60
            let pct = Int(frac * 100)
            print(
                "[bikeOnly #\(idx)] " +
                "flavor=\(it.bikeFlavor?.rawValue ?? "?") " +
                "dur=\(mins)m climb=\(Int(climb))m " +
                "bucket=\(bucket) lanes=\(pct)% " +
                "top=[\(topNames)]"
            )
        }
        #endif

        return unique
    }

    /// Merge the three bike+transit candidate sets that came back from the
    /// `.bikeMore` / `.balanced` / `.bikeLess` flavor queries. Each flavor
    /// applies a different multiplier on top of the user's preference's
    /// `bikeReluctance`, which shifts OTP's optimization frontier and often
    /// surfaces a different boarding stop — biking further to catch a
    /// faster, more direct bus, or biking less to catch one closer to the
    /// origin.
    ///
    /// Dedup is by boarding-stop sequence (same key as
    /// `dedupeByTransitStops`): if all three flavors produced a trip that
    /// boards at "Westlake Sta", we keep only one. `.balanced` wins ties
    /// so we don't badge a route as "More bike" / "Less bike" unless it's
    /// genuinely a different boarding-stop choice the default flavor
    /// wouldn't have surfaced.
    ///
    /// `flavorSets` is iterated in the order passed (caller puts
    /// `.balanced` first), and each itinerary keeps the flavor tag from
    /// whichever query first produced it. The final list is sorted by
    /// effective duration so the fastest trip — regardless of which flavor
    /// it came from — is at the top.
    ///
    /// Unlike `mergeBikeOnly`, this doesn't fetch elevation profiles
    /// inline — `ElevationService.stampClientBikeDurations` runs on
    /// the merged result back in `planTrip()` and stamps each bike
    /// leg with our pace+slope-aware duration.
    static func mergeBikeTransit(
        flavorSets: [(BikeTransitFlavor, [Itinerary])]
    ) -> [Itinerary] {
        var seen = Set<String>()
        var unique: [Itinerary] = []
        for (_, set) in flavorSets {
            for it in set {
                let stops = it.legs
                    .filter { $0.isTransit }
                    .map { normalizeStop($0.from.name) }
                // Trips with no transit leg shouldn't get into a
                // bike+transit result set, but if one slips through (OTP
                // returning a bike-only itinerary under a transit query),
                // give it a unique fallback key so it doesn't all collapse
                // to one row.
                let key = stops.isEmpty ? "none-\(it.id)" : stops.joined(separator: "|")
                if seen.contains(key) { continue }
                seen.insert(key)
                unique.append(it)
            }
        }
        // Fastest first. effectiveDurationSeconds folds in the climb
        // penalty when one's been computed; for fresh-from-OTP trips that
        // haven't been re-ranked yet, it falls back to OTP duration, so
        // this is a safe ordering whether elevation has landed or not.
        unique.sort { $0.effectiveDurationSeconds < $1.effectiveDurationSeconds }

        #if DEBUG
        for (idx, it) in unique.enumerated() {
            let stops = it.legs
                .filter { $0.isTransit }
                .map { $0.from.name }
                .joined(separator: " → ")
            let mins = it.duration / 60
            print(
                "[bikeTransit #\(idx)] " +
                "flavor=\(it.transitFlavor?.rawValue ?? "?") " +
                "dur=\(mins)m bikeMi=\(String(format: "%.1f", it.bikeMiles)) " +
                "stops=[\(stops)]"
            )
        }
        #endif

        return unique
    }
}
