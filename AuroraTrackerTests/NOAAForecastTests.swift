import XCTest
@testable import AuroraTracker

final class NOAAForecastTests: XCTestCase {
    private let validSample = """
    :Product: 3-Day Forecast
    :Issued: 2026 Mar 22 0030 UTC
    # Prepared by the US Dept. of Commerce, NOAA, Space Weather Prediction Center
    #
    NOAA Kp index forecast 22 Mar - 24 Mar
                 Mar 22      Mar 23      Mar 24
    00-03UT       2.00        3.00        2.00
    03-06UT       2.33        3.33        2.33
    06-09UT       2.67        3.67        2.67
    09-12UT       3.00        4.00        3.00
    12-15UT       3.33        4.33        3.33
    15-18UT       3.67        4.67        3.67
    18-21UT       4.00        5.00        4.00
    21-00UT       4.33        5.33        4.33

    """

    func testParsesValidForecast() {
        let data = Data(validSample.utf8)
        switch NOAAForecastFetcher.parse(data) {
        case .success(let forecast):
            XCTAssertEqual(forecast.today.count, 8)
            XCTAssertEqual(forecast.tomorrow.count, 8)
            XCTAssertEqual(forecast.day2.count, 8)
            XCTAssertEqual(forecast.today.first?.kp, 2.00)
            XCTAssertEqual(forecast.tomorrow.first?.kp, 3.00)
            XCTAssertEqual(forecast.dateLabels, ["Mar 22", "Mar 23", "Mar 24"])
        case .failure(let error):
            XCTFail("Expected successful parse, got \(error)")
        }
    }

    func testRejectsMissingHeader() {
        let data = Data("garbage text with no NOAA header at all".utf8)
        switch NOAAForecastFetcher.parse(data) {
        case .success:
            XCTFail("Expected malformedData failure")
        case .failure(let error):
            XCTAssertEqual(error, .malformedData)
        }
    }

    func testRejectsOutOfRangeKpValues() {
        let malformed = """
        NOAA Kp index forecast 22 Mar - 24 Mar
                     Mar 22      Mar 23      Mar 24
        00-03UT       99.00 (13)   3.00 (33)   2.00 (13)

        """
        let data = Data(malformed.utf8)
        switch NOAAForecastFetcher.parse(data) {
        case .success(let forecast):
            // Row's today value (99.00) is out of 0...9 range and should be dropped,
            // leaving zero valid slots -> parse should fail as malformed.
            XCTFail("Expected malformedData failure, got \(forecast.today.count) slots")
        case .failure(let error):
            XCTAssertEqual(error, .malformedData)
        }
    }
}

final class ForecastCurrentDayTests: XCTestCase {
    // File issued 22:05 UTC Oct 17: first column is already Oct 18.
    private let sample = """
    NOAA Kp index forecast 18 Oct - 20 Oct
                 Oct 18    Oct 19    Oct 20
    00-03UT        1.67      1.67      4.00
    03-06UT        1.67      2.00      5.00
    06-09UT        1.33      1.00      3.00
    09-12UT        1.33      1.33      4.33
    12-15UT        1.33      1.33      3.00
    15-18UT        1.33      3.33      2.00
    18-21UT        1.33      4.00      3.67
    21-00UT        1.67      4.00      2.67

    """

    private func utc(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    private func parse(at iso: String, _ text: String? = nil) -> NOAAForecast {
        guard case .success(let f) = NOAAForecastFetcher.parse(Data((text ?? sample).utf8), now: utc(iso)) else {
            XCTFail("parse failed"); fatalError()
        }
        return f
    }

    func testPicksColumnMatchingUTCDate() {
        let f = parse(at: "2026-10-19T04:00:00Z")
        XCTAssertEqual(f.currentDayIndex, 1)
        XCTAssertEqual(f.currentSlotIndex, 1)
        XCTAssertEqual(f.currentKp, 2.00)
    }

    func testBeforeForecastStartUsesFirstSlotNotTomorrowsHour() {
        // 23:00 UTC Oct 17 — file already covers Oct 18; must not index Oct 18 by hour 23.
        let f = parse(at: "2026-10-17T23:00:00Z")
        XCTAssertEqual(f.currentDayIndex, 0)
        XCTAssertEqual(f.currentSlotIndex, 0)
    }

    func testStaleFileUsesLastSlot() {
        let f = parse(at: "2026-10-25T10:00:00Z")
        XCTAssertEqual(f.currentDayIndex, 2)
        XCTAssertEqual(f.currentSlotIndex, 7)
        XCTAssertEqual(f.currentKp, 2.67)
    }

    func testIncompleteColumnIsDroppedNotShifted() {
        let broken = sample.replacingOccurrences(of: "03-06UT        1.67      2.00", with: "03-06UT        1.67      x.xx")
        let f = parse(at: "2026-10-18T10:00:00Z", broken)
        XCTAssertEqual(f.today.count, 8)
        XCTAssertTrue(f.tomorrow.isEmpty)
        XCTAssertEqual(f.day2.count, 8)
    }
}
