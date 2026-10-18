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
        if let grid = try? await ovationResult.get(), let cached = CachedLocation.load() {
            ovationProbability = grid.probability(atLat: cached.lat, lon: cached.lon)
            isDark = Daylight.isDark(lat: cached.lat, lon: cached.lon)
        }

        let outlook = AuroraOutlook.compute(
            forecastKp: forecast.currentKp,
            observedKp: observed?.value,
            observedAt: observed?.timeTag,
            ovationProbability: ovationProbability,
            isDark: isDark,
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
        let verdictLabel = entry.outlook?.verdict ?? auroraLevel(for: entry.currentKp).label
        let color = entry.outlook?.color ?? auroraLevel(for: entry.currentKp).color
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

                Text(verdictLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.2))
                    .foregroundStyle(color)
                    .clipShape(Capsule())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 0)

                Text(entry.date, style: .relative)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
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
        .description("Live NOAA Kp index and aurora forecast.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
