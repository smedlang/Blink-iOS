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
        // Collect (label, tint) pairs — one per capsule. For bike/walk
        // that's a single duration label tinted by the leg's mode; for
        // transit it's the primary route plus each alternative, with
        // each capsule tinted by *its own* route's brand color so a
        // chip row like "1 Line / 2 Line" renders Link 1 green next to
        // Link 2 blue instead of two green chips. Earlier all chips
        // used the leg's primary `transitBrand`, which made every
        // alternative inherit the primary's color.
        let entries: [(label: String, tint: Color)] = {
            switch leg.mode {
            case "BICYCLE", "BICYCLE_RENT", "WALK":
                return [(Itinerary.formatMinutes(leg.durationMinutes), tint(for: leg))]
            default:
                let primaryLabel = routeChipName(for: leg.route) ?? leg.mode.capitalized
                let primaryTint = leg.transitBrand(for: leg.route).color
                var out: [(String, Color)] = [(primaryLabel, primaryTint)]
                for alt in leg.alternativeRoutes {
                    guard let label = routeChipName(for: alt) else { continue }
                    out.append((label, leg.transitBrand(for: alt).color))
                }
                return out
            }
        }()
        return HStack(spacing: 4) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                singleChip(
                    icon: iconName(for: leg.mode),
                    label: entry.label,
                    tint: entry.tint
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
        if leg.isTransit { return leg.transitBrand.color }
        switch leg.mode {
        case "BICYCLE", "BICYCLE_RENT":
            // Pine green #00875A — matches the bike-on-infra polyline
            // color in the map and nav renderers. Single source of
            // truth lives in `Palette.bikeInfra`.
            return Palette.bikeInfra
        case "WALK":                    return .gray
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
    /// True when the trip's "from" is the user's current GPS location,
    /// so launching live navigation makes sense (the user can actually
    /// follow the directions from here). False when planning from a
    /// non-current origin (e.g. "Capitol Hill → Golden Gardens" from
    /// the couch at work) — there's no GPS anchor for nav, so we
    /// downgrade the action to a Preview-mode read of the steps.
    var isAtTripStart: Bool = true
    @Environment(\.dismiss) private var dismiss
    @State private var showNavigation = false
    @State private var showPreviewSteps = false

    var body: some View {
        // Single reconciled timeline drives every clock-time + duration
        // on this page so they can't disagree. See
        // `Itinerary.effectiveTimeline` for the model.
        let timeline = itinerary.effectiveTimeline()
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(timeline: timeline)
                    goButton
                    Divider()
                    ForEach(Array(itinerary.legs.enumerated()), id: \.offset) { idx, leg in
                        let entry = timeline.indices.contains(idx) ? timeline[idx] : nil
                        // Surface a "wait X min" hint or a missed-connection
                        // warning before this leg when relevant. Only shows
                        // up between legs (idx > 0) since the gap is
                        // relative to the previous leg's end.
                        if idx > 0, let entry = entry {
                            connectionRow(for: entry, leg: leg)
                        }
                        LegDetailRow(leg: leg, timeline: entry)
                        if idx < itinerary.legs.count - 1 {
                            Divider().padding(.leading, 36)
                        }
                    }
                    Divider()
                    arriveFooter(timeline: timeline)
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
                TripNavigationView(
                    itinerary: itinerary,
                    mode: mode,
                    preference: preference,
                    isPreview: !isAtTripStart
                )
            }
            .sheet(isPresented: $showPreviewSteps) {
                PreviewStepsList(itinerary: itinerary)
            }
        }
    }

    private var goButton: some View {
        // Three states for the primary action button:
        //
        // 1. Past trip (`itinerary.isPast`)        — gray, disabled,
        //    "Trip has already departed."
        // 2. Not-at-start (`!isAtTripStart`)       — outlined accent,
        //    "Preview ›››", no icon. Inert label — the actual
        //    step list is rendered just below by ForEach over the
        //    legs, so this button is purely a state indicator.
        // 3. Default (at start, not past)          — filled accent,
        //    "GO", launches live navigation with GPS tracking.
        //
        // All three render the same shape and height so the layout
        // doesn't shift between alternates as the user picks
        // different itineraries.
        let isPast = itinerary.isPast
        let isPreview = !isPast && !isAtTripStart
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                // Preview opens a flat step list in a sheet; live nav
                // launch only happens in the at-start, non-past case.
                if isPast { return }
                if isPreview { showPreviewSteps = true }
                else        { showNavigation = true }
            } label: {
                HStack {
                    if let icon = buttonIcon(isPast: isPast, isPreview: isPreview) {
                        Image(systemName: icon)
                    }
                    Text(buttonText(isPast: isPast, isPreview: isPreview)).bold()
                }
                .font(.title3)
                .foregroundColor(buttonForeground(isPast: isPast, isPreview: isPreview))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(buttonBackground(isPast: isPast, isPreview: isPreview))
            }
            .buttonStyle(.plain)
            .disabled(isPast)
            // Past-trip hint only — the disabled gray state isn't
            // obvious on its own. The Preview state stands on its
            // own with the button label + outlined style.
            if isPast {
                Text("You're viewing this trip's schedule. To plan a new trip, adjust the time.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func buttonIcon(isPast: Bool, isPreview: Bool) -> String? {
        if isPast    { return "clock.badge.xmark" }
        if isPreview { return nil }
        return "location.north.line.fill"
    }

    private func buttonText(isPast: Bool, isPreview: Bool) -> String {
        if isPast    { return "Trip has already departed" }
        if isPreview { return "Preview  ›››" }
        return "GO"
    }

    private func buttonForeground(isPast: Bool, isPreview: Bool) -> Color {
        if isPast    { return .white }
        if isPreview { return .accentColor }
        return .white
    }

    @ViewBuilder
    private func buttonBackground(isPast: Bool, isPreview: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        if isPast {
            shape.fill(Color.gray)
        } else if isPreview {
            shape
                .fill(Color.accentColor.opacity(0.08))
                .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 1.5))
        } else {
            shape.fill(Color.accentColor)
        }
    }

    private func header(timeline: [LegTimeline]) -> some View {
        // Header reads its total + range off the reconciled timeline
        // so a delayed bus + wait at the stop are reflected in the
        // top-line "X min" and the time range, instead of the page
        // saying "18 min, 6:41 → 6:59" while the legs below sum to
        // something else.
        let first = timeline.first?.startDate ?? itinerary.startDate
        let last  = timeline.last?.endDate ?? itinerary.endDate
        let totalSecs = max(0, Int(last.timeIntervalSince(first)))
        return VStack(alignment: .leading, spacing: 4) {
            Text(Itinerary.formatMinutes(totalSecs / 60))
                .font(.largeTitle).bold()
            Text(Self.formatHM(first) + " → " + Self.formatHM(last))
                .font(.subheadline).foregroundColor(.secondary)
            summaryRow
        }
    }

    /// "Wait 6 min" line shown between two legs when the gap is
    /// big enough to flag (≥ 60 s), and a "Bike pace would miss
    /// this bus by X min" warning when the gap is negative.
    @ViewBuilder
    private func connectionRow(for entry: LegTimeline, leg: Leg) -> some View {
        if entry.missedConnection {
            // Negative wait — at the rider's stamped pace they'd
            // arrive after the bus pulls away. Surface this so the
            // trip isn't silently inconsistent. The user can drop
            // pace in Preferences or pick a different itinerary.
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Bike pace would miss this connection by \(Int(ceil(-entry.waitBefore / 60))) min")
            }
            .font(.caption).bold()
            .foregroundColor(.red)
            .padding(.leading, 36)
        } else if entry.waitBefore >= 60 {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text("Wait \(Int(entry.waitBefore / 60)) min")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.leading, 36)
        }
    }

    /// "3:45 PM" formatter. Static so `LegDetailRow` can use the
    /// same one without leaning on `Leg` / `Itinerary` string
    /// accessors (those still read OTP-raw times rather than the
    /// reconciled timeline).
    static func formatHM(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    /// Trip summary line below the time range. Same content as
    /// `itinerary.summary` but built as a view so each mode segment
    /// renders as a brand-colored capsule (cyan bike bubble for the
    /// bike portion, operator-colored bubbles for transit legs)
    /// rather than plain prose. Transit legs are separated by
    /// chevrons (›) rather than the "+" the string version uses,
    /// so the line reads like a sequence ("124 › 1 Line › 271")
    /// rather than an addition. Bike attributes (total climb feet,
    /// "steep" flag) stay as plain caption text — they describe the
    /// bike portion rather than being a leg of their own.
    private var summaryRow: some View {
        HStack(spacing: 6) {
            // Bike duration — pine green capsule with bicycle icon. Pine
            // green (#00875A) matches the bike-on-infra polyline color
            // the map renders for these legs. Sourced from `Palette`.
            if itinerary.bikeMinutes > 0 {
                summaryBubble(
                    icon: "bicycle",
                    label: "\(itinerary.bikeMinutes) min",
                    tint: Palette.bikeInfra
                )
            }
            // Total climb — mountain-icon capsule color-coded by trip
            // hill severity. Red for steep (any leg's peak grade ≥10%
            // or avg ≥5%), orange for moderate (peak ≥6% or avg ≥3%),
            // yellow otherwise. Same buckets as the per-leg HillBadge
            // so the trip-summary chip and the per-leg badges agree.
            if let label = hillBubbleLabel {
                if itinerary.bikeMinutes > 0 {
                    Text("•").font(.caption).foregroundColor(.secondary)
                }
                summaryBubble(
                    icon: "mountain.2.fill",
                    label: label,
                    tint: hillBubbleTint
                )
            }
            // Transit lines — each rendered as a brand-tinted capsule,
            // chevron between consecutive legs.
            let transitLegs = itinerary.legs.filter { $0.isTransit }
            if !transitLegs.isEmpty {
                let hasPrefix = itinerary.bikeMinutes > 0 || hillBubbleLabel != nil
                if hasPrefix {
                    Text("•").font(.caption).foregroundColor(.secondary)
                }
                ForEach(Array(transitLegs.enumerated()), id: \.offset) { idx, leg in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    summaryBubble(
                        icon: summaryBubbleIcon(for: leg.mode),
                        label: leg.route?.shortName ?? leg.route?.longName ?? "transit",
                        tint: leg.transitBrand.color
                    )
                }
            }
        }
    }

    /// Climb-feet label for the hill bubble. Returns nil when the
    /// trip's total climb is below ~10 m (33 ft) — trivially flat
    /// trips don't get a bubble at all. Returns "228 ft" otherwise.
    private var hillBubbleLabel: String? {
        let totalClimb = itinerary.legs.compactMap { $0.climbMeters }.reduce(0, +)
        guard totalClimb >= 10 else { return nil }
        let feet = Int((totalClimb * 3.28084).rounded())
        return "\(feet) ft"
    }

    /// Color for the hill bubble — encodes trip-level difficulty.
    /// Red for steep, orange for moderate, yellow otherwise (light
    /// elevation that's still worth flagging). Thresholds and
    /// precedence come from `Itinerary.hasSteepBikeLeg` /
    /// `hasModerateBikeLeg` which mirror the per-leg `HillBadge`
    /// classifier in `ElevationProfile.difficulty`.
    private var hillBubbleTint: Color {
        if itinerary.hasSteepBikeLeg { return .red }
        if itinerary.hasModerateBikeLeg { return .orange }
        return .yellow
    }

    /// Mini brand-colored capsule used by every bubble in the trip
    /// summary line. Matches the visual treatment of the option chip
    /// in `ItineraryRow.singleChip` (icon + label, tint × 0.15
    /// background, tint foreground, Capsule shape) but with tighter
    /// padding (6/2 instead of 8/4) since it sits inline with
    /// caption-sized secondary text rather than as a standalone
    /// affordance.
    private func summaryBubble(icon: String, label: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption).bold()
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundColor(tint)
        .background(tint.opacity(0.15), in: Capsule())
    }

    /// SF Symbol name for a leg's mode, used inside the summary-line
    /// transit bubbles. Mirrors the `iconName(for:)` mappings in
    /// `ItineraryRow` and `LegDetailRow`; duplicated here so the
    /// summary view doesn't need to reach into a sibling view's
    /// private helper.
    private func summaryBubbleIcon(for mode: String) -> String {
        switch mode {
        case "BICYCLE", "BICYCLE_RENT": return "bicycle"
        case "WALK":                    return "figure.walk"
        case "BUS":                     return "bus.fill"
        case "RAIL", "TRAM", "SUBWAY":  return "tram.fill"
        case "FERRY":                   return "ferry.fill"
        default:                        return "arrow.right"
        }
    }

    private func arriveFooter(timeline: [LegTimeline]) -> some View {
        // Last leg's reconciled end — covers realtime delays + wait
        // time, instead of the old itinerary.endDate which was
        // startDate + summed stamped durations and ignored both.
        let arrival = timeline.last?.endDate ?? itinerary.endDate
        return HStack(spacing: 10) {
            Image(systemName: "flag.checkered")
                .foregroundColor(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Arrive \(itinerary.legs.last?.to.name ?? "")")
                    .font(.subheadline).bold()
                Text(Self.formatHM(arrival))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

/// Flat, scrollable list of every maneuver in an itinerary —
/// presented as a sheet when the user taps "Preview ›››" from the
/// trip-detail view (i.e. when the trip's "from" isn't their
/// current location and live nav doesn't apply).
///
/// Rendering:
/// - One Section per leg, headed by leg type + duration.
/// - Walk / bike legs render each `WalkStep` as a row with its
///   turn icon, instruction ("Turn left onto Federal Ave E"),
///   and step distance.
/// - Transit legs render three rows: board (with effective
///   departure time + boarding stop), ride (duration + intermediate
///   stop count), alight (with effective arrival time + stop name).
/// - Times use the realtime-adjusted `effectiveStart/EndTimeString`
///   so a delayed bus shows the delayed time, same as live nav.
private struct PreviewStepsList: View {
    let itinerary: Itinerary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(itinerary.legs.enumerated()), id: \.offset) { idx, leg in
                    Section {
                        legContent(leg)
                    } header: {
                        legHeader(leg)
                    }
                }
            }
            .navigationTitle("Steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func legHeader(_ leg: Leg) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: leg))
                .foregroundColor(.accentColor)
            Text(headerText(for: leg))
        }
    }

    @ViewBuilder
    private func legContent(_ leg: Leg) -> some View {
        if leg.isTransit {
            transitRows(leg)
        } else if let steps = leg.steps, !steps.isEmpty {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                stepRow(step)
            }
        } else {
            // No detailed steps returned (rare — usually short walk
            // legs near transit stops). Fall back to the leg's
            // own summary line so the section isn't empty.
            HStack {
                Text(leg.from.name.isEmpty ? "Start" : leg.from.name)
                Spacer()
                if let d = leg.distanceString {
                    Text(d).font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func stepRow(_ step: WalkStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.icon)
                .frame(width: 22)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.instruction)
                    .font(.body)
                if step.distance >= 1 {
                    Text(formatStepDistance(step.distance))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func transitRows(_ leg: Leg) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Board at \(leg.effectiveStartTimeString)").bold()
            Text(leg.from.name).font(.caption).foregroundColor(.secondary)
        }
        Text("Ride \(leg.durationMinutes) min")
            .font(.caption).foregroundColor(.secondary)
        VStack(alignment: .leading, spacing: 2) {
            Text("Get off at \(leg.effectiveEndTimeString)").bold()
            Text(leg.to.name).font(.caption).foregroundColor(.secondary)
        }
    }

    private func iconName(for leg: Leg) -> String {
        switch leg.mode {
        case "BICYCLE", "BICYCLE_RENT": return "bicycle"
        case "WALK":                    return "figure.walk"
        case "BUS":                     return "bus.fill"
        case "RAIL", "TRAM", "SUBWAY":  return "tram.fill"
        case "FERRY":                   return "ferry.fill"
        default:                        return "arrow.right"
        }
    }

    private func headerText(for leg: Leg) -> String {
        if leg.isTransit { return leg.displayName }
        switch leg.mode {
        case "BICYCLE", "BICYCLE_RENT":
            let label = leg.isRental ? "Lime bike" : "Bike"
            return "\(label) · \(leg.durationMinutes) min"
        case "WALK":
            return "Walk · \(leg.durationMinutes) min"
        default:
            return leg.displayName
        }
    }

    /// Step distance shown under the instruction — feet for short
    /// hops, miles otherwise. Mirrors the formatter in
    /// NavigationView's banner but lives here so this view doesn't
    /// reach into nav internals.
    private func formatStepDistance(_ meters: Double) -> String {
        let feet = meters * 3.28084
        if feet < 300 { return "\(Int((feet / 10).rounded()) * 10) ft" }
        let miles = meters / 1609.34
        return miles < 0.1 ? String(format: "%.2f mi", miles) : String(format: "%.1f mi", miles)
    }
}

/// Single leg row in the detail view.
private struct LegDetailRow: View {
    let leg: Leg
    /// Reconciled timeline entry for this leg, computed once by the
    /// parent view (`ItineraryDetailView`) so duration label, time
    /// range, and the "Board at ... / Get off at ..." times all
    /// agree. Nil only if the parent didn't pass one — falls back to
    /// the leg's own raw timestamps in that case (the pre-timeline
    /// behavior).
    var timeline: LegTimeline? = nil
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
                            Text("Board at \(boardTimeString)").bold()
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
                            Text("Get off at \(alightTimeString)").bold()
                            Text(leg.to.name).foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "mappin.circle.fill")
                            .font(.caption2).foregroundColor(tint)
                    }
                    .font(.caption)
                } else {
                    // Walk / bike block. Duration and time range both
                    // come from the reconciled timeline (passed in
                    // from `ItineraryDetailView`) so the "X min"
                    // label and the "h:mm → h:mm" range always agree,
                    // and the start time picks up any realtime
                    // delay from the previous transit leg.
                    HStack(spacing: 6) {
                        Text("\(displayMinutes) min")
                        if let d = leg.distanceString {
                            Text("·")
                            Text(d)
                        }
                        Text("·")
                        Text("\(timelineStartString) → \(timelineEndString)")
                    }
                    .font(.caption).foregroundColor(.secondary)

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
            // Show "{route} → {alight stop}" rather than the bus's
            // headsign destination. `Leg.displayName` reads
            // `headsign` (the bus's final destination as printed on
            // its front sign — useful when boarding, since that's
            // how you identify the right bus), but on the trip
            // detail page the rider already knows which bus to
            // board (the per-leg card has its own board/alight
            // block), so the title should say where THIS leg ends
            // up dropping them. Falls back to displayName if the
            // alight stop name is empty — defensive; OTP usually
            // populates `to.name` for transit legs.
            if let route = leg.route?.shortName ?? leg.route?.longName,
               !route.isEmpty,
               !leg.to.name.isEmpty {
                return "\(route) → \(leg.to.name)"
            }
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
        // sees on the route line. Sourced from `Palette`.
        if leg.isRental { return Palette.lime }
        // Transit legs use the route's brand color (Sound Transit
        // Link/Sounder/STRIDE/T Line where mapped; mode-default
        // otherwise) so the icon next to the leg row matches the
        // colored polyline on the map.
        if leg.isTransit { return leg.transitBrand.color }
        switch leg.mode {
        case "BICYCLE", "BICYCLE_RENT":
            // Pine green #00875A — see `Palette.bikeInfra`. Same color
            // used for the bike-on-infra polyline on the map.
            return Palette.bikeInfra
        case "WALK":                    return .secondary
        default:                        return .primary
        }
    }

    // MARK: - Timeline-derived strings
    //
    // All four read off `timeline?` when the parent passed one in
    // (every site that uses `LegDetailRow` from `ItineraryDetailView`
    // does), falling back to the leg's own raw timestamps so the row
    // still renders cleanly if someone reuses it elsewhere without
    // a timeline.

    /// `Itinerary.formatMinutes(...)` isn't accessible here (it's a
    /// static on a different type with the same name); inline the
    /// minute conversion. Floors below 1 → "1 min" so a sub-minute
    /// leg doesn't render "0 min · 200 ft."
    private var displayMinutes: Int {
        if let mins = timeline?.durationMinutes, mins >= 1 {
            return mins
        }
        return leg.durationMinutes
    }

    private var timelineStartString: String {
        ItineraryDetailView.formatHM(timeline?.startDate ?? leg.startDate)
    }

    private var timelineEndString: String {
        ItineraryDetailView.formatHM(timeline?.endDate ?? leg.endDate)
    }

    private var boardTimeString: String {
        ItineraryDetailView.formatHM(timeline?.startDate ?? leg.effectiveStartDate)
    }

    private var alightTimeString: String {
        ItineraryDetailView.formatHM(timeline?.endDate ?? leg.effectiveEndDate)
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
