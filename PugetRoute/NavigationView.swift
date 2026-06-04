import SwiftUI
import MapKit
import CoreLocation

/// Full-screen turn-by-turn navigation for a chosen itinerary.
///
/// Walk / bike legs get step-by-step directions that advance automatically as
/// the user gets within ~20m of the next step. Transit legs show a boarding /
/// alighting card; the user taps "I'm off" or it auto-advances once the
/// scheduled end time passes.
///
/// Off-route detection: while on a walk/bike leg, if the user is more than
/// ~60m from the leg polyline for several seconds, we call OTP again with the
/// same mode + preference and replace the remaining itinerary with a fresh
/// plan from the current GPS fix to the original destination.
struct TripNavigationView: View {
    // Passed in from ItineraryDetailView
    private let initialItinerary: Itinerary
    private let mode: TripMode
    private let preference: RoutePreference
    /// True when launched from a trip whose "from" isn't the user's
    /// current GPS location — there's nothing useful for live nav to
    /// track. In preview mode we skip the GPS subscription (so no
    /// startLiveUpdates, no battery cost), and the gating that already
    /// keys off `location.lastLocation` (recomputeLiveRemaining,
    /// tryAutoAdvance, off-route detection) naturally short-circuits.
    /// The user can still scrub through steps manually via the
    /// banner chevrons, see the route polyline on the map, and read
    /// the planned ETA on the bottom card.
    private let isPreview: Bool

    @Environment(\.dismiss) private var dismiss
    @StateObject private var location = LocationManager()

    /// Read from @AppStorage so it stays in sync with the same setting in
    /// PreferencesSheet — no need to plumb it through every call site that
    /// presents this view.
    @AppStorage("bikePace") private var bikePace: BikePace = .moderate

    /// Read alongside `bikePace`. For e-bikes we override pace with a
    /// fixed motor-cruise speed and use a smaller climb penalty per
    /// meter — the live ETA and any mid-trip reroute stamping respect
    /// both. See `BikeKind` in Models.swift.
    @AppStorage("bikeKind") private var bikeKind: BikeKind = .standard

    /// Mirror of ContentView's Lime-mode toggle. Read here so mid-trip
    /// reroutes stay on Lime when a Lime-mode trip goes off-route — if
    /// we re-planned at own-bike speed, the new route would route the
    /// rider as if they're suddenly on a personal bike.
    @AppStorage("useLime") private var useLime: Bool = false

    /// Mutable so auto-reroute can replace it mid-trip.
    @State private var itinerary: Itinerary
    @State private var currentLegIndex: Int = 0
    @State private var currentStepIndex: Int = 0
    @State private var now: Date = Date()

    /// Live remaining seconds, recomputed each tick from arc-length-to-end of
    /// the polyline at the user's current snap point. Falls back to the
    /// itinerary's static endDate when we don't yet have a fix or when the
    /// active leg is transit (transit duration is governed by the schedule,
    /// not by user pace). Cached on `@State` so the bottom card and ETA
    /// re-render in lockstep without doing the geometry twice.
    @State private var liveRemainingSeconds: TimeInterval? = nil

    /// Live remaining distance to destination, in meters — active leg's
    /// arc-length from the snap point onward plus every future leg's
    /// full distance. Set alongside `liveRemainingSeconds`; nil when
    /// there's no live computation (transit leg, no GPS fix, past arrival).
    @State private var liveRemainingMeters: Double? = nil

    /// Live remaining for just the *current* leg. In multi-leg trips
    /// the bottom card's `X min · Y mi` chip shows these so the rider
    /// sees "until I catch the bus" instead of "total trip duration."
    /// `Arriving 3:45 PM` on the right still tracks the whole trip end.
    /// Seconds are live for bike/walk (arc-length ÷ pace) and fall
    /// back to schedule (`leg.endTime - now`) for transit. Meters are
    /// nil on transit / pre-fix and the chip suppresses itself then.
    @State private var liveActiveLegSeconds: TimeInterval? = nil
    @State private var liveActiveLegMeters: Double? = nil

    /// Last known progress along the active leg's polyline, expressed as the
    /// vertex index of the closest point. Monotonic — only advances forward —
    /// so a brief GPS burp that places the user "earlier" along the line
    /// doesn't flip a step from done back to pending. Resets on leg change.
    @State private var legProgressIndex: Int = 0

    /// Tick counter so we can run battery-expensive checks (off-route
    /// distance-to-polyline, live-ETA recomputation) on a sub-rate of the 1s
    /// timer instead of every tick. Off-route runs every 3 ticks; live ETA
    /// runs every tick because it's cheap (one vertex lookup).
    @State private var tickCount: Int = 0

    /// Last camera target we actually applied. Suppresses redundant
    /// `setCamera` calls when the user is standing still — those were the
    /// biggest battery drain in profiling.
    @State private var lastAppliedCameraCoord: CLLocationCoordinate2D? = nil
    @State private var lastAppliedHeading: CLLocationDirection = -1

    /// Consecutive ticks (~1s each) the user has been > offRouteThreshold m
    /// from the active leg polyline. We wait a few ticks before triggering
    /// a reroute to avoid GPS jitter.
    @State private var offRouteStreak: Int = 0
    @State private var isRerouting: Bool = false
    @State private var rerouteCount: Int = 0
    @State private var lastRerouteAt: Date? = nil

    /// Bike racks near the trip's final destination, fetched once at
    /// startup. The map only renders them when the user gets close
    /// enough that they're about to need to lock up (see
    /// `racksVisibleProximityMeters` below). Empty array on Lime
    /// trips (user drops the rental within the geofence; doesn't need
    /// own-bike parking) and on trips with no bike leg at all.
    @State private var nearbyDestinationRacks: [BikeRack] = []

    /// Show the rack pins once the user is within this distance of
    /// the trip's final destination. Short enough that the racks
    /// don't clutter the map for most of the ride; far enough back
    /// that the rider sees them with time to plan where to lock up.
    private let racksVisibleProximityMeters: Double = 300

    /// Only fetch racks within this radius of the destination. Riders
    /// want to lock up close, not walk 200m from a rack to their
    /// actual destination. Matches the `primaryRadius` in
    /// BikeRackService.
    private let racksFetchRadiusMeters: Int = 150

    /// Camera-follow state. True = first-person follow (the default during
    /// navigation). Flipped to false by the map view when the user
    /// pinches/pans/rotates manually, and back to true by the recenter
    /// button. While false, location/heading updates do NOT touch the
    /// camera, so a manual zoom-out stays put.
    @State private var isFollowingUser: Bool = true

    private let offRouteThresholdMeters: Double = 60
    private let offRouteStreakToReroute: Int = 6      // ≈6 sec of drift
    private let minSecondsBetweenReroutes: Double = 15

    /// How often we refresh the realtime delay/cancellation fields on the
    /// trip's transit legs. 30 s is brisk enough that a "running 4 min
    /// late" update lands well before the user gets to the stop, and
    /// slack enough that we're not slamming OTP from the nav screen.
    private let realtimeRefreshIntervalSeconds: Double = 30
    @State private var lastRealtimeRefreshAt: Date? = nil
    @State private var isRefreshingRealtime: Bool = false

    /// The trip-level origin used for the *initial* plan. We re-issue the
    /// same plan call for realtime refreshes so OTP returns itineraries
    /// shaped enough like our original to match by boarding-stop sequence.
    /// Captured on init from the first leg's start coordinate.
    private let originForRealtimeRefresh: CLLocationCoordinate2D

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(
        itinerary: Itinerary,
        mode: TripMode,
        preference: RoutePreference,
        isPreview: Bool = false
    ) {
        self.initialItinerary = itinerary
        self.mode = mode
        self.preference = preference
        self.isPreview = isPreview
        self._itinerary = State(initialValue: itinerary)
        self.originForRealtimeRefresh = itinerary.legs.first?.from.coordinate
            ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }

    /// The final destination — the last leg's endpoint. Used to replan on
    /// off-route. Captured from the current itinerary; stays consistent across
    /// reroutes because we always replan to this coordinate.
    private var finalDestination: CLLocationCoordinate2D {
        itinerary.legs.last?.to.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }

    /// Racks to render on the live nav map right now. Empty unless the
    /// user is within `racksVisibleProximityMeters` of the trip's
    /// final destination — that's when "where do I lock up" becomes a
    /// useful question. Also empty in Lime mode and on transit-only
    /// trips (handled by the .task fetch never populating
    /// `nearbyDestinationRacks` in those cases).
    private var racksToDisplay: [BikeRack] {
        guard !nearbyDestinationRacks.isEmpty,
              let user = location.lastLocation,
              let dest = itinerary.legs.last?.to.coordinate else { return [] }
        let d = user.distance(from: CLLocation(latitude: dest.latitude, longitude: dest.longitude))
        return d <= racksVisibleProximityMeters ? nearbyDestinationRacks : []
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationMapView(
                itinerary: itinerary,
                userLocation: location.lastLocation,
                heading: location.heading,
                currentLegIndex: currentLegIndex,
                bikeRacks: racksToDisplay,
                isFollowing: $isFollowingUser
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                rerouteBanner
                instructionBanner
                Spacer()
                // Recenter button — only visible when the user has zoomed/
                // panned away from the first-person camera. Tapping it
                // flips follow back on and the next location update snaps
                // the map back to first-person.
                //
                // Anchored just above the bottom card (rather than the
                // top-right) so it stays well clear of the instruction
                // banner, which can grow tall on multi-line maneuvers
                // and was hiding the button in earlier versions.
                if !isFollowingUser {
                    HStack {
                        Spacer()
                        Button {
                            isFollowingUser = true
                        } label: {
                            Image(systemName: "location.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.accentColor, in: Circle())
                                .shadow(radius: 3)
                        }
                        .accessibilityLabel("Recenter on me")
                    }
                    .transition(.opacity)
                }
                bottomCard
            }
            .padding()
        }
        .animation(.easeInOut(duration: 0.2), value: isFollowingUser)
        .onAppear {
            // Preview mode: don't request location permission and don't
            // start the GPS updates. Everything that depends on a live
            // fix (recomputeLiveRemaining, tryAutoAdvance, off-route
            // detection) already gates on location.lastLocation being
            // non-nil, so leaving it nil cleanly degrades the view into
            // a static read of the planned route.
            if !isPreview {
                location.requestWhenInUse()
                location.startLiveUpdates()
            }
        }
        .onDisappear {
            if !isPreview {
                location.stopLiveUpdates()
            }
        }
        // Fetch bike racks near the trip's final destination, once,
        // at start of nav. We don't refresh — destination is fixed
        // for the trip, and the rack data only changes on graph
        // rebuilds. Skipped for Lime trips and for trips with no
        // own-bike leg (transit-only).
        .task {
            guard !useLime,
                  itinerary.legs.contains(where: { $0.mode == "BICYCLE" }),
                  let dest = itinerary.legs.last?.to.coordinate else { return }
            nearbyDestinationRacks = await BikeRackService.fetchAt(
                dest, radius: racksFetchRadiusMeters
            )
        }
        .onReceive(ticker) { t in
            now = t
            tickCount &+= 1
            // Auto-advance + live ETA every tick — both are cheap (one vertex
            // lookup along the active leg's polyline). Off-route detection
            // runs every 3 ticks: it scans every segment of the active leg's
            // polyline, which is the single most expensive thing per second
            // and benefits the most from sub-rate throttling.
            tryAutoAdvance()
            recomputeLiveRemaining()
            if tickCount % 3 == 0 {
                tryReroute()
            }
            // Pull fresh realtime delay/cancellation info for the trip's
            // transit legs. Crucially this NEVER replaces the bus or the
            // boarding stop — it only copies arrivalDelay / departureDelay /
            // realtimeState onto the legs we already have. See
            // refreshRealtimeForTransitLegs() for the matching rules.
            tryRefreshRealtime()
        }
        // Reset progress + ETA cache when the active leg changes, so a new
        // leg doesn't inherit a vertex index from the old one's polyline.
        .onChange(of: currentLegIndex) { _, _ in
            legProgressIndex = 0
            recomputeLiveRemaining()
        }
    }

    // MARK: - Current references

    private var currentLeg: Leg? {
        guard itinerary.legs.indices.contains(currentLegIndex) else { return nil }
        return itinerary.legs[currentLegIndex]
    }

    private var currentStep: WalkStep? {
        guard let leg = currentLeg,
              let steps = leg.steps,
              steps.indices.contains(currentStepIndex) else { return nil }
        return steps[currentStepIndex]
    }

    /// The maneuver the user is currently *approaching* — i.e., the next
    /// step's instruction that they'll execute when they cross its anchor.
    /// This is what belongs in the navigation banner: "turn right onto
    /// Pine St in 200 ft" reads correctly when shown *before* the turn,
    /// then advances to the next maneuver the moment they execute it.
    ///
    /// Showing `currentStep` instead would always be one step late — by
    /// the time `tryAutoAdvance()` fires `advance()`, the user has just
    /// crossed the maneuver point and is now executing it; describing
    /// that maneuver is describing the past, not the future.
    ///
    /// Nil at the end of a leg (no more steps remaining); the banner
    /// falls back to "Continue to {destination}" in that case.
    private var upcomingStep: WalkStep? {
        guard let leg = currentLeg,
              let steps = leg.steps else { return nil }
        let next = currentStepIndex + 1
        return steps.indices.contains(next) ? steps[next] : nil
    }

    /// Where the next maneuver happens. For walk/bike, it's the next step's
    /// location; for the last step or transit legs, it's the leg's end.
    private var nextManeuverCoord: CLLocationCoordinate2D? {
        guard let leg = currentLeg else { return nil }
        if let steps = leg.steps, steps.indices.contains(currentStepIndex + 1) {
            return steps[currentStepIndex + 1].coordinate
        }
        return leg.to.coordinate
    }

    private var distanceToNextManeuver: CLLocationDistance? {
        guard let user = location.lastLocation, let target = nextManeuverCoord else { return nil }
        return user.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
    }

    // MARK: - Reroute banner

    @ViewBuilder
    private var rerouteBanner: some View {
        if isRerouting {
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Rerouting…")
                    .font(.subheadline).bold()
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.orange, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 2)
            .transition(.opacity)
        }
    }

    // MARK: - Banner (next instruction)

    @ViewBuilder
    private var instructionBanner: some View {
        if let leg = currentLeg {
            if leg.isTransit {
                transitBanner(leg: leg)
            } else {
                walkBikeBanner(leg: leg)
            }
        } else {
            arrivedBanner
        }
    }

    private func walkBikeBanner(leg: Leg) -> some View {
        // Banner shows the *upcoming* maneuver, not the one the user is
        // currently traversing. See `upcomingStep` for the rationale.
        // Two fallbacks for when no upcoming step exists:
        //   - End of leg with steps: "Continue to {destination}" — they
        //     just crossed the last turn and are heading to the leg's
        //     end (transit stop, final destination, etc.).
        //   - No steps at all (rare): generic start-bike/walk hint.
        let icon: String
        let instruction: String
        if let step = upcomingStep {
            icon = step.icon
            instruction = step.instruction
        } else if let steps = leg.steps, !steps.isEmpty {
            icon = "flag.checkered"
            let dest = leg.to.name.isEmpty ? "destination" : leg.to.name
            instruction = "Continue to \(dest)"
        } else if leg.isRental {
            // Rental legs open with "pick up the bike" rather than the
            // generic "Start biking" — the user needs to find and unlock
            // a Lime before they're actually riding. After they've
            // started moving, upcomingStep takes over with the real
            // turn-by-turn directions.
            icon = "bicycle"
            instruction = "Pick up a Lime bike here"
        } else {
            icon = leg.mode == "BICYCLE" ? "bicycle" : "figure.walk"
            instruction = leg.mode == "BICYCLE" ? "Start biking" : "Start walking"
        }
        return HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.largeTitle).bold()
                .foregroundColor(.white)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(instruction)
                    .font(.title3).bold()
                    .foregroundColor(.white)
                    .lineLimit(2)
                if let d = distanceToNextManeuver {
                    Text(formatMeters(d)).font(.subheadline).foregroundColor(.white.opacity(0.85))
                }
                // Show the next maneuver inline so the user can glance once
                // and know what's coming up after this turn — much friendlier
                // for handlebar-mounted phones than a single-line banner.
                if let preview = nextStepPreview {
                    Divider().background(Color.white.opacity(0.35)).padding(.vertical, 2)
                    HStack(spacing: 6) {
                        Image(systemName: preview.icon)
                            .font(.caption).bold()
                            .foregroundColor(.white.opacity(0.9))
                        Text("Then: \(preview.text)")
                            .font(.caption).foregroundColor(.white.opacity(0.9))
                            .lineLimit(2)
                    }
                }
                // If next leg is transit, hint at boarding so the user knows
                // where this walk/bike is taking them.
                if let next = nextTransitLeg {
                    Text("Then board \(next.displayName) at \(next.from.name)")
                        .font(.caption).foregroundColor(.white.opacity(0.8))
                        .lineLimit(2)
                }
                // Step navigator — co-located with the step text now so
                // the chevrons read as "advance/rewind THIS step" rather
                // than a generic trip control buried at the bottom of
                // the screen. Auto-advance is still the primary
                // mechanism; these are the manual nudge when GPS drifts
                // or the user wants to peek ahead.
                bannerStepControls(for: leg)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 4)
    }

    /// The maneuver one step *beyond* the upcoming one shown in the
    /// banner. Used to render the "Then: X" preview row so the rider
    /// can glance once and know what's coming up *after* the next turn
    /// — useful for handlebar-mounted phones where you can't easily
    /// scroll for more context.
    ///
    /// Indexes at `currentStepIndex + 2` because the banner already
    /// shows `currentStepIndex + 1` (see `upcomingStep`); preview is
    /// the one after that. Falls back across the leg boundary when the
    /// current leg has no further steps — e.g., the upcoming step is
    /// "arrive at X" and the next leg is a transit board, so we show
    /// "Then: board the X bus."
    private var nextStepPreview: (icon: String, text: String)? {
        if let leg = currentLeg, let steps = leg.steps,
           steps.indices.contains(currentStepIndex + 2) {
            let s = steps[currentStepIndex + 2]
            return (s.icon, s.instruction)
        }
        // Cross-leg fallback
        let after = currentLegIndex + 1
        guard itinerary.legs.indices.contains(after) else { return nil }
        let next = itinerary.legs[after]
        if next.isTransit {
            return ("tram.fill", "Board \(next.displayName)")
        }
        if let firstStep = next.steps?.first {
            return (firstStep.icon, firstStep.instruction)
        }
        return (next.mode == "BICYCLE" ? "bicycle" : "figure.walk",
                next.mode == "BICYCLE" ? "Start biking" : "Start walking")
    }

    /// Transit banner: top row = board info, bottom row = alight info.
    /// The user wants to know both *where to catch it* and *where to get off*.
    private func transitBanner(leg: Leg) -> some View {
        // Brand-driven palette: every text/icon on this banner reads
        // its color from `leg.transitBrand.textColor` (white for most
        // brand backgrounds, black for STRIDE yellow / Sounder
        // lavender). The dimmer secondary labels use `.opacity(0.85)`
        // off the same base.
        let textColor = leg.transitBrand.textColor
        return VStack(alignment: .leading, spacing: 10) {
            // --- Board row ---
            HStack(spacing: 14) {
                Image(systemName: transitIcon(leg.mode))
                    .font(.largeTitle).bold()
                    .foregroundColor(textColor)
                    .frame(width: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Board \(leg.displayName)")
                        .font(.headline).bold().foregroundColor(textColor)
                        .lineLimit(2)
                    Text("at \(leg.from.name)")
                        .font(.caption).foregroundColor(textColor.opacity(0.85))
                        .lineLimit(2)
                    Text(boardCountdown(leg: leg))
                        .font(.subheadline).bold().foregroundColor(textColor)
                }
                Spacer()
            }

            Divider().background(textColor.opacity(0.35))

            // --- Alight row ---
            HStack(spacing: 14) {
                Image(systemName: "figure.walk.arrival")
                    .font(.title2).bold()
                    .foregroundColor(textColor)
                    .frame(width: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get off at")
                        .font(.caption).foregroundColor(textColor.opacity(0.85))
                    Text(leg.to.name)
                        .font(.headline).bold().foregroundColor(textColor)
                        .lineLimit(2)
                    Text("arriving \(leg.effectiveEndTimeString)")
                        .font(.caption).foregroundColor(textColor.opacity(0.85))
                }
                Spacer()
            }

            // Step navigator at the bottom of the transit banner. Same
            // role as on the walk/bike banner — manual nudge for legs
            // whose auto-advance is stuck (e.g. a bus reporting past
            // scheduled end while still in transit).
            bannerStepControls(for: leg)
        }
        .padding(14)
        .background(leg.transitBrand.color, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 4)
    }

    private var arrivedBanner: some View {
        HStack {
            Image(systemName: "flag.checkered").font(.largeTitle).foregroundColor(.white)
            Text("You've arrived").font(.title2).bold().foregroundColor(.white)
            Spacer()
        }
        .padding(14)
        .background(Color.green, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 4)
    }

    /// Next transit leg after the current one (if any), so walk/bike banners
    /// can hint at what's coming up.
    private var nextTransitLeg: Leg? {
        let after = currentLegIndex + 1
        guard itinerary.legs.indices.contains(after) else { return nil }
        return itinerary.legs[after..<itinerary.legs.count].first(where: { $0.isTransit })
    }

    // MARK: - Bottom card

    private var bottomCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: bottomCardLeadingIcon)
                    .font(.title3).bold()
                Text(remainingTimeString)
                    .font(.title3).bold()
                    .monospacedDigit()
                if let dist = remainingDistanceString {
                    Text("·")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text(dist)
                        .font(.title3).bold()
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("Arriving \(arrivalTimeString)")
                    .font(.subheadline).foregroundColor(.secondary)
            }

            // Live countdown to the next transit boarding, shown only
            // while the rider is on a walk/bike leg heading toward one.
            // `boardCountdown` uses `leg.startTime` (realtime-adjusted by
            // OTP at plan time) and re-renders on every `now` tick.
            if let next = nextTransitLeg,
               let cur = currentLeg, !cur.isTransit {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: transitIcon(next.mode))
                        .font(.subheadline).bold()
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(next.displayName) \(boardCountdown(leg: next))")
                            .font(.subheadline).bold()
                            .lineLimit(2)
                        Text("Board at \(next.from.name)")
                            .font(.caption).foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }

            // Suppressed for bike legs — the top instruction banner
            // already shows the mode/icon, so a second "Bicycle" row
            // here is just clutter. Transit and walk legs still render
            // because their displayName ("D Line → Ballard Uptown",
            // "Walk to NW Market St & 24th Ave NW") carries info the
            // top banner doesn't repeat in the same form.
            if let leg = currentLeg, leg.mode != "BICYCLE", leg.mode != "BICYCLE_RENT" {
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: leg.mode))
                        .foregroundColor(.secondary)
                    Text(leg.displayName)
                        .font(.caption).bold()
                        .lineLimit(1)
                    Spacer()
                    // Manual step chevrons used to live here. They now
                    // render inside the instruction banner at the top
                    // (see `bannerStepControls` and its usage in
                    // walkBikeBanner / transitBanner) so they're
                    // co-located with the step text the user is
                    // actually navigating. Behavior unchanged — same
                    // goBack() / advance() handlers, same cross-leg
                    // boundary semantics.
                }
            }

            // Only End here — navigation auto-advances as the user
            // physically moves past each maneuver (walk/bike) or
            // reaches the alighting stop (transit), so a manual
            // advance button isn't needed. Manual reroute is also
            // gone from this row; off-route detection still triggers
            // `manualReroute()` automatically when the user drifts
            // too far from the active leg's polyline.
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("End")
                        .font(.subheadline).bold()
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color(.systemGray5), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 4)
    }

    // MARK: - Manual step controls

    /// Chevron pair flanking the step counter, rendered inside the
    /// colored instruction banner at the top of the screen.
    ///
    /// Manual step controls used to live in the bottom card next to
    /// the leg icon, but that placement disconnected them from the
    /// step text the user is actually navigating. Co-locating them
    /// here makes the chevrons read as "advance/rewind THIS step"
    /// rather than a generic trip control.
    ///
    /// Auto-advance is still the primary mechanism — these are the
    /// manual nudge when GPS drifts or the user wants to peek ahead.
    /// Wired through `goBack()` / `advance()` so they cross leg
    /// boundaries the same way auto progression does.
    ///
    /// Styled with white text/icons and 35%/90% opacity for
    /// disabled/enabled so the controls read clearly against the
    /// blue (walk/bike) or purple (transit) banner backgrounds
    /// without competing with the primary instruction text.
    @ViewBuilder
    private func bannerStepControls(for leg: Leg) -> some View {
        HStack(spacing: 10) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline).bold()
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAtFirstStep)
            .opacity(isAtFirstStep ? 0.35 : 0.9)
            .accessibilityLabel("Previous step")

            Button {
                advance()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline).bold()
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAtLastStep)
            .opacity(isAtLastStep ? 0.35 : 0.9)
            .accessibilityLabel("Next step")
        }
    }

    /// True when there is no earlier step to return to anywhere in the
    /// trip — i.e., we're at step 0 of leg 0.
    private var isAtFirstStep: Bool {
        currentLegIndex == 0 && currentStepIndex == 0
    }

    /// True when there's no later step. For the last leg, that's the
    /// final step (or just being on the last leg if it has no steps).
    /// For earlier legs, there's always a next leg to advance into, so
    /// this returns false.
    private var isAtLastStep: Bool {
        let lastLegIdx = itinerary.legs.count - 1
        guard currentLegIndex >= lastLegIdx else { return false }
        guard let leg = currentLeg else { return true }
        let stepCount = leg.steps?.count ?? 0
        if stepCount == 0 { return true }
        return currentStepIndex >= stepCount - 1
    }

    // MARK: - Advance logic (auto + manual)

    private func advance() {
        guard let leg = currentLeg else { return }
        if !leg.isTransit,
           let steps = leg.steps,
           currentStepIndex + 1 < steps.count {
            currentStepIndex += 1
            return
        }
        // Advance to next leg
        currentStepIndex = 0
        currentLegIndex += 1
        offRouteStreak = 0
    }

    /// Symmetric to `advance()`. Walks the step pointer back one within
    /// the current leg, or into the last step of the previous leg at a
    /// leg boundary. Manual-only — auto progression never calls this.
    /// Resets `offRouteStreak` to avoid an immediate reroute right after
    /// the user manually stepped backward.
    private func goBack() {
        if currentStepIndex > 0 {
            currentStepIndex -= 1
            offRouteStreak = 0
            return
        }
        // At step 0 of the current leg → fall back into the previous leg.
        guard currentLegIndex > 0 else { return }
        currentLegIndex -= 1
        let prev = itinerary.legs[currentLegIndex]
        if let steps = prev.steps, !steps.isEmpty {
            currentStepIndex = steps.count - 1
        } else {
            currentStepIndex = 0
        }
        offRouteStreak = 0
    }

    /// Auto-advance once the user has physically progressed past
    /// the current maneuver (walk/bike) or the alighting stop
    /// (transit). Time is never the trigger — we don't auto-advance
    /// just because clock time says a bus "should have" arrived.
    /// That used to be the transit-leg trigger but caused the
    /// "tap GO after the plan's original start time → rapid-fire
    /// through every stale leg in a single tick" bug. Location-only
    /// means the user is always in control: their phone has to have
    /// actually moved past the relevant point to advance.
    ///
    /// Progression uses monotonic polyline-snap rather than raw
    /// "within 20m of the next maneuver point." The old proximity
    /// check fired inconsistently — at intersections where multiple
    /// steps share a corner, a 20m radius matches the *current*
    /// maneuver and the *next* one simultaneously, so the banner
    /// would skip a step or stay stuck. Snapping the GPS fix to the
    /// closest vertex on the leg polyline and only advancing when
    /// that vertex passes the next step's anchor gives a stable
    /// "you are here" reading that progresses one step at a time.
    private func tryAutoAdvance() {
        guard let leg = currentLeg else { return }
        guard let user = location.lastLocation else { return }
        // GPS quality cutoff — a 100m ±accuracy reading would snap to
        // the wrong vertex and false-advance through several steps.
        // Transit legs get a slightly looser bound (50m vs 35m for
        // walk/bike) because the phone is inside a vehicle and the
        // signal is typically noisier; we still reject obviously
        // bad fixes.
        let accuracyCap: CLLocationDistance = leg.isTransit ? 50 : 35
        guard user.horizontalAccuracy > 0,
              user.horizontalAccuracy < accuracyCap else { return }

        let pts = PolylineDecoder.decode(leg.legGeometry.points)
        guard pts.count >= 2 else { return }
        let snap = closestVertex(to: user.coordinate, polyline: pts)
        // Monotonic — never move backwards along the polyline. A momentary
        // GPS jitter that puts us "earlier" doesn't undo a real maneuver.
        if snap > legProgressIndex { legProgressIndex = snap }

        if leg.isTransit {
            // For transit, the "maneuvers" are just board (already
            // past, by definition of being on this leg) and alight
            // (the leg's endpoint). Advance once the user is at or
            // past the last vertex of the bus's polyline.
            let endIdx = pts.count - 1
            if legProgressIndex >= endIdx - 1 {
                advance()
            }
            return
        }

        // Walk/bike — find the polyline index nearest to the next step's
        // anchor; once our progress is past that, the user has visibly
        // moved through that maneuver and we advance.
        guard let steps = leg.steps,
              steps.indices.contains(currentStepIndex + 1) else {
            // No more steps in this leg — fall back to "near the leg endpoint."
            let endIdx = pts.count - 1
            if legProgressIndex >= endIdx - 1 {
                advance()
            }
            return
        }
        let nextAnchor = steps[currentStepIndex + 1].coordinate
        let nextIdx = closestVertex(to: nextAnchor, polyline: pts)
        if legProgressIndex >= nextIdx {
            advance()
        }
    }

    /// Index of the polyline vertex closest to `coord`. O(n) but n is small
    /// (a few hundred vertices for the longest legs we plan).
    private func closestVertex(
        to coord: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> Int {
        var bestIdx = 0
        var bestD2 = Double.infinity
        // Squared planar distance is fine for "which vertex is closest"
        // — we don't need true meters, just a comparable number.
        for (i, p) in polyline.enumerated() {
            let dx = p.latitude - coord.latitude
            let dy = p.longitude - coord.longitude
            let d2 = dx * dx + dy * dy
            if d2 < bestD2 { bestD2 = d2; bestIdx = i }
        }
        return bestIdx
    }

    /// Recompute the live remaining-time estimate, used by the bottom card.
    ///
    /// For walk/bike legs we have a real-time pace and a real-time position,
    /// so we compute remaining seconds = remaining-arc-length-of-active-leg /
    /// pace + sum-of-still-to-come-leg-durations. For transit legs the
    /// schedule governs duration, so we just use the static itinerary
    /// endDate. This keeps the user honest: a faster rider sees the ETA
    /// drop faster, a slower one sees it linger.
    private func recomputeLiveRemaining() {
        guard let leg = currentLeg else {
            // Past the last leg — clear the override and let the static
            // endDate take over.
            liveRemainingSeconds = nil
            liveRemainingMeters = nil
            liveActiveLegSeconds = nil
            liveActiveLegMeters = nil
            return
        }
        guard !leg.isTransit, let user = location.lastLocation else {
            liveRemainingSeconds = nil
            liveRemainingMeters = nil
            liveActiveLegSeconds = nil
            liveActiveLegMeters = nil
            return
        }
        let pts = PolylineDecoder.decode(leg.legGeometry.points)
        guard pts.count >= 2 else {
            liveRemainingSeconds = nil
            liveRemainingMeters = nil
            liveActiveLegSeconds = nil
            liveActiveLegMeters = nil
            return
        }
        let snap = closestVertex(to: user.coordinate, polyline: pts)
        // Sum arc length from the snap point through the rest of the leg.
        var remainingMeters = 0.0
        for i in snap..<(pts.count - 1) {
            let a = CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude)
            let b = CLLocation(latitude: pts[i + 1].latitude, longitude: pts[i + 1].longitude)
            remainingMeters += a.distance(from: b)
        }
        // Off-route floor: `closestVertex` picks the geographically nearest
        // polyline vertex, which on final approach can be the leg's end
        // vertex even when the user still has meaningful distance to go
        // (route curves back near itself, or user shortcuts across the
        // planned path). In that case the arc-length sum above is ~0 and
        // the bottom card flashes "0 min" while the user is still 800 m
        // out. Clamping remainingMeters to ≥ crow-flies distance to the
        // leg's destination fixes that without breaking the on-route
        // case (on a curved route, arc-length ≥ crow-flies by definition,
        // so max() is a no-op when the snap is correct).
        let crowFliesToEnd = user.distance(from: CLLocation(
            latitude: leg.to.lat, longitude: leg.to.lon
        ))
        remainingMeters = max(remainingMeters, crowFliesToEnd)
        // Bike legs go through `ElevationService.bikeLegDuration` so
        // every term in the duration model (pace, climb, signals,
        // stops, yields) stays in lockstep with what the planner
        // stamped. Walk legs use a fixed brisk-walk speed — we
        // don't ask the user for their walking pace.
        let isBikeLeg = leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT"
        var activeSecs: Double
        if isBikeLeg {
            // Rental legs (Lime) force `.electric` regardless of
            // the user's BikeKind — Lime in Seattle is e-bike-only.
            let effectiveKind: BikeKind = leg.isRental ? .electric : bikeKind
            let totalMeters = max(leg.distance, 0)
            let fraction = totalMeters > 0
                ? min(1.0, max(0.0, remainingMeters / totalMeters))
                : 1.0
            let remainingClimb = max(0, (leg.climbMeters ?? 0) * fraction)
            // Scale intersection seconds by the same fraction —
            // signals are roughly uniformly distributed along the
            // polyline, the same approximation we already accept
            // for the climb scaling above.
            let intersectionSecs = ElevationService.intersectionSeconds(
                forLeg: leg, scaledBy: fraction
            )
            activeSecs = ElevationService.bikeLegDuration(
                distance: remainingMeters,
                climb: remainingClimb,
                intersectionSeconds: intersectionSecs,
                pace: bikePace,
                kind: effectiveKind
            )
        } else {
            activeSecs = remainingMeters / 1.4   // ≈ 5 km/h walk
        }

        // Walk forward through the remaining legs, computing each
        // leg's predicted wall-clock end time. Transit legs are
        // anchored to their realtime-adjusted schedule, which
        // *absorbs early arrivals as wait time at the boarding
        // stop* — without this, summing raw per-leg durations
        // dropped the wait gap entirely and the countdown read
        // shorter than `itinerary.endDate - now` by however much
        // wait was at upcoming stops. That mismatch was the
        // "live nav flashes a different number the moment GPS
        // lands" bug.
        var predictedEnd = now.addingTimeInterval(activeSecs)
        var futureMeters = 0.0
        for futureLeg in itinerary.legs.dropFirst(currentLegIndex + 1) {
            futureMeters += futureLeg.distance
            if futureLeg.isTransit {
                let scheduledStart = futureLeg.effectiveStartDate
                let scheduledEnd   = futureLeg.effectiveEndDate
                if predictedEnd <= scheduledStart {
                    // User arrives on time (or early — they wait at
                    // the stop). Transit holds its schedule; trip
                    // resumes at the realtime-adjusted alight time.
                    predictedEnd = scheduledEnd
                } else {
                    // User is late and would miss this connection.
                    // We don't currently re-plan, so just charge the
                    // transit's nominal duration on top of where the
                    // user actually is — keeps the countdown
                    // non-zero rather than pretending we caught a
                    // bus we didn't.
                    let dur = scheduledEnd.timeIntervalSince(scheduledStart)
                    predictedEnd = predictedEnd.addingTimeInterval(dur)
                }
                continue
            }
            // Bike/walk: forward from predictedEnd.
            let legSecs: Double
            let isFutureBike = futureLeg.mode == "BICYCLE" || futureLeg.mode == "BICYCLE_RENT"
            if isFutureBike {
                let effectiveKind: BikeKind = futureLeg.isRental ? .electric : bikeKind
                let intersectionSecs = ElevationService.intersectionSeconds(forLeg: futureLeg)
                legSecs = ElevationService.bikeLegDuration(
                    distance: futureLeg.distance,
                    climb: futureLeg.climbMeters ?? 0,
                    intersectionSeconds: intersectionSecs,
                    pace: bikePace,
                    kind: effectiveKind
                )
            } else {
                legSecs = futureLeg.distance / 1.4   // ≈ 5 km/h walk
            }
            predictedEnd = predictedEnd.addingTimeInterval(legSecs)
        }
        liveRemainingSeconds = max(0, predictedEnd.timeIntervalSince(now))
        liveRemainingMeters = remainingMeters + futureMeters
        liveActiveLegSeconds = activeSecs
        liveActiveLegMeters = remainingMeters
    }

    // MARK: - Off-route detection

    /// Distance from the user to the nearest point on the active leg's
    /// polyline, in meters. Uses proper point-to-segment distance (not just
    /// vertex-to-vertex) since OTP sometimes thins out straight stretches.
    private func distanceToActiveLeg(from user: CLLocation) -> CLLocationDistance? {
        guard let leg = currentLeg else { return nil }
        let pts = PolylineDecoder.decode(leg.legGeometry.points)
        return Self.distanceToPolyline(user.coordinate, polyline: pts)
    }

    private func tryReroute() {
        guard !isRerouting else { return }
        guard let leg = currentLeg, !leg.isTransit else {
            offRouteStreak = 0
            return
        }
        guard let user = location.lastLocation else { return }
        // Require decent GPS accuracy — a ±100m fix will falsely trigger
        // off-route every time.
        guard user.horizontalAccuracy > 0, user.horizontalAccuracy < 35 else { return }
        // Debounce repeated reroutes
        if let last = lastRerouteAt, Date().timeIntervalSince(last) < minSecondsBetweenReroutes {
            return
        }

        guard let d = distanceToActiveLeg(from: user) else { return }
        if d > offRouteThresholdMeters {
            offRouteStreak += 1
            if offRouteStreak >= offRouteStreakToReroute {
                performReroute(from: user.coordinate)
            }
        } else {
            offRouteStreak = 0
        }
    }

    private func manualReroute() {
        guard !isRerouting, let user = location.lastLocation else { return }
        performReroute(from: user.coordinate)
    }

    // MARK: - Realtime refresh (transit-only, no bus swap)

    /// Periodically re-query OTP and fold any fresh delay / cancellation info
    /// onto the trip's existing transit legs. Never changes the bus, the
    /// boarding stop, or anything else about the trip — only the four
    /// realtime fields (`realTime`, `realtimeState`, `arrivalDelay`,
    /// `departureDelay`) are copied over, and only when the candidate
    /// itinerary's transit-leg sequence matches our current one by
    /// (route shortName, normalized boarding-stop name).
    ///
    /// Why re-issue the full plan instead of a per-leg query: OTP doesn't
    /// expose a clean "give me just the realtime status of this scheduled
    /// trip" hook in the GraphQL endpoint we're using. The plan() call is
    /// idempotent and cached upstream of the realtime layer, so the cost
    /// is small once the network round-trip is paid.
    private func tryRefreshRealtime() {
        guard !isRefreshingRealtime else { return }
        // Skip if no transit legs in this trip — nothing to refresh.
        guard itinerary.legs.contains(where: { $0.isTransit }) else { return }
        // Throttle to the configured interval.
        if let last = lastRealtimeRefreshAt,
           Date().timeIntervalSince(last) < realtimeRefreshIntervalSeconds {
            return
        }
        lastRealtimeRefreshAt = Date()
        refreshRealtimeForTransitLegs()
    }

    private func refreshRealtimeForTransitLegs() {
        isRefreshingRealtime = true
        let originSnap = originForRealtimeRefresh
        let destSnap = finalDestination
        let modeSnap = mode
        let prefSnap = preference
        let paceSnap = bikePace
        let kindSnap = bikeKind
        // Snapshot the current transit legs' identifying keys so we can
        // match the response without holding state on the actor.
        let currentKeys = itinerary.legs.enumerated().compactMap { (idx, leg) -> (Int, String)? in
            guard leg.isTransit else { return nil }
            return (idx, Self.transitMatchKey(for: leg))
        }
        guard !currentKeys.isEmpty else {
            isRefreshingRealtime = false
            return
        }

        Task {
            let candidates: [Itinerary]
            do {
                candidates = try await RoutingClient.plan(
                    from: originSnap,
                    to: destSnap,
                    mode: modeSnap,
                    when: .leaveNow,
                    preference: prefSnap,
                    bikePace: paceSnap,
                    bikeKind: kindSnap,
                    // Bypass the in-memory cache — the whole point of this
                    // refresh is to land newer realtime fields than what
                    // the cache holds. Reading the cache would just return
                    // the same data we just had.
                    bypassCache: true,
                    useLime: useLime
                )
            } catch {
                await MainActor.run { self.isRefreshingRealtime = false }
                return
            }

            // Pick the candidate whose transit-leg key sequence best
            // matches ours. We require an exact sequence match — partial
            // matches risk grafting a different bus's delay onto our leg.
            let ourSequence = currentKeys.map { $0.1 }
            let match = candidates.first { cand in
                let candSeq = cand.legs
                    .filter { $0.isTransit }
                    .map { Self.transitMatchKey(for: $0) }
                return candSeq == ourSequence
            }
            guard let match else {
                await MainActor.run { self.isRefreshingRealtime = false }
                return
            }

            await MainActor.run {
                // Copy realtime fields from the matched candidate's transit
                // legs onto ours, in order. Nothing else moves.
                let freshTransitLegs = match.legs.filter { $0.isTransit }
                var updated = self.itinerary
                var freshIter = freshTransitLegs.makeIterator()
                for (idx, _) in currentKeys {
                    guard let fresh = freshIter.next() else { break }
                    var leg = updated.legs[idx]
                    leg.realTime = fresh.realTime
                    leg.realtimeState = fresh.realtimeState
                    leg.arrivalDelay = fresh.arrivalDelay
                    leg.departureDelay = fresh.departureDelay
                    updated.legs[idx] = leg
                }
                self.itinerary = updated
                self.isRefreshingRealtime = false
            }
        }
    }

    /// Identity key for a transit leg used to match between our committed
    /// trip and a freshly-planned one. Combines the route's short name
    /// (e.g. "56", "1 Line") with the normalized boarding-stop name. Two
    /// legs with the same key are treated as the same scheduled trip for
    /// the purpose of copying realtime fields. We intentionally don't key
    /// on departure time — that's exactly the field we're trying to
    /// refresh, and including it would defeat the match.
    private static func transitMatchKey(for leg: Leg) -> String {
        let route = leg.route?.shortName ?? leg.route?.longName ?? leg.mode
        let stop = leg.from.name
            .lowercased()
            .replacingOccurrences(of: #"\s*-\s*bay\s*\d+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "\(route)|\(stop)"
    }

    /// Replace the active bike/walk leg with a fresh OTP path from the
    /// user's current location to the next anchor — either the boarding
    /// stop of the upcoming transit leg, or the final destination if the
    /// user is past every transit leg.
    ///
    /// What this function will NEVER do
    /// --------------------------------
    /// - Pick a different bus.
    /// - Pick a different boarding stop.
    /// - Drop a transit leg.
    /// - Replace any leg the user has already completed.
    ///
    /// The user has committed to the bus when they started navigation —
    /// they may be biking past a different stop *because of how OTP routed
    /// them*, and a fresh `.bikeTransit` plan from the current location
    /// would happily say "actually, switch to a different bus from a
    /// different stop." That's exactly the wrong behavior mid-trip. The
    /// realtime delay/cancellation status on the existing transit leg
    /// continues to update via the leg's own `realtimeStatus` getter, so
    /// the user still sees "running 4 min late" without us re-querying
    /// the whole plan.
    ///
    /// Splicing strategy
    /// -----------------
    /// `legs[..<currentLegIndex]`   — already completed; preserve untouched
    /// `legs[currentLegIndex]`      — being rerouted; replaced
    /// `legs[currentLegIndex+1...]` up to the next transit leg — replaced
    /// `legs[nextTransitIdx...]`    — preserved (the bus + everything after)
    ///
    /// If there is no transit leg ahead, the entire tail is replaced
    /// (anchored on the final destination), since there's no committed
    /// transit to protect.
    private func performReroute(from origin: CLLocationCoordinate2D) {
        guard itinerary.legs.indices.contains(currentLegIndex) else { return }
        let activeLeg = itinerary.legs[currentLegIndex]
        // Don't reroute on transit legs — caller already gates on this,
        // but re-checking keeps the splice math safe.
        guard !activeLeg.isTransit else { return }

        isRerouting = true
        lastRerouteAt = Date()

        // Find the next transit leg at-or-after the current index. If one
        // exists, anchor the reroute at its boarding stop and preserve
        // everything from that index onward — that's the leg sequence
        // that protects the bus.
        let tailStart: Int? = (currentLegIndex..<itinerary.legs.count)
            .first(where: { itinerary.legs[$0].isTransit })
        let anchor: CLLocationCoordinate2D = tailStart
            .map { itinerary.legs[$0].from.coordinate }
            ?? finalDestination

        // Pick the OTP transport modes for the rerouted segment based on
        // what the user is actually doing right now. Walk legs reroute as
        // walk-only, bike legs as bike-only. Crucially, neither includes
        // TRANSIT — we never want OTP introducing a different bus into
        // the rerouted middle.
        let activeMode = activeLeg.mode
        let isWalk = (activeMode == "WALK")
        let modesOverride: [[String: String]] = isWalk
            ? [["mode": "WALK"]]
            : [["mode": "BICYCLE"]]

        let prefSnap = preference
        let paceSnap = bikePace
        let kindSnap = bikeKind
        // Use .bikeOnly as the mode argument so the reluctance/triangle
        // selection inside RoutingClient.plan picks bike-friendly weights.
        // The actual transport modes sent to OTP come from the override,
        // so for a walk-only reroute the bike weights are just inert.
        let modeForKnobs: TripMode = .bikeOnly
        let preservedHead = Array(itinerary.legs[..<currentLegIndex])
        let preservedTail: [Leg] = tailStart.map { Array(itinerary.legs[$0...]) } ?? []

        Task {
            do {
                let its = try await RoutingClient.plan(
                    from: origin,
                    to: anchor,
                    mode: modeForKnobs,
                    when: .leaveNow,
                    preference: prefSnap,
                    bikePace: paceSnap,
                    bikeKind: kindSnap,
                    transportModesOverride: modesOverride,
                    useLime: useLime
                )
                await MainActor.run {
                    guard let best = its.first else {
                        self.offRouteStreak = 0
                        self.isRerouting = false
                        return
                    }
                    // Splice. Defensive filter on the new legs: drop any
                    // transit legs OTP somehow returned (shouldn't happen
                    // with the override, but if it did we'd be silently
                    // changing the bus, which is the one thing this method
                    // exists to prevent).
                    var newMiddle = best.legs.filter { !$0.isTransit }
                    guard !newMiddle.isEmpty else {
                        self.offRouteStreak = 0
                        self.isRerouting = false
                        return
                    }
                    // Stamp client-side bike durations onto the new legs
                    // so the ETA countdown matches the planner's model
                    // (distance / pace + climb * 3.9 s/m). Climb on the
                    // new legs is left nil here — the live ETA will
                    // fall back to a flat-speed estimate on the new
                    // segment until ElevationService stamps it on demand.
                    // That's a small inconsistency for a few seconds
                    // mid-trip, acceptable in exchange for not blocking
                    // the reroute on an elevation fetch.
                    newMiddle = newMiddle.map { leg in
                        guard leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT" else { return leg }
                        var l = leg
                        // E-bike overrides pace with the motor-cruise speed;
                        // climb stays unstamped here because the reroute path
                        // intentionally skips the elevation fetch (see
                        // surrounding comment).
                        let flatSecs = leg.distance / kindSnap.metersPerSecond(pace: paceSnap)
                        l.estimatedDurationSeconds = Int(flatSecs.rounded())
                        return l
                    }
                    let merged = preservedHead + newMiddle + preservedTail

                    var rerouted = self.itinerary
                    rerouted.legs = merged
                    // Keep the original startTime (when the trip began —
                    // the user has been on it); recompute endTime from
                    // the last leg so arrival math reflects the new path.
                    if let last = merged.last { rerouted.endTime = last.endTime }
                    rerouted.duration = merged.reduce(0) {
                        $0 + Int(($1.endTime - $1.startTime) / 1000)
                    }
                    rerouted.walkDistance = merged
                        .filter { $0.mode == "WALK" }
                        .reduce(0) { $0 + $1.distance }
                    // Climb is recomputed on demand by `effectiveDuration
                    // Seconds`'s consumers (ElevationService memoizes per
                    // polyline), so wiping the stale value here is fine.
                    rerouted.climbMeters = nil

                    self.itinerary = rerouted
                    // The new active leg is the first leg of `newMiddle`,
                    // which sits right after the preserved head.
                    self.currentLegIndex = preservedHead.count
                    self.currentStepIndex = 0
                    self.rerouteCount += 1
                    self.offRouteStreak = 0
                    self.isRerouting = false
                }
            } catch {
                await MainActor.run {
                    self.offRouteStreak = 0
                    self.isRerouting = false
                }
            }
        }
    }

    // MARK: - Formatting

    private var remainingTimeString: String {
        // Active-leg remaining (live arc-length ÷ pace for bike/walk,
        // schedule-based for transit). In multi-leg trips this means
        // "until you catch the bus" / "until you alight" / "until you
        // reach the destination" depending on which leg you're on —
        // the whole-trip end is still surfaced by `Arriving X:XX PM`.
        // In single-leg trips active == whole, so behavior is unchanged.
        let remaining = max(0, Int(activeLegRemainingSeconds))
        let m = remaining / 60
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(m % 60) min"
    }

    /// Active-leg remaining distance. Nil when we have no live
    /// computation (transit leg, no GPS fix) — bottomCard hides the
    /// distance chip then rather than show a stale planner number.
    private var remainingDistanceString: String? {
        guard let m = liveActiveLegMeters else { return nil }
        let miles = m / 1609.34
        if miles >= 1 { return "\(Int(miles.rounded())) mi" }
        return String(format: "%.1f mi", miles)
    }

    /// Leading icon for the bottom card's time/distance row. Bike legs
    /// show a bicycle (we suppressed the redundant "Bicycle" leg-info
    /// row below, so this is the only place the mode reads from the
    /// card); walk legs show a walking figure; transit legs and any
    /// off-leg state keep the neutral clock so the row still reads as
    /// "time remaining" when active travel isn't the right framing.
    private var bottomCardLeadingIcon: String {
        guard let leg = currentLeg else { return "clock" }
        switch leg.mode {
        case "BICYCLE", "BICYCLE_RENT": return "bicycle"
        case "WALK":                    return "figure.walk"
        default:                        return "clock"
        }
    }

    /// Seconds remaining in the *current* leg. Falls back to the
    /// planner's stamped duration (bike/walk) or the realtime-
    /// adjusted scheduled end (transit) when no live computation
    /// is available — typically the moment between tapping GO and
    /// the first GPS fix landing.
    ///
    /// For bike/walk legs, we use `estimatedDurationSeconds` (the
    /// pace + climb + intersection model the live recompute also
    /// uses), not `leg.effectiveEndDate - now`. The latter is OTP's
    /// flat-speed-planned end time, which doesn't match the stamped
    /// model: at trip start the label would show e.g. 32 min (OTP's
    /// estimate from a stale `startTime` to OTP's planned end), then
    /// snap to 22 min the moment GPS lands and `liveActiveLegSeconds`
    /// took over. Always reading the stamped duration eliminates
    /// that flash.
    ///
    /// Transit legs still use `effectiveEndDate - now` so a bus that
    /// becomes more delayed mid-ride pushes our "X min remaining"
    /// forward as the realtime feed updates `arrivalDelay`.
    private var activeLegRemainingSeconds: TimeInterval {
        if let live = liveActiveLegSeconds { return max(0, live) }
        guard let leg = currentLeg else { return 0 }
        if !leg.isTransit, let est = leg.estimatedDurationSeconds {
            return max(0, Double(est))
        }
        return max(0, leg.effectiveEndDate.timeIntervalSince1970 - now.timeIntervalSince1970)
    }

    private var arrivalTimeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        let arrival = now.addingTimeInterval(liveRemainingSecondsOrFallback)
        return f.string(from: arrival)
    }

    /// Live remaining seconds when available, otherwise the static
    /// itinerary endDate countdown. Centralised so the time-remaining label
    /// and the ETA label stay in lockstep — they were drifting apart when
    /// one used live and the other used static.
    private var liveRemainingSecondsOrFallback: TimeInterval {
        if let live = liveRemainingSeconds { return max(0, live) }
        return max(0, itinerary.endDate.timeIntervalSince1970 - now.timeIntervalSince1970)
    }

    private func boardCountdown(leg: Leg) -> String {
        // effectiveStartDate folds in any populated departureDelay
        // (refreshed every 30 s) so the countdown reflects whatever
        // delay the realtime feed last reported.
        let secs = Int(leg.effectiveStartDate.timeIntervalSince1970 - now.timeIntervalSince1970)
        if secs <= 0 { return "Boarding now" }
        if secs < 60 { return "in \(secs) sec" }
        return "in \(secs / 60) min"
    }

    private func formatMeters(_ m: Double) -> String {
        let feet = m * 3.28084
        if feet < 300 { return "\(Int((feet / 10).rounded()) * 10) ft" }
        let miles = m / 1609.34
        return miles < 0.1 ? String(format: "%.2f mi", miles) : String(format: "%.1f mi", miles)
    }

    private func iconName(for mode: String) -> String {
        switch mode {
        case "BICYCLE", "BICYCLE_RENT": return "bicycle"
        case "WALK":                    return "figure.walk"
        case "BUS":                     return "bus.fill"
        case "RAIL", "TRAM", "SUBWAY":  return "tram.fill"
        case "FERRY":                   return "ferry.fill"
        default:                        return "arrow.right"
        }
    }

    private func transitIcon(_ mode: String) -> String {
        switch mode {
        case "BUS":                    return "bus.fill"
        case "RAIL", "TRAM", "SUBWAY": return "tram.fill"
        case "FERRY":                  return "ferry.fill"
        default:                       return "tram.fill"
        }
    }

    // MARK: - Geometry helpers (point-to-polyline distance)

    /// Min distance from `p` to any segment of `polyline`, in meters.
    /// Uses a local flat-earth projection, which is accurate to within a few
    /// cm for segments of the length OTP produces (well under 1 km).
    static func distanceToPolyline(
        _ p: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> CLLocationDistance {
        guard !polyline.isEmpty else { return .infinity }
        if polyline.count == 1 {
            return CLLocation(latitude: p.latitude, longitude: p.longitude)
                .distance(from: CLLocation(latitude: polyline[0].latitude, longitude: polyline[0].longitude))
        }
        var minD: CLLocationDistance = .infinity
        for i in 0..<(polyline.count - 1) {
            let d = distanceToSegment(p: p, a: polyline[i], b: polyline[i + 1])
            if d < minD { minD = d }
        }
        return minD
    }

    /// Point-to-segment distance in meters, using a local equirectangular
    /// projection around the segment midpoint.
    static func distanceToSegment(
        p: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let metersPerDegLat = 111_320.0
        let refLat = (a.latitude + b.latitude) / 2 * .pi / 180
        let metersPerDegLon = metersPerDegLat * cos(refLat)

        let ax = 0.0, ay = 0.0
        let bx = (b.longitude - a.longitude) * metersPerDegLon
        let by = (b.latitude  - a.latitude)  * metersPerDegLat
        let px = (p.longitude - a.longitude) * metersPerDegLon
        let py = (p.latitude  - a.latitude)  * metersPerDegLat

        let dx = bx - ax
        let dy = by - ay
        let len2 = dx * dx + dy * dy
        if len2 < 1e-6 {
            return hypot(px - ax, py - ay)
        }
        var t = ((px - ax) * dx + (py - ay) * dy) / len2
        t = max(0, min(1, t))
        let cx = ax + t * dx
        let cy = ay + t * dy
        return hypot(px - cx, py - cy)
    }
}

// MARK: - Navigation-specific map

/// MapView that tracks the user, highlights the active leg, and dims the rest.
///
/// Camera behavior
/// ---------------
/// While `isFollowing` is true, every location/heading update reapplies a
/// top-down 2D camera (pitch 0°, 500m altitude, oriented to user heading).
/// As soon as the user pans/zooms/rotates the map manually, we flip
/// `isFollowing` to false via the binding and stop touching the camera —
/// so a manual zoom-out *stays* zoomed out. The recenter button on the
/// parent view sets `isFollowing` back to true to re-engage follow mode.
struct NavigationMapView: UIViewRepresentable {
    let itinerary: Itinerary
    let userLocation: CLLocation?
    let heading: CLHeading?
    let currentLegIndex: Int
    /// Bike racks to render as map annotations. Caller (TripNavigationView)
    /// passes an empty array unless the user is approaching the trip's
    /// destination — see `racksToDisplay` there.
    var bikeRacks: [BikeRack] = []
    @Binding var isFollowing: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.userTrackingMode = .followWithHeading
        // Keep the coordinator pointed at the latest binding state. The
        // stored binding lets the delegate flip `isFollowing` to false
        // when it sees a user gesture.
        context.coordinator.isFollowingBinding = $isFollowing
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Bindings can be re-created across SwiftUI updates; refresh the
        // coordinator's pointer every time so it always writes back to
        // the current source of truth.
        context.coordinator.isFollowingBinding = $isFollowing

        map.removeOverlays(map.overlays)
        // Drop any previous bus-stop AND bike-rack annotations before
        // re-adding. Bus-stop set is itinerary-driven so it only
        // changes on leg progression; bike-rack set toggles between
        // empty and populated as the user approaches the destination,
        // so removing+re-adding every update is the simplest path.
        // Don't touch MKUserLocation.
        map.removeAnnotations(
            map.annotations.filter { $0 is TransitStopAnnotation || $0 is BikeRackAnnotation }
        )

        for (idx, leg) in itinerary.legs.enumerated() {
            let pts = PolylineDecoder.decode(leg.legGeometry.points)
            guard pts.count >= 2 else { continue }

            // Bike legs are split per-step so on-infra portions render green
            // and on-street portions render blue. Each sub-segment carries
            // the same isActive/isPast state as its parent leg.
            if leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT" {
                let segments = bikeLegSegments(leg)
                for seg in segments where seg.coords.count >= 2 {
                    let line = LegPolyline(coordinates: seg.coords, count: seg.coords.count)
                    line.mode = leg.mode
                    line.isOnBikeInfra = seg.onBikeInfra
                    line.isActive = (idx == currentLegIndex)
                    line.isPast = (idx < currentLegIndex)
                    map.addOverlay(line)
                }
            } else {
                let line = LegPolyline(coordinates: pts, count: pts.count)
                line.mode = leg.mode
                line.isActive = (idx == currentLegIndex)
                line.isPast = (idx < currentLegIndex)
                // Transit legs carry their route's brand color into
                // the renderer (see Leg.transitBrand). Non-transit
                // legs leave it nil so the WALK / BICYCLE paths in
                // rendererFor pick their defaults.
                if leg.isTransit {
                    line.brandStrokeColor = leg.transitBrand.uiColor
                }
                map.addOverlay(line)
            }
        }

        // Bus-stop dots — boarding (orange), alighting (red), and every
        // intermediate stop the bus makes between them (small unfilled
        // dot). Same dedup as ItineraryMapView so back-to-back transfers
        // don't render two dots stacked at the same coordinate, and an
        // intermediate stop that coincides with a boarding/alighting stop
        // on a neighboring leg defers to the louder dot.
        var seenStops = Set<String>()
        for leg in itinerary.legs where leg.isTransit {
            let brand = leg.transitBrand.uiColor
            for endpoint in [(leg.from.coordinate, leg.from.name, TransitStopAnnotation.Kind.boarding),
                             (leg.to.coordinate,   leg.to.name,   TransitStopAnnotation.Kind.alighting)] {
                let key = String(format: "%.5f,%.5f", endpoint.0.latitude, endpoint.0.longitude)
                if seenStops.insert(key).inserted {
                    let stop = TransitStopAnnotation()
                    stop.coordinate = endpoint.0
                    stop.title = endpoint.1
                    stop.kind = endpoint.2
                    stop.brandColor = brand
                    map.addAnnotation(stop)
                }
            }
        }
        for leg in itinerary.legs where leg.isTransit {
            let brand = leg.transitBrand.uiColor
            for inter in leg.intermediateStops ?? [] {
                let key = String(format: "%.5f,%.5f", inter.lat, inter.lon)
                if seenStops.insert(key).inserted {
                    let stop = TransitStopAnnotation()
                    stop.coordinate = inter.coordinate
                    stop.title = inter.name
                    stop.kind = .intermediate
                    stop.brandColor = brand
                    map.addAnnotation(stop)
                }
            }
        }

        // Bike-rack pins near the trip's final destination. Caller
        // passes an empty array unless the user is close enough that
        // "where to lock up" is the next decision (see
        // TripNavigationView.racksToDisplay). Reuses the same
        // BikeRackAnnotation type the trip-detail map uses, so the
        // rendering and callout behavior match.
        for rack in bikeRacks {
            let ann = BikeRackAnnotation()
            ann.coordinate = rack.coordinate
            ann.title = rack.name?.isEmpty == false ? rack.name : "Bike parking"
            let summary = rack.summary
            if !summary.isEmpty { ann.subtitle = summary }
            ann.rack = rack
            map.addAnnotation(ann)
        }

        // Only force the first-person camera while follow mode is on. When
        // the user has zoomed/panned manually, leave the map where they
        // put it — the recenter button is how they ask us to take over again.
        guard isFollowing, let loc = userLocation else { return }

        // Battery: skip the setCamera animation when neither position nor
        // heading has changed meaningfully since last apply. Each setCamera
        // animation pegs the GPU for ~0.25s; doing it 60 times a minute on
        // a stationary user was the dominant battery cost during navigation.
        let newHeading = heading?.trueHeading ?? loc.course
        let coordChanged: Bool = {
            guard let last = context.coordinator.lastAppliedCoord else { return true }
            let d = CLLocation(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
                .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
            return d > 5  // meters
        }()
        let headingChanged = abs(newHeading - context.coordinator.lastAppliedHeading) > 8
        guard coordChanged || headingChanged || context.coordinator.lastAppliedCoord == nil else {
            return
        }
        context.coordinator.lastAppliedCoord = loc.coordinate
        context.coordinator.lastAppliedHeading = newHeading

        // Suppress our own programmatic camera change from triggering the
        // "user moved the map" branch in the delegate. We re-enable after
        // dispatching past the animation start.
        context.coordinator.suppressNextRegionChange = true
        // Top-down 2D follow camera (pitch=0). Earlier this used pitch=45
        // for an immersive first-person tilt — that view looked great in
        // demos but turned out to be harder to use mid-ride: hilly
        // Seattle terrain made the foreground over-occlude what was
        // coming up next, the rendering load increased GPU/battery use,
        // and the tilted map didn't match the user's mental model of
        // "where am I on the map" that flat overhead views give.
        map.setCamera(MKMapCamera(
            lookingAtCenter: loc.coordinate,
            fromDistance: 500,
            pitch: 0,
            heading: newHeading
        ), animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        /// Bound from the parent so we can flip `isFollowing` to false when
        /// the user pans/zooms. Refreshed on every `updateUIView`.
        var isFollowingBinding: Binding<Bool>?

        /// Set to true right before our own programmatic `setCamera` so the
        /// resulting region change isn't misinterpreted as a user gesture.
        /// Cleared inside `regionDidChangeAnimated`.
        var suppressNextRegionChange: Bool = false

        /// Last coordinate / heading we actually applied to the camera. We
        /// suppress further setCamera calls when the new values are within
        /// a small tolerance of these — see updateUIView for the thresholds
        /// (5 m for position, 8° for heading). Lives on the coordinator
        /// rather than as @State on the parent because UIViewRepresentable
        /// updateUIView re-runs frequently and we want the suppression to
        /// hold across those reruns without churning SwiftUI state.
        var lastAppliedCoord: CLLocationCoordinate2D? = nil
        var lastAppliedHeading: CLLocationDirection = -1

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // If a gesture recognizer on the map's content view is currently
            // active, the region change is user-driven (pinch / pan / rotate).
            // The "trick" is that gestureRecognizers live on the first private
            // subview; this is the documented Apple-pattern for distinguishing
            // user vs. programmatic region changes.
            guard !suppressNextRegionChange else { return }
            let recognizers = mapView.subviews.first?.gestureRecognizers ?? []
            let userDriven = recognizers.contains { recognizer in
                let s = recognizer.state
                return s == .began || s == .changed || s == .ended
            }
            if userDriven {
                // Hop back to main to write the binding (region delegate
                // callbacks already run on main, but staying explicit avoids
                // SwiftUI complaining about state changes inside layout).
                DispatchQueue.main.async { [weak self] in
                    self?.isFollowingBinding?.wrappedValue = false
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Always clear the suppression flag at the end of any region
            // change so the *next* user gesture is detected normally.
            suppressNextRegionChange = false
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? LegPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = MKPolylineRenderer(polyline: line)
            // Color base by mode. Bike picks pine green vs. blue per
            // sub-segment depending on whether that step is on known bike
            // infrastructure. Pine green (#00875A) is darker/more
            // saturated than Sound Transit Link 1 (#3DAE2B) so the two
            // greens stay distinguishable. Color value lives in Palette
            // — MapView.swift's renderer uses the same constant.
            let base: UIColor
            switch line.mode {
            case "BICYCLE", "BICYCLE_RENT":
                base = line.isOnBikeInfra ? Palette.bikeInfraUI : .systemBlue
            case "WALK":
                base = .systemGray
            default:
                // Per-route brand color when set at overlay-add time
                // (Sound Transit Link/Sounder/STRIDE/T Line where
                // mapped); falls back to systemOrange for unmapped
                // operators.
                base = line.brandStrokeColor ?? .systemOrange
            }
            if line.isPast {
                r.strokeColor = base.withAlphaComponent(0.25)
                r.lineWidth = 3
            } else if line.isActive {
                r.strokeColor = base
                r.lineWidth = 7
            } else {
                r.strokeColor = base.withAlphaComponent(0.5)
                r.lineWidth = 5
            }
            if line.mode == "WALK" { r.lineDashPattern = [2, 6] }
            return r
        }

        // Render bus-stop and bike-rack annotations using the shared
        // builders in ItineraryMapView.Coordinator so the live-nav map
        // and the trip-detail map look identical without each one
        // re-implementing the dot styles.
        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let stop = annotation as? TransitStopAnnotation {
                return ItineraryMapView.Coordinator.makeStopAnnotationView(
                    for: stop, on: map, reuseId: "transit-stop-nav"
                )
            }
            if let rack = annotation as? BikeRackAnnotation {
                return ItineraryMapView.Coordinator.makeBikeRackAnnotationView(
                    for: rack, on: map
                )
            }
            return nil
        }
    }
}

/// Re-use the LegPolyline from MapView.swift but add two more flags for
/// active / past state during navigation.
extension LegPolyline {
    private static var activeKey: UInt8 = 0
    private static var pastKey: UInt8 = 0

    var isActive: Bool {
        get { (objc_getAssociatedObject(self, &Self.activeKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &Self.activeKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    var isPast: Bool {
        get { (objc_getAssociatedObject(self, &Self.pastKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &Self.pastKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}
