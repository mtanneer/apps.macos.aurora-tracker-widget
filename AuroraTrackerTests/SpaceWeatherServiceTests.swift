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
        XCTAssertEqual(outlook.verdict, "Good Chance Now")
    }

    func testLowSignalsProduceUnlikely() {
        let outlook = AuroraOutlook.compute(forecastKp: 1.0, ovationProbability: 2)
        XCTAssertEqual(outlook.verdict, "Unlikely Now")
    }
}

final class CloudCoverTests: XCTestCase {
    func testParsesCurrentCloudCover() {
        let json = #"{"current":{"time":"2026-10-19T01:00","cloud_cover":72}}"#
        guard case .success(let pct) = CloudCoverFetcher.parse(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(pct, 72)
    }

    func testRejectsMalformedCloudCover() {
        XCTAssertThrowsError(try CloudCoverFetcher.parse(Data("{}".utf8)).get())
    }

    func testHeavyCloudOverridesGoodChance() {
        let o = AuroraOutlook.compute(forecastKp: 4, ovationProbability: 60, isDark: true, cloudCover: 95)
        XCTAssertEqual(o.verdict, "Likely Hidden by Clouds")
        XCTAssertEqual(o.chance, 60)
    }

    func testClearSkyKeepsGoodChance() {
        let o = AuroraOutlook.compute(forecastKp: 4, ovationProbability: 60, isDark: true, cloudCover: 10)
        XCTAssertEqual(o.verdict, "Good Chance Now")
    }
}

final class OutlookReasoningTests: XCTestCase {
    func testObservedVsForecastReadsInPlainWords() {
        let o = AuroraOutlook.compute(forecastKp: 4, observedKp: 2)
        XCTAssertTrue(o.reasoning.contains("Sky activity is quiet right now; forecast says active"))
        XCTAssertFalse(o.reasoning.joined().contains("Kp"))
    }
}

final class AlertProductTests: XCTestCase {
    func testWatchAndWarningProductsGetReadableSummaries() {
        let now = DateFormatter()
        now.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        now.timeZone = .gmt
        let ts = now.string(from: Date())
        let json = """
        [
          {"product_id":"A20F","issue_datetime":"\(ts)","message":"Code: WATA20\\r\\n\\r\\nWATCH: Geomagnetic Storm Category G1 Predicted\\n"},
          {"product_id":"K04W","issue_datetime":"\(ts)","message":"Code: WARK04\\r\\n\\r\\nWARNING: Geomagnetic K-index of 4 expected\\n"}
        ]
        """
        guard case .success(let alerts) = AlertsFetcher.parse(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(alerts.map(\.summary), ["WATCH: Geomagnetic Storm Category G1 Predicted", "WARNING: Geomagnetic K-index of 4 expected"])
    }
}

final class AuroraOutlookLogicTests: XCTestCase {
    private func alert(age: TimeInterval = 0) -> SpaceWeatherAlert {
        SpaceWeatherAlert(id: "K06A", issuedAt: Date().addingTimeInterval(-age), summary: "ALERT: Geomagnetic K-index of 6")
    }

    func testStormDoesNotOverrideZeroProbabilityAtLocation() {
        let o = AuroraOutlook.compute(forecastKp: 6.5, ovationProbability: 0, isDark: true, activeAlert: alert())
        XCTAssertEqual(o.verdict, "Unlikely Now")
    }

    func testHighKpDoesNotMaskLowProbabilityWithoutAlert() {
        let o = AuroraOutlook.compute(forecastKp: 6.0, ovationProbability: 2, isDark: true)
        XCTAssertEqual(o.verdict, "Unlikely Now")
    }

    func testDaylightGatesLocalVerdict() {
        let o = AuroraOutlook.compute(forecastKp: 3, ovationProbability: 80, isDark: false)
        XCTAssertEqual(o.verdict, "Not Dark Yet")
    }

    func testQuietObservedDoesNotMaskForecastStorm() {
        let o = AuroraOutlook.compute(forecastKp: 6, observedKp: 2, activeAlert: alert())
        XCTAssertEqual(o.verdict, "Active Alert — Check Now")
    }

    func testStaleObservedIsIgnored() {
        let old = Date().addingTimeInterval(-10 * 3600)
        let o = AuroraOutlook.compute(forecastKp: 2, observedKp: 7, observedAt: old)
        XCTAssertEqual(o.verdict, "Quiet")
    }

    func testOldAlertNoLongerActive() {
        let o = AuroraOutlook.compute(forecastKp: 6, activeAlert: alert(age: 12 * 3600))
        XCTAssertEqual(o.verdict, "Strong G2-3")
    }
}

final class DaylightTests: XCTestCase {
    func testSolarElevationKnownPoints() {
        // Equinox noon at the equator on the prime meridian: sun ~overhead.
        let noon = ISO8601DateFormatter().date(from: "2026-03-20T12:00:00Z")!
        XCTAssertGreaterThan(Daylight.solarElevation(lat: 0, lon: 0, at: noon), 80)
        // Same instant on the opposite meridian: midnight.
        XCTAssertLessThan(Daylight.solarElevation(lat: 0, lon: 180, at: noon), -80)
        XCTAssertTrue(Daylight.isDark(lat: 0, lon: 180, at: noon))
        XCTAssertFalse(Daylight.isDark(lat: 0, lon: 0, at: noon))
    }
}
