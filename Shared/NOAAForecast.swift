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
    let currentSlotIndex: Int
    let fetchedAt: Date
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

    static func parse(_ data: Data) -> Result<NOAAForecast, NOAAFetchError> {
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

        var today: [KpSlot] = []
        var tomorrow: [KpSlot] = []
        var day2: [KpSlot] = []

        let tableStart = min(headerIdx + 2, lines.count - 1)
        for (i, line) in lines[tableStart...].enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 4 else { continue }
            let label = slotLabels[i % slotLabels.count]
            if let kp = validKp(parts[1]) { today.append(KpSlot(label: label, kp: kp, day: d1)) }
            if let kp = validKp(parts[2]) { tomorrow.append(KpSlot(label: label, kp: kp, day: d2)) }
            if let kp = validKp(parts[3]) { day2.append(KpSlot(label: label, kp: kp, day: d3)) }
        }

        guard !today.isEmpty else {
            logger.error("Parsed zero valid Kp slots from NOAA response")
            return .failure(.malformedData)
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(abbreviation: "UTC")!
        let slotIdx = cal.component(.hour, from: Date()) / 3
        let currentKp = today.indices.contains(slotIdx) ? today[slotIdx].kp : today.last?.kp ?? 0

        return .success(NOAAForecast(
            today: today, tomorrow: tomorrow, day2: day2,
            dateLabels: dateLabels, rangeString: rangeString,
            currentKp: currentKp, currentSlotIndex: slotIdx, fetchedAt: Date()
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
