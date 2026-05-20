import SwiftUI

// MARK: - Itinerary card

/// Full-width row for one itinerary. Shows a compact, left-to-right sequence
/// of the legs — bike → transit line → bike, etc. — with duration or line
/// name inside each chip.
struct ItineraryRow: View {
    let itinerary: Itinerary
    let isSelected: Bool

    /// Total climb across all bike legs in this itinerary, in feet. Populated
    /// asynchronously by the `.task` below — `nil` while in flight or before
    /// the row first appears, so the bike-summary line renders miles only and
    /// adds the climb in once the value lands.
    @State private var totalClimbFeet: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Left: total time as a single bold focal point. For trips under
            // an hour we show "23" big + "min" caption; for trips ≥ 60 min we
            // show "1h" big + "5 min" caption (or just "1h" if the remainder
            // is zero). Monospaced digits keep adjacent rows aligned.
            VStack(alignment: .leading, spacing: -2) {
                Text(durationPrimary)
                    .font(.title).bold()
                    .monospacedDigit()
                if !durationSecondary.isEmpty {
                    Text(durationSecondary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(minWidth: 50, alignment: .leading)

            // Right: stacked lines — depart → arrive clock times, the leg
            // chip sequence, an optional bike summary (miles + climb), and
            // (for transit trips) the absolute boarding time + stop name.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(itinerary.timeRange)
                        .font(.subheadline).bold()
                    // "Past trip" badge — surfaces itineraries whose
                    // arrival time has already gone by. They stay in
                    // the list (the user might want to inspect the
                    // schedule), but the GO button in the detail
                    // sheet is disabled separately. Rendered first
                    // so it sits closest to the time range, which is
                    // what the user is actually scanning when they're
                    // wondering "wait, why can't I take this one?"
                    if itinerary.isPast {
                        flavorBadge("Past trip", icon: "clock.badge.xmark", color: .gray)
                    }
                    // "Well-lit" badge — appears when any portion of this
                    // trip falls during civil-twilight darkness (start
                    // or end) AND most of the bike portion runs on OSM
                    // `lit=yes` infrastructure (proxy-computed
                    // litFraction, distance-weighted). The both-endpoints
                    // check inside `litBadgeQualifies` covers
                    // late-evening trips (start light, end dark) and
                    // early-morning trips (start dark, end light).
                    if itinerary.litBadgeQualifies {
                        // Orange rather than yellow — yellow on the
                        // default sheet background washes out in
                        // daylight phone use; orange holds contrast.
                        flavorBadge("Well-lit", icon: "lightbulb.fill", color: .orange)
                    }
                    // Bike-only alternative tags. `.faster` is the implicit
                    // default and gets no badge. `.lessEffort` (the "Flatter"
                    // badge) was also dropped — the bike-lane bucket sort
                    // and the new mileage-vs-lane% filter already push
                    // those options to the right place in the list, and
                    // an explicit badge added noise the user didn't want.
                    // `.safer` is still useful because it doesn't
                    // correlate with lane coverage the same way slope does.
//                    if itinerary.bikeFlavor == .safer {
//                        flavorBadge("Safer", icon: "shield.lefthalf.filled", color: .blue)
//                    }
                    // Bike+transit alternative tags. `.balanced` is the
                    // implicit default; `.bikeMore` ("More bike" badge)
                    // was removed because the user already sees how
                    // much biking each option entails from the leg chips
                    // and the bike summary, and the badge added noise
                    // when the boarding-stop dedup already kept it out
                    // of the list when there was no real distinction.
                    // Keep `.bikeLess` because it's a meaningful "less
                    // active" cue that's not visible from the chips
                    // alone.
//                    if itinerary.transitFlavor == .bikeLess {
//                        flavorBadge("Less bike", icon: "tram.fill", color: .purple)
//                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(visibleLegs.enumerated()), id: \.offset) { idx, leg in
                            chip(for: leg)
                            if idx < visibleLegs.count - 1 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                if itinerary.bikeMiles > 0 {
                    Text(bikeSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let transit = firstTransitLeg {
                    Text("\(clockTime(for: transit)) from \(transit.from.name)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Subtle tint on the selected row — no per-row card, so it sits
        // inside the shared list container as one item among many.
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        // Past trips render at reduced opacity to read as
        // archival/informational rather than actionable. The user can
        // still tap into the detail sheet to inspect the schedule,
        // but the GO button there is disabled.
        .opacity(itinerary.isPast ? 0.45 : 1.0)
        // Pull total climb across all bike legs. Each profile() call hits
        // ElevationCache before the network, so this is free on the second
        // appearance of the same itinerary (e.g., after a mode-pill toggle).
        .task(id: itinerary.id) {
            guard itinerary.bikeMiles > 0, totalClimbFeet == nil else { return }
            var meters: Double = 0
            for leg in itinerary.legs where leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT" {
                if let p = try? await ElevationService.profile(for: leg) {
                    meters += p.climbMeters
                }
            }
            totalClimbFeet = Int((meters * 3.28084).rounded())
        }
    }

    /// Big-number portion of the duration display.
    /// "23" for trips < 60 min, "1h" / "2h" for longer trips.
    private var durationPrimary: String {
        let total = itinerary.durationMinutes
        if total < 60 { return "\(total)" }
        return "\(total / 60)h"
    }

    /// Caption portion of the duration display.
    /// "min" for short trips, "5 min" for hour+ trips with a remainder, ""
    /// when the duration is an exact number of hours (caller hides the line).
    private var durationSecondary: String {
        let total = itinerary.durationMinutes
        if total < 60 { return "min" }
        let m = total % 60
        return m == 0 ? "" : "\(m) min"
    }

    /// Small color-coded capsule used to tag bike-only alternatives that
    /// emerged from a non-default `BikePreference` (i.e., flatter or safer
    /// detours that survived the merge as distinct routes).
    private func flavorBadge(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.caption2).bold()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundColor(color)
        .background(color.opacity(0.15), in: Capsule())
    }

    /// "5.2 mi" while elevation is still loading, "5.2 mi · ↗ 240 ft · 65%
    /// lanes · 80% lit" once the per-leg climb and litFraction have been
    /// computed. Hidden entirely when the itinerary has no bike legs.
    /// Miles use 1 decimal under 10 mi, 0 decimals above.
    ///
    /// The lane-percentage is only shown when ≥25% — below that, "8% lanes"
    /// reads as a negative the user didn't ask for and clutters the summary.
    /// Percentage rounds to the nearest 5% so jitter from name-matching
    /// noise (e.g., a single unnamed step) doesn't twitch the displayed
    /// number on every re-plan.
    ///
    /// The lit-percentage shows whenever the proxy populated `litFraction`
    /// on the bike legs (we have a `litFractionWeighted` accessor that
    /// returns nil if no leg has data — that's when we skip the field).
    /// Unlike the conditional "Well-lit" badge, this number renders
    /// always — even during the day — so users can compare lighting
    /// coverage across alternative routes at any time. Rounded to 5%.
    private var bikeSummary: String {
        let miles = itinerary.bikeMiles
        let milesStr = miles < 10
            ? String(format: "%.1f mi", miles)
            : String(format: "%.0f mi", miles)
        var parts: [String] = [milesStr]
        if let feet = totalClimbFeet, feet > 0 {
            parts.append("↗ \(feet) ft")
        }
        let frac = bikeLaneFraction(itinerary)
        if frac >= 0.25 {
            let pct = Int((frac * 20).rounded()) * 5  // round to nearest 5%
            parts.append("\(pct)% lanes")
        }
        // Lit percentage shows only when the trip falls during civil-
        // twilight darkness (start OR end), since lighting only matters
        // for night riding. Same darkness condition the "Well-lit"
        // badge uses, surfaced as `Itinerary.isTripDark`. Daytime
        // trips skip this field entirely — at noon the user doesn't
        // need to know that 35% of the route is on lit ways, the info
        // is just clutter. Within dark trips, we also skip when the
        // proxy returned no litFraction data (nil) so a stale or
        // restarted proxy doesn't surface a misleading "0% lit" on
        // every row.
        if itinerary.isTripDark, let litFrac = itinerary.litFractionWeighted {
            let pct = Int((litFrac * 20).rounded()) * 5  // round to nearest 5%
            parts.append("\(pct)% lit")
        }
        return parts.joined(separator: " · ")
    }

    /// First transit leg in the itinerary (used for the boarding-time line).
    private var firstTransitLeg: Leg? {
        itinerary.legs.first(where: { $0.isTransit })
    }

    /// "11:47 PM" — hour+minute boarding time for a transit leg.
    private func clockTime(for leg: Leg) -> String {
        let depart = Date(timeIntervalSince1970: TimeInterval(leg.startTime) / 1000)
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: depart)
    }

    /// Drop sub-minute legs (OTP sometimes emits a 20-second walk-to-bus-stop
    /// leg that just clutters the sequence).
    private var visibleLegs: [Leg] {
        itinerary.legs.filter { $0.durationMinutes >= 1 }
    }

    /// One or more chips per leg. For bike/walk it shows a single
    /// duration chip ("8 min"). For transit it shows the line's short
    /// name ("1 Line", "E Line", "40") — and when the leg has
    /// alternative routes (same boarding stops, different bus lines,
    /// merged in by `dedupeByTransitStops`), each route gets its own
    /// capsule rendered side-by-side: `[1 Line] [2 Line] [E Line]`.
    /// Each capsule is fully self-contained with its own icon and
    /// label so the user can scan them independently — visually
    /// stronger than slash-joining route names into one capsule.
    private func chip(for leg: Leg) -> some View {
        // Collect the list of labels we need to render — one per
        // capsule. For bike/walk that's a single "duration" label;
        // for transit it's the primary route + each alternative,
        // computed up front so every capsule goes through the same
        // ForEach + singleChip path. Earlier the primary was
        // rendered outside the ForEach and alternatives inside,
        // which gave SwiftUI subtly different layout containers per
        // chip and made the second+ capsules render slightly
        // smaller than the first.
        let labels: [String] = {
            switch leg.mode {
            case "BICYCLE", "BICYCLE_RENT", "WALK":
                return [Itinerary.formatMinutes(leg.durationMinutes)]
            default:
                let primary = routeChipName(for: leg.route) ?? leg.mode.capitalized
                let alts = leg.alternativeRoutes.compactMap(routeChipName(for:))
                return [primary] + alts
            }
        }()
        return HStack(spacing: 4) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                singleChip(
                    icon: iconName(for: leg.mode),
                    label: label,
                    tint: tint(for: leg)
                )
            }
        }
    }

    /// Render one capsule — icon + label, tinted by mode, padded the
    /// same as the original single-chip layout. Extracted so the
    /// transit-with-alternatives path can call it per route without
    /// duplicating styling.
    private func singleChip(icon: String, label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption).bold()
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundColor(tint)
        .background(tint.opacity(0.15), in: Capsule())
    }

    /// Pull the rider-facing label out of a RouteInfo. Mirrors the
    /// short-name-then-long-name fallback used for the primary chip,
    /// extracted into a helper since we now look it up multiple times
    /// per chip when alternatives are present. Returns nil for routes
    /// that have neither name (extremely rare; the chip falls back to
    /// the mode capitalized in that case).
    private func routeChipName(for route: RouteInfo?) -> String? {
        if let s = route?.shortName, !s.isEmpty { return s }
        if let l = route?.longName,  !l.isEmpty { return l }
        return nil
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

    private func tint(for leg: Leg) -> Color {
        switch leg.mode {
        case "BICYCLE", "BICYCLE_RENT": return .green
        case "WALK":                    return .gray
        case "BUS":                     return .blue
        case "RAIL", "TRAM", "SUBWAY":  return .purple
        case "FERRY":                   return .teal
        default:                        return .primary
        }
    }
}

// MARK: - Itinerary detail

/// Full turn-by-turn breakdown for a single itinerary.
/// Shown when the user taps one of the cards in the carousel.
struct ItineraryDetailView: View {
    let itinerary: Itinerary
    let mode: TripMode
    let preference: RoutePreference
    @Environment(\.dismiss) private var dismiss
    @State private var showNavigation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    goButton
                    Divider()
                    ForEach(Array(itinerary.legs.enumerated()), id: \.offset) { idx, leg in
                        LegDetailRow(leg: leg)
                        if idx < itinerary.legs.count - 1 {
                            Divider().padding(.leading, 36)
                        }
                    }
                    Divider()
                    arriveFooter
                }
                .padding()
            }
            .navigationTitle("Trip details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showNavigation) {
                TripNavigationView(itinerary: itinerary, mode: mode, preference: preference)
            }
        }
    }

    private var goButton: some View {
        // Past trips: render the button greyed out and inert, with a
        // small helper line below explaining why. Viewing the detail
        // sheet is still useful (the user might be inspecting the
        // schedule), but starting navigation against a trip that's
        // already arrived would be misleading.
        let isPast = itinerary.isPast
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if !isPast { showNavigation = true }
            } label: {
                HStack {
                    Image(systemName: isPast ? "clock.badge.xmark" : "location.north.line.fill")
                    Text(isPast ? "Trip has already departed" : "GO").bold()
                }
                .font(.title3)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    (isPast ? Color.gray : Color.accentColor),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
            .buttonStyle(.plain)
            .disabled(isPast)
            // Hint for the past-trip case so the disabled state isn't
            // mysterious. Keeps the explanation in-context rather than
            // requiring the user to deduce it from the icon.
            if isPast {
                Text("You're viewing this trip's schedule. To plan a new trip, adjust the time.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(itinerary.formattedDuration)
                .font(.largeTitle).bold()
            Text(itinerary.timeRange)
                .font(.subheadline).foregroundColor(.secondary)
            Text(itinerary.summary)
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var arriveFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "flag.checkered")
                .foregroundColor(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Arrive \(itinerary.legs.last?.to.name ?? "")")
                    .font(.subheadline).bold()
                Text(formattedArrivalTime)
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var formattedArrivalTime: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: itinerary.endDate)
    }
}

/// Single leg row in the detail view.
private struct LegDetailRow: View {
    let leg: Leg
    @State private var elevation: ElevationProfile?
    @State private var elevLoading: Bool = false

    private var isBike: Bool {
        leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundColor(tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline).bold()
                    if leg.isTransit {
                        RealtimeBadge(status: leg.realtimeStatus)
                    }
                    if isBike, let e = elevation {
                        HillBadge(profile: e)
                    }
                    Spacer()
                }

                if leg.isTransit {
                    // Board / ride / alight block
                    Label {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Board at \(leg.startTimeString)").bold()
                            Text(leg.from.name).foregroundColor(.secondary)
                            // Alternative-route departures. For each
                            // alternate bus (1 Line + 2 Line + ...),
                            // show "or 2 Line at 8:14" — but only if
                            // the alternative leaves noticeably later
                            // than the primary (>1 min). Same-minute
                            // alternatives are visually redundant
                            // since the rider just hops on whichever
                            // arrives first.
                            ForEach(Array(zip(leg.alternativeRoutes,
                                              leg.alternativeStartTimes).enumerated()),
                                    id: \.offset) { _, pair in
                                let (route, startMs) = pair
                                if let line = altLine(route),
                                   shouldShowAltTime(altStart: startMs) {
                                    Text("or \(line) at \(formatClock(startMs))")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } icon: {
                        Image(systemName: "circle.fill")
                            .font(.caption2).foregroundColor(tint)
                    }
                    .font(.caption)

                    Text("Ride \(leg.durationMinutes) min")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.leading, 18)

                    Label {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Get off at \(leg.endTimeString)").bold()
                            Text(leg.to.name).foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "mappin.circle.fill")
                            .font(.caption2).foregroundColor(tint)
                    }
                    .font(.caption)
                } else {
                    // Walk / bike block. Per-leg minutes come from
                    // `leg.durationMinutes`, which after planTrip's
                    // stamping pass already includes climb, signal, and
                    // Ballard-Locks penalties — the same number
                    // everything else in the UI shows.
                    HStack(spacing: 6) {
                        Text("\(leg.durationMinutes) min")
                        if let d = leg.distanceString {
                            Text("·")
                            Text(d)
                        }
                        Text("·")
                        Text("\(leg.startTimeString) → \(leg.endTimeString)")
                    }
                    .font(.caption).foregroundColor(.secondary)

                    if !leg.from.name.isEmpty {
                        Text("From \(leg.from.name)")
                            .font(.caption2).foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    if !leg.to.name.isEmpty {
                        Text("To \(leg.to.name)")
                            .font(.caption2).foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    // Hill profile for bike legs only (walk legs are usually
                    // short enough that elevation isn't interesting).
                    if isBike {
                        if let e = elevation {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(e.summaryLine)
                                    .font(.caption).foregroundColor(.secondary)
                                ElevationSparkline(samples: e.samples)
                                    .frame(height: 36)
                            }
                            .padding(.top, 2)
                        } else if elevLoading {
                            Text("Loading elevation…")
                                .font(.caption2).foregroundColor(.secondary)
                                .padding(.top, 2)
                        }
                    }
                }
            }
            Spacer()
        }
        .task {
            guard isBike, elevation == nil, !elevLoading else { return }
            elevLoading = true
            defer { elevLoading = false }
            do {
                elevation = try await ElevationService.profile(for: leg)
            } catch {
                // Leave elevation nil — the chip/summary just won't render.
            }
        }
    }

    private var title: String {
        if leg.isRental { return "Lime bike" }
        switch leg.mode {
        case "WALK": return "Walk"
        case "BICYCLE", "BICYCLE_RENT": return "Bike"
        default:
            // Just the primary route's display name. The chip
            // rendering up in ItineraryRow renders alternatives as
            // separate capsules, and the boarding block below this
            // title surfaces each alternative as its own "or X Line
            // at Y:YY" row — so the title doesn't need to repeat
            // them. Keeping the title to a single line name also
            // avoids the awkward slash-joined heading.
            return leg.displayName
        }
    }

    /// Short rider-facing label for an alternative route.
    private func altLine(_ route: RouteInfo) -> String? {
        if let s = route.shortName, !s.isEmpty { return s }
        if let l = route.longName,  !l.isEmpty { return l }
        return nil
    }

    /// Decide whether to display an alternative route's departure time
    /// at all. The primary leg's startTime is the canonical (earliest)
    /// departure; alternates that depart within the same minute are
    /// just "the next bus on the same platform" and visually noisy to
    /// list. We threshold at 60s so anything more than a minute later
    /// gets its own "or X:XX" line.
    private func shouldShowAltTime(altStart: Int64) -> Bool {
        return altStart - leg.startTime > 60 * 1000
    }

    /// Format an epoch-ms timestamp as a short clock time with AM/PM
    /// marker ("8:14 AM" / "4:30 PM"), in Pacific time. PugetRoute is
    /// a Seattle-region app and every trip is in PT regardless of
    /// where the phone's clock is; the AM/PM marker disambiguates
    /// morning vs evening alternatives so the user doesn't have to
    /// guess which 8:14 the bus actually departs.
    private func formatClock(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    private var iconName: String {
        switch leg.mode {
        case "BICYCLE", "BICYCLE_RENT": return "bicycle"
        case "WALK":                    return "figure.walk"
        case "BUS":                     return "bus.fill"
        case "RAIL", "TRAM", "SUBWAY":  return "tram.fill"
        case "FERRY":                   return "ferry.fill"
        default:                        return "arrow.right"
        }
    }

    private var tint: Color {
        // Rental bikes (Lime) get the same Lime-tinted green as the map
        // polyline, so the detail row visually matches what the user
        // sees on the route line.
        if leg.isRental {
            return Color(red: 0.20, green: 0.80, blue: 0.05)
        }
        switch leg.mode {
        case "BICYCLE", "BICYCLE_RENT": return .green
        case "WALK":                    return .secondary
        case "BUS":                     return .blue
        case "RAIL", "TRAM", "SUBWAY":  return .purple
        case "FERRY":                   return .teal
        default:                        return .primary
        }
    }
}

// MARK: - Realtime badge

/// Small pill shown next to a transit leg's title. Encodes whether the
/// departure/arrival is live, and if so, how far off schedule it's running.
struct RealtimeBadge: View {
    let status: RealTimeStatus

    var body: some View {
        switch status {
        case .unknown:   EmptyView()
        case .scheduled:
            badge(text: "Scheduled", color: .gray, dot: false)
        case .onTime:
            badge(text: "On time", color: .green, dot: true)
        case .late(let m):
            badge(text: "\(m) min late", color: .orange, dot: true)
        case .early(let m):
            badge(text: "\(m) min early", color: .blue, dot: true)
        case .canceled:
            badge(text: "Canceled", color: .red, dot: false)
        }
    }

    @ViewBuilder
    private func badge(text: String, color: Color, dot: Bool) -> some View {
        HStack(spacing: 4) {
            if dot {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.caption2).bold()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundColor(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Hill badge + sparkline

/// Small "↗ 240 ft" pill shown next to a bike leg's title. Color-coded by
/// how hard the climbing is — green for flat, orange for hilly, red for steep.
struct HillBadge: View {
    let profile: ElevationProfile

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 9))
            Text(profile.chipLabel)
                .font(.caption2).bold()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundColor(color)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch profile.difficulty {
        case .flat:    return .green
        case .rolling: return .blue
        case .hilly:   return .orange
        case .steep:   return .red
        }
    }
}

/// Line-chart of elevation along the leg. Values are normalized to the
/// sample min/max so you see the *shape* of the hills, not absolute altitude.
struct ElevationSparkline: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geo in
            if samples.count < 2 {
                EmptyView()
            } else {
                let lo = samples.min() ?? 0
                let hi = samples.max() ?? 1
                let range = max(hi - lo, 1)   // avoid divide-by-zero on flat legs
                let w = geo.size.width
                let h = geo.size.height
                let step = w / CGFloat(samples.count - 1)

                ZStack {
                    // Filled area under the curve
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        for (i, v) in samples.enumerated() {
                            let x = CGFloat(i) * step
                            let y = h - CGFloat((v - lo) / range) * h
                            p.addLine(to: CGPoint(x: x, y: y))
                        }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(Color.green.opacity(0.18))

                    // Stroke on top
                    Path { p in
                        for (i, v) in samples.enumerated() {
                            let x = CGFloat(i) * step
                            let y = h - CGFloat((v - lo) / range) * h
                            if i == 0 {
                                p.move(to: CGPoint(x: x, y: y))
                            } else {
                                p.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.green, lineWidth: 1.5)
                }
            }
        }
    }
}
