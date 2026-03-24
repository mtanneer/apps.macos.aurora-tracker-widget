import WidgetKit
import SwiftUI
import Charts
import os

private let logger = Logger(subsystem: "manas.projects.AuroraTracker", category: "widget")

// MARK: - Data Models

struct KpSlot: Identifiable {
    let id = UUID()
    let label: String  // e.g. "00-03"
    let kp: Double
}

struct AuroraEntry: TimelineEntry {
    let date: Date
    let currentKp: Double
    let currentSlotIndex: Int
    let todaySlots: [KpSlot]
    let tomorrowSlots: [KpSlot]
    let day2Slots: [KpSlot]
    let dateLabels: [String]
    let rangeString: String
    let hasError: Bool

    static let slotTimeLabels = [
        "00-03", "03-06", "06-09", "09-12",
        "12-15", "15-18", "18-21", "21-00"
    ]

    static var placeholder: AuroraEntry {
        let kps: [Double] = [2.0, 2.5, 3.0, 3.5, 4.0, 3.5, 3.0, 2.5]
        let slots = kps.enumerated().map { i, kp in KpSlot(label: slotTimeLabels[i], kp: kp) }
        return AuroraEntry(
            date: Date(), currentKp: 3.5, currentSlotIndex: 4,
            todaySlots: slots, tomorrowSlots: slots, day2Slots: slots,
            dateLabels: ["Mar 22", "Mar 23", "Mar 24"],
            rangeString: "22-24 Mar", hasError: false
        )
    }
}

// MARK: - NOAA URLs

enum NOAA {
    static let forecastURL = URL(string: "https://services.swpc.noaa.gov/text/3-day-geomag-forecast.txt")!
    static let viewlineURL = URL(string: "https://services.swpc.noaa.gov/experimental/images/aurora_dashboard/tonights_static_viewline_forecast.png")!
    static let ovationURL  = URL(string: "https://services.swpc.noaa.gov/images/animations/ovation/north/latest.jpg")!
    static let kStationURL = URL(string: "https://services.swpc.noaa.gov/images/station-k-index.png")!
}

// MARK: - Provider

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> AuroraEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (AuroraEntry) -> Void) {
        fetchData(completion: completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AuroraEntry>) -> Void) {
        fetchData { entry in
            let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
                ?? Date().addingTimeInterval(1800)
            completion(Timeline(entries: [entry], policy: .after(refresh)))
        }
    }

    private func fetchData(completion: @escaping (AuroraEntry) -> Void) {
        URLSession.shared.dataTask(with: NOAA.forecastURL) { data, _, error in
            if let error {
                logger.error("Fetch failed: \(error.localizedDescription)")
                completion(errorEntry())
                return
            }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                completion(errorEntry())
                return
            }
            completion(parse(text))
        }.resume()
    }

    private func currentUTCSlotIndex() -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(abbreviation: "UTC")!
        return cal.component(.hour, from: Date()) / 3
    }

    private func errorEntry() -> AuroraEntry {
        AuroraEntry(date: Date(), currentKp: 0, currentSlotIndex: 0,
                    todaySlots: [], tomorrowSlots: [], day2Slots: [],
                    dateLabels: [], rangeString: "", hasError: true)
    }

    private func parse(_ text: String) -> AuroraEntry {
        let lines = text.components(separatedBy: "\n")

        guard let headerIdx = lines.firstIndex(where: { $0.contains("NOAA Kp index forecast") }) else {
            logger.error("Could not find Kp header in NOAA response")
            return errorEntry()
        }

        // Extract forecast date range from the header line
        let rangeString = lines[headerIdx]
            .replacingOccurrences(of: "NOAA Kp index forecast", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse date labels: "     Feb 22      Feb 23      Feb 24"
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

        // Parse the Kp table (2 lines after header)
        var todaySlots: [KpSlot] = []
        var tomorrowSlots: [KpSlot] = []
        var day2Slots: [KpSlot] = []

        let tableStart = min(headerIdx + 2, lines.count - 1)
        for (i, line) in lines[tableStart...].enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 4 else { continue }
            let label = AuroraEntry.slotTimeLabels[i % AuroraEntry.slotTimeLabels.count]
            if let kp = Double(parts[1]) { todaySlots.append(KpSlot(label: label, kp: kp)) }
            if let kp = Double(parts[2]) { tomorrowSlots.append(KpSlot(label: label, kp: kp)) }
            if let kp = Double(parts[3]) { day2Slots.append(KpSlot(label: label, kp: kp)) }
        }

        logger.debug("Parsed \(todaySlots.count) slots for today, range: \(rangeString)")

        let slotIdx = currentUTCSlotIndex()
        let currentKp = todaySlots.indices.contains(slotIdx)
            ? todaySlots[slotIdx].kp
            : todaySlots.last?.kp ?? 0

        return AuroraEntry(
            date: Date(), currentKp: currentKp, currentSlotIndex: slotIdx,
            todaySlots: todaySlots, tomorrowSlots: tomorrowSlots, day2Slots: day2Slots,
            dateLabels: dateLabels, rangeString: rangeString, hasError: false
        )
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

func auroraColor(for kp: Double) -> Color {
    auroraLevel(for: kp).color
}

// MARK: - Widget Views

struct AuroraWidgetView: View {
    let entry: AuroraEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if entry.hasError {
                errorView
            } else {
                switch family {
                case .systemSmall:  smallView
                default:            mediumView
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: Error

    private var errorView: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            Text("Unable to load\naurora data")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: Small

    private var smallView: some View {
        let (levelLabel, color) = auroraLevel(for: entry.currentKp)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text("AURORA")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Spacer(minLength: 0)

            Text(String(format: "%.1f", entry.currentKp))
                .font(.system(size: 50, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)

            Text("Kp Index")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(levelLabel)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.2))
                .foregroundStyle(color)
                .clipShape(Capsule())
        }
        .padding(12)
    }

    // MARK: Medium

    private var mediumView: some View {
        let (levelLabel, color) = auroraLevel(for: entry.currentKp)
        return HStack(spacing: 14) {

            // Left: current Kp
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text("AURORA KP")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Text(String(format: "%.1f", entry.currentKp))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.6)

                Text(levelLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.2))
                    .foregroundStyle(color)
                    .clipShape(Capsule())

                Spacer(minLength: 0)

                if let label = entry.dateLabels.first {
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 110)

            Divider()

            // Right: 8-slot bar chart for today
            VStack(alignment: .leading, spacing: 4) {
                Text("TODAY'S FORECAST")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                if entry.todaySlots.isEmpty {
                    Spacer()
                    Text("No data")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    MiniBarChart(
                        slots: entry.todaySlots,
                        currentIndex: entry.currentSlotIndex
                    )
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Mini Bar Chart (used in medium widget)

struct MiniBarChart: View {
    let slots: [KpSlot]
    let currentIndex: Int

    var body: some View {
        GeometryReader { geo in
            let count = slots.count
            guard count > 0 else { return AnyView(EmptyView()) }
            let spacing: CGFloat = 2
            let totalSpacing = spacing * CGFloat(count - 1)
            let barWidth = (geo.size.width - totalSpacing) / CGFloat(count)
            let chartH = geo.size.height - 14  // leave room for labels

            return AnyView(
                VStack(spacing: 0) {
                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(Array(slots.enumerated()), id: \.offset) { i, slot in
                            let color = auroraColor(for: slot.kp)
                            let barH = max(3, (slot.kp / 9.0) * chartH)
                            let isCurrent = i == currentIndex

                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(isCurrent ? color : color.opacity(0.35))
                                    .frame(width: barWidth, height: barH)
                                    .overlay(
                                        isCurrent
                                            ? RoundedRectangle(cornerRadius: 2)
                                                .strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
                                            : nil
                                    )
                            }
                            .frame(height: chartH)
                        }
                    }

                    // Time axis labels
                    HStack {
                        Text("12AM")
                        Spacer()
                        Text("Now")
                            .foregroundStyle(auroraColor(for: slots.indices.contains(currentIndex)
                                ? slots[currentIndex].kp : 0))
                        Spacer()
                        Text("12PM")
                        Spacer()
                        Text("11PM")
                    }
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                }
            )
        }
    }
}

// MARK: - Widget Definition

@main
struct AuroraWidget: Widget {
    let kind = "AuroraWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            AuroraWidgetView(entry: entry)
                .widgetURL(URL(string: "auroratracker://open"))
        }
        .configurationDisplayName("Aurora Tracker")
        .description("Live NOAA Kp index and aurora forecast.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
