import WidgetKit
import SwiftUI

struct Logger{
    
}

let logger = Logger()

// MARK: - Timeline Entry
struct AuroraEntry: TimelineEntry {
    let date: Date
    let kp: Double
}

struct NOAA {
    static let forecasturl = URL(string: "https://services.swpc.noaa.gov/text/3-day-geomag-forecast.txt")
    static let viewlineurl = URL(string: "https://services.swpc.noaa.gov/experimental/images/aurora_dashboard/tonights_static_viewline_forecast.png")
    static let latesturl = URL(string: "https://services.swpc.noaa.gov/images/animations/ovation/north/latest.jpg")
    static let kurl = URL(string:"https://services.swpc.noaa.gov/images/station-k-index.png")
}

// MARK: - Provider
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> AuroraEntry {
        AuroraEntry(date: Date(), kp: 0.0)
    }

    func getSnapshot(in context: Context, completion: @escaping (AuroraEntry) -> Void) {
        completion(AuroraEntry(date: Date(), kp: 2.0))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AuroraEntry>) -> Void) {
        print("=== getTimeline CALLED ===")
        fetchKP { kpValue in
            let entry = AuroraEntry(date: Date(), kp: kpValue)
//            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date())! // refresh every 30 minutes
//            let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
            let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30)))
            completion(timeline)
        }
    }
    
    private func fetchKP(completion: @escaping (Double) -> Void) {
        guard let url = NOAA.forecasturl else {
            completion(0.0)
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data,
                  let text = String(data: data, encoding: .utf8),
                  error == nil else {
                completion(0.0)
                return
            }
            
            let lines = text.components(separatedBy: "\n")
            guard let kpHeaderIndex = lines.firstIndex(where: {
                $0.contains("NOAA Kp index forecast")
            }) else {
                completion(0.0)
                return
            }
            
            var kpValues: [Double] = []
            for line in lines[(kpHeaderIndex + 2)...] { // Skip header lines (2 lines below header is where table starts)
                if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        
                if parts.count >= 2, // Expected format: ["00-03UT", "2.67", "3.67", "3.67"]
                   let kp = Double(parts[1]) {
                    kpValues.append(kp)
                }
            }
            print("=== FETCH STARTED ====")
            print(text)
            print("Parsed values: \(kpValues)")
            
            completion(kpValues.first ?? 0.0) // current 3-hour period
            
        }.resume()
    }
}

// MARK: - Widget View
struct AuroraWidgetView: View {
    var entry: Provider.Entry

    var body: some View {
        VStack {
            Text("Aurora Kp")
                .font(.headline)
            
            Text("\(entry.kp, specifier: "%.2f")")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(colorForKP(entry.kp))
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
//        .containerBackground(.thinMaterial, for: .widget)
//        .containerBackground(Color.black.gradient, for: .widget)
    }
    
    func colorForKP(_ kp: Double) -> Color {
        if kp >= 7 { return .red }
        if kp >= 4 { return .green }
        return .gray
    }
}

// MARK: - Widget Definition
@main
struct AuroraWidget: Widget {
    let kind: String = "AuroraWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            AuroraWidgetView(entry: entry)
        }
        .configurationDisplayName("Aurora Tracker")
        .description("Shows latest NOAA Kp index.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
