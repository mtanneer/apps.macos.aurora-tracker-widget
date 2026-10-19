import WidgetKit
import SwiftUI
import Charts

// MARK: - Data Models

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
    let outlook: AuroraOutlook?

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
            rangeString: "22-24 Mar", hasError: false,
            outlook: AuroraOutlook.compute(forecastKp: 3.5)
        )
    }
}

// MARK: - Provider

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> AuroraEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (AuroraEntry) -> Void) {
        Task { completion(await fetchEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AuroraEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
                ?? Date().addingTimeInterval(1800)
            completion(Timeline(entries: [entry], policy: .after(refresh)))
        }
    }

    private func fetchEntry() async -> AuroraEntry {
        async let forecastResult = NOAAForecastFetcher.fetch()
        async let observedResult = ObservedKpFetcher.fetch()
        async let alertsResult = AlertsFetcher.fetch()
        async let ovationResult = OvationFetcher.fetch()

        guard case .success(let forecast) = await forecastResult else {
            return AuroraEntry(date: Date(), currentKp: 0, currentSlotIndex: 0,
                        todaySlots: [], tomorrowSlots: [], day2Slots: [],
                        dateLabels: [], rangeString: "", hasError: true, outlook: nil)
        }

        let observed = try? await observedResult.get()
        let alerts = (try? await alertsResult.get()) ?? []

        var ovationProbability: Int? = nil
        var isDark: Bool? = nil
        var cloudCover: Int? = nil
        if let grid = try? await ovationResult.get(), let cached = CachedLocation.load() {
            ovationProbability = grid.probability(atLat: cached.lat, lon: cached.lon)
            isDark = Daylight.isDark(lat: cached.lat, lon: cached.lon)
            cloudCover = try? await CloudCoverFetcher.fetch(lat: cached.lat, lon: cached.lon).get()
        }

        let outlook = AuroraOutlook.compute(
            forecastKp: forecast.currentKp,
            observedKp: observed?.value,
            observedAt: observed?.timeTag,
            ovationProbability: ovationProbability,
            isDark: isDark,
            cloudCover: cloudCover,
            activeAlert: alerts.first
        )

        return AuroraEntry(
            date: forecast.fetchedAt, currentKp: forecast.currentKp,
            currentSlotIndex: forecast.currentSlotIndex,
            todaySlots: forecast.currentDaySlots, tomorrowSlots: forecast.tomorrow, day2Slots: forecast.day2,
            dateLabels: forecast.dateLabels, rangeString: forecast.rangeString, hasError: false,
            outlook: outlook
        )
    }
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

    // MARK: Shared pieces

    /// Big % when we know the user's location, otherwise the verdict in words.
    @ViewBuilder
    private func headline(verdict: String, color: Color, bigSize: CGFloat, verdictSize: CGFloat) -> some View {
        if let chance = entry.outlook?.chance {
            Text("\(chance)%")
                .font(.system(size: bigSize, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(verdict)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        } else {
            Text(verdict)
                .font(.system(size: verdictSize, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.7)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var cloudLine: some View {
        if let cloud = entry.outlook?.cloudCover {
            Label("\(cloud)% clouds", systemImage: cloud >= AuroraOutlook.cloudyFrom ? "cloud.fill" : "cloud.sun")
                .font(.system(size: 10))
                .foregroundStyle(cloud >= AuroraOutlook.cloudyFrom ? .orange : .secondary)
        }
    }

    // MARK: Small

    private var smallView: some View {
        let band = KpBand.band(for: entry.currentKp)
        let verdict = entry.outlook?.verdict ?? band.headline
        let color = entry.outlook?.color ?? band.color
        return VStack(alignment: .leading, spacing: 3) {
            Text("AURORA NOW")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            headline(verdict: verdict, color: color, bigSize: 38, verdictSize: 20)

            Spacer(minLength: 0)

            cloudLine
            KpMeter(kp: entry.currentKp, height: 6, showLabels: false)

            // Kp is a footnote; the word carries the meaning.
            Text("\(band.headline) · Kp \(String(format: "%.1f", entry.currentKp))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
    }

    // MARK: Medium

    private var mediumView: some View {
        let band = KpBand.band(for: entry.currentKp)
        let verdict = entry.outlook?.verdict ?? band.headline
        let color = entry.outlook?.color ?? band.color
        let peak = entry.todaySlots.map(\.kp).max() ?? entry.currentKp
        return HStack(spacing: 14) {

            VStack(alignment: .leading, spacing: 3) {
                Text("AURORA NOW")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                headline(verdict: verdict, color: color, bigSize: 40, verdictSize: 20)

                if entry.outlook?.chance == nil {
                    Text(band.meaning)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Spacer(minLength: 0)

                cloudLine
                KpMeter(kp: entry.currentKp, height: 6, showLabels: false)

                Text("\(band.headline) · Kp \(String(format: "%.1f", entry.currentKp))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150)

            Divider()

            // Right: 8-slot bar chart for today
            VStack(alignment: .leading, spacing: 4) {
                Text("TODAY'S ACTIVITY")
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
                    Text("Peak: \(KpBand.band(for: peak).headline)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(KpBand.band(for: peak).color)
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
            let spacing: CGFloat = 2
            let totalSpacing = spacing * CGFloat(max(slots.count - 1, 0))
            let barWidth = (geo.size.width - totalSpacing) / CGFloat(max(slots.count, 1))
            let chartH = geo.size.height - 14  // leave room for labels

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

                // Time axis: slots run in UTC order, so label from the slots' own (local-time)
                // labels rather than hardcoding clock times. The highlighted bar marks "now".
                HStack {
                    Text(slots.first?.label ?? "")
                    Spacer()
                    Text(slots.indices.contains(4) ? slots[4].label : "")
                    Spacer()
                    Text(slots.last?.label ?? "")
                }
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
            }
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
        .description("Your chance of seeing aurora right now, with cloud cover.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
