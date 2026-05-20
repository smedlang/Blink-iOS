import Foundation
import CoreLocation

/// Thin GraphQL client for OpenTripPlanner 2.
enum RoutingClient {

    // OTP backend. The current public endpoint is fronted by Cloudflare
    // Tunnel: cloudflared runs on the Mac that hosts OTP, terminates TLS at
    // Cloudflare's edge, and proxies through to the local OTP container at
    // localhost:8080. The hostname is stable across tunnel/Mac restarts, so
    // this URL doesn't need to change when the dev machine reboots.
    //
    // For local dev without the tunnel:
    //   Simulator + OTP on same Mac: http://localhost:8080
    //   Real device on same Wi-Fi:   http://192.168.x.x:8080  (needs ATS exception)
    static let baseURL = URL(string: "https://seattlebikebus-otp.com")!

    static var graphQLEndpoint: URL {
        baseURL.appendingPathComponent("otp/routers/default/index/graphql")
    }

    enum RoutingError: Error, LocalizedError {
        case http(Int)
        case empty
        case decode(Error)

        var errorDescription: String? {
            switch self {
            case .http(let c): return "Backend returned HTTP \(c)"
            case .empty:       return "No routes found"
            case .decode(let e): return "Couldn't parse response: \(e.localizedDescription)"
            }
        }
    }

    static func plan(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        mode: TripMode,
        when: TimeTarget = .leaveNow,
        preference: RoutePreference = .fastest,
        bikePreference: BikePreference = .faster,
        bikePace: BikePace = .moderate,
        bikeKind: BikeKind = .standard,
        bikeTransitFlavor: BikeTransitFlavor? = nil,
        // Internal override used by mid-trip reroutes. When set, this is
        // sent to OTP instead of `mode.otpTransportModes` and the cache is
        // bypassed (since the cache key doesn't capture the override).
        // Lets the navigation reroute ask for bike-only or walk-only paths
        // even though the high-level trip mode is `.bikeTransit` — we
        // never want a reroute introducing a different bus mid-trip.
        transportModesOverride: [[String: String]]? = nil,
        // When true, skip both the cache read and the cache write. Used
        // by the navigation realtime-refresh loop, which needs fresh
        // delay/cancellation data and would otherwise read up to 60 s of
        // stale values from the plan() the user just made before
        // entering navigation.
        bypassCache: Bool = false,
        // When true, any BICYCLE entry in the modes list gets a
        // `qualifier: RENT` appended — turning own-bike queries into
        // Lime bikeshare queries (Lime alone for .bikeOnly, Lime+transit
        // for .bikeTransit). The user-facing PreferencesSheet toggle
        // drives this; mid-trip reroutes read the same `@AppStorage` so
        // a Lime-mode trip stays on Lime if the rider goes off-route.
        useLime: Bool = false
    ) async throws -> [Itinerary] {

        // Consult the in-memory cache before hitting the network. Same trip
        // re-planned within the same minute (e.g., user nudges the time
        // picker and reverts, or toggles preferences and reverts) returns
        // instantly. See ItineraryCache for key shape and TTL.
        //
        // Skip the cache when modes are overridden — the cache key is
        // built from `mode` alone, so two different override values would
        // collide and serve the wrong polyline. Reroutes are infrequent
        // enough (capped by `minSecondsBetweenReroutes`) that the network
        // hit is fine.
        let cacheKey = ItineraryCache.Key(
            from: from, to: to, mode: mode, when: when,
            preference: preference, bikePreference: bikePreference,
            bikePace: bikePace, bikeKind: bikeKind,
            bikeTransitFlavor: bikeTransitFlavor,
            useLime: useLime
        )
        if !bypassCache, transportModesOverride == nil,
           let cached = await ItineraryCache.shared.get(cacheKey) {
            return cached
        }

        // Pick the routing knobs based on which mode this is. Bike-only is
        // governed entirely by `bikePreference` — its triangle controls the
        // slope ↔ time tradeoff, and the multimodal walk/bike reluctances
        // aren't meaningful when there's no transit on the table. Multimodal
        // modes use the user-facing `preference` as before.
        let walkRel: Double
        var bikeRel: Double
        let optimize: String
        let triangle: [String: Double]
        switch mode {
        case .bikeOnly, .bikeshare:
            // Bikeshare is still bike-driven from the user's perspective —
            // the BikePreference triangle (safety/slope/time weights)
            // shapes the rental ride the same way it shapes own-bike.
            walkRel  = bikePreference.walkReluctance
            bikeRel  = bikePreference.bikeReluctance
            optimize = bikePreference.bikeOptimize
            triangle = bikePreference.bikeTriangle
        case .bikeTransit, .transitOnly:
            walkRel  = preference.walkReluctance
            bikeRel  = preference.bikeReluctance
            optimize = preference.bikeOptimize
            triangle = preference.bikeTriangle
        }
        // Apply the bike+transit flavor multiplier on top of the user's
        // preference. This is what gives OTP permission (or refusal) to
        // bike further to a different boarding stop without breaking the
        // user's high-level "fastest vs less active" intent. Only relevant
        // for bike+transit — bike-only and transit-only ignore the flavor.
        if mode == .bikeTransit, let flavor = bikeTransitFlavor {
            bikeRel = max(0.5, bikeRel * flavor.bikeReluctanceMultiplier)
        }

        // E-bike overrides. When the user has selected `.electric`, swap
        // in a quick-favoring triangle and a lower bikeReluctance — both
        // chosen to match how e-bike riders actually pick routes (direct
        // over flat, willing to bike longer instead of catching a
        // transfer). Standard bikes return nil from both overrides so
        // the preference-derived values pass through unchanged.
        //
        // Bikeshare mode forces e-bike characteristics regardless of the
        // user's BikeKind setting — Lime in Seattle is e-bike-only, so
        // OTP should plan rental rides at e-bike speed and using e-bike
        // route preferences (direct over flat). Without this override,
        // OTP would route at pedal-bike speed (~5 m/s) and return
        // durations 25–30% longer than the real ride.
        //
        // `useLime` extends this to any mode that includes a BICYCLE
        // entry: when on, bike-only becomes Lime-only and bike+transit
        // becomes Lime+transit. Bike characteristics flip to e-bike for
        // those queries too. transitOnly is unaffected.
        let isLimeQuery = (mode == .bikeshare) || (useLime && (mode == .bikeOnly || mode == .bikeTransit))
        let effectiveKind: BikeKind = isLimeQuery ? .electric : bikeKind
        let effectiveTriangle = effectiveKind.triangleOverride ?? triangle
        let effectiveBikeRel  = effectiveKind.bikeReluctanceOverride ?? bikeRel

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "America/Los_Angeles")
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        tf.timeZone = df.timeZone

        let referenceDate = when.date

        let query = """
        query Plan(
          $fromLat: Float!, $fromLon: Float!,
          $toLat: Float!,   $toLon: Float!,
          $modes: [TransportMode!]!,
          $date: String!, $time: String!,
          $arriveBy: Boolean!,
          $walkReluctance: Float!,
          $bikeReluctance: Float!,
          $bikeOptimize: OptimizeType!,
          $triangle: InputTriangle,
          $bikeSpeed: Float!,
          $searchWindow: Long!
        ) {
          plan(
            from: { lat: $fromLat, lon: $fromLon }
            to:   { lat: $toLat,   lon: $toLon }
            transportModes: $modes
            date: $date
            time: $time
            arriveBy: $arriveBy
            walkReluctance: $walkReluctance
            bikeReluctance: $bikeReluctance
            optimize: $bikeOptimize
            triangle: $triangle
            bikeSpeed: $bikeSpeed
            numItineraries: 10
            searchWindow: $searchWindow
          ) {
            itineraries {
              duration
              walkDistance
              startTime
              endTime
              legs {
                mode
                startTime
                endTime
                distance
                realTime
                realtimeState
                arrivalDelay
                departureDelay
                # True when the leg is a Lime bikeshare rental. OTP keeps
                # `mode = BICYCLE` for these and uses this flag to mark
                # them; the iOS side reads `Leg.isRental` everywhere we
                # branch on rental-vs-own-bike.
                rentedBike
                from { name lat lon vertexType }
                to   { name lat lon vertexType }
                legGeometry { points }
                route { shortName longName }
                headsign
                steps {
                  distance
                  relativeDirection
                  absoluteDirection
                  streetName
                  lat
                  lon
                  # Per-step elevation samples from OTP's DEM, baked in
                  # at graph build time (`seattle_elevation.tif`).
                  # `distance` is meters from the start of THIS step
                  # (not the leg). The iOS side assembles a leg-level
                  # profile in `Leg.assembledElevationProfile`. May be
                  # null/empty for steps that exit DEM coverage; the
                  # client falls back to Open-Meteo in that case.
                  elevationProfile {
                    distance
                    elevation
                  }
                }
                intermediateStops {
                  name
                  lat
                  lon
                }
              }
            }
          }
        }
        """

        // Apply the Lime flavor to any BICYCLE entries when useLime is
        // on — converts bike-only into Lime-only, bike+transit into
        // Lime+transit. The override list (used by mid-trip reroutes)
        // gets the same treatment so a reroute on a Lime trip keeps
        // looking for rental bikes, not own-bike paths.
        let rawModes = transportModesOverride ?? mode.otpTransportModes
        let limeAdjustedModes: [[String: String]] = isLimeQuery
            ? rawModes.map { entry in
                guard entry["mode"] == "BICYCLE" else { return entry }
                var m = entry
                m["qualifier"] = "RENT"
                return m
            }
            : rawModes

        let body: [String: Any] = [
            "query": query,
            "variables": [
                "fromLat":  from.latitude, "fromLon": from.longitude,
                "toLat":    to.latitude,   "toLon":   to.longitude,
                "modes":    limeAdjustedModes,
                "date":     df.string(from: referenceDate),
                "time":     tf.string(from: referenceDate),
                "arriveBy": when.arriveBy,
                "walkReluctance": walkRel,
                "bikeReluctance": effectiveBikeRel,
                "bikeOptimize":   optimize,
                // Triangle weights must sum to 1.0. For standard bikes,
                // `effectiveTriangle` is the preference-derived triangle
                // (slope-heavy so OTP avoids steep blocks when a flatter
                // alternative exists). For e-bikes, it's overridden to a
                // quick-heavy triangle since hills aren't an effort
                // problem — see BikeKind.triangleOverride.
                "triangle":       effectiveTriangle,
                // Biking speed in m/s. Standard bikes use the user's
                // pace pick; e-bikes (own or rented Lime) use a fixed
                // motor-cruise speed, not rider-determined. `effectiveKind`
                // forces .electric on bikeshare queries so OTP plans the
                // rental ride at e-bike speed.
                "bikeSpeed":      effectiveKind.metersPerSecond(pace: bikePace),
                // Time window (seconds) in which OTP searches for valid
                // departures. OTP's dynamic default can be as short as
                // 30–60 min, which silently fails for sparse-frequency
                // routes — most notably WSF Fauntleroy-Vashon and the
                // King County Water Taxi, where the next bike-allowed
                // departure can be 60–90 min after the requested time.
                // 7200 s (2 hours) covers every ferry frequency on
                // Puget Sound while still keeping the result set
                // focused. Empirically: bike+transit Seattle→Vashon
                // returned empty under default; works with 7200.
                "searchWindow":   7200,
            ]
        ]

        var req = URLRequest(url: graphQLEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // 20 s covers normal plans (~1 s), a slow VM under load (~5 s), and
        // cold-cache pauses up to ~15 s. The URLSession.shared default of
        // 60 s lets a stalled OTP hang the UI for a full minute — long
        // enough that users assume the app is broken and force-quit.
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)

        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RoutingError.http(http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(PlanResponse.self, from: data)
            var its = decoded.data?.plan.itineraries ?? []
            if its.isEmpty { throw RoutingError.empty }
            // Tag bike-only results with the flavor of the query that produced
            // them. The UI uses this to badge "less effort" alternatives that
            // survive the climb-reduction filter in `planTrip()`.
            if mode == .bikeOnly {
                its = its.map {
                    var copy = $0
                    copy.bikeFlavor = bikePreference
                    return copy
                }
            }
            // Same idea for bike+transit: tag with the query flavor so the
            // boarding-stop-dedup merge can keep one per stop sequence and
            // the UI can badge "More bike" / "Less bike" alternatives. Only
            // tag when the caller passed a flavor — single-shot calls (e.g.
            // reroute) get a nil tag and don't render a badge.
            if mode == .bikeTransit, let flavor = bikeTransitFlavor {
                its = its.map {
                    var copy = $0
                    copy.transitFlavor = flavor
                    return copy
                }
            }
            // Cache successful, non-empty responses only. We deliberately
            // don't cache failures or empty results — we'd rather retry on
            // the next call than memoize a transient backend hiccup. Also
            // skip the cache when modes were overridden (see top of plan):
            // the cache key doesn't capture the override, so storing under
            // that key would poison future hits.
            if !bypassCache, transportModesOverride == nil {
                await ItineraryCache.shared.set(cacheKey, its)
            }
            return its
        } catch let e as RoutingError {
            throw e
        } catch {
            throw RoutingError.decode(error)
        }
    }
}
