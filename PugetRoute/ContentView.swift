import SwiftUI
import MapKit
import CoreLocation

// Bike-lane scoring helpers (bikeLaneDistances, bikeLaneFraction,
// bikeLaneBucket, isBikeInfrastructure, seattleBikeCorridors) live in
// BikeInfra.swift so the map renderers can share them.
//
// Trip planning logic (planTrip, safePlan, mergeBikeOnly, mergeBikeTransit,
// filterForMode, filterPastStarts, dedupeByTransitStops, normalizeStop)
// lives in Planning.swift as an `extension ContentView`. The properties
// that extension touches are declared internal (default access) below
// rather than `private` so the cross-file extension can read/write them.

struct ContentView: View {
    @StateObject var location = LocationManager()

    @State var fromQuery = ""
    @State private var toQuery   = ""
    @State var fromCoord: CLLocationCoordinate2D?
    @State var toCoord:   CLLocationCoordinate2D?

    @State private var mode: TripMode = .bikeTransit
    @State private var itineraries: [Itinerary] = []
    @State private var selectedItinerary: Itinerary?
    @State var isLoading = false
    @State var errorMessage: String?

    /// Full itinerary lists for every mode, cached so switching modes in the
    /// bottom bar doesn't require a re-fetch. Populated by `planTrip()` which
    /// fires all three queries in parallel.
    @State var modeItineraries: [TripMode: [Itinerary]] = [:]

    /// Which field is currently presenting the place-search sheet (nil = none).
    enum SearchTarget: Identifiable { case from, to; var id: Int { hashValue } }
    @State private var searchTarget: SearchTarget?

    /// Search target to open after the trip-detail sheet finishes
    /// dismissing. SwiftUI only allows one sibling `.sheet` at a time on
    /// a given view, so when the user taps a From/To row while detail is
    /// up we close detail first and chain the search open via the
    /// `onChange(of: detailItinerary)` handler below.
    @State private var pendingSearchAfterDetailClose: SearchTarget?

    /// Departure/arrival target for the trip.
    @State var when: TimeTarget = .leaveNow
    @State private var showTimePicker = false

    /// Routing preference (fastest vs. less biking/walking vs. safer bike).
    @State var preference: RoutePreference = .fastest
    @State private var showPrefs = false

    /// User's preferred biking pace, persisted across launches. Threads through
    /// the OTP `bikeSpeed` variable, the climb-penalized duration math, and the
    /// live ETA in NavigationView. Default is `.moderate` (~5 m/s ≈ 11 mph),
    /// roughly the OTP default; users who consistently bike faster can bump
    /// this up so estimates and bus-catching connections actually reflect them.
    @AppStorage("bikePace") var bikePace: BikePace = .moderate

    /// Whether the user is riding a standard bike or an e-bike. Default
    /// is `.standard`. When set to `.electric`, OTP receives a fixed
    /// 18 mph bike speed plus a quick-favoring triangle, and the client-
    /// side climb penalty drops from 3.9 to 1.0 s/m. See `BikeKind`.
    @AppStorage("bikeKind") var bikeKind: BikeKind = .standard

    /// "Lime mode" switch — when on, the bike-only and bike+transit
    /// pills query Lime bikeshare instead of own-bike. The pills'
    /// visual position doesn't change; only their query payload does.
    /// A small indicator above the mode bar surfaces the active state
    /// so the user can't forget the toggle is on. Mid-trip reroutes in
    /// NavigationView read this same flag so a Lime trip stays on Lime
    /// if the rider goes off-route. Defaults to off.
    @AppStorage("useLime") var useLime: Bool = false

    /// Itinerary currently shown in the detail sheet (nil = none).
    @State private var detailItinerary: Itinerary?

    /// Whether the bottom-panel sheet is presented. Mirrors
    /// `!modeItineraries.isEmpty && detailItinerary == nil` but as a
    /// real @State so SwiftUI's sheet machinery can drive both sides
    /// of the binding (read for display, write when user swipes the
    /// sheet down). Kept in sync via `.onChange` modifiers below.
    /// Using a real binding (rather than a computed one with a no-op
    /// setter) avoids quirks where the sheet's
    /// `presentationBackgroundInteraction` doesn't take effect.
    @State private var bottomPanelPresented: Bool = false

    /// Currently-selected sheet detent for the bottom panel. Bound to
    /// `presentationDetents(_:selection:)` so we can force the initial
    /// detent (small — just the time chips + mode bar visible) and
    /// react to drag-induced detent changes if needed. Default
    /// `.height(140)` matches the smallest detent in the list below.
    @State private var bottomPanelDetent: PresentationDetent = .height(140)

    /// Bike-rack annotations rendered on the main map for the
    /// currently-selected itinerary. Refreshed via `.task(id:)` below
    /// whenever `selectedItinerary` changes; cleared while no
    /// itinerary is selected so a freshly-tapped destination doesn't
    /// briefly show stale rack pins from the previous trip.
    @State private var bikeRacks: [BikeRack] = []

    var body: some View {
        ZStack {
            ItineraryMapView(itinerary: selectedItinerary, bikeRacks: bikeRacks)
                .ignoresSafeArea()

            // Top: search bar, the Lime toggle button under it, and any
            // loading/error hint. The Lime toggle is always visible (not
            // buried in preferences) because changing it changes what the
            // bike pills query — making it a one-tap control under the
            // search bars matches "what mode am I planning in?"
            VStack(spacing: 8) {
                searchCard
                limeToggleButton
                if isLoading {
                    ProgressView().padding(8)
                } else if let err = errorMessage {
                    Text(err).font(.caption).foregroundColor(.red).padding(6)
                }
            }
            .padding(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Bottom panel is presented as a native `.sheet` with
            // detents (see modifier below). The previous custom
            // ZStack-overlay version had hand-rolled drag handling
            // that fought SwiftUI; the native sheet gives us
            // bulletproof drag-to-resize plus the standard pill
            // affordance. The smallest detent (140 pt) acts as the
            // "collapsed" state — just enough to show time chips + the
            // mode bar — while medium/large reveal the alternates
            // list. Search bar and Lime toggle stay tappable at the
            // small detent because `presentationBackgroundInteraction
            // (.enabled)` lets touches reach the ZStack below.
        }
        .animation(.easeInOut(duration: 0.2), value: detailItinerary != nil)
        .onAppear {
            location.requestWhenInUse()
            location.requestOneShotLocation()
            // Default From to the user's current location. If they want to
            // change it they can tap the From row inside the search sheet.
            if fromQuery.isEmpty { fromQuery = "Your location" }

            // UI-test affordance: when launched with `--ui-test-from
            // <lat>,<lon>`, pre-seed `fromCoord` synchronously at app
            // launch instead of waiting for CoreLocation. Without this,
            // Maestro/XCUITest flows that pick a destination immediately
            // after launch hit the place-search sheet flipping to the
            // From field (because fromCoord is still nil), which
            // requires an extra interaction to resolve. The arg only
            // affects fromCoord; the rest of the location pipeline
            // (CoreLocation, live tracking during nav) continues as
            // normal. Production builds shouldn't see this arg.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--ui-test-from"),
               i + 1 < args.count {
                let parts = args[i + 1].split(separator: ",")
                if parts.count == 2,
                   let lat = Double(parts[0]),
                   let lon = Double(parts[1]) {
                    fromCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    // fromQuery stays as "Your location" — the trip's
                    // origin still semantically equals current location,
                    // and downstream code (e.g., the detail page's
                    // `isAtTripStart` check) reads the literal string.
                }
            }
        }
        .onChange(of: location.lastLocation?.coordinate.latitude) { _, _ in
            // Bind the live GPS fix to the "Your location" default as soon
            // as CoreLocation delivers one.
            if fromQuery == "Your location", let c = location.lastLocation?.coordinate {
                fromCoord = c
            }
        }
        .task(id: selectedItinerary?.id) {
            // Pull bike-rack annotations for every bike-leg endpoint
            // in the selected itinerary. Cancelled and re-fired by
            // SwiftUI whenever the user taps a different itinerary
            // (the .id keys it). Empty array on no-selection, on
            // Lime mode (the user isn't parking their own bike, they
            // drop the Lime within the geofence), or on any fetch
            // failure — racks are decorative, never gating.
            guard let it = selectedItinerary, !useLime else {
                bikeRacks = []
                return
            }
            bikeRacks = await BikeRackService.racksForBikeLegEndpoints(it)
        }
        // Lime toggle flipping has to invalidate the rack annotations
        // — without this, switching mid-session leaves stale racks on
        // (or missing from) the map. SwiftUI doesn't otherwise re-fire
        // the .task above when only useLime changes (it's keyed on
        // selectedItinerary). On-toggle: clear if Lime is now on; if
        // Lime is now off and we have a selected itinerary, refetch.
        .onChange(of: useLime) { _, nowLime in
            if nowLime {
                bikeRacks = []
            } else if let it = selectedItinerary {
                Task { bikeRacks = await BikeRackService.racksForBikeLegEndpoints(it) }
            }
        }
        // Clear any stuck error message whenever the user opens an
        // input sheet. Without this, an earlier "No routes found"
        // overlay can linger and make the UI feel broken: the user
        // adjusts inputs but sees the same error until something
        // explicit clears it. Tying the reset to sheet presentation
        // means every retry attempt starts from a clean state, no
        // matter which input the user touched. See bug T2.
        .onChange(of: showTimePicker) { _, isPresented in
            if isPresented { errorMessage = nil }
        }
        .onChange(of: showPrefs) { _, isPresented in
            if isPresented { errorMessage = nil }
        }
        .onChange(of: searchTarget) { _, target in
            if target != nil { errorMessage = nil }
        }
        // Drive the bottom-panel sheet: show whenever we have
        // itineraries and **no other modal is up**. SwiftUI sheets at
        // the same view level fight each other — opening a second one
        // while one is presented just silently drops the new
        // presentation. The cleanest workaround is to keep the
        // bottom-panel sheet at ContentView level alongside the
        // others, and have any modal (search, prefs, time picker,
        // trip detail) explicitly dismiss the panel sheet by flipping
        // `bottomPanelPresented` to false. Once the modal closes, the
        // panel reappears because `modeItineraries` is still
        // populated. The bottom-panel sheet behaves like a
        // "background view" that other modals temporarily take
        // priority over — same pattern Apple Maps uses.
        .onChange(of: modeItineraries.isEmpty) { _, _ in
            updateBottomPanelVisibility()
        }
        .onChange(of: showTimePicker) { _, _ in
            updateBottomPanelVisibility()
        }
        .onChange(of: showPrefs) { _, _ in
            updateBottomPanelVisibility()
        }
        .onChange(of: searchTarget) { _, _ in
            updateBottomPanelVisibility()
        }
        // Chain: if the user tapped a From/To row while trip-detail was
        // up, we dismissed detail first (see openSearch) and stashed the
        // target. After detail finishes dismissing, present search.
        // Small delay matches the sheet dismiss animation so SwiftUI's
        // sheet queue doesn't drop the second presentation.
        //
        // Observes `detailItinerary != nil` (Bool) rather than the
        // optional itself so we don't need Itinerary to be Equatable —
        // all we care about is the transition to nil.
        //
        // Also re-checks bottom-panel visibility — when detail opens
        // the panel dismisses; when detail closes it re-presents (if
        // itineraries remain).
        .onChange(of: detailItinerary != nil) { _, isPresent in
            updateBottomPanelVisibility()
            guard !isPresent,
                  let pending = pendingSearchAfterDetailClose else { return }
            pendingSearchAfterDetailClose = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                searchTarget = pending
            }
        }
        // Persistent bottom panel — presented as a native sheet so the
        // drag-to-resize works natively. The smallest detent shows just
        // time chips + mode bar (panel-as-status-bar); medium/large
        // reveal the alternates list. `presentationBackgroundInteraction
        // (.enabled)` keeps the searchCard and Lime toggle tappable at
        // the small detent — without it, the sheet captures all
        // touches and the search bar goes dead. We bind `selection` to
        // `bottomPanelDetent` so the sheet starts at the small detent
        // every time it presents.
        .sheet(isPresented: $bottomPanelPresented) {
            bottomPanelSheetContent
                .presentationDetents(
                    [.height(140), .height(bottomPanelContentFitHeight)],
                    selection: $bottomPanelDetent
                )
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
        }
        .sheet(isPresented: $showTimePicker) {
            TimeTargetSheet(target: $when) {
                if fromCoord != nil && toCoord != nil { planTrip() }
            }
            .presentationDetents([.height(340), .medium])
        }
        .sheet(isPresented: $showPrefs) {
            PreferencesSheet(preference: $preference, bikePace: $bikePace, bikeKind: $bikeKind) {
                if fromCoord != nil && toCoord != nil { planTrip() }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $detailItinerary) { it in
            ItineraryDetailView(
                itinerary: it,
                mode: mode,
                preference: preference,
                isAtTripStart: fromQuery == "Your location"
            )
            .presentationDetents([.height(260), .medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .height(260)))
            .interactiveDismissDisabled(false)
        }
        .sheet(item: $searchTarget) { target in
            PlaceSearchSheet(
                initialField: target == .from ? .from : .to,
                fromQuery: $fromQuery,
                fromCoord: $fromCoord,
                toQuery:   $toQuery,
                toCoord:   $toCoord,
                lastLocation: location.lastLocation,
                onCommit: {
                    if fromCoord != nil && toCoord != nil { planTrip() }
                }
            )
        }
    }

    /// Recompute whether the bottom-panel sheet should be visible.
    /// Called from the various `.onChange` handlers above. The panel
    /// is shown only when there are itineraries to display *and*
    /// no other modal is competing for the screen. SwiftUI sheet
    /// modifiers attached at the same view level can't coexist
    /// visually — only one can be the active sheet — so we
    /// explicitly hide the panel whenever any of search / prefs /
    /// time picker / trip detail is up, then bring it back when
    /// they dismiss.
    private func updateBottomPanelVisibility() {
        let anyModalUp = showTimePicker
            || showPrefs
            || searchTarget != nil
            || detailItinerary != nil
        bottomPanelPresented = !modeItineraries.isEmpty && !anyModalUp
    }

    /// Computed sheet height that fits the panel's content — tall
    /// enough to show the time chips, mode bar, and every itinerary
    /// row of whichever mode has the most. Replaces `.medium` /
    /// `.large` as the "expanded" detent so the user can't drag the
    /// sheet larger than it needs to be (which leaves a chunk of
    /// blank white space below the last row).
    ///
    /// We sum the height of the **max-count** mode (not the current
    /// mode) so that toggling between bike-only / bike+transit /
    /// transit-only doesn't change the detent set. When the detent
    /// set changes mid-presentation, SwiftUI snaps the sheet to the
    /// nearest detent — usually the small one — which feels like
    /// the sheet auto-collapses every time the user picks a mode.
    /// Using the max count keeps the detents stable; modes with
    /// fewer rows show a small amount of trailing blank space at
    /// most, which is preferable to the snap-back annoyance.
    ///
    /// Heights are approximate, measured against the rendered output
    /// of ItineraryRow on iPhone 17 Pro at iOS 26.5. Rows can vary
    /// (Lime badge, hill badge) but the per-row budget absorbs it.
    private var bottomPanelContentFitHeight: CGFloat {
        // Compact base: drag indicator + time chips + mode bar + a
        // small breathing space. Slightly less than the smallest
        // detent (140) because the small detent leaves room for one
        // peek-preview row, while the header alone is tighter.
        let headerHeight: CGFloat = 110
        // Each itinerary row + its trailing divider.
        let rowHeight: CGFloat = 95
        // Top divider that separates the mode bar from the list.
        let listChrome: CGFloat = 8

        // Max rows across all modes — keeps the detent stable when
        // the user switches modes. Falls back to 1 row if no
        // itineraries are loaded yet (defensive; the sheet shouldn't
        // be presented in that case anyway).
        let maxRowCount = max(1, modeItineraries.values.map(\.count).max() ?? 1)
        return headerHeight + listChrome + CGFloat(maxRowCount) * rowHeight
    }

    // MARK: - Subviews

    /// Two-row search card: From on top, To below, with a swap button on the
    /// right that flips the two endpoints. The From row is pre-filled with
    /// "Your location" on first launch; tapping either row opens the
    /// place-search sheet focused on that field.
    private var searchCard: some View {
        HStack(spacing: 8) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.green)
                        .frame(width: 14)
                    placeRow(
                        text: fromQuery.isEmpty ? "Choose start" : fromQuery,
                        isPlaceholder: fromQuery.isEmpty
                    ) {
                        openSearch(.from)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .frame(width: 14)
                    placeRow(
                        text: toQuery.isEmpty ? "Where to?" : toQuery,
                        isPlaceholder: toQuery.isEmpty
                    ) {
                        openSearch(.to)
                    }
                }
            }
            // Right rail: preferences icon on top of swap, both small and
            // circular. Preferences moved up here from the bottom time row
            // so it's discoverable in every mode (bike-only previously
            // hid it because RoutePreference doesn't drive bike-only
            // results — but BikePace still does, and users shouldn't have
            // to guess where to find their pace setting).
            VStack(spacing: 6) {
                Button { showPrefs = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .padding(6)
                        .background(Color(.tertiarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preferences")

                Button(action: swapEndpoints) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .padding(8)
                        .background(Color(.tertiarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(fromQuery.isEmpty && toQuery.isEmpty)
                .opacity((fromQuery.isEmpty && toQuery.isEmpty) ? 0.4 : 1)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Exchange From and To (both display string and resolved coordinate) and
    /// re-plan if both endpoints are set. Reaches into `planTrip()` instead of
    /// just clearing results so the user gets the swapped route immediately.
    /// Open the place-search sheet for the given field. If the
    /// trip-detail sheet is currently up, dismiss it first and let the
    /// `onChange(of: detailItinerary)` handler open search after the
    /// dismiss animation — SwiftUI only presents one sibling sheet at a
    /// time, so we can't just stack them.
    private func openSearch(_ target: SearchTarget) {
        if detailItinerary != nil {
            pendingSearchAfterDetailClose = target
            detailItinerary = nil
        } else {
            searchTarget = target
        }
    }

    private func swapEndpoints() {
        let savedQuery = fromQuery
        let savedCoord = fromCoord
        fromQuery = toQuery
        fromCoord = toCoord
        toQuery = savedQuery
        toCoord = savedCoord
        if fromCoord != nil && toCoord != nil {
            planTrip()
        }
    }

    /// Tappable "text field" that opens the place-search sheet.
    private func placeRow(text: String, isPlaceholder: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(text)
                .foregroundColor(isPlaceholder ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    /// Horizontal bar of three mode pills — Bike only, Bike + Transit, Transit
    /// only — that sits as the header row of the bottom panel, visually fused
    /// with the itinerary list below.
    private var modeBar: some View {
        HStack(spacing: 6) {
            modePill(.bikeOnly)
            modePill(.bikeTransit)
            modePill(.transitOnly)
        }
    }

    /// Always-visible pill below the search card that toggles Lime mode.
    /// Off state: outlined, gray, "Use Lime". On state: filled lime
    /// green, "Lime mode on" with a small check glyph. Tap toggles and
    /// re-fires `planTrip` so the new pill state takes effect
    /// immediately without the user having to nudge another input.
    private var limeToggleButton: some View {
        Button {
            useLime.toggle()
            if fromCoord != nil && toCoord != nil {
                planTrip()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: useLime ? "checkmark.circle.fill" : "bicycle")
                    .font(.caption).bold()
                Text(useLime ? "Lime mode on" : "Use Lime")
                    .font(.caption).bold()
            }
            .foregroundColor(useLime ? .white : Palette.lime)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if useLime {
                    Capsule().fill(Palette.lime)
                } else {
                    Capsule().fill(Color(.tertiarySystemBackground))
                }
            }
            .overlay(
                Capsule().strokeBorder(
                    Palette.lime.opacity(useLime ? 0 : 0.55),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(useLime ? "Lime mode on. Tap to switch back to your own bike." : "Use Lime. Tap to plan trips with Lime bikeshare instead of your own bike.")
    }

    /// Single pill inside the mode bar. Shows the mode's icons and either the
    /// fastest duration (when itineraries are available for that mode) or a
    /// "—" dash when that mode has no results yet. Content uses a small font
    /// and a single-line layout so the icon(s) + duration always fit together.
    private func modePill(_ m: TripMode) -> some View {
        let isActive = (m == mode)
        // Show the duration of the FIRST itinerary in the sorted list
        // for this mode, not the minimum across all alternatives. The
        // sort uses bike-lane fraction as a primary key, so the
        // listed-first route isn't always the shortest — a high-lane
        // 35-min route can outrank a low-lane 28-min one. The pill
        // should match what the user sees when they tap in, which is
        // the first listed row. Falling back to `nil` (which disables
        // the pill) when no itineraries returned at all.
        let fastest = modeItineraries[m]?.first?.effectiveDurationSeconds
        return Button {
            if mode != m {
                mode = m
                updateCurrentItineraries()
            }
        } label: {
            HStack(spacing: 4) {
                modeIcons(for: m)
                Text(durationLabel(for: fastest))
                    .bold()
            }
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .foregroundColor(isActive ? .white : .primary)
            .background {
                if isActive {
                    Capsule().fill(Color.accentColor)
                } else {
                    Capsule().fill(Color(.tertiarySystemBackground))
                }
            }
            .overlay(
                Capsule().strokeBorder(
                    isActive ? Color.clear : Color.secondary.opacity(0.2),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(fastest == nil)
        .opacity(fastest == nil ? 0.55 : 1)
    }

    /// SF Symbol(s) for a given mode. Bike + Transit shows two icons side by
    /// side so the "multimodal" nature is obvious at a glance.
    @ViewBuilder
    private func modeIcons(for m: TripMode) -> some View {
        switch m {
        case .bikeOnly:
            Image(systemName: "bicycle")
        case .bikeshare:
            // Bikeshare uses the same bike glyph tinted Lime green so
            // the pill reads "bike, but rental" at a glance. The pill
            // background also picks up the Lime accent in `modeBar`.
            Image(systemName: "bicycle")
                .foregroundColor(.green)
        case .bikeTransit:
            HStack(spacing: 1) {
                Image(systemName: "bicycle")
                Image(systemName: "tram.fill")
            }
        case .transitOnly:
            Image(systemName: "tram.fill")
        }
    }

    /// Content of the persistent bottom-panel sheet. The sheet
    /// modifier (in `body`) provides the chrome (drag indicator,
    /// rounded corners, material), so this view is just the
    /// contents: time chips at the top, mode bar, then the
    /// scrollable itinerary list. At the smallest detent only the
    /// time chips + mode bar fit; medium/large reveal the list.
    private var bottomPanelSheetContent: some View {
        VStack(spacing: 0) {
            timeRow
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            modeBar
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            if !itineraries.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(itineraries.enumerated()), id: \.element.id) { idx, it in
                            ItineraryRow(
                                itinerary: it,
                                isSelected: selectedItinerary?.id == it.id
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedItinerary = it
                                detailItinerary = it
                            }
                            if idx < itineraries.count - 1 {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
        }
    }

    /// True when the currently-displayed itineraries include at
    /// least one whose start time is already in the past. Drives
    /// the refresh affordance in the bottom panel — once the user's
    /// soonest planned option has slipped behind clock time, the
    /// remaining options are stale and a re-plan is the right move.
    private var hasStaleItineraries: Bool {
        let now = Date()
        return itineraries.contains { $0.startDate < now }
    }

    /// Format a total-seconds duration as "12 min" or "1 h 5 min" / "2 h".
    /// Returns "—" for a nil duration so the pill renders a visible but
    /// de-emphasized placeholder while that mode's query is still in flight.
    ///
    /// Uses **truncating** integer division (not nearest-minute rounding)
    /// so the pill always matches `Itinerary.durationMinutes`, which
    /// itself does `effectiveDurationSeconds / 60`. Earlier this used
    /// `.rounded()` which produced an off-by-one display bug: a 2510-
    /// second trip showed as "42 min" on the pill but "41 min" on its
    /// row, because the pill rounded up and the row truncated.
    private func durationLabel(for seconds: Int?) -> String {
        guard let s = seconds else { return "—" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// Chip that shows the current depart/arrive target and opens the picker.
    private var timeRow: some View {
        HStack(spacing: 8) {
            Button {
                showTimePicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: when.arriveBy ? "flag.checkered" : "clock")
                    Text(when.chipLabel).font(.subheadline).bold()
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            // Icon-only refresh affordance — visible only when at
            // least one of the currently-shown itineraries has a
            // start time already in the past (the soonest options
            // have slipped behind clock time). Tapping fires
            // planTrip() with the current time. Hidden while a plan
            // is already in flight so we don't double-fire.
            if hasStaleItineraries && !isLoading {
                Button {
                    planTrip()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline).bold()
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh trip options")
            }

            // Preferences moved to the small slider icon at the top of
            // the screen (next to the swap button) so it's reachable in
            // every mode without crowding the time row. Used to live
            // here as a chip that was conditionally hidden in bike-only
            // mode; now it's always available from the top icon.

            Spacer()

            if case .leaveNow = when {
                EmptyView()
            } else {
                Button {
                    when = .leaveNow
                    if fromCoord != nil && toCoord != nil { planTrip() }
                } label: {
                    Text("Now").font(.caption).bold()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    /// Pull itineraries for the currently-selected mode out of the cache and
    /// assign them to the visible list. Called on mode switch and after each
    /// successful `planTrip()`.
    func updateCurrentItineraries() {
        let its = modeItineraries[mode] ?? []
        itineraries = its
        // Keep the currently-selected itinerary if it still exists in the
        // new list; otherwise snap to the fastest option for this mode.
        let keepCurrent = selectedItinerary.map { cur in
            its.contains(where: { $0.id == cur.id })
        } ?? false
        if !keepCurrent {
            selectedItinerary = its.first
        }
    }

}

#Preview {
    ContentView()
}
