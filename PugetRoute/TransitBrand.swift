import SwiftUI
import UIKit

/// Brand color for a transit route, plus its companion text color so
/// labels drawn over the brand background stay legible. Each value
/// looks up a `Leg`'s route and returns the operator/line's
/// official brand color when we know it, falling back to a
/// mode-based default for routes we haven't mapped yet.
///
/// Sound Transit's full brand spec covers Link 1-4, Link T
/// (Tacoma), Sounder N/S, and STRIDE S1/S2/S3. KC Metro covers
/// RapidRide A-I (dark red) and local routes (fluorescent
/// yellow). Seattle Streetcar (SDOT) covers the SLU and First
/// Hill lines. Washington State Ferries gets WSF green.
/// Community Transit, Pierce Transit, and Sound Transit Express
/// still fall through to the bus default (now yellow) — extend
/// the switch below when those brand books are ready and we
/// plumb the GTFS `agency` field through `RouteInfo` to
/// discriminate.
struct TransitBrand {
    /// SwiftUI Color for views (banners, badges, icon tints).
    let color: Color
    /// UIColor for UIKit-backed views (MKMapView polyline strokes,
    /// MKAnnotationView ring borders).
    let uiColor: UIColor
    /// Text color guaranteed to meet contrast minimums over `color`
    /// as the background. Brand colors like STRIDE yellow and Sounder
    /// lavender are too light for white text — `darkText: true` at
    /// construction picks black instead.
    let textColor: Color

    init(hex: UInt32, darkText: Bool = false) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8)  & 0xff) / 255
        let b = Double( hex        & 0xff) / 255
        let ui = UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
        self.uiColor = ui
        self.color = Color(ui)
        self.textColor = darkText ? .black : .white
    }

    init(systemColor: UIColor, darkText: Bool = false) {
        self.uiColor = systemColor
        self.color = Color(systemColor)
        self.textColor = darkText ? .black : .white
    }
}

/// Centralized color palette for the app. Everything that paints a
/// route, chip, or polyline reaches into here so a brand change is a
/// one-line edit instead of a hunt through view code. Transit lines are
/// `TransitBrand` instances (color + companion text color); non-transit
/// mode colors (bike, Lime rental) are exposed as paired `UIColor`
/// (for MKPolylineRenderer / UIKit) and `Color` (for SwiftUI views).
enum Palette {
    // MARK: Sound Transit
    /// Link 1 Line — green.
    static let link1   = TransitBrand(hex: 0x3DAE2B)
    /// Link 2 Line — blue.
    static let link2   = TransitBrand(hex: 0x00A0DF)
    /// Link 3 Line — pink.
    static let link3   = TransitBrand(hex: 0xED40A9)
    /// Link 4 Line — purple.
    static let link4   = TransitBrand(hex: 0xB14FC5)
    /// Tacoma T Line — orange.
    static let tacomaT = TransitBrand(hex: 0xF38B00)
    /// STRIDE BRT (S1/S2/S3) — yellow. Needs dark text.
    static let stride  = TransitBrand(hex: 0xEBA900, darkText: true)
    /// Sounder commuter rail (N/S) — lavender. Needs dark text.
    static let sounder = TransitBrand(hex: 0x9AB6D3, darkText: true)

    // MARK: King County Metro
    /// RapidRide (A-I) — dark red.
    static let rapidRide   = TransitBrand(hex: 0xA6192E)
    /// KC Metro local bus — amber-yellow #E6A800. Doubles as the bus
    /// fallback for unbranded operators (CT, PT, ST Express). Needs
    /// dark text.
    static let kcmLocalBus = TransitBrand(hex: 0xE6A800, darkText: true)
    /// KC Metro Water Taxi — systemTeal.
    static let waterTaxi   = TransitBrand(systemColor: .systemTeal)

    // MARK: Seattle Streetcar (SDOT)
    /// South Lake Union Streetcar — aquamarine.
    static let sluStreetcar       = TransitBrand(hex: 0x00A3A1)
    /// First Hill Streetcar — warm orange.
    static let firstHillStreetcar = TransitBrand(hex: 0xFF4000)

    // MARK: Washington State Ferries
    /// WSF — dark green.
    static let wsf = TransitBrand(hex: 0x006434)

    // MARK: Mode fallbacks
    /// Fallback for RAIL/TRAM/SUBWAY routes we haven't mapped above.
    /// Shouldn't normally hit in production since Link and streetcars
    /// are matched explicitly.
    static let railFallback = TransitBrand(systemColor: .systemPurple)

    // MARK: Non-transit mode colors
    /// Bike legs on known bike infrastructure (trail / cycletrack /
    /// protected lane). Pine green #00875A — dark enough to stand
    /// apart from Link 1 (#3DAE2B, brighter green) and lighter than
    /// WSF (#006434).
    static let bikeInfraUI = UIColor(red: 0.0, green: 0.529, blue: 0.353, alpha: 1.0)
    /// SwiftUI mirror of `bikeInfraUI`.
    static let bikeInfra: Color = Color(bikeInfraUI)

    /// Lime bikeshare rental — Lime-brand-ish bright green #33CC0D.
    /// Used for the polyline stroke on rental legs and the Lime-mode
    /// toggle pill in the search bar.
    static let limeUI = UIColor(red: 0.20, green: 0.80, blue: 0.05, alpha: 1.0)
    /// SwiftUI mirror of `limeUI`.
    static let lime: Color = Color(limeUI)
}

extension Leg {
    /// Brand colors for rendering this leg's transit segments. For
    /// known Sound Transit lines (Link, Sounder, STRIDE, Tacoma Link)
    /// this returns the operator's official brand color; for other
    /// transit routes it returns a mode-based default that matches
    /// the pre-branding behavior (orange for bus, purple for rail,
    /// teal for ferry). Walk/bike legs aren't transit and shouldn't
    /// call this — the default fallback is bus-orange but should be
    /// unused for those modes.
    var transitBrand: TransitBrand {
        // Sound Transit — matched on the route's GTFS shortName,
        // which agency feeds set to the rider-facing name ("1 Line",
        // "T Line", "S1 Line", "N Line", etc.).
        switch route?.shortName {
        case "1 Line":  return Palette.link1
        case "2 Line":  return Palette.link2
        case "3 Line":  return Palette.link3
        case "4 Line":  return Palette.link4
        case "T Line":  return Palette.tacomaT
        case "S1 Line", "S2 Line", "S3 Line":
            return Palette.stride
        case "N Line", "S Line":
            return Palette.sounder
        // KC Metro RapidRide — single-letter "<X> Line" naming.
        // Doesn't collide with Sound Transit ("T" is Tacoma Link
        // above, "N"/"S" are Sounder above, "1"-"4"/"S1"-"S3"
        // are numeric); the RapidRide letters in service are A-I.
        case "A Line", "B Line", "C Line", "D Line", "E Line",
             "F Line", "G Line", "H Line", "I Line":
            return Palette.rapidRide
        default:
            break
        }

        // Seattle Streetcar (SDOT) — two isolated lines, both
        // surfaced as mode:TRAM in GTFS (same as Link). Sound
        // Transit Link 1-4 and Tacoma T Line all return early
        // via the shortName switch above, so anything still
        // mode:TRAM down here is one of SDOT's streetcars.
        // Discriminate by route name since the GTFS agency
        // field isn't decoded into `RouteInfo` today.
        if mode == "TRAM" {
            let name = (route?.longName ?? "") + " " + (route?.shortName ?? "")
            if name.localizedCaseInsensitiveContains("south lake union") {
                return Palette.sluStreetcar
            }
            if name.localizedCaseInsensitiveContains("first hill") {
                return Palette.firstHillStreetcar
            }
        }

        // Ferries — Washington State Ferries (WSF) vs. KC Metro
        // Water Taxi. We don't decode the GTFS agency field today
        // (would require plumbing `agency { id name }` through
        // RoutingClient's GraphQL query and `RouteInfo`), so we
        // discriminate by name: anything whose long/short name
        // doesn't include "Water Taxi" is treated as WSF. Catches
        // every WSF route ("Bainbridge - Seattle", "Edmonds -
        // Kingston", etc.) while leaving the two KCM Water Taxi
        // routes on the teal fallback. Worth promoting to a proper
        // agency check if a third ferry operator ever shows up.
        if mode == "FERRY" {
            let name = (route?.longName ?? "") + " " + (route?.shortName ?? "")
            if !name.localizedCaseInsensitiveContains("water taxi") {
                return Palette.wsf
            }
            return Palette.waterTaxi
        }

        // Mode-based fallback for non-ST routes. Buses default
        // to KC Metro's fluorescent yellow — appropriate for
        // standard KCM local routes (40, 70, etc.), and a
        // reasonable visual default for Community Transit /
        // Pierce Transit / Sound Transit Express until we plumb
        // the GTFS `agency` field through the GraphQL plan
        // response and `RouteInfo` to brand them separately.
        // Yellow is too light for white text — darkText:true
        // picks black instead.
        switch mode {
        case "RAIL", "TRAM", "SUBWAY":
            return Palette.railFallback
        case "BUS":
            return Palette.kcmLocalBus
        default:
            return Palette.kcmLocalBus
        }
    }
}
