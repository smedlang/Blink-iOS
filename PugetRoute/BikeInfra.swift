import Foundation
import CoreLocation

// MARK: - Bike-infrastructure heuristic
//
// OTP doesn't expose per-edge bike-infrastructure tags in its plan response,
// so we approximate by matching the per-step `streetName` against a list of
// known bike facilities. The score is the fraction of total bike-leg
// distance that lands on a matched street, in [0, 1].
//
// Lives at file scope (module-internal) so both the route-list ranking
// (mergeBikeOnly in ContentView) and the map renderers (ItineraryMapView,
// NavigationMapView) can call it. The list is name-based, not OSM-tag
// based — it will miss streets that have bike lanes but don't say so in
// the name and aren't in the curated set; edits welcome as the network
// expands.

/// Total bike-leg distance and the portion of it on known bike
/// infrastructure, summed across every bike leg in the itinerary. Returns
/// (0, 0) for itineraries with no bike legs.
func bikeLaneDistances(_ it: Itinerary) -> (onLane: Double, total: Double) {
    var total: Double = 0
    var onLane: Double = 0
    for leg in it.legs where leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT" {
        guard let steps = leg.steps else { continue }
        for step in steps {
            total += step.distance
            if isBikeInfrastructure(step.streetName) {
                onLane += step.distance
            }
        }
    }
    return (onLane, total)
}

/// Fraction of the bike legs on known bike infrastructure, in [0, 1].
/// 0 if there are no bike legs (or no steps).
func bikeLaneFraction(_ it: Itinerary) -> Double {
    let (onLane, total) = bikeLaneDistances(it)
    return total > 0 ? onLane / total : 0
}

/// Per-leg version of `bikeLaneFraction` — sums step distances within a
/// single leg rather than across the whole itinerary. Used by the
/// duration-stamping pipeline to apply the signal-time penalty only to
/// each leg's *street* mileage (cycletracks and trails don't have
/// signals, so the same 5-mile leg has very different real-world wait
/// time depending on how much of it is on protected infrastructure).
/// Returns 0 for non-bike legs and for bike legs without step data.
func bikeLaneFractionForLeg(_ leg: Leg) -> Double {
    guard leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT" else { return 0 }
    guard let steps = leg.steps, !steps.isEmpty else { return 0 }
    var total: Double = 0
    var onLane: Double = 0
    for step in steps {
        total += step.distance
        if isBikeInfrastructure(step.streetName) {
            onLane += step.distance
        }
    }
    return total > 0 ? onLane / total : 0
}

/// Coarse "how bike-friendly is this route" bucket used as the primary
/// sort key. We bucket instead of sorting on the raw fraction so a route
/// with 78% bike infra always beats one with 41%, even if the 41% one is
/// a couple minutes faster — bike-lane preference is paramount. Within a
/// bucket, time wins.
func bikeLaneBucket(_ fraction: Double) -> Int {
    if fraction >= 0.75 { return 3 }
    if fraction >= 0.50 { return 2 }
    if fraction >= 0.25 { return 1 }
    return 0
}

/// Maximum proportional discount applied to a trip's effective sort
/// duration based on its lighting coverage. A 100%-lit route is
/// scored as if it were 30% shorter than its actual duration; a
/// 0%-lit route stays at full duration. Tuned by feel: 30% is
/// enough that lit alternatives consistently surface above unlit
/// ones at similar duration, but not so much that a 30-min lit
/// detour outranks a 15-min unlit direct route. Adjust here in
/// one place if night-route ranking ever feels off.
private let litDiscountWeight: Double = 0.3

/// Sort key for bike-only alternatives that accounts for lighting
/// when the trip falls during civil-twilight darkness. Returns the
/// itinerary's effective duration as a comparable Double — same
/// unit as `effectiveDurationSeconds` so the existing comparator
/// can use it as a direct replacement. Daytime trips return raw
/// duration unchanged (lighting irrelevant); dark trips return
/// `duration × (1 - 0.3 × litFraction)`, discounting better-lit
/// routes proportional to their coverage.
///
/// Worked example: two routes home from Belltown at 10 PM, both
/// returning OTP-equal at 24 min:
///   Route A: 90% lit (Westlake → Burke-Gilman) → 24 × (1 - 0.27) = 17.5 min sort score
///   Route B:  5% lit (residential side streets) → 24 × (1 - 0.015) = 23.6 min sort score
/// Route A wins the secondary sort comfortably even though both
/// have identical actual duration. The discount is purely a sort
/// signal — the user still sees the real 24-min duration in the row.
func darkAwareSortSeconds(_ it: Itinerary) -> Double {
    let raw = Double(it.effectiveDurationSeconds)
    guard it.isTripDark, let litFrac = it.litFractionWeighted else { return raw }
    // Clamp to [0, 1] defensively. litFractionWeighted SHOULD already
    // be in that range, but guarding here means a stray value can't
    // make the sort score go negative and flip the ordering.
    let clamped = max(0.0, min(1.0, litFrac))
    return raw * (1.0 - litDiscountWeight * clamped)
}

/// Returns true when a step's street name strongly suggests it's on
/// dedicated bike infrastructure. Two paths to true: substring match on
/// generic bike-infra keywords (catches unlisted trails, greenways, paths
/// in OSM), or exact match (after normalization) against the curated
/// Seattle list below.
func isBikeInfrastructure(_ streetName: String?) -> Bool {
    guard let raw = streetName else { return false }
    let n = raw.lowercased()
    if n.contains("trail")               { return true }
    if n.contains("cycletrack")          { return true }
    if n.contains("cycle track")         { return true }
    if n.contains("bike path")           { return true }
    if n.contains("bike lane")           { return true }   // "Westlake Protected Bike Lane" etc.
    if n.contains("protected bike")      { return true }   // belt-and-suspenders for SDOT naming
    if n.contains("greenway")            { return true }
    // "path" alone is too greedy — matches "pathway", street names like
    // "Sandy Beach Path" rarely. We allow it because most "Path" entries
    // in Seattle OSM are bike/ped paths, but exclude the false-positive
    // "pathway" since it's a generic English word and shows up sometimes.
    if n.contains("path") && !n.contains("pathway") { return true }
    return seattleBikeCorridorsNormalized.contains(normalizeStreetName(raw))
}

/// Fold OSM/OTP street-name variants onto a single canonical form for set
/// lookup. Expands the common abbreviations (St → Street, Ave → Avenue,
/// Blvd → Boulevard, etc.) so we don't have to enumerate both spellings
/// for every entry — OTP often emits "Pike Street" rather than "Pike St",
/// and the curated set should match either.
///
/// Directionals are NOT stripped — "12th Ave" downtown and "12th Ave NW"
/// in Ballard are different streets with different bike status, so they
/// need to remain distinguishable in the set.
fileprivate func normalizeStreetName(_ raw: String) -> String {
    let n = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let expansions: [String: String] = [
        "st":   "street",
        "ave":  "avenue",
        "av":   "avenue",
        "blvd": "boulevard",
        "rd":   "road",
        "dr":   "drive",
        "pl":   "place",
        "ln":   "lane",
        "ct":   "court",
        "ter":  "terrace",
        "hwy":  "highway",
        "pkwy": "parkway",
        // Long-form directionals collapse to the short letter form so
        // "East Pike Street" and "E Pike Street" land on the same key.
        "east":      "e",
        "west":      "w",
        "north":     "n",
        "south":     "s",
        "northeast": "ne",
        "northwest": "nw",
        "southeast": "se",
        "southwest": "sw",
    ]
    let parts = n.split(separator: " ").map(String.init)
    return parts.map { expansions[$0] ?? $0 }.joined(separator: " ")
}

/// Pre-normalized version of the curated set, computed once at module load
/// so each `isBikeInfrastructure` call is a single hash lookup instead of
/// a per-call normalize-then-contains-by-equality scan.
fileprivate let seattleBikeCorridorsNormalized: Set<String> = {
    Set(seattleBikeCorridors.map { normalizeStreetName($0) })
}()

/// Curated list of Seattle-area streets / facilities with significant
/// protected bike infrastructure. Names are lowercased and stored exactly
/// as OTP/OSM emits them; trailing directionals (E / N / NE / etc.) are
/// part of the name. Matching is exact-equals against the lowercased
/// streetName, not substring, so "2nd Ave" won't accidentally match
/// "NW 102nd Ave".
let seattleBikeCorridors: Set<String> = [
    // Multi-use trails (effectively cycleways end-to-end)
    "burke-gilman trail",
    "burke gilman trail",
    "elliott bay trail",
    "westlake cycletrack",
    "westlake cycle track",
    "mountains to sound greenway",
    "interurban trail",
    "interurban trail north",
    "interurban trail south",
    "chief sealth trail",
    "i-90 trail",
    "ship canal trail",
    "alaskan way trail",
    "duwamish trail",
    "soundview trail",
    "centennial trail",
    "sammamish river trail",
    "cedar river trail",
    "missing link",
    // Downtown / First Hill / Capitol Hill protected lanes. These streets
    // also carry car traffic, so the name alone doesn't reveal the bike
    // lane — they're hardcoded here on the strength of SDOT signage.
    "2nd ave",
    "4th ave",
    "7th ave",
    // Pike & Pine: protected bike lanes downtown ("Pike Street") and the
    // Capitol Hill continuation ("E Pike Street"). Both prefix forms are
    // listed; long-form "East" collapses to "e" via the normalizer, so
    // "East Pike Street" also lands here.
    "pike st",
    "e pike st",
    "pine st",
    "e pine st",
    "broadway",
    "broadway e",
    "12th ave",
    "12th ave e",
    "dexter ave n",
    "roosevelt way",
    "roosevelt way ne",
    // South Lake Union → Fremont. The protected Westlake cycletrack runs
    // most of the length of Westlake Ave N from Mercer up to the Fremont
    // Bridge approach, but OTP usually emits the street name, not the
    // cycletrack name, for steps along it. False-positive risk: a short
    // segment near Denny is unprotected, but the routing engine almost
    // never sends bikes that way when there's an alternative.
    "westlake ave n",
    "westlake avenue n",
    // South Lake Union → Eastlake → University District via the east shore
    // of Lake Union. Eastlake Ave has buffered bike lanes (Eastlake
    // RapidRide reconstruction added them); Fairview is the protected
    // cycletrack along the SLU east shore. Lakeview Blvd is a designated
    // bike route over the I-5 lid. These are the streets OTP currently
    // surfaces on a Belltown→UW ride at high safety preference, so
    // marking them as bike infra here keeps the displayed lane% honest
    // while we sort out the OSM data for the Westlake cycletrack
    // upstream.
    "eastlake ave e",
    "eastlake avenue e",
    "eastlake ave ne",
    "eastlake avenue ne",
    "fairview ave n",
    "fairview avenue n",
    "fairview ave e",
    "fairview avenue e",
    "lakeview blvd e",
    "lakeview boulevard e",
    "12th ave ne",
    "12th avenue ne",
    // Downtown protected cycletracks named explicitly. Some of these
    // were caught by the substring "cycle track" / "cycletrack" rules
    // already; listing them by name as well doesn't hurt and protects
    // against OTP emitting a slightly different form.
    "9th ave cycle track",
    "9th avenue cycle track",
    "bell st cycle track",
    "bell street cycle track",
    "4th avenue cycletrack",
    "4th ave cycletrack",
    // Burke-Gilman gap in Fremont/Wallingford — between the Fremont Bridge
    // and Gas Works the trail briefly runs along (or as) N Northlake Way,
    // and OTP sometimes emits that name for the on-street section.
    "n northlake way",
    "northlake way",
    // The Cheshiahud Lake Union Loop on the west and east sides — these
    // are mixed-use paths along the lake.
    "cheshiahud lake union loop",
    "lake union loop",
    // Neighborhood greenways / arterials with bike facilities
    "linden ave n",
    "fremont ave n",
    "8th ave nw",
    "17th ave nw",
    "39th ave ne",
    "ravenna ave ne",
    "lake washington blvd",
    "lake washington blvd e",
    "lake washington blvd s",
    "beacon ave s",
    "phinney ave n",
    "stone way n",
    "wallingford ave n",
    // Eastside
    "bellevue-redmond rd",
    "northrup way",
    "lakeview dr",
]

// MARK: - Per-step polyline splitting

/// One sub-segment of a bike leg's polyline, tagged with whether the
/// underlying step's street is on known bike infrastructure. Used by the
/// map renderers to color the route line green-on-infra / blue-on-street.
struct BikeLegSegment {
    let coords: [CLLocationCoordinate2D]
    let onBikeInfra: Bool
}

/// Split a leg's polyline into colored sub-segments by step. For each
/// step we snap its (lat, lon) to the closest vertex on the decoded
/// polyline; the sub-polyline between consecutive snap points is colored
/// according to that step's street name.
///
/// Falls back to a single non-infra segment when the leg has no step
/// data (e.g., transit) or the polyline is too short to split. Callers
/// should use this only for bike legs — walk and transit color whole-leg.
///
/// Snap monotonicity: in unusual geometry (a u-turn or a loop crossing
/// itself), the closest-vertex search can land on an earlier index than
/// the previous step. We clamp each snap index to be ≥ the previous one
/// so segments don't overlap or run backwards.
func bikeLegSegments(_ leg: Leg) -> [BikeLegSegment] {
    let polyline = PolylineDecoder.decode(leg.legGeometry.points)
    guard polyline.count >= 2 else { return [] }
    guard let steps = leg.steps, !steps.isEmpty else {
        // No step-level data — emit one segment, marked as not-on-infra
        // so it renders blue. Reasonable default for malformed bike legs.
        return [BikeLegSegment(coords: polyline, onBikeInfra: false)]
    }

    // Snap each step's start coordinate to the nearest polyline vertex.
    // The snap is "closest by point distance" rather than "first point
    // past distance D" because OTP polylines aren't dense enough for the
    // latter to be reliable; closest-vertex gets within one polyline
    // segment, which is plenty for coloring.
    var snapIndices: [Int] = []
    snapIndices.reserveCapacity(steps.count + 1)
    for step in steps {
        let target = CLLocationCoordinate2D(latitude: step.lat, longitude: step.lon)
        snapIndices.append(closestPolylineIndex(target, in: polyline))
    }
    // Final endpoint of the polyline — the last step ends here.
    snapIndices.append(polyline.count - 1)

    // Clamp monotonically non-decreasing.
    for i in 1..<snapIndices.count {
        if snapIndices[i] < snapIndices[i - 1] {
            snapIndices[i] = snapIndices[i - 1]
        }
    }

    var out: [BikeLegSegment] = []
    out.reserveCapacity(steps.count)
    for i in 0..<steps.count {
        let start = snapIndices[i]
        let end   = snapIndices[i + 1]
        if end <= start { continue }                       // empty step (zero-length)
        let sub = Array(polyline[start...end])             // inclusive end so segments share endpoints
        if sub.count < 2 { continue }
        let infra = isBikeInfrastructure(steps[i].streetName)
        // Coalesce consecutive segments of the same color so the renderer
        // doesn't draw seams every block. This also reduces overlay count
        // by 5–10× on long bike legs.
        if let last = out.last, last.onBikeInfra == infra {
            // Merge: drop the last point of the prior segment (it's the
            // shared endpoint) and append this segment's points.
            let merged = last.coords.dropLast() + sub
            out[out.count - 1] = BikeLegSegment(coords: Array(merged), onBikeInfra: infra)
        } else {
            out.append(BikeLegSegment(coords: sub, onBikeInfra: infra))
        }
    }

    if out.isEmpty {
        return [BikeLegSegment(coords: polyline, onBikeInfra: false)]
    }
    return out
}

/// Index of the polyline vertex closest to `target`. Uses squared-distance
/// in degree space — fine for picking the nearest point at city scale and
/// avoids the per-point Haversine cost of CLLocation.distance(from:).
private func closestPolylineIndex(
    _ target: CLLocationCoordinate2D,
    in polyline: [CLLocationCoordinate2D]
) -> Int {
    var bestIdx = 0
    var bestD2 = Double.greatestFiniteMagnitude
    for i in 0..<polyline.count {
        let dLat = polyline[i].latitude  - target.latitude
        let dLon = polyline[i].longitude - target.longitude
        let d2 = dLat * dLat + dLon * dLon
        if d2 < bestD2 {
            bestD2 = d2
            bestIdx = i
        }
    }
    return bestIdx
}
