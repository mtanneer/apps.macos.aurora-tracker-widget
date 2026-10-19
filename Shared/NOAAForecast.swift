import SwiftUI
import os

private let logger = Logger(subsystem: "manas.projects.AuroraTracker", category: "noaa")

// MARK: - NOAA URLs

enum NOAA {
    static let forecastURL = URL(string: "https://services.swpc.noaa.gov/text/3-day-geomag-forecast.txt")!
    static let viewlineURL = URL(string: "https://services.swpc.noaa.gov/experimental/images/aurora_dashboard/tonights_static_viewline_forecast.png")!
    static let ovationURL  = URL(string: "https://services.swpc.noaa.gov/images/animations/ovation/north/latest.jpg")!
    static let kStationURL = URL(string: "https://services.swpc.noaa.gov/images/station-k-index.png")!
}

// MARK: - Data Model

struct KpSlot: Identifiable {
    let id = UUID()
    let label: String   // e.g. "12AM" or "00-03"
    let kp: Double
    let day: String      // e.g. "Mar 22" (empty when unused)

    init(label: String, kp: Double, day: String = "") {
        self.label = label
        self.kp = kp
        self.day = day
    }
}

struct NOAAForecast {
    let today: [KpSlot]
    let tomorrow: [KpSlot]
    let day2: [KpSlot]
    let dateLabels: [String]
    let rangeString: String
    let currentKp: Double
    /// Column (0...2) matching the current UTC date, and 3-hour slot within it.
    let currentDayIndex: Int
    let currentSlotIndex: Int
    let fetchedAt: Date

    var currentDaySlots: [KpSlot] {
        [today, tomorrow, day2][currentDayIndex]
    }
}

enum NOAAFetchError: Error, Equatable {
    case network(String)
    case malformedData

    static func == (lhs: NOAAFetchError, rhs: NOAAFetchError) -> Bool {
        switch (lhs, rhs) {
        case (.malformedData, .malformedData): return true
        case (.network, .network): return true
        default: return false
        }
    }
}

// MARK: - Fetcher

enum NOAAForecastFetcher {
    /// UTC 3-hour slot boundaries NOAA's table is keyed on.
    static let utcSlotHours = [0, 3, 6, 9, 12, 15, 18, 21]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    /// Fetches and parses the NOAA 3-day Kp forecast, retrying once on transient network failure.
    static func fetch() async -> Result<NOAAForecast, NOAAFetchError> {
        do {
            let (data, _) = try await session.data(from: NOAA.forecastURL)
            return parse(data)
        } catch {
            // ponytail: single retry after a short delay, no exponential backoff — NOAA is a
            // simple flaky-network case, not a rate-limited API needing full backoff.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            do {
                let (data, _) = try await session.data(from: NOAA.forecastURL)
                return parse(data)
            } catch {
                logger.error("NOAA fetch failed after retry: \(error.localizedDescription)")
                return .failure(.network(error.localizedDescription))
            }
        }
    }

    static func parse(_ data: Data, now: Date = Date()) -> Result<NOAAForecast, NOAAFetchError> {
        guard let text = String(data: data, encoding: .utf8) else {
            logger.error("NOAA response was not valid UTF-8")
            return .failure(.malformedData)
        }

        let lines = text.components(separatedBy: "\n")
        guard let headerIdx = lines.firstIndex(where: { $0.contains("NOAA Kp index forecast") }) else {
            logger.error("Could not find Kp header in NOAA response")
            return .failure(.malformedData)
        }

        let rangeString = lines[headerIdx]
            .replacingOccurrences(of: "NOAA Kp index forecast", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var dateLabels: [String] = []
        if headerIdx + 1 < lines.count {
            let parts = lines[headerIdx + 1]
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            var i = 0
            while i + 1 < parts.count {
                dateLabels.append("\(parts[i]) \(parts[i+1])")
                i += 2
            }
        }

        let slotLabels = utcSlotHours.map { localSlotLabel(utcHour: $0) }
        let d1 = dateLabels.count > 0 ? dateLabels[0] : "Day 1"
        let d2 = dateLabels.count > 1 ? dateLabels[1] : "Day 2"
        let d3 = dateLabels.count > 2 ? dateLabels[2] : "Day 3"

        var columns: [[KpSlot]] = [[], [], []]
        let labels = [d1, d2, d3]

        let tableStart = min(headerIdx + 2, lines.count - 1)
        for (i, line) in lines[tableStart...].enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 4 else { continue }
            let label = slotLabels[i % slotLabels.count]
            for c in 0..<3 {
                if let kp = validKp(parts[c + 1]) { columns[c].append(KpSlot(label: label, kp: kp, day: labels[c])) }
            }
        }

        // A column with a missing/invalid cell would shift every later slot against its time
        // label, so drop incomplete columns rather than serve misaligned data.
        for c in 0..<3 where columns[c].count != utcSlotHours.count { columns[c] = [] }

        // NOAA's first column is whichever UTC day the file was issued for, so it is not always
        // "today": just after 00:00 UTC (before the new file lands) it is yesterday, and late in
        // the previous UTC day it is already tomorrow. Pick the column by date, not position.
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = .gmt
        let hour = utcCal.component(.hour, from: now)
        func label(_ date: Date) -> String {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = .gmt
            fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
        let tomorrowDate = utcCal.date(byAdding: .day, value: 1, to: now) ?? now
        let dayIdx: Int, slotIdx: Int
        if let m = dateLabels.firstIndex(of: label(now)), m < 3 {
            (dayIdx, slotIdx) = (m, hour / 3)
        } else if dateLabels.first == label(tomorrowDate) {
            // Forecast already starts tomorrow: nearest known value is its first slot.
            (dayIdx, slotIdx) = (0, 0)
        } else if columns[0].isEmpty {
            (dayIdx, slotIdx) = (0, 0)
        } else {
            // File is older than today (feed stalled): last known slot.
            let last = columns.lastIndex(where: { !$0.isEmpty }) ?? 0
            (dayIdx, slotIdx) = (last, utcSlotHours.count - 1)
        }

        guard columns[dayIdx].indices.contains(slotIdx) else {
            logger.error("Parsed no valid Kp slots for the current day from NOAA response")
            return .failure(.malformedData)
        }

        return .success(NOAAForecast(
            today: columns[0], tomorrow: columns[1], day2: columns[2],
            dateLabels: dateLabels, rangeString: rangeString,
            currentKp: columns[dayIdx][slotIdx].kp, currentDayIndex: dayIdx,
            currentSlotIndex: slotIdx, fetchedAt: now
        ))
    }

    /// NOAA's Kp scale runs 0...9; anything outside that is a malformed row, not real data.
    private static func validKp(_ raw: String) -> Double? {
        guard let kp = Double(raw), (0...9).contains(kp) else { return nil }
        return kp
    }

    /// Converts a UTC slot hour (0, 3, 6 … 21) to a short local time string.
    static func localSlotLabel(utcHour: Int) -> String {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = .gmt
        let todayUTC = utcCal.startOfDay(for: Date())
        guard let slotDate = utcCal.date(byAdding: .hour, value: utcHour, to: todayUTC) else {
            return String(format: "%d:00", utcHour)
        }
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        fmt.timeZone = .current
        return fmt.string(from: slotDate)
    }
}

// MARK: - Aurora Level Helpers

func auroraLevel(for kp: Double) -> (label: String, color: Color) {
    switch kp {
    case 8...:  return ("Extreme G4+", .red)
    case 6..<8: return ("Strong G2-3", .orange)
    case 5..<6: return ("Moderate G1", .yellow)
    case 3..<5: return ("Active", .green)
    case 1..<3: return ("Quiet", .blue)
    default:    return ("Very Quiet", .gray)
    }
}

func auroraColor(for kp: Double) -> Color { auroraLevel(for: kp).color }

// MARK: - Plain-language Kp guide (shared by app and widget)

/// One row per activity band. `from` is the lowest Kp in the band; colors match `auroraLevel(for:)`.
struct KpBand {
    let from: Double
    let label: String      // legend name
    let range: String
    let color: Color
    let headline: String   // human name for the activity level
    let meaning: String    // what it means for someone looking up

    static let all: [KpBand] = [
        KpBand(from: 0, label: "Very Quiet", range: "Kp 0–1", color: .gray, headline: "Calm",
               meaning: "Earth's magnetic field is calm. Aurora stays near the poles."),
        KpBand(from: 1, label: "Quiet", range: "Kp 1–3", color: .blue, headline: "Quiet",
               meaning: "Faint aurora in the far north — Arctic Circle, northern Alaska, Iceland."),
        KpBand(from: 3, label: "Active", range: "Kp 3–5", color: .green, headline: "Active",
               meaning: "Good aurora for northern Canada, Alaska and Scandinavia."),
        KpBand(from: 5, label: "G1 Minor", range: "Kp 5–6", color: .yellow, headline: "Minor storm",
               meaning: "Aurora may reach the northern US border, Scotland and southern Scandinavia."),
        KpBand(from: 6, label: "G2–G3 Strong", range: "Kp 6–8", color: .orange, headline: "Strong storm",
               meaning: "Aurora can reach mid-latitudes — the Great Lakes, northern Europe, southern Canada."),
        KpBand(from: 8, label: "G4+ Extreme", range: "Kp 8–9", color: .red, headline: "Extreme storm",
               meaning: "Rare. Aurora can be seen far south — the southern US and the Mediterranean."),
    ]

    static func band(for kp: Double) -> KpBand {
        all.last { kp >= $0.from } ?? all[0]
    }
}

/// 0–9 segmented gauge, each segment tinted by its own band, so position reads as "how stormy".
struct KpMeter: View {
    let kp: Double
    var height: CGFloat = 10
    var showLabels = true

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<9, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(kp > Double(i) ? KpBand.band(for: Double(i)).color : Color.secondary.opacity(0.15))
                        .frame(height: height)
                }
            }
            if showLabels {
                HStack {
                    Text("Calm")
                    Spacer()
                    Text("Storm")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }
}
