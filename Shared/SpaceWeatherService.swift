import Foundation
import os

private let logger = Logger(subsystem: "manas.projects.AuroraTracker", category: "spaceweather")

// MARK: - URLs

extension NOAA {
    static let observedKpURL = URL(string: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json")!
    static let ovationURL2   = URL(string: "https://services.swpc.noaa.gov/json/ovation_aurora_latest.json")!
    static let alertsURL     = URL(string: "https://services.swpc.noaa.gov/products/alerts.json")!
}

private let sharedSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 20
    return URLSession(configuration: config)
}()

/// Fetches `url`, retrying once after a short delay on transient failure.
/// ponytail: single retry, no exponential backoff — matches NOAAForecastFetcher's approach
/// for these low-volume, unauthenticated NOAA endpoints.
private func fetchWithRetry(_ url: URL) async -> Result<Data, NOAAFetchError> {
    do {
        let (data, _) = try await sharedSession.data(from: url)
        return .success(data)
    } catch {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        do {
            let (data, _) = try await sharedSession.data(from: url)
            return .success(data)
        } catch {
            logger.error("Fetch failed after retry for \(url.lastPathComponent): \(error.localizedDescription)")
            return .failure(.network(error.localizedDescription))
        }
    }
}

// MARK: - Observed Kp

struct ObservedKp {
    let value: Double
    let timeTag: Date
}

private struct ObservedKpRow: Decodable {
    let time_tag: String
    let Kp: Double
}

enum ObservedKpFetcher {
    static func fetch() async -> Result<ObservedKp, NOAAFetchError> {
        switch await fetchWithRetry(NOAA.observedKpURL) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            return parse(data)
        }
    }

    static func parse(_ data: Data) -> Result<ObservedKp, NOAAFetchError> {
        guard let rows = try? JSONDecoder().decode([ObservedKpRow].self, from: data),
              let latest = rows.last,
              (0...9).contains(latest.Kp) else {
            logger.error("Could not parse observed Kp response")
            return .failure(.malformedData)
        }

        let timeTag = ISO8601DateFormatter().date(from: latest.time_tag + "Z") ?? Date()

        return .success(ObservedKp(value: latest.Kp, timeTag: timeTag))
    }
}

// MARK: - Ovation Aurora Probability Grid

struct OvationGrid {
    /// Flat array of [longitude(0...359), latitude(-90...90), probability(0...9 or higher)].
    private let coordinates: [[Double]]
    let observationTime: Date

    init(coordinates: [[Double]], observationTime: Date) {
        self.coordinates = coordinates
        self.observationTime = observationTime
    }

    /// Nearest-integer-degree lookup — the grid is 1° resolution, so no interpolation needed.
    func probability(atLat lat: Double, lon: Double) -> Int? {
        let targetLat = lat.rounded()
        var targetLon = lon.rounded()
        if targetLon < 0 { targetLon += 360 }

        guard let match = coordinates.first(where: {
            $0.count == 3 && $0[0] == targetLon && $0[1] == targetLat
        }) else { return nil }

        return Int(match[2])
    }
}

private struct OvationResponse: Decodable {
    let observationTime: String
    let coordinates: [[Double]]

    enum CodingKeys: String, CodingKey {
        case observationTime = "Observation Time"
        case coordinates
    }
}

enum OvationFetcher {
    static func fetch() async -> Result<OvationGrid, NOAAFetchError> {
        switch await fetchWithRetry(NOAA.ovationURL2) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            return parse(data)
        }
    }

    static func parse(_ data: Data) -> Result<OvationGrid, NOAAFetchError> {
        guard let response = try? JSONDecoder().decode(OvationResponse.self, from: data),
              !response.coordinates.isEmpty else {
            logger.error("Could not parse Ovation aurora response")
            return .failure(.malformedData)
        }
        let formatter = ISO8601DateFormatter()
        let observedAt = formatter.date(from: response.observationTime) ?? Date()
        return .success(OvationGrid(coordinates: response.coordinates, observationTime: observedAt))
    }
}

// MARK: - Alerts

struct SpaceWeatherAlert: Identifiable {
    let id: String
    let issuedAt: Date
    let summary: String
}

private struct AlertRow: Decodable {
    let product_id: String
    let issue_datetime: String
    let message: String
}

enum AlertsFetcher {
    /// Only alerts issued within this window are considered "active" for the outlook.
    static let activeWindow: TimeInterval = 24 * 3600

    static func fetch() async -> Result<[SpaceWeatherAlert], NOAAFetchError> {
        switch await fetchWithRetry(NOAA.alertsURL) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            return parse(data)
        }
    }

    static func parse(_ data: Data) -> Result<[SpaceWeatherAlert], NOAAFetchError> {
        guard let rows = try? JSONDecoder().decode([AlertRow].self, from: data) else {
            logger.error("Could not parse alerts response")
            return .failure(.malformedData)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = .gmt

        let cutoff = Date().addingTimeInterval(-activeWindow)

        // Only surface geomagnetic K-index alerts (product IDs like "K06A") — other NOAA
        // product families (electron flux, radio blackout, etc.) are out of scope for this app.
        let alerts: [SpaceWeatherAlert] = rows.compactMap { row in
            guard row.product_id.hasPrefix("K"),
                  let issuedAt = formatter.date(from: row.issue_datetime),
                  issuedAt >= cutoff else {
                return nil
            }
            let summary = firstLine(of: row.message) ?? row.product_id
            return SpaceWeatherAlert(id: row.product_id + row.issue_datetime, issuedAt: issuedAt, summary: summary)
        }

        return .success(alerts)
    }

    private static func firstLine(of message: String) -> String? {
        for line in message.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ALERT:") || trimmed.hasPrefix("WATCH:") || trimmed.hasPrefix("CONTINUED ALERT:") {
                return trimmed
            }
        }
        return nil
    }
}
