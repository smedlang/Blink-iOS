import Foundation

/// Sunrise / sunset / civil-twilight computation, no external API.
///
/// Used to decide whether to render the "Well-lit" badge on bike-only
/// itineraries — we only show it when the trip departs (or, for
/// arrive-by trips, arrives) after dark, since street lighting is
/// irrelevant when it's daylight out.
///
/// Algorithm
/// ---------
/// Standard NOAA-ish solar position calc, accurate to within ±2 minutes
/// for any date in any year between roughly 1900 and 2100. Inputs:
///   - date (any UTC moment in the day to compute for)
///   - lat / lon (we use Seattle's 47.6°N, -122.3°E by default)
/// Outputs:
///   - sunrise, sunset, civil twilight times in UTC
///
/// We treat "dark" as "after civil twilight in the evening, before civil
/// twilight in the morning." Civil twilight (sun 6° below horizon) is
/// the conventional threshold for "needs artificial lighting" and is
/// roughly 25-30 minutes after sunset / before sunrise in Seattle. Pure
/// sunset / sunrise would flag transitional dusk-but-still-visible
/// periods as "dark," which would over-badge.
///
/// We deliberately don't pull this from CoreLocation or a network call:
/// the math is cheap, deterministic, and works offline. A bug in the
/// algorithm would shift the badge threshold by ~1 minute — totally
/// inconsequential — so reliability beats precision here.
enum Solar {

    /// Seattle reference coordinates. The badge logic is invariant to
    /// being a few miles off (sunset shifts about 1 second per mile
    /// east-west at this latitude), so a fixed reference is fine for
    /// every Puget Sound user.
    static let seattleLat: Double = 47.6062
    static let seattleLon: Double = -122.3321

    /// True if `date` falls within civil twilight evening through civil
    /// twilight morning at the reference location. Computed in UTC so
    /// daylight saving doesn't enter the picture; the underlying
    /// `civilTwilight(for:)` call handles the conversion.
    static func isDark(at date: Date,
                       lat: Double = seattleLat,
                       lon: Double = seattleLon) -> Bool {
        let (morning, evening) = civilTwilight(for: date, lat: lat, lon: lon)
        // Two cases: dark in the early hours before morning twilight,
        // or dark in the evening after evening twilight. Both are
        // "before sunrise OR after sunset" of the calendar day.
        return date < morning || date > evening
    }

    /// True if `date` is *past today's evening civil twilight* —
    /// strictly the post-sunset case. Differs from `isDark` in that
    /// pre-dawn hours (e.g., 5 AM on a summer day when sunrise is at
    /// 5:15) return *false*, even though `isDark` would return true.
    ///
    /// Used by `Itinerary.isTripDark` so the lit-aware UI (Well-lit
    /// badge, % lit summary row, sort discount) fires only for trips
    /// the user explicitly thinks of as "biking after dark" — the
    /// evening case — and not for early-morning rides that happen to
    /// start before sunrise. Pre-dawn dark is technically the same
    /// luminance as post-sunset dark, but riders perceive the two
    /// situations very differently, and the user wants the badge
    /// reserved for the evening case.
    static func isPastSunset(at date: Date,
                             lat: Double = seattleLat,
                             lon: Double = seattleLon) -> Bool {
        let (_, evening) = civilTwilight(for: date, lat: lat, lon: lon)
        return date > evening
    }

    /// Returns `(morningCivilTwilight, eveningCivilTwilight)` for the
    /// calendar day of `date`, interpreted in UTC. The morning value is
    /// the moment the sun is 6° below the horizon heading up (dawn);
    /// the evening value is the same heading down (dusk). The interval
    /// between them is "daylight enough that street lights aren't
    /// helping" — outside it, we badge "well-lit" routes.
    static func civilTwilight(for date: Date,
                              lat: Double = seattleLat,
                              lon: Double = seattleLon) -> (morning: Date, evening: Date) {
        // Compute for the Y-M-D of `date` in UTC. We're not trying to
        // match local-noon precisely — anywhere within ~5 minutes of
        // true astronomical noon is fine for the badge threshold.
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let year  = comps.year ?? 2025
        let month = comps.month ?? 1
        let day   = comps.day ?? 1

        // Day of year, 1-indexed.
        let n = dayOfYear(year: year, month: month, day: day)

        // Convert to radians for the trig that follows.
        let latRad = lat * .pi / 180.0

        // Fractional year, in radians. Captures the orbital phase.
        let gamma = 2.0 * .pi / 365.0 * (Double(n - 1) + 0.5)

        // Equation of time, in minutes — corrects clock time vs. solar
        // time for the Earth's elliptical orbit + axial tilt.
        let eqTimeMin =
            229.18 * (0.000075
                + 0.001868 * cos(gamma)
                - 0.032077 * sin(gamma)
                - 0.014615 * cos(2 * gamma)
                - 0.040849 * sin(2 * gamma))

        // Solar declination — the sun's apparent latitude.
        let decl =
            0.006918
            - 0.399912 * cos(gamma)
            + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma)
            + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma)
            + 0.00148  * sin(3 * gamma)

        // Civil twilight uses a sun-altitude angle of -6° (90° + 6°
        // zenith below horizon). For sunrise / sunset proper, this
        // would be 90.833° (accounting for atmospheric refraction).
        let zenithDeg = 96.0
        let zenithRad = zenithDeg * .pi / 180.0

        // Hour angle at twilight, in radians. The `acos` can fail
        // (no twilight that day) above the Arctic Circle in summer —
        // not a concern in Seattle, but we guard defensively.
        let cosHourAngle =
            (cos(zenithRad) - sin(latRad) * sin(decl))
            / (cos(latRad) * cos(decl))
        // Clamp to [-1, 1] so the acos always resolves to a real number.
        // Outside that range means "sun stays below 6° all day" or
        // "stays above 6° all day" — vanishingly unlikely in our region.
        let clamped = max(-1.0, min(1.0, cosHourAngle))
        let hourAngleRad = acos(clamped)
        let hourAngleDeg = hourAngleRad * 180.0 / .pi

        // Solar-noon UTC, in minutes. lon is degrees east-positive;
        // each degree of longitude is 4 minutes of clock time.
        let solarNoonMin = 720.0 - 4.0 * lon - eqTimeMin

        // Civil twilight UTC, in minutes from midnight UTC.
        let morningMin = solarNoonMin - 4.0 * hourAngleDeg
        let eveningMin = solarNoonMin + 4.0 * hourAngleDeg

        // Build absolute Dates for the morning / evening moments on
        // the same UTC calendar day as `date`.
        var midnightComps = DateComponents()
        midnightComps.year = year
        midnightComps.month = month
        midnightComps.day = day
        midnightComps.hour = 0
        midnightComps.minute = 0
        midnightComps.second = 0
        midnightComps.timeZone = TimeZone(identifier: "UTC")
        let midnight = cal.date(from: midnightComps) ?? date

        let morning = midnight.addingTimeInterval(morningMin * 60.0)
        let evening = midnight.addingTimeInterval(eveningMin * 60.0)
        return (morning, evening)
    }

    /// Day of year, 1–366. Handles leap years via Gregorian rules. No
    /// localization concerns — purely an astronomical calendar.
    private static func dayOfYear(year: Int, month: Int, day: Int) -> Int {
        let cumulative: [Int] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
        let isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
        let idx = max(1, min(12, month)) - 1
        var d = cumulative[idx] + max(1, day)
        if isLeap && month > 2 { d += 1 }
        return d
    }
}
