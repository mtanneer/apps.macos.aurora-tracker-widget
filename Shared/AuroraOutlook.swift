import SwiftUI

struct AuroraOutlook {
    let verdict: String
    let color: Color
    let reasoning: [String]

    /// Combines forecast Kp, observed Kp, an active alert, and (if the user's location and the
    /// Ovation grid are both available) a location-specific aurora probability into one verdict.
    /// Degrades gracefully: with only a forecast Kp, this reduces to the original Kp-only logic.
    static func compute(
        forecastKp: Double,
        observedKp: Double? = nil,
        ovationProbability: Int? = nil,
        activeAlert: SpaceWeatherAlert? = nil
    ) -> AuroraOutlook {
        var reasoning: [String] = []

        if let activeAlert {
            reasoning.append(activeAlert.summary)
        }

        let effectiveKp = observedKp ?? forecastKp
        if let observedKp {
            reasoning.append("Observed Kp \(String(format: "%.1f", observedKp)) vs. forecast \(String(format: "%.1f", forecastKp))")
        } else {
            reasoning.append("Forecast Kp \(String(format: "%.1f", forecastKp))")
        }

        if let ovationProbability {
            reasoning.append("\(ovationProbability)% aurora probability at your location")
        }

        let (verdict, color) = Self.verdict(
            effectiveKp: effectiveKp,
            ovationProbability: ovationProbability,
            hasActiveAlert: activeAlert != nil
        )

        return AuroraOutlook(verdict: verdict, color: color, reasoning: reasoning)
    }

    private static func verdict(effectiveKp: Double, ovationProbability: Int?, hasActiveAlert: Bool) -> (String, Color) {
        if hasActiveAlert && effectiveKp >= 5 {
            return ("Active Alert — Check Now", .red)
        }
        if let ovationProbability, ovationProbability >= 40 {
            return ("Good Chance Tonight", .green)
        }
        if let ovationProbability, ovationProbability < 5, effectiveKp < 4 {
            return ("Unlikely Tonight", .gray)
        }

        // Fall back to Kp-only assessment when Ovation data isn't available for this location.
        let (label, color) = auroraLevel(for: effectiveKp)
        return (label, color)
    }
}
