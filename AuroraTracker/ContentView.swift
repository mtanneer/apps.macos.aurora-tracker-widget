import SwiftUI
import Charts
import CoreLocation
import WidgetKit
#if os(macOS)
import AppKit
#endif

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
    var cloudCover: Int? = nil
    var outlook: AuroraOutlook? = nil
    var currentDayIndex = 0
    private var ovationGrid: OvationGrid? = nil
    private var hasPickedInitialDay = false

    let location = LocationService()

    /// Slots for the current UTC day — column 0 isn't always "today" (see NOAAForecast.currentDayIndex).
    var currentDaySlots: [KpSlot] {
        [todaySlots, tomorrowSlots, day2Slots][currentDayIndex]
    }

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
            currentDayIndex = forecast.currentDayIndex
            if !hasPickedInitialDay {
                selectedDay = forecast.currentDayIndex
                hasPickedInitialDay = true
            }
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

        if case .success(let grid) = await ovationResult {
            ovationGrid = grid
        }
        await refreshClouds()

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

    /// Recomputes the outlook from whatever data and location are currently known.
    func updateOutlook() {
        var probability: Int? = nil
        var isDark: Bool? = nil
        if let grid = ovationGrid, let coord = location.lastLocation {
            probability = grid.probability(atLat: coord.latitude, lon: coord.longitude)
            isDark = Daylight.isDark(lat: coord.latitude, lon: coord.longitude)
        }
        ovationProbability = probability

        outlook = AuroraOutlook.compute(
            forecastKp: currentKp,
            observedKp: observedKp?.value,
            observedAt: observedKp?.timeTag,
            ovationProbability: probability,
            isDark: isDark,
            cloudCover: cloudCover,
            activeAlert: activeAlerts.first
        )
    }

    /// Fetches cloud cover for the known location (if any) and recomputes the outlook.
    func refreshClouds() async {
        if let coord = location.lastLocation,
           case .success(let pct) = await CloudCoverFetcher.fetch(lat: coord.latitude, lon: coord.longitude) {
            cloudCover = pct
        }
        updateOutlook()
    }

    /// Asks for permission if still undecided, gets a fix, and refines the outlook with it.
    /// Never blocks the main data fetch — location only sharpens the verdict.
    func refreshLocation() async {
        if location.status == .notDetermined {
            _ = await location.requestAuthorizationAndWait()
        }
        _ = await location.fetchLocation()
        await refreshClouds()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Navigation

enum AppSection: String, CaseIterable, Identifiable {
    case tonight, forecast, maps, guide
    var id: Self { self }

    var title: String {
        switch self {
        case .tonight:  return "Tonight"
        case .forecast: return "Forecast"
        case .maps:     return "Maps"
        case .guide:    return "What is Kp?"
        }
    }

    var icon: String {
        switch self {
        case .tonight:  return "moon.stars"
        case .forecast: return "chart.bar.xaxis"
        case .maps:     return "map"
        case .guide:    return "questionmark.circle"
        }
    }
}

// MARK: - Content View

struct MapItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let urlString: String
}

private extension View {
    func card(tint: Color? = nil) -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.map { $0.opacity(0.10) } ?? Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder((tint ?? .secondary).opacity(0.25), lineWidth: tint == nil ? 0 : 1)
            )
    }
}

struct ContentView: View {
    @AppStorage("appTheme") private var theme: AppTheme = .system
    @State private var vm = AuroraViewModel()
    @State private var selectedMap: MapItem? = nil
    @State private var section: AppSection? = .tonight
    @State private var column: NavigationSplitViewColumn = .detail

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            List(AppSection.allCases, selection: $section) { s in
                Label(s.title, systemImage: s.icon)
                    .badge(s == .tonight ? vm.activeAlerts.count : 0)
            }
            .navigationTitle("Aurora Tracker")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { noaaAttribution }
        } detail: {
            detail
        }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 620)
        #endif
        .sheet(item: $selectedMap) { map in
            MapDetailView(map: map)
        }
    }

    private var detail: some View {
        let current = section ?? .tonight
        return ScrollView {
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
                    if vm.hasError { staleDataBanner }
                    switch current {
                    case .tonight:  tonightPage
                    case .forecast: forecastPage
                    case .maps:     mapsPage
                    case .guide:    guidePage
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(current.title)
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
            async let fetched: Void = vm.fetch()
            await vm.refreshLocation()
            await fetched
        }
    }

    // MARK: - Tonight page

    private var tonightPage: some View {
        VStack(spacing: 16) {
            if !vm.activeAlerts.isEmpty { alertsBanner }
            outlookCard
            activityCard
        }
    }

    private var outlookCard: some View {
        let color = vm.outlook?.color ?? .secondary
        return VStack(alignment: .leading, spacing: 12) {
            Label("Aurora right now", systemImage: "moon.stars.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let outlook = vm.outlook {
                if let chance = outlook.chance {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(chance)%")
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .foregroundStyle(color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(outlook.verdict)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(color)
                            Text("chance of aurora overhead")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(outlook.verdict)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                }

                if let cloud = outlook.cloudCover {
                    Label("\(cloud)% cloud cover", systemImage: cloud >= AuroraOutlook.cloudyFrom ? "cloud.fill" : "cloud.sun")
                        .font(.callout)
                        .foregroundStyle(cloud >= AuroraOutlook.cloudyFrom ? .orange : .secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(outlook.reasoning, id: \.self) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                            Text(line)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView()
            }

            if vm.location.status != .authorized {
                Button {
                    if vm.location.status == .denied {
                        // macOS won't re-prompt after a denial; the user has to flip it in Settings.
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                            NSWorkspace.shared.open(url)
                        }
                    } else {
                        Task { await vm.refreshLocation() }
                    }
                } label: {
                    Label(vm.location.status == .denied
                          ? "Location is off — open System Settings"
                          : "Enable Location for a personalized outlook",
                          systemImage: "location")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .card(tint: color)
    }

    private var activityCard: some View {
        let band = KpBand.band(for: vm.currentKp)
        let peak = vm.currentDaySlots.map(\.kp).max() ?? 0
        let peakBand = KpBand.band(for: peak)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Sky activity right now", systemImage: "waveform.path.ecg")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                // Kp stays visible, but as a footnote — the words above carry the meaning.
                Text("Kp \(String(format: "%.1f", vm.currentKp))")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(band.color.opacity(0.15))
                    .clipShape(Capsule())
                    .help("Kp is the 0–9 scale of how disturbed Earth's magnetic field is. See “What is Kp?”")
            }

            Text(band.headline)
                .font(.title.weight(.bold))
                .foregroundStyle(band.color)
            Text(band.meaning)
                .font(.callout)
                .foregroundStyle(.secondary)

            KpMeter(kp: vm.currentKp)

            Divider().opacity(0.4)

            HStack {
                Text("Expected peak today")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(peakBand.headline) · Kp \(String(format: "%.1f", peak))")
                    .fontWeight(.semibold)
                    .foregroundStyle(peakBand.color)
            }
            .font(.caption)
        }
        .card()
    }

    private var alertsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Active alerts", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
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
            }
        }
        .card(tint: .red)
    }

    // MARK: - Forecast page

    private var forecastPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("3-Day Forecast")
                .font(.headline)

            if vm.dateLabels.count >= 3 {
                Picker("Day", selection: $vm.selectedDay) {
                    ForEach(0..<3, id: \.self) { Text(vm.dateLabels[$0]).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if !vm.selectedSlots.isEmpty {
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
                .frame(height: 220)
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

                HStack(spacing: 10) {
                    summaryBadge(label: "Peak", kp: vm.peakKp)
                    summaryBadge(label: "Average", kp: vm.avgKp)
                    Spacer()
                }

                // Legend lives with the chart it explains.
                Divider().opacity(0.4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(KpBand.all, id: \.label) { legendChip($0) }
                }
            } else {
                Text("No forecast data available.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .card()
    }

    private func summaryBadge(label: String, kp: Double) -> some View {
        let band = KpBand.band(for: kp)
        return VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("\(band.headline) · Kp \(String(format: "%.1f", kp))")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(band.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(band.color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func legendChip(_ band: KpBand) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(band.color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(band.label).font(.caption).fontWeight(.semibold)
                Text(band.range).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(band.color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Maps page

    private let mapItems = [
        MapItem(title: "Tonight's Viewline", subtitle: "Areas likely to see aurora tonight",
                urlString: "https://services.swpc.noaa.gov/experimental/images/aurora_dashboard/tonights_static_viewline_forecast.png"),
        MapItem(title: "Ovation Aurora Map", subtitle: "Northern hemisphere aurora now",
                urlString: "https://services.swpc.noaa.gov/images/animations/ovation/north/latest.jpg"),
        MapItem(title: "K-Index Stations", subtitle: "Geomagnetic station readings",
                urlString: "https://services.swpc.noaa.gov/images/station-k-index.png"),
    ]

    private var mapsPage: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
            ForEach(mapItems) { auroraImageTile(map: $0) }
        }
    }

    private func auroraImageTile(map: MapItem) -> some View {
        Button { selectedMap = map } label: {
            VStack(alignment: .leading, spacing: 8) {
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

                // Fixed frame so every tile is the same size whatever the source image's ratio;
                // .fit inside it so no map data is cropped.
                Color.secondary.opacity(0.1)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if let url = URL(string: map.urlString) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().aspectRatio(contentMode: .fit)
                                case .failure:
                                    Label("Image unavailable", systemImage: "photo.slash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                default:
                                    ProgressView()
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .card()
        }
        .buttonStyle(.plain)
        .help("Click to expand")
    }

    // MARK: - Guide page

    private var guidePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What is Kp?")
                    .font(.headline)
                Text("Kp is a 0–9 score for how disturbed Earth's magnetic field is. Higher means a stronger geomagnetic storm, which pushes the aurora further from the poles and makes it brighter. Scores of 5 and up are called storms and get a “G” rating (G1 to G5).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Kp is global — what you'll actually see depends on how far north (or south) you are and how dark and clear the sky is. That's why Tonight combines Kp with your location.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                Text("Scale at a glance")
                    .font(.headline)
                ForEach(KpBand.all, id: \.label) { band in
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(band.color)
                            .frame(width: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(band.headline) · \(band.range)")
                                .font(.subheadline.weight(.semibold))
                            Text(band.meaning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .card()
        }
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

    // MARK: - NOAA Attribution (sidebar footer)

    private var noaaAttribution: some View {
        VStack(alignment: .leading, spacing: 4) {
            Link(destination: URL(string: "https://www.swpc.noaa.gov")!) {
                Label("Data: NOAA SWPC", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Link("Weather data by Open-Meteo.com", destination: URL(string: "https://open-meteo.com")!)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let lastUpdated = vm.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
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
