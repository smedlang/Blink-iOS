import Foundation
import CoreLocation

/// Terrain / hill info for a single leg. Computed from elevation samples
/// taken along the leg's polyline.
///
/// Codable because `ElevationCache` persists profiles to disk so we don't
/// re-fetch the same polyline across cold starts. All four stored properties
/// are plain Codable types so the synthesized conformance is correct; the
/// computed properties (`climbFeet`, `summaryLine`, `difficulty`) aren't
/// stored and aren't part of the encoded shape.
struct ElevationProfile: Equatable, Codable {
    /// Smoothed elevation at each sample point, in meters, in order along the
    /// polyline. Already passed through a 3-point moving average so the
    /// sparkline renders cleanly.
    let samples: [Double]
    /// Sum of all positive elevation deltas (post-smoothing, post-threshold)
    /// between consecutive samples.
    let climbMeters: Double
    /// Sum of all *negative* deltas (returned as a positive number).
    let descentMeters: Double
    /// Max **ascent** grade observed over a rolling ~80m window along
    /// the route. Descents don't count — a 10% downhill is fun on a
    /// bike, not a warning, so the steepness classifier shouldn't fire
    /// on it. Using a rolling window instead of point-to-point keeps a
    /// single SRTM quantization step from blowing the grade up to 10%+.
    let maxGradePercent: Double

    var climbFeet:   Int { Int((climbMeters   * 3.28084).rounded()) }
    var descentFeet: Int { Int((descentMeters * 3.28084).rounded()) }

    /// Compact one-line summary: "↗ 240 ft · ↘ 180 ft · max 8% grade".
    var summaryLine: String {
        String(format: "↗ %d ft · ↘ %d ft · max %.0f%% grade",
               climbFeet, descentFeet, maxGradePercent)
    }

    /// Even shorter chip label for cards: "↗ 240 ft".
    var chipLabel: String {
        "↗ \(climbFeet) ft"
    }

    /// Rough qualitative tag. Useful for color-coding or sorting by difficulty.
    enum Difficulty { case flat, rolling, hilly, steep }
    var difficulty: Difficulty {
        if maxGradePercent >= 10 || climbFeet >= 600 { return .steep }
        if maxGradePercent >= 6  || climbFeet >= 300 { return .hilly }
        if maxGradePercent >= 3  || climbFeet >= 100 { return .rolling }
        return .flat
    }
}

/// Fetches elevation data from Open-Meteo's free elevation API (no auth,
/// backed by the Copernicus 30m DEM).
///
/// The pipeline is: arc-length resample → fetch → smooth → compute climb /
/// descent / grade. Each stage addresses a specific source of error:
///
/// - Arc-length resampling produces uniformly-spaced ground samples; OTP's
///   encoded polylines cluster points at turns, so naive index sampling
///   would oversample intersections and undersample long straights.
/// - A 3-point moving average kills the ±1-2 m quantization noise that
///   would otherwise accumulate into tens of feet of fake climb on flat
///   rides.
/// - A minimum-delta threshold on climb/descent (1.0 m) further suppresses
///   sub-meter jiggle that survives smoothing.
/// - Grade is computed over a rolling ~80 m window rather than between
///   adjacent samples, so a single noisy sample can't spike the max.
enum ElevationService {

    /// Max number of sample points per API call. Open-Meteo caps at 100.
    private static let maxSamples = 60

    /// Target ground spacing between samples. ~50 m is roughly twice the
    /// DEM cell size, which is the sweet spot between resolution and
    /// noise — any tighter and we just oversample a single grid cell.
    private static let targetSpacingMeters: Double = 50

    /// Climb/descent deltas smaller than this (in meters) are treated as
    /// DEM noise and discarded. Sized for the Open-Meteo path, where the
    /// upstream DEM (90 m SRTM with ±1–2 m vertical jitter) routinely
    /// produces phantom 0.5–0.9 m steps between adjacent flat samples.
    /// At 1.0 m the noise gets rejected without throwing away real urban
    /// climbs (typical Seattle block: ~3 m up over ~80 m).
    private static let climbNoiseFloorMeters: Double = 1.0

    /// Tighter floor for OTP-supplied samples. OTP's per-leg profile is
    /// built from the project's own DEM (`seattle_elevation.tif`,
    /// USGS 3DEP 1/3 arc-second LIDAR-derived) at graph-build time —
    /// vertical accuracy is ~0.1–0.3 m, much better than Open-Meteo's
    /// SRTM source. A 1.0 m floor on this data systematically discards
    /// real 30–80 cm grade changes that compound across a multi-mile
    /// route into hundreds of feet of dropped climb (observed gap of
    /// ~3× vs. RideWithGPS on a 6-mile bike route). 0.3 m still rejects
    /// the worst of the per-vertex jitter while keeping the legitimate
    /// short undulations that make up most of urban riding's climb.
    private static let otpClimbNoiseFloorMeters: Double = 0.3

    /// Rolling-window length used for max-grade estimation.
    private static let gradeWindowMeters: Double = 80

    /// Flip this on in a Debug build to dump intermediate elevation data to
    /// the console for field verification.
    private static let debugLogging: Bool = false

    /// Re-rank a list of itineraries by a cost that combines trip duration
    /// with the total climb across all bike legs. Use this at planning time
    /// as a safety net: even if the OTP graph was built without elevation
    /// data (so `optimize: TRIANGLE` + `slopeFactor` is a no-op server-side),
    /// the app still prefers flatter options — including ones that route to
    /// a stop a few blocks further away but downhill from the steep one.
    ///
    /// Stamps each itinerary's `climbMeters` with the measured total across
    /// its bike legs and sorts by `effectiveDurationSeconds` — i.e., the same
    /// elevation-adjusted duration the UI displays. Sort and label come from
    /// the same number, so the list order always matches the per-row time.
    static func reRankByClimb(_ its: [Itinerary]) async -> [Itinerary] {
        guard its.count > 1 else { return its }

        // Fire elevation fetches concurrently for every bike leg. The
        // profile() call is cached by encoded polyline, so this is a no-op
        // the second time a user hits plan for the same from/to pair.
        var climbByItinerary: [String: Double] = [:]
        await withTaskGroup(of: (String, Double).self) { group in
            for it in its {
                group.addTask {
                    var climb: Double = 0
                    for leg in it.legs where Self.isBike(leg.mode) {
                        if let p = try? await profile(for: leg) {
                            climb += p.climbMeters
                        }
                    }
                    return (it.id, climb)
                }
            }
            for await (id, climb) in group {
                climbByItinerary[id] = climb
            }
        }

        // Attach the measured climb to each itinerary so the rest of the
        // app reads a consistent elevation-adjusted duration. Sort by that
        // adjusted number — this is the *same* function used by the UI to
        // render "25 min" or "1 h 12 min", so list order and labels can't
        // disagree.
        let stamped: [Itinerary] = its.map {
            var copy = $0
            copy.climbMeters = climbByItinerary[$0.id] ?? 0
            return copy
        }
        return stamped.sorted { $0.effectiveDurationSeconds < $1.effectiveDurationSeconds }
    }

    private static func isBike(_ mode: String) -> Bool {
        mode == "BICYCLE" || mode == "BICYCLE_RENT"
    }

    /// Replace OTP's per-leg bike duration with a client-side estimate
    /// computed from the user's pace and the leg's measured climb:
    ///
    ///     legSeconds = distance / pace.metersPerSecond
    ///                + climbMeters * Itinerary.climbSecondsPerMeter
    ///
    /// OTP's bike duration is governed by the single `bikeSpeed` scalar
    /// we send and doesn't account for slope. Stamping our own number
    /// onto each bike leg makes every display site (chip, row total,
    /// mode pill, navigation ETA) read a consistent value that responds
    /// to both pace changes and the actual hills along the route.
    ///
    /// Also rolls up a per-itinerary `climbMeters` total so ranking
    /// code that wants a single climb scalar still has one without
    /// having to re-scan legs.
    ///
    /// Polyline-keyed cache: identical bike polylines across different
    /// itineraries share one elevation fetch. A user with three bike-
    /// only flavors that mostly overlap pays for unique segments only.
    static func stampClientBikeDurations(
        _ its: [Itinerary],
        pace: BikePace,
        kind: BikeKind = .standard
    ) async -> [Itinerary] {
        if its.isEmpty { return its }

        // Collect every distinct bike polyline → one representative Leg
        // across the input set. Polyline string is the cache key; the Leg
        // is what carries OTP's `elevationProfile`, so we hand it to
        // `profile(for:)` to enable the OTP fast path. Two legs with the
        // same polyline string have, by construction, the same OTP
        // elevation profile too — so picking any leg with that polyline
        // is fine.
        var legByPolyline: [String: Leg] = [:]
        for it in its {
            for leg in it.legs where isBike(leg.mode) {
                let key = leg.legGeometry.points
                if legByPolyline[key] == nil {
                    legByPolyline[key] = leg
                }
            }
        }
        if legByPolyline.isEmpty { return its }

        var profileByPolyline: [String: (climbMeters: Double, maxGradePercent: Double)] = [:]
        await withTaskGroup(of: (String, Double, Double).self) { group in
            for (poly, leg) in legByPolyline {
                group.addTask {
                    if let p = try? await profile(for: leg) {
                        return (poly, p.climbMeters, p.maxGradePercent)
                    }
                    return (poly, 0, 0)
                }
            }
            for await (poly, climb, peak) in group {
                profileByPolyline[poly] = (climb, peak)
            }
        }

        return its.map { it in
            var copy = it
            var total: Double = 0
            copy.legs = copy.legs.map { leg in
                guard isBike(leg.mode) else { return leg }
                var l = leg
                let entry = profileByPolyline[leg.legGeometry.points] ?? (0, 0)
                let climb = entry.climbMeters
                l.climbMeters = climb
                l.maxGradePercent = entry.maxGradePercent
                // E-bike overrides standard pace with a fixed motor-cruise
                // speed; standard bikes use the user's pace pick. Climb
                // penalty also varies by kind — e-bikes pay a much lower
                // per-meter cost because the motor handles the work.
                //
                // Rental legs (Lime bikeshare) force `.electric` regardless
                // of the user's BikeKind setting: Lime in Seattle is
                // e-bike-only, so stamping at standard-bike pace would
                // overestimate duration by ~25% and double-count climb.
                let effectiveKind: BikeKind = leg.isRental ? .electric : kind
                let effectivePaceMps = effectiveKind.metersPerSecond(pace: pace)
                let flatSecs = leg.distance / effectivePaceMps
                let climbSecs = climb * effectiveKind.climbSecondsPerMeter
                // Note: an earlier revision of this code added a flat
                // 5-minute penalty for legs that traversed the Ballard
                // Locks spillway. That penalty is gone now — OTP's
                // `bicycle.walk` config in router-config.json gives
                // the router a walking-with-bike speed and a mount/
                // dismount time, applied automatically to any way
                // tagged `bicycle=dismount` in OSM (locks, Pike Place
                // arcade, parts of UW campus, etc.). The leg duration
                // OTP returns already accounts for the dismount time,
                // so adding our own penalty would double-count.
                let lockSecs: Double = 0
                // Signal/stop-sign penalty. Two paths:
                //
                //   1. **Proxy-augmented (preferred).** When the signal-
                //      augment proxy is in front of OTP, each step
                //      arrives with `signalCount`, `stopCount`, and
                //      `yieldCount` populated from a static OSM
                //      extract. We sum `count × seconds-per` per type
                //      across the leg's steps. Far more accurate than
                //      the flat-rate fallback because it knows where
                //      signals actually are (vs. assuming a constant
                //      density).
                //
                //   2. **Flat-rate fallback.** When iOS is pointed
                //      straight at OTP (no proxy), the augmented fields
                //      are nil. Use the legacy approximation: penalize
                //      only the street portion of the leg (off-bike-
                //      infra fraction) at `signalPenaltySecondsPerMile`.
                let signalSecs: Double = {
                    if let steps = leg.steps,
                       steps.contains(where: { $0.signalCount != nil
                                            || $0.stopCount != nil
                                            || $0.yieldCount != nil }) {
                        return steps.reduce(0.0) { acc, step in
                            acc
                                + Double(step.signalCount ?? 0) * Itinerary.secondsPerTrafficSignal
                                + Double(step.stopCount   ?? 0) * Itinerary.secondsPerStopSign
                                + Double(step.yieldCount  ?? 0) * Itinerary.secondsPerYield
                        }
                    }
                    let laneFrac = bikeLaneFractionForLeg(leg)
                    let onStreetMeters = leg.distance * (1.0 - laneFrac)
                    let onStreetMiles = onStreetMeters / 1609.34
                    return onStreetMiles * Itinerary.signalPenaltySecondsPerMile
                }()
                l.estimatedDurationSeconds = Int((flatSecs + climbSecs + lockSecs + signalSecs).rounded())
                total += climb
                return l
            }
            copy.climbMeters = total
            return copy
        }
    }

    /// Fetch a profile for a leg, preferring OTP-supplied per-leg samples
    /// (computed against `seattle_elevation.tif` at graph build time) and
    /// falling back to Open-Meteo only when those samples are missing or
    /// unreasonable. This is the entry point every caller that has a `Leg`
    /// should use; `profile(forEncoded:)` is reserved for places that only
    /// have a polyline (e.g., mid-trip reroute, where the legs are still
    /// being constructed).
    ///
    /// Cache key remains the encoded polyline string, so the disk cache
    /// continues to dedup across sessions and across legs that happen to
    /// share geometry. The two source paths only differ in *how* the cache
    /// gets populated:
    ///
    ///   1. OTP path: zero network, computed from samples already on the
    ///      `Leg`. Used when `leg.assembledElevationProfile` (built by
    ///      walking the leg's steps and concatenating each step's own
    ///      `elevationProfile`) is non-empty and passes a sanity check
    ///      (no obviously-bad altitudes).
    ///   2. Open-Meteo path: existing polyline-decode + sample + fetch
    ///      pipeline. Used when (1) is unavailable — typically because
    ///      the leg crosses outside the Seattle DEM bounding box.
    ///
    /// In-flight coalescing still applies — two concurrent callers for
    /// the same polyline share one Task whether the answer comes from
    /// OTP or Open-Meteo.
    static func profile(for leg: Leg) async throws -> ElevationProfile {
        let polyline = leg.legGeometry.points
        if let cached = await ElevationCache.shared.get(polyline) {
            return cached
        }
        if let existing = await ElevationCache.shared.inFlightTask(polyline) {
            return try await existing.value
        }

        // Snapshot the OTP samples once; the Task closure may run after
        // the leg goes out of scope on the caller side. `assembledElevation
        // Profile` walks the leg's `steps` and concatenates each step's
        // own `elevationProfile`, offsetting distance by cumulative step
        // length so the result is a leg-level view (`distance` from leg
        // start). Null on transit legs and on legs whose steps don't
        // carry elevation (out of DEM coverage).
        let otpSamples = leg.assembledElevationProfile

        let task = Task<ElevationProfile, Error> {
            defer { Task { await ElevationCache.shared.clearInFlight(polyline) } }
            // Path 1: OTP-supplied samples. No network, no rate limit.
            if let samples = otpSamples,
               samples.count >= 2,
               isReasonableSamples(samples) {
                let profile = computeFromOTPSamples(samples)
                await ElevationCache.shared.set(polyline, profile)
                #if DEBUG
                let key = polyline.prefix(12)
                let climbFt = Int((profile.climbMeters * 3.28084).rounded())
                let descFt = Int((profile.descentMeters * 3.28084).rounded())
                print("[Elevation][profile] OTP polyline=\(key)… samples=\(samples.count) " +
                      "climb=\(Int(profile.climbMeters))m/\(climbFt)ft " +
                      "descent=\(Int(profile.descentMeters))m/\(descFt)ft " +
                      "maxGrade=\(String(format: "%.1f", profile.maxGradePercent))%")
                #endif
                return profile
            }
            // Path 2: Open-Meteo fallback. Same compute pipeline, just
            // sourced from a uniform polyline resampling.
            let coords = PolylineDecoder.decode(polyline)
            do {
                let profile = try await compute(for: coords)
                await ElevationCache.shared.set(polyline, profile)
                #if DEBUG
                let key = polyline.prefix(12)
                print("[Elevation][profile] OPEN-METEO polyline=\(key)… coords=\(coords.count) (OTP samples \(otpSamples?.count ?? 0))")
                #endif
                return profile
            } catch {
                #if DEBUG
                let key = polyline.prefix(12)
                print("[Elevation][profile] FAIL polyline=\(key)… coords=\(coords.count) error=\(error)")
                #endif
                throw error
            }
        }
        await ElevationCache.shared.registerInFlight(polyline, task)
        return try await task.value
    }

    /// Polyline-only entry point — kept for callers that don't have a
    /// `Leg` (mid-trip reroute legs that haven't been materialized into
    /// the itinerary yet). Always uses Open-Meteo; if you have a `Leg`,
    /// call `profile(for:)` instead so the OTP fast path can run.
    ///
    /// Concurrent callers asking for the same polyline share a single
    /// in-flight Task via `ElevationCache.inFlightTask` — only one network
    /// fetch fires regardless of how many places want the result.
    static func profile(forEncoded polyline: String) async throws -> ElevationProfile {
        if let cached = await ElevationCache.shared.get(polyline) {
            return cached
        }

        // If somebody else is already fetching this exact polyline, wait
        // for their result instead of firing a duplicate request.
        if let existing = await ElevationCache.shared.inFlightTask(polyline) {
            return try await existing.value
        }

        // Build a fresh task and register it so concurrent callers can
        // coalesce. The task itself does the work, sets the cache on
        // success, and clears the in-flight slot on the way out (success
        // OR failure — otherwise a 429 once would jam every future call
        // for this polyline).
        let task = Task<ElevationProfile, Error> {
            defer { Task { await ElevationCache.shared.clearInFlight(polyline) } }
            let coords = PolylineDecoder.decode(polyline)
            do {
                let profile = try await compute(for: coords)
                await ElevationCache.shared.set(polyline, profile)
                return profile
            } catch {
                #if DEBUG
                // Polyline truncated to keep log lines readable; first 12
                // chars are enough to identify which leg failed when
                // cross-referencing with the [bikeOnly #N] dump in
                // mergeBikeOnly.
                let key = polyline.prefix(12)
                print("[Elevation][profile] FAIL polyline=\(key)… coords=\(coords.count) error=\(error)")
                #endif
                throw error
            }
        }
        await ElevationCache.shared.registerInFlight(polyline, task)
        return try await task.value
    }

    // MARK: - OTP-sample compute

    /// Run OTP's per-leg `(distance, elevation)` samples through the
    /// climb / descent / max-grade pipeline.
    ///
    /// Two key differences from the Open-Meteo path's `compute(for:)`:
    ///
    ///  1. **No smoothing.** OTP's elevation samples are read out of a
    ///     LIDAR-derived DEM that's already been quality-controlled at
    ///     graph build time. Running them through a 3-point moving
    ///     average a second time flattens real short undulations and
    ///     systematically undercounts climb on routes with lots of
    ///     small grade changes. Open-Meteo's SRTM source is noisier
    ///     and genuinely needs smoothing; OTP's doesn't.
    ///
    ///  2. **Tighter noise floor (`otpClimbNoiseFloorMeters`).** With
    ///     better vertical accuracy we can lower the threshold without
    ///     phantom climb on flat rides. See the constant's comment for
    ///     the empirical motivation (3× undercount vs. RideWithGPS).
    ///
    /// We use OTP's own per-sample distances for the grade-window
    /// accumulation rather than re-deriving them from coordinate pairs.
    private static func computeFromOTPSamples(
        _ samples: [ElevationProfileSample]
    ) -> ElevationProfile {
        let elev = samples.map { $0.elevation }

        var climb: Double = 0
        var descent: Double = 0
        for i in 1..<elev.count {
            let dE = elev[i] - elev[i - 1]
            if abs(dE) < otpClimbNoiseFloorMeters { continue }
            if dE > 0 { climb += dE } else { descent -= dE }
        }

        // Max ascent grade over a rolling window using OTP's actual
        // along-leg distances (exact, not haversine-estimated).
        // Descents map to 0 (we don't warn on downhills), so a window
        // whose net change is negative or zero contributes nothing.
        // End-of-leg samples that can't fill the window are skipped.
        var maxGrade: Double = 0
        for i in 0..<elev.count - 1 {
            var acc = 0.0
            var j = i
            while j < elev.count - 1, acc < gradeWindowMeters {
                acc += samples[j + 1].distance - samples[j].distance
                j += 1
            }
            if acc < gradeWindowMeters * 0.5 { continue }
            let dE = elev[j] - elev[i]
            let grade = max(0, dE) / acc * 100
            if grade > maxGrade { maxGrade = grade }
        }

        return ElevationProfile(
            samples: elev,
            climbMeters: climb,
            descentMeters: descent,
            maxGradePercent: maxGrade
        )
    }

    /// Sanity check for OTP-supplied samples before we trust them. OTP
    /// can return values outside the DEM bounds as small negatives or
    /// occasionally absurd numbers when the underlying GeoTIFF has
    /// no-data pixels; falling through to Open-Meteo is safer than
    /// rendering "↗ 12,000 ft" climb on a 5-mile commute.
    ///
    /// Range is permissive — Pacific NW altitudes top out around 4,400m
    /// (Mt. Rainier) and the shoreline is ~0m, so [-50, 5000] catches
    /// real values plus a small no-data slop without rejecting any
    /// plausible Seattle leg.
    private static func isReasonableSamples(_ samples: [ElevationProfileSample]) -> Bool {
        samples.allSatisfy { $0.elevation > -50 && $0.elevation < 5000 }
    }

    /// Fetch + compute without caching. Exposed for tests / ad-hoc use.
    static func compute(for coords: [CLLocationCoordinate2D]) async throws -> ElevationProfile {
        // Resample the polyline so samples are uniformly spaced in *meters*,
        // not in polyline-index. This is the single biggest accuracy win —
        // OTP polylines densify at turns and stretch at straights, so
        // index-based sampling produces clustered hills where there aren't
        // any and flat regions where there are.
        let sampled = resampleByArcLength(coords, spacingMeters: targetSpacingMeters, maxSamples: maxSamples)
        guard sampled.count >= 2 else {
            #if DEBUG
            print("[Elevation][compute] short-leg coords=\(coords.count) sampled=\(sampled.count) — returning zero-climb profile")
            #endif
            return ElevationProfile(samples: [], climbMeters: 0, descentMeters: 0, maxGradePercent: 0)
        }

        let raw = try await fetchElevations(sampled)
        guard raw.count == sampled.count else {
            #if DEBUG
            // Open-Meteo is supposed to return one elevation per coordinate;
            // a count mismatch usually means it truncated a too-long request
            // or returned a partial response. Either way, we can't compute
            // climb reliably, so we bail to zero — log so it's visible.
            print("[Elevation][compute] count mismatch sampled=\(sampled.count) raw=\(raw.count) — returning zero-climb profile")
            #endif
            return ElevationProfile(samples: raw, climbMeters: 0, descentMeters: 0, maxGradePercent: 0)
        }

        // 3-point centered moving average — one pass is enough to knock down
        // the ±1-2m SRTM quantization jitter without flattening real hills.
        let elev = smooth(raw)

        // Cumulative climb / descent with a noise floor. Without the floor,
        // flat rides accumulate tens of feet of fake climb from DEM jitter.
        var climb: Double = 0
        var descent: Double = 0
        for i in 1..<elev.count {
            let dE = elev[i] - elev[i - 1]
            if abs(dE) < climbNoiseFloorMeters { continue }
            if dE > 0 { climb += dE } else { descent -= dE }
        }

        // Max grade over a rolling ~80m window. For each starting sample we
        // extend forward until the cumulative horizontal distance crosses
        // the window length, then compute |Δelevation / Δdistance|. This
        // smooths out single-sample spikes while still catching real short
        // climbs (Seattle blocks tend to be 80–100m, so one block's worth
        // of hill still shows up clearly).
        let distances = segmentDistances(sampled)
        // Ascent-only: descents map to 0 so we don't classify a 10%
        // downhill as "steep." See the matching change above for the
        // OTP-supplied profile path; both code paths feed the same
        // `maxGradePercent` field that the trip-level steep/moderate
        // classifier reads.
        var maxGrade: Double = 0
        for i in 0..<elev.count - 1 {
            var acc = 0.0
            var j = i
            while j < elev.count - 1, acc < gradeWindowMeters {
                acc += distances[j]
                j += 1
            }
            if acc < gradeWindowMeters * 0.5 { continue }  // too close to end
            let dE = elev[j] - elev[i]
            let grade = max(0, dE) / acc * 100
            if grade > maxGrade { maxGrade = grade }
        }

        if debugLogging {
            let total = distances.reduce(0, +)
            print("""
                [Elevation] samples=\(elev.count) length=\(Int(total))m \
                climb=\(Int(climb))m descent=\(Int(descent))m maxGrade=\(String(format: "%.1f", maxGrade))%
                raw: \(raw.map { Int($0) })
                smoothed: \(elev.map { Int($0) })
                """)
        }

        return ElevationProfile(
            samples: elev,
            climbMeters: climb,
            descentMeters: descent,
            maxGradePercent: maxGrade
        )
    }

    // MARK: - Resampling

    /// Resample a polyline so the returned points are uniformly spaced along
    /// the route at approximately `spacingMeters` apart. Always preserves
    /// the first and last points. Caps output length at `maxSamples`.
    private static func resampleByArcLength(
        _ coords: [CLLocationCoordinate2D],
        spacingMeters: Double,
        maxSamples: Int
    ) -> [CLLocationCoordinate2D] {
        guard coords.count >= 2 else { return coords }

        let segs = segmentDistances(coords)
        let total = segs.reduce(0, +)
        guard total > 0 else { return [coords[0]] }

        // Prefix sums of segment lengths. `prefix[i]` = cumulative distance
        // from coords[0] to coords[i]. Size is coords.count.
        var prefix: [Double] = [0]
        prefix.reserveCapacity(coords.count)
        for s in segs { prefix.append(prefix.last! + s) }

        // Target sample count: one per `spacingMeters`, bounded by maxSamples.
        let target = max(2, min(maxSamples, Int((total / spacingMeters).rounded(.up)) + 1))
        let step = total / Double(target - 1)

        var out: [CLLocationCoordinate2D] = [coords[0]]
        out.reserveCapacity(target)

        // For each interior sample i (1..<target-1), find the segment it
        // falls on via the prefix table and linearly interpolate.
        var segIdx = 0
        for i in 1..<(target - 1) {
            let targetDist = Double(i) * step
            while segIdx < segs.count - 1, prefix[segIdx + 1] < targetDist {
                segIdx += 1
            }
            let segLen = segs[segIdx]
            let t = segLen > 0 ? (targetDist - prefix[segIdx]) / segLen : 0
            let a = coords[segIdx]
            let b = coords[segIdx + 1]
            out.append(CLLocationCoordinate2D(
                latitude:  a.latitude  + (b.latitude  - a.latitude)  * t,
                longitude: a.longitude + (b.longitude - a.longitude) * t
            ))
        }

        out.append(coords[coords.count - 1])
        return out
    }

    /// Distance (meters) of each segment between adjacent coords. Length is
    /// `coords.count - 1`.
    private static func segmentDistances(_ coords: [CLLocationCoordinate2D]) -> [Double] {
        guard coords.count >= 2 else { return [] }
        var out: [Double] = []
        out.reserveCapacity(coords.count - 1)
        for i in 1..<coords.count {
            let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
            let b = CLLocation(latitude: coords[i].latitude,     longitude: coords[i].longitude)
            out.append(a.distance(from: b))
        }
        return out
    }

    // MARK: - Smoothing

    /// 3-point centered moving average. Endpoints use the 2-point average
    /// of themselves and their single neighbor, so array length is preserved.
    private static func smooth(_ xs: [Double]) -> [Double] {
        guard xs.count >= 3 else { return xs }
        var out = Array(repeating: 0.0, count: xs.count)
        out[0] = (xs[0] + xs[1]) / 2
        out[xs.count - 1] = (xs[xs.count - 1] + xs[xs.count - 2]) / 2
        for i in 1..<xs.count - 1 {
            out[i] = (xs[i - 1] + xs[i] + xs[i + 1]) / 3
        }
        return out
    }

    // MARK: - Network

    /// Max attempts on a single fetch — one initial try plus this many
    /// retries. A 429 from Open-Meteo's free tier clears within ~60s, but
    /// a single short backoff is usually enough because the limiter keeps
    /// concurrency low and the next minute boundary clears the bucket.
    private static let maxFetchAttempts: Int = 3

    /// Backoff schedule per retry, in seconds. Doubles each attempt; the
    /// last retry waits long enough to clear most rate-limit windows.
    private static let backoffSchedule: [UInt64] = [800, 2_000, 5_000]  // ms

    /// Public entry point: acquires a permit from the concurrency limiter,
    /// runs the request with retry on 429, and always releases the permit
    /// (even on failure / cancellation).
    private static func fetchElevations(_ coords: [CLLocationCoordinate2D]) async throws -> [Double] {
        await ElevationFetchLimiter.shared.acquire()
        defer { Task { await ElevationFetchLimiter.shared.release() } }
        return try await fetchElevationsWithRetry(coords)
    }

    /// Inner retry loop. We retry on 429 (rate limit) and transient
    /// network/timeout errors only — 4xx other than 429 and decode errors
    /// are not retried, since waiting won't fix them.
    private static func fetchElevationsWithRetry(_ coords: [CLLocationCoordinate2D]) async throws -> [Double] {
        var attempt = 0
        while true {
            do {
                return try await fetchElevationsOnce(coords)
            } catch let e as ElevationFetchError where e.isRetriable && attempt < maxFetchAttempts - 1 {
                let waitMs = backoffSchedule[min(attempt, backoffSchedule.count - 1)]
                #if DEBUG
                print("[Elevation][fetch] retry \(attempt + 1)/\(maxFetchAttempts - 1) after \(waitMs)ms (reason: \(e))")
                #endif
                try await Task.sleep(nanoseconds: waitMs * 1_000_000)
                attempt += 1
                continue
            } catch let e as URLError where (e.code == .timedOut || e.code == .networkConnectionLost) && attempt < maxFetchAttempts - 1 {
                let waitMs = backoffSchedule[min(attempt, backoffSchedule.count - 1)]
                #if DEBUG
                print("[Elevation][fetch] retry \(attempt + 1)/\(maxFetchAttempts - 1) after \(waitMs)ms (network: \(e.code))")
                #endif
                try await Task.sleep(nanoseconds: waitMs * 1_000_000)
                attempt += 1
                continue
            }
        }
    }

    /// One round-trip to Open-Meteo. Throws ElevationFetchError for HTTP
    /// failures so the retry layer can decide whether to back off and try
    /// again or bubble the error.
    private static func fetchElevationsOnce(_ coords: [CLLocationCoordinate2D]) async throws -> [Double] {
        let lats = coords.map { String(format: "%.5f", $0.latitude)  }.joined(separator: ",")
        let lons = coords.map { String(format: "%.5f", $0.longitude) }.joined(separator: ",")
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
        comps.queryItems = [
            URLQueryItem(name: "latitude",  value: lats),
            URLQueryItem(name: "longitude", value: lons),
        ]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            #if DEBUG
            // Surface the actual status code + the first slice of the body —
            // Open-Meteo returns JSON error messages ("API request limit
            // reached", "invalid latitude") for client-correctable issues,
            // and including them turns "ElevationService quietly broken"
            // into "ElevationService rate-limited at 14:32 UTC".
            let body = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
            print("[Elevation][fetch] HTTP \(http.statusCode) coords=\(coords.count) body=\(body)")
            #endif
            throw ElevationFetchError(status: http.statusCode)
        }
        struct Resp: Decodable { let elevation: [Double] }
        do {
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            return decoded.elevation
        } catch {
            #if DEBUG
            let body = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
            print("[Elevation][fetch] decode failure coords=\(coords.count) error=\(error) body=\(body)")
            #endif
            throw error
        }
    }
}

/// HTTP-level error from Open-Meteo. `isRetriable` is true for 429 (rate
/// limit) and 5xx; the retry layer leaves everything else alone since
/// waiting won't change a 400 or 404.
private struct ElevationFetchError: Error, CustomStringConvertible {
    let status: Int
    var isRetriable: Bool { status == 429 || (500...599).contains(status) }
    var description: String { "ElevationFetchError(status=\(status))" }
}

/// Actor-backed cache so concurrent fetches for the same polyline don't each
/// hit the network. Key is the encoded polyline string — it's stable for a
/// given leg, so cache hits line up with what the UI asks for.
///
/// **Persisted to disk.** The cache hydrates from
/// `Caches/PugetRoute/elevation-cache.json` on first access and writes back
/// (debounced, 2 s) on each `set`. This is the single biggest defense
/// against Open-Meteo's free-tier rate limit: a Seattle commuter who replans
/// the same neighborhoods over multiple sessions hits the network for a
/// polyline exactly once, ever (until LRU eviction or OS cache purge).
///
/// **LRU eviction.** Once the cache exceeds `maxEntries`, we drop the oldest
/// 10% by `lastAccessed`. Bulk-evict-once-then-coast is much cheaper than
/// per-access bookkeeping and the resulting churn is fine for a cache where
/// every entry is regenerable.
///
/// **Caches directory, not Application Support.** iOS may purge the caches
/// directory under storage pressure — that's exactly the right semantics
/// here, since elevation data is a network-derived optimization, not user
/// data. The app can always re-fetch.
///
/// **In-flight coalescing (unchanged).** Two concurrent callers asking for
/// the same polyline share one Task via `inFlightTask` / `registerInFlight`.
/// `mergeBikeOnly` + `stampClientBikeDurations` both fan out elevation
/// fetches in parallel for many itineraries that share bike-leg polylines
/// (especially across flavor variants), so this still meaningfully cuts
/// real network volume on top of the disk cache.
actor ElevationCache {
    static let shared = ElevationCache()

    private var cache: [String: ElevationProfile] = [:]
    private var lastAccessed: [String: Date] = [:]
    private var inFlight: [String: Task<ElevationProfile, Error>] = [:]

    /// Whether `cache` has been hydrated from disk yet. We do this lazily on
    /// the first `get`/`set` so app startup doesn't block on disk I/O for
    /// users who never plan a trip in the session.
    private var loaded: Bool = false

    /// Single-flight load. If multiple callers hit the actor before disk
    /// hydration finishes, they all await the same Task instead of racing
    /// (actor reentrancy means a naive `if !loaded` check would let the
    /// second caller skip past the first's in-progress load).
    private var loadTask: Task<Void, Never>?

    /// Pending debounced save. Cancelled and re-scheduled on each `set`, so
    /// rapid-fire updates (a single `planTrip` may stamp 30+ profiles in
    /// quick succession) collapse into one disk write.
    private var pendingSave: Task<Void, Never>?

    /// Hard upper bound on cached entries. ~5000 entries × ~60 samples ×
    /// 4 doubles per profile ≈ a few MB on disk — well within reasonable
    /// caches-directory usage for a routing app.
    private let maxEntries: Int = 5000

    /// Debounce window for disk writes.
    private let saveDebounceNanos: UInt64 = 2_000_000_000  // 2 s

    /// Persistent storage location. Stored as a static computed prop so we
    /// don't bake a stale path into the actor and so failures (no caches
    /// dir) degrade to "in-memory only" without crashing.
    private static var cacheURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("PugetRoute", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("elevation-cache.json")
    }

    func get(_ key: String) async -> ElevationProfile? {
        await ensureLoaded()
        guard let value = cache[key] else { return nil }
        lastAccessed[key] = Date()
        return value
    }

    func set(_ key: String, _ value: ElevationProfile) async {
        await ensureLoaded()
        cache[key] = value
        lastAccessed[key] = Date()
        if cache.count > maxEntries {
            evictLRU()
        }
        scheduleSave()
    }

    /// Return the in-flight task for `key` if one exists. Caller awaits
    /// `.value` to get the result (which the original task will set into
    /// the cache when it completes). Note: doesn't await disk hydration —
    /// in-flight tracking is purely a runtime concern and any cache hit
    /// will already have been resolved by `get` before we reach here.
    func inFlightTask(_ key: String) -> Task<ElevationProfile, Error>? {
        inFlight[key]
    }

    /// Register an in-flight task. Caller is responsible for clearing it
    /// via `clearInFlight` when the task settles.
    func registerInFlight(_ key: String, _ task: Task<ElevationProfile, Error>) {
        inFlight[key] = task
    }

    func clearInFlight(_ key: String) {
        inFlight.removeValue(forKey: key)
    }

    /// Force any pending debounced save to flush immediately. Useful from
    /// `applicationDidEnterBackground` — iOS gives us ~5 s before suspend,
    /// which is plenty for one JSON write but not enough to wait out a 2 s
    /// debounce that may be near the start of its window.
    func flushNow() async {
        guard let pending = pendingSave else { return }
        pending.cancel()
        pendingSave = nil
        let snapshot = cache
        let timestamps = lastAccessed
        await Self.writeToDisk(cache: snapshot, timestamps: timestamps)
    }

    // MARK: - Disk persistence

    /// On-disk shape. Versioned so future format changes can detect old
    /// files and either migrate or discard them. Storing
    /// `[String: StoredEntry]` rather than parallel dicts keeps the file
    /// human-readable and lets us atomically encode/decode without
    /// dictionary-key alignment bugs.
    private struct StoredEntry: Codable {
        let profile: ElevationProfile
        let lastAccessed: Date
    }

    private struct StoredFile: Codable {
        let version: Int
        let entries: [String: StoredEntry]
    }

    /// Hydrate the cache from disk, exactly once. Single-flighted by
    /// `loadTask` so two simultaneous `get`/`set` calls don't each load.
    private func ensureLoaded() async {
        if loaded { return }
        if let existing = loadTask {
            await existing.value
            return
        }
        // Explicit guard rather than `await self?.performLoad()` — the
        // optional chain version makes the closure return `Void?` and
        // Swift infers `Task<()?, Never>`, which won't bind to our
        // `Task<Void, Never>` slot. Singleton ownership means `self` is
        // effectively never nil; the weak capture is just hygiene.
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
    }

    private func performLoad() {
        defer {
            loaded = true
            loadTask = nil
        }
        guard let url = Self.cacheURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let stored = try JSONDecoder().decode(StoredFile.self, from: data)
            // Format version. Bump when the climb-computation pipeline
            // changes meaningfully so cached entries computed under the
            // old pipeline don't poison the new one. v2 dropped 3-point
            // smoothing and lowered the noise floor on the OTP path.
            guard stored.version == 2 else {
                #if DEBUG
                print("[Elevation][cache] disk format version \(stored.version) doesn't match current (2) — discarding cache")
                #endif
                try? FileManager.default.removeItem(at: url)
                return
            }
            for (key, entry) in stored.entries {
                cache[key] = entry.profile
                lastAccessed[key] = entry.lastAccessed
            }
            #if DEBUG
            print("[Elevation][cache] loaded \(cache.count) entries from disk (\(data.count) bytes)")
            #endif
        } catch {
            #if DEBUG
            print("[Elevation][cache] load failed: \(error) — discarding corrupt cache and starting fresh")
            #endif
            // Corrupt cache file: nuke it. Otherwise every subsequent
            // launch re-attempts decoding and re-fails.
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Drop the oldest 10% of entries by `lastAccessed`. Called only when
    /// `cache.count > maxEntries`, so amortized cost is ~1 sort per
    /// `maxEntries / 10` inserts.
    private func evictLRU() {
        let evictCount = max(1, cache.count / 10)
        let oldest = lastAccessed.sorted { $0.value < $1.value }.prefix(evictCount)
        for (key, _) in oldest {
            cache.removeValue(forKey: key)
            lastAccessed.removeValue(forKey: key)
        }
        #if DEBUG
        print("[Elevation][cache] evicted \(evictCount) LRU entries (now \(cache.count))")
        #endif
    }

    /// Cancel any pending save, snapshot the current state, and schedule a
    /// new write 2 s out. Snapshotting *now* (inside the actor) means the
    /// detached writer doesn't need to bounce back through actor isolation
    /// to read state. Repeated calls within the window collapse into one
    /// write because each call cancels its predecessor.
    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = cache
        let timestamps = lastAccessed
        let delay = saveDebounceNanos
        pendingSave = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            await Self.writeToDisk(cache: snapshot, timestamps: timestamps)
        }
    }

    /// Static so the writer doesn't need actor isolation — it works only
    /// from its parameters. Atomic write so a crash mid-write can't leave
    /// a half-truncated JSON file that breaks all future loads.
    private static func writeToDisk(
        cache: [String: ElevationProfile],
        timestamps: [String: Date]
    ) async {
        guard let url = cacheURL else { return }
        var entries: [String: StoredEntry] = [:]
        entries.reserveCapacity(cache.count)
        for (key, profile) in cache {
            entries[key] = StoredEntry(
                profile: profile,
                lastAccessed: timestamps[key] ?? Date()
            )
        }
        let stored = StoredFile(version: 2, entries: entries)
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: url, options: [.atomic])
            #if DEBUG
            print("[Elevation][cache] saved \(cache.count) entries (\(data.count) bytes)")
            #endif
        } catch {
            #if DEBUG
            print("[Elevation][cache] save failed: \(error)")
            #endif
        }
    }
}

/// Actor-backed semaphore that bounds how many elevation HTTP requests can
/// be in flight at once. Open-Meteo's free tier rate-limits per minute, and
/// a burst from `mergeBikeOnly` (3 flavors × up to 10 itineraries × 1–2
/// bike legs) can easily exceed that ceiling if every fetch fires
/// simultaneously. Three permits is enough to keep the pipeline busy
/// without blowing the limit on the trips we've tested.
actor ElevationFetchLimiter {
    static let shared = ElevationFetchLimiter()

    private let maxConcurrent: Int = 3
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
        // Resumed by `release()` — the count is already debited there.
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
            // A waiter is taking our place; in-flight count stays the same.
        } else {
            inFlight -= 1
        }
    }
}
