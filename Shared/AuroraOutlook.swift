import SwiftUI

/// Rough solar position, accurate to well under a degree — plenty for "is it dark yet".
enum Daylight {
    /// Sun this far below the horizon (nautical twilight) counts as dark enough for aurora.
    static let darkElevation = -12.0

    static func solarElevation(lat: Double, lon: Double, at date: Date) -> Double {
        let rad = Double.pi / 180
        let n = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
        let meanLon = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = ((357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360)) * rad
        let eclLon = (meanLon + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
        let obliquity = (23.439 - 0.0000004 * n) * rad
        let declination = asin(sin(obliquity) * sin(eclLon))
        let rightAscension = atan2(cos(obliquity) * sin(eclLon), cos(eclLon))
        let gmst = (280.46061837 + 360.98564736629 * n).truncatingRemainder(dividingBy: 360)
        let hourAngle = (gmst + lon) * rad - rightAscension
        let sinEl = sin(lat * rad) * sin(declination) + cos(lat * rad) * cos(declination) * cos(hourAngle)
        return asin(sinEl) / rad
    }

    static func isDark(lat: Double, lon: Double, at date: Date = Date()) -> Bool {
        solarElevation(lat: lat, lon: lon, at: date) < darkElevation
    }
}

struct AuroraOutlook {
    let verdict: String
    let color: Color
    let reasoning: [String]
    /// Aurora probability (%) at the user's location right now; nil without a location.
    let chance: Int?
    /// Cloud cover (%) at the user's location right now; nil without a location or when unavailable.
    let cloudCover: Int?

    /// Observed Kp older than this is ignored — the feed can stall, and a stale quiet reading
    /// must not mask a storm.
    static let observedMaxAge: TimeInterval = 6 * 3600
    /// An alert older than this no longer drives the "Active Alert" verdict.
    static let alertMaxAge: TimeInterval = 6 * 3600
    /// Below this Ovation probability the aurora is effectively not visible at the location.
    static let unlikelyBelow = 5
    static let goodChanceFrom = 40
    /// At or above this cloud cover the sky is effectively blocked.
    static let cloudyFrom = 85

    /// Combines forecast Kp, observed Kp, an active alert, and (if the user's location and the
    /// Ovation grid are both available) a location-specific aurora probability into one verdict.
    /// Degrades gracefully: with only a forecast Kp, this reduces to the original Kp-only logic.
    /// `isDark` is only meaningful when a location is known; pass nil otherwise.
    static func compute(
        forecastKp: Double,
        observedKp: Double? = nil,
        observedAt: Date? = nil,
        ovationProbability: Int? = nil,
        isDark: Bool? = nil,
        cloudCover: Int? = nil,
        activeAlert: SpaceWeatherAlert? = nil,
        now: Date = Date()
    ) -> AuroraOutlook {
        var reasoning: [String] = []

        let alert = activeAlert.flatMap { now.timeIntervalSince($0.issuedAt) <= alertMaxAge ? $0 : nil }
        if let alert {
            reasoning.append(alert.summary)
        }

        let observedIsFresh = observedAt.map { now.timeIntervalSince($0) <= observedMaxAge } ?? true
        let freshObserved = observedIsFresh ? observedKp : nil

        // Whichever is higher: a forecast storm shouldn't be hidden by a quiet current reading,
        // nor an observed storm by a quiet forecast.
        let effectiveKp = max(forecastKp, freshObserved ?? 0)
        let forecastWord = KpBand.band(for: forecastKp).headline.lowercased()
        if let freshObserved {
            let observedWord = KpBand.band(for: freshObserved).headline.lowercased()
            reasoning.append(observedWord == forecastWord
                ? "Sky activity is \(observedWord), as forecast"
                : "Sky activity is \(observedWord) right now; forecast says \(forecastWord)")
        } else {
            reasoning.append("Forecast sky activity: \(forecastWord)")
        }

        if isDark == false {
            reasoning.append("Sun is up at your location — aurora is only visible after dark")
        }

        let (verdict, color) = Self.verdict(
            effectiveKp: effectiveKp,
            ovationProbability: ovationProbability,
            isDark: isDark ?? true,
            cloudCover: cloudCover,
            hasActiveAlert: alert != nil
        )

        return AuroraOutlook(verdict: verdict, color: color, reasoning: reasoning,
                             chance: ovationProbability, cloudCover: cloudCover)
    }

    private static func verdict(effectiveKp: Double, ovationProbability: Int?, isDark: Bool, cloudCover: Int?, hasActiveAlert: Bool) -> (String, Color) {
        let unlikelyHere = ovationProbability.map { $0 < unlikelyBelow } ?? false

        if hasActiveAlert && effectiveKp >= 5 && !unlikelyHere {
            return ("Active Alert — Check Now", .red)
        }
        if !isDark {
            return ("Not Dark Yet", .gray)
        }
        if let cloudCover, cloudCover >= cloudyFrom, !unlikelyHere {
            return ("Likely Hidden by Clouds", .gray)
        }
        if let ovationProbability, ovationProbability >= goodChanceFrom {
            return ("Good Chance Now", .green)
        }
        // Location beats global Kp: a strong storm is still no aurora for someone at 25°N.
        if unlikelyHere {
            return ("Unlikely Now", .gray)
        }

        // Fall back to Kp-only assessment when Ovation data isn't available for this location.
        return auroraLevel(for: effectiveKp)
    }
}
