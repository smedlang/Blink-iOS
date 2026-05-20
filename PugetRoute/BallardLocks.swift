import Foundation
import CoreLocation

/// Routing rules for the Hiram M. Chittenden Locks (Ballard Locks), the
/// pedestrian/bike crossing between Magnolia and Ballard.
///
/// **Operating hours filter.** The crossing is open 7 AM – 9 PM Pacific
/// time, every day. Outside those hours the gates are locked and a
/// route that would traverse the spillway is infeasible. We drop those
/// itineraries from the result list rather than serve up an option the
/// rider can't actually take.
///
/// **Walk-the-bike time** is no longer handled here. OSM tags the
/// locks crossing as `bicycle=dismount` (correct), and our
/// `router-config.json` gives OTP a `bicycle.walk` block — walking
/// speed plus mount/dismount cost — applied automatically by OTP to
/// every dismount-tagged way (the locks, Pike Place Market arcade,
/// parts of UW campus, etc.). The walking time is already in the leg
/// duration OTP returns, so no client-side penalty is needed.
///
/// Detection here remains geographic for the hours filter: a small
/// radius around the spillway midpoint. We don't try to read OSM way
/// names or tags — way names for this particular crossing are
/// inconsistent across OSM editors, and a 60 m geographic check
/// matches every route through the locks reliably while never
/// false-positiving on routes that bike past on Shilshole Ave or
/// 32nd Ave NW.
enum BallardLocks {

    /// Center point of the pedestrian/bike crossing across the locks
    /// spillway. Coordinates verified against satellite imagery; the
    /// pedestrian path here is short (~150 m end-to-end) so a
    /// `crossingRadiusMeters` of 60 captures every polyline that
    /// actually traverses it.
    static let crossingCenter = CLLocationCoordinate2D(
        latitude: 47.6657,
        longitude: -122.3970
    )

    /// Search radius (meters) around `crossingCenter` for detecting a
    /// crossing. Tight enough that a route biking past on a parallel
    /// street doesn't trigger a false positive; loose enough that any
    /// polyline through the spillway has at least one decoded vertex
    /// inside the buffer.
    static let crossingRadiusMeters: Double = 60

    /// Operating hours of the bike/pedestrian crossing in Pacific time.
    /// 7 AM – 9 PM, daily. Hours have been stable since the locks were
    /// built; if the Army Corps of Engineers ever adjusts them we'd
    /// update here rather than chase a feed.
    private static let openHour = 7
    private static let closeHour = 21

    /// True if the crossing is open at the given moment. Always
    /// evaluated in `America/Los_Angeles` regardless of the device
    /// locale — the locks operate on local time and a user planning
    /// from out-of-state shouldn't see different open/closed status.
    static func isOpen(at date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let hour = cal.component(.hour, from: date)
        return hour >= openHour && hour < closeHour
    }

    /// True if this leg's polyline traverses the lock crossing. Decodes
    /// the polyline and checks whether any vertex falls within
    /// `crossingRadiusMeters` of the crossing center. Returns false for
    /// non-bike legs (locks transit isn't a thing for buses or trains).
    ///
    /// Cheap: polyline decode is microseconds, distance calc is one
    /// sqrt per vertex. We re-call this from both the stamping path
    /// (to add the walk penalty) and the filter path (to drop
    /// closed-hours routes); cost is negligible enough that caching
    /// the result on the leg isn't worth the complexity.
    static func legUsesCrossing(_ leg: Leg) -> Bool {
        guard leg.mode == "BICYCLE" || leg.mode == "BICYCLE_RENT" else {
            return false
        }
        let centerLoc = CLLocation(
            latitude: crossingCenter.latitude,
            longitude: crossingCenter.longitude
        )
        let coords = PolylineDecoder.decode(leg.legGeometry.points)
        for c in coords {
            let d = CLLocation(latitude: c.latitude, longitude: c.longitude)
                .distance(from: centerLoc)
            if d < crossingRadiusMeters { return true }
        }
        return false
    }

    /// Approximate timestamp at which the rider arrives at the locks
    /// during this leg. Uses the midpoint of the leg's start/end
    /// times — close enough for a typical 1–3 mile cross-Magnolia or
    /// cross-Ballard bike leg, and avoids the polyline-arc-length
    /// math we'd need to compute the exact moment of crossing.
    ///
    /// Edge case the midpoint approximation gets wrong: a long leg
    /// that starts well before opening time and crosses the locks
    /// just before close. In practice this doesn't happen with realistic
    /// trips; lock-using legs tend to be the cross-the-canal short hop,
    /// not multi-hour epics.
    static func crossingTime(for leg: Leg) -> Date {
        let midMs = (leg.startTime + leg.endTime) / 2
        return Date(timeIntervalSince1970: TimeInterval(midMs) / 1000)
    }

    /// True if this itinerary should be dropped from results because
    /// it would have the rider arrive at the lock crossing while the
    /// gates are closed. Checked per-bike-leg so we correctly handle
    /// itineraries with multiple bike segments (e.g. bike → ferry →
    /// bike, where only one of the bike legs touches the locks).
    static func shouldDropForClosedCrossing(_ it: Itinerary) -> Bool {
        for leg in it.legs where legUsesCrossing(leg) {
            if !isOpen(at: crossingTime(for: leg)) { return true }
        }
        return false
    }
}
