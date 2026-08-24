import XCTest
@testable import AuroraTracker

final class ObservedKpTests: XCTestCase {
    func testParsesValidObservedKp() {
        let json = """
        [
          {"time_tag":"2026-08-17T00:00:00","Kp":1.67,"a_running":6,"station_count":6},
          {"time_tag":"2026-08-17T03:00:00","Kp":3.33,"a_running":9,"station_count":6}
        ]
        """
        let data = Data(json.utf8)
        switch ObservedKpFetcher.parse(data) {
        case .success(let observed):
            // Latest row (last in array) should win.
            XCTAssertEqual(observed.value, 3.33)
        case .failure(let error):
            XCTFail("Expected successful parse, got \(error)")
        }
    }

    func testRejectsMalformedObservedKp() {
        let data = Data("not json".utf8)
        switch ObservedKpFetcher.parse(data) {
        case .success:
            XCTFail("Expected malformedData failure")
        case .failure(let error):
            XCTAssertEqual(error, .malformedData)
        }
    }
}

final class OvationFetcherTests: XCTestCase {
    // Uses the real NOAA field names ("Observation Time" with a space, capitalized) —
    // this is a regression test: the fetcher previously used "observationTime" as the
    // JSON key, which silently failed to decode against the real API every time.
    func testParsesRealFieldNames() {
        let json = """
        {"Observation Time": "2026-08-24T06:05:00Z", "Forecast Time": "2026-08-24T07:16:00Z", "Data Format": "[Longitude, Latitude, Aurora]", "coordinates": [[0, -90, 2], [0, 45, 7], [350, 60, 3]]}
        """
        let data = Data(json.utf8)
        switch OvationFetcher.parse(data) {
        case .success(let grid):
            XCTAssertEqual(grid.probability(atLat: 45, lon: 0), 7)
            XCTAssertEqual(grid.probability(atLat: 60, lon: -10), 3) // -10 normalizes to 350
        case .failure(let error):
            XCTFail("Expected successful parse, got \(error)")
        }
    }

    func testRejectsMalformedOvationResponse() {
        let data = Data("not json".utf8)
        switch OvationFetcher.parse(data) {
        case .success:
            XCTFail("Expected malformedData failure")
        case .failure(let error):
            XCTAssertEqual(error, .malformedData)
        }
    }
}

final class AlertsFetcherTests: XCTestCase {
    private func isoNow() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = .gmt
        return formatter.string(from: Date())
    }

    func testParsesRecentKIndexAlert() {
        let json = """
        [
          {"product_id":"K06A","issue_datetime":"\(isoNow())","message":"Space Weather Message Code: ALTK06\\r\\nALERT: Geomagnetic K-index of 6 \\r\\nActive Warning: YES"}
        ]
        """
        let data = Data(json.utf8)
        switch AlertsFetcher.parse(data) {
        case .success(let alerts):
            XCTAssertEqual(alerts.count, 1)
            XCTAssertTrue(alerts.first?.summary.contains("Geomagnetic K-index of 6") ?? false)
        case .failure(let error):
            XCTFail("Expected successful parse, got \(error)")
        }
    }

    func testFiltersOutNonKIndexAlerts() {
        let json = """
        [
          {"product_id":"EF3A","issue_datetime":"\(isoNow())","message":"ALERT: Electron 2MeV Integral Flux exceeded 1,000pfu"}
        ]
        """
        let data = Data(json.utf8)
        switch AlertsFetcher.parse(data) {
        case .success(let alerts):
            XCTAssertTrue(alerts.isEmpty)
        case .failure(let error):
            XCTFail("Expected successful parse (empty), got \(error)")
        }
    }

    func testFiltersOutStaleAlerts() {
        let staleDate = "2020-01-01 00:00:00.000"
        let json = """
        [
          {"product_id":"K06A","issue_datetime":"\(staleDate)","message":"ALERT: Geomagnetic K-index of 6"}
        ]
        """
        let data = Data(json.utf8)
        switch AlertsFetcher.parse(data) {
        case .success(let alerts):
            XCTAssertTrue(alerts.isEmpty)
        case .failure(let error):
            XCTFail("Expected successful parse (empty), got \(error)")
        }
    }
}

final class AuroraOutlookTests: XCTestCase {
    func testFallsBackToKpOnlyWithNoOtherSignals() {
        let outlook = AuroraOutlook.compute(forecastKp: 6.5)
        XCTAssertEqual(outlook.verdict, "Strong G2-3")
    }

    func testActiveAlertWithHighKpProducesTopVerdict() {
        let alert = SpaceWeatherAlert(id: "K06A", issuedAt: Date(), summary: "ALERT: Geomagnetic K-index of 6")
        let outlook = AuroraOutlook.compute(forecastKp: 6.0, activeAlert: alert)
        XCTAssertEqual(outlook.verdict, "Active Alert — Check Now")
    }

    func testHighOvationProbabilityProducesGoodChance() {
        let outlook = AuroraOutlook.compute(forecastKp: 2.0, ovationProbability: 55)
        XCTAssertEqual(outlook.verdict, "Good Chance Tonight")
    }

    func testLowSignalsProduceUnlikely() {
        let outlook = AuroraOutlook.compute(forecastKp: 1.0, ovationProbability: 2)
        XCTAssertEqual(outlook.verdict, "Unlikely Tonight")
    }
}
