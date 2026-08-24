import SwiftUI
import Charts
import CoreLocation

// MARK: - Theme

enum AppTheme: String, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }
}

// MARK: - View Model

@Observable
class AuroraViewModel {
    var currentKp: Double = 0
    var todaySlots: [KpSlot] = []
    var tomorrowSlots: [KpSlot] = []
    var day2Slots: [KpSlot] = []
    var dateLabels: [String] = []
    var rangeString: String = ""
    var lastUpdated: Date? = nil
    var isLoading = false
    var hasError = false
    var errorMessage: String = ""
    var selectedDay = 0

    var observedKp: ObservedKp? = nil
    var activeAlerts: [SpaceWeatherAlert] = []
    var ovationProbability: Int? = nil
    var outlook: AuroraOutlook? = nil

    let location = LocationService()

    var selectedSlots: [KpSlot] {
        switch selectedDay {
        case 1: return tomorrowSlots
        case 2: return day2Slots
        default: return todaySlots
        }
    }

    var peakKp: Double { selectedSlots.map(\.kp).max() ?? 0 }
    var avgKp: Double {
        guard !selectedSlots.isEmpty else { return 0 }
        return selectedSlots.reduce(0) { $0 + $1.kp } / Double(selectedSlots.count)
    }

    func fetch() async {
        isLoading = true
        hasError = false
        defer { isLoading = false }

        async let forecastResult = NOAAForecastFetcher.fetch()
        async let observedResult = ObservedKpFetcher.fetch()
        async let alertsResult = AlertsFetcher.fetch()
        async let ovationResult = OvationFetcher.fetch()

        switch await forecastResult {
        case .success(let forecast):
            currentKp = forecast.currentKp
            todaySlots = forecast.today
            tomorrowSlots = forecast.tomorrow
            day2Slots = forecast.day2
            dateLabels = forecast.dateLabels
            rangeString = forecast.rangeString
            lastUpdated = forecast.fetchedAt
            hasAutoRetried = false
        case .failure(let error):
            // Keep any previously loaded (stale) data on screen; only flag the error banner.
            hasError = true
            switch error {
            case .network:
                errorMessage = "No connection to NOAA servers. Check your internet connection."
            case .malformedData:
                errorMessage = "NOAA data format is currently unrecognized. Try again later."
            }
        }

        if case .success(let observed) = await observedResult {
            observedKp = observed
        }
        if case .success(let alerts) = await alertsResult {
            activeAlerts = alerts
        }

        var probability: Int? = nil
        if case .success(let grid) = await ovationResult, let coord = location.lastLocation {
            probability = grid.probability(atLat: coord.latitude, lon: coord.longitude)
        }
        ovationProbability = probability

        outlook = AuroraOutlook.compute(
            forecastKp: currentKp,
            observedKp: observedKp?.value,
            ovationProbability: probability,
            activeAlert: activeAlerts.first
        )

        // A cold-launch network blip shouldn't strand the user on a stale error banner —
        // retry once automatically rather than requiring a manual refresh tap.
        if hasError {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await retryOnce()
        }
    }

    private var hasAutoRetried = false

    private func retryOnce() async {
        guard !hasAutoRetried else { return }
        hasAutoRetried = true
        await fetch()
    }

    func refreshLocation() async {
        _ = await location.fetchLocation()
    }
}

// MARK: - Content View

struct MapItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let urlString: String
}

struct ContentView: View {
    @AppStorage("appTheme") private var theme: AppTheme = .system
    @State private var vm = AuroraViewModel()
    @State private var selectedMap: MapItem? = nil
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if vm.isLoading && vm.todaySlots.isEmpty {
                        ProgressView("Fetching aurora data…")
                            .padding(40)
                    } else if vm.hasError && vm.todaySlots.isEmpty {
                        ContentUnavailableView(
                            "Could Not Load Data",
                            systemImage: "wifi.exclamationmark",
                            description: Text(vm.errorMessage)
                        )
                        .padding(40)
                    } else {
                        if vm.hasError {
                            staleDataBanner
                        }
                        outlookCard
                        currentKpCard
                        if !vm.activeAlerts.isEmpty {
                            alertsCard
                        }
                        forecastCard
                        auroraImagesCard
                        kpScaleLegend
                        noaaAttribution
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Aurora Tracker")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        ForEach(AppTheme.allCases, id: \.self) { t in
                            Button {
                                theme = t
                            } label: {
                                Label(t.label, systemImage: t.icon)
                            }
                            .disabled(theme == t)
                        }
                    } label: {
                        Image(systemName: theme.icon)
                    }
                    .help("Appearance")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await vm.fetch() }
                    } label: {
                        if vm.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(vm.isLoading)
                    .help("Refresh aurora data")
                }
            }
            .task {
                if vm.location.status == .notDetermined {
                    _ = await vm.location.requestAuthorizationAndWait()
                }
                await vm.refreshLocation()
                await vm.fetch()
            }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 620)
        #endif
        .sheet(item: $selectedMap) { map in
            MapDetailView(map: map)
        }
    }

    // MARK: - Current Kp Card

    private var currentKpCard: some View {
        let (levelLabel, color) = auroraLevel(for: vm.currentKp)
        return Group {
            if isCompact {
                compactKpCard(levelLabel: levelLabel, color: color)
            } else {
                regularKpCard(levelLabel: levelLabel, color: color)
            }
        }
        .padding(16)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(color.opacity(0.25), lineWidth: 1)
        )
    }

    private func compactKpCard(levelLabel: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Current Kp Index (\(TimeZone.current.abbreviation() ?? "local"))", systemImage: "aqi.medium")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.2f", vm.currentKp))
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text("Kp")
                    .font(.title2)
                    .foregroundStyle(color.opacity(0.7))
                    .padding(.bottom, 6)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 9, height: 9)
                        Text(levelLabel)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(color)
                    }
                    if let observed = vm.observedKp {
                        Text("Observed: \(String(format: "%.1f", observed.value))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider().opacity(0.3)

            HStack(spacing: 0) {
                compactStat(title: "Today's Peak", value: String(format: "%.1f Kp", vm.todaySlots.map(\.kp).max() ?? 0), color: color)
                Spacer()
                compactStat(title: "Today's Avg", value: String(format: "%.1f Kp", vm.todaySlots.isEmpty ? 0 : vm.todaySlots.reduce(0) { $0 + $1.kp } / Double(vm.todaySlots.count)), color: color)
                Spacer()
                if let d1 = vm.dateLabels.first {
                    compactStat(title: "Start Date", value: d1, color: .secondary)
                }
            }
        }
    }

    private func compactStat(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
    }

    private func regularKpCard(levelLabel: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Current Kp Index (\(TimeZone.current.abbreviation() ?? "local"))", systemImage: "aqi.medium")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.2f", vm.currentKp))
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                    Text("Kp")
                        .font(.title2)
                        .foregroundStyle(color.opacity(0.7))
                        .padding(.bottom, 8)
                }

                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 10, height: 10)
                    Text(levelLabel)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(color)
                }
                if let observed = vm.observedKp {
                    Text("Observed: \(String(format: "%.1f", observed.value)) Kp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                if !vm.rangeString.isEmpty {
                    Text(vm.rangeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .trailing, spacing: 4) {
                    statRow(title: "Today's Peak", value: String(format: "%.1f Kp", vm.todaySlots.map(\.kp).max() ?? 0))
                    statRow(title: "Today's Avg", value: String(format: "%.1f Kp", vm.todaySlots.isEmpty ? 0 : vm.todaySlots.reduce(0) { $0 + $1.kp } / Double(vm.todaySlots.count)))
                    if let d1 = vm.dateLabels.first {
                        statRow(title: "Forecast Start", value: d1)
                    }
                }
            }
        }
    }

    private func statRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold)
        }
        .font(.caption)
    }

    // MARK: - Tonight's Outlook Card

    private var outlookCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tonight's Outlook")
                    .font(.headline)
                Spacer()
                if let outlook = vm.outlook {
                    Text(outlook.verdict)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(outlook.color)
                }
            }

            if let outlook = vm.outlook {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(outlook.reasoning, id: \.self) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(line).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }

            if vm.location.status != .authorized {
                Button {
                    Task {
                        _ = await vm.location.requestAuthorizationAndWait()
                        await vm.refreshLocation()
                        await vm.fetch()
                    }
                } label: {
                    Label("Enable Location for a personalized outlook", systemImage: "location")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .background((vm.outlook?.color ?? .secondary).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder((vm.outlook?.color ?? .secondary).opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Active Alerts Card

    private var alertsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Active Alerts", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)

            ForEach(vm.activeAlerts) { alert in
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.summary)
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(alert.issuedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Forecast Chart Card

    private var forecastCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isCompact {
                Text("3-Day Kp Forecast")
                    .font(.headline)
                if vm.dateLabels.count >= 3 {
                    Picker("Day", selection: $vm.selectedDay) {
                        Text(vm.dateLabels[0]).tag(0)
                        Text(vm.dateLabels[1]).tag(1)
                        Text(vm.dateLabels[2]).tag(2)
                    }
                    .pickerStyle(.segmented)
                }
            } else {
                HStack {
                    Text("3-Day Kp Forecast")
                        .font(.headline)
                    Spacer()
                    if vm.dateLabels.count >= 3 {
                        Picker("Day", selection: $vm.selectedDay) {
                            Text(vm.dateLabels[0]).tag(0)
                            Text(vm.dateLabels[1]).tag(1)
                            Text(vm.dateLabels[2]).tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                    }
                }
            }

            if !vm.selectedSlots.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Chart {
                        ForEach(vm.selectedSlots) { slot in
                            BarMark(
                                x: .value("Time", slot.label),
                                y: .value("Kp", slot.kp),
                                width: .ratio(0.65)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [auroraColor(for: slot.kp), auroraColor(for: slot.kp).opacity(0.6)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .cornerRadius(3)
                        }

                        RuleMark(y: .value("G1 (Kp5)", 5.0))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            .foregroundStyle(.yellow.opacity(0.8))
                            .annotation(position: .top, alignment: .leading) {
                                Text("G1").font(.system(size: 9)).foregroundStyle(.yellow)
                            }
                        RuleMark(y: .value("G2 (Kp6)", 6.0))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            .foregroundStyle(.orange.opacity(0.8))
                            .annotation(position: .top, alignment: .leading) {
                                Text("G2").font(.system(size: 9)).foregroundStyle(.orange)
                            }
                        RuleMark(y: .value("G3 (Kp7)", 7.0))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            .foregroundStyle(.red.opacity(0.8))
                            .annotation(position: .top, alignment: .leading) {
                                Text("G3").font(.system(size: 9)).foregroundStyle(.red)
                            }
                    }
                    .frame(height: 200)
                    .chartYScale(domain: 0...9)
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]) { _ in
                            AxisGridLine()
                            AxisValueLabel()
                        }
                    }
                    .chartXAxis {
                        AxisMarks { _ in
                            AxisGridLine()
                            AxisValueLabel(orientation: .vertical)
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.bottom, 8)

                    HStack(spacing: isCompact ? 10 : 20) {
                        summaryBadge(label: "Peak", value: String(format: "%.1f", vm.peakKp), color: auroraColor(for: vm.peakKp))
                        summaryBadge(label: "Average", value: String(format: "%.1f", vm.avgKp), color: auroraColor(for: vm.avgKp))
                        summaryBadge(label: "Storm Level", value: auroraLevel(for: vm.peakKp).label, color: auroraColor(for: vm.peakKp))
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            } else {
                Text("No forecast data available.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .padding(16)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func summaryBadge(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Aurora Images Card

    private let mapItems = [
        MapItem(title: "Tonight's Viewline", subtitle: "Areas likely to see aurora tonight",
                urlString: "https://services.swpc.noaa.gov/experimental/images/aurora_dashboard/tonights_static_viewline_forecast.png"),
        MapItem(title: "Ovation Aurora Map", subtitle: "Northern hemisphere aurora now",
                urlString: "https://services.swpc.noaa.gov/images/animations/ovation/north/latest.jpg"),
        MapItem(title: "K-Index Stations", subtitle: "Geomagnetic station readings",
                urlString: "https://services.swpc.noaa.gov/images/station-k-index.png"),
    ]

    private var mapGridColumns: [GridItem] {
        #if os(iOS)
        let count = isCompact ? 1 : 2
        #else
        let count = 3
        #endif
        return Array(repeating: GridItem(.flexible()), count: count)
    }

    private var auroraImagesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Aurora Maps")
                .font(.headline)

            LazyVGrid(columns: mapGridColumns, spacing: 12) {
                ForEach(mapItems) { map in
                    auroraImageTile(map: map)
                }
            }
        }
        .padding(16)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func auroraImageTile(map: MapItem) -> some View {
        Button { selectedMap = map } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(map.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        Text(map.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let url = URL(string: map.urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        case .failure:
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.1))
                                    .frame(minHeight: 80)
                                Label("Image unavailable", systemImage: "photo.slash")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case .empty:
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.1))
                                    .frame(minHeight: 80)
                                ProgressView()
                            }
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Click to expand")
    }

    // MARK: - Kp Scale Legend

    private var kpScaleLegend: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kp / G-Scale Reference")
                .font(.headline)

            if isCompact {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(legendItems, id: \.label) { item in
                        legendBadge(item: item)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(legendItems, id: \.label) { item in
                        legendBadge(item: item)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func legendBadge(item: (label: String, range: String, color: Color)) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(item.color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(.caption).fontWeight(.semibold)
                Text(item.range).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: isCompact ? .infinity : nil, alignment: .leading)
        .background(item.color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var legendItems: [(label: String, range: String, color: Color)] {
        [
            ("Very Quiet", "Kp 0-1", .gray),
            ("Quiet", "Kp 1-3", .blue),
            ("Active", "Kp 3-5", .green),
            ("G1 Minor", "Kp 5-6", .yellow),
            ("G2-3 Strong", "Kp 6-8", .orange),
            ("G4+ Extreme", "Kp 8-9", .red),
        ]
    }

    // MARK: - Stale Data Banner

    private var staleDataBanner: some View {
        Button {
            Task { await vm.fetch() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Showing last known data. \(vm.errorMessage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Retry")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(vm.isLoading)
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - NOAA Attribution

    private var noaaAttribution: some View {
        VStack(spacing: 4) {
            Link(destination: URL(string: "https://www.swpc.noaa.gov")!) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("Data provided by NOAA Space Weather Prediction Center")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let lastUpdated = vm.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) · refreshes every 30 minutes")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Forecasts update every 30 minutes")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Map Detail View

struct MapDetailView: View {
    let map: MapItem
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var loadedImage: Image? = nil

    var body: some View {
        #if os(iOS)
        NavigationStack {
            zoomableImage
                .navigationTitle(map.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if let loadedImage {
                            ShareLink(item: loadedImage, preview: SharePreview(map.title, image: loadedImage)) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            withAnimation { scale = max(1.0, scale / 1.5); clampOffset() }
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .disabled(scale <= 1.0)

                        Spacer()
                        Text("\(Int(scale * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()

                        Button {
                            withAnimation { scale = min(8.0, scale * 1.5) }
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }

                        Spacer()

                        Button {
                            withAnimation { scale = 1.0; offset = .zero; lastScale = 1.0; lastOffset = .zero }
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .disabled(scale == 1.0 && offset == .zero)
                    }
                }
        }
        #else
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(map.title).font(.headline)
                    Text(map.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 12) {
                    Button {
                        withAnimation { scale = max(1.0, scale / 1.5); clampOffset() }
                    } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(scale <= 1.0)
                    .help("Zoom out")

                    Text("\(Int(scale * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40)

                    Button {
                        withAnimation { scale = min(8.0, scale * 1.5) }
                    } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in")

                    Button {
                        withAnimation { scale = 1.0; offset = .zero }
                    } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(scale == 1.0 && offset == .zero)
                    .help("Reset zoom")

                    if let loadedImage {
                        ShareLink(item: loadedImage, preview: SharePreview(map.title, image: loadedImage)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .help("Share image")
                    }

                    Button("Done") { dismiss() }
                        .keyboardShortcut(.escape)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            zoomableImage
        }
        .frame(minWidth: 700, minHeight: 520)
        #endif
    }

    private var zoomableImage: some View {
        GeometryReader { geo in
            if let url = URL(string: map.urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { val in
                                        scale = (lastScale * val).clamped(to: 1...8)
                                    }
                                    .onEnded { _ in
                                        lastScale = scale
                                        clampOffset()
                                    }
                            )
                            .gesture(
                                DragGesture()
                                    .onChanged { val in
                                        offset = CGSize(
                                            width: lastOffset.width + val.translation.width,
                                            height: lastOffset.height + val.translation.height
                                        )
                                    }
                                    .onEnded { _ in
                                        lastOffset = offset
                                        clampOffset()
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation {
                                    if scale > 1.0 {
                                        scale = 1.0; lastScale = 1.0
                                        offset = .zero; lastOffset = .zero
                                    } else {
                                        scale = 2.0; lastScale = 2.0
                                    }
                                }
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .onAppear { loadedImage = image }
                    case .failure:
                        ContentUnavailableView("Image Unavailable", systemImage: "photo.slash")
                    case .empty:
                        ProgressView("Loading…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
        .clipped()
    }

    private func clampOffset() {
        if scale <= 1.0 {
            withAnimation { offset = .zero; lastOffset = .zero }
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    ContentView()
}
