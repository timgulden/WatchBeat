import XCTest
@testable import WatchBeatCore

final class StandardBeatRateTests: XCTestCase {

    func testHzValues() {
        // hz returns beats per second (ticks/sec), used by DSP
        XCTAssertEqual(StandardBeatRate.bph28800.hz, 8.0)
        XCTAssertEqual(StandardBeatRate.bph36000.hz, 10.0)
        XCTAssertEqual(StandardBeatRate.bph19800.hz, 5.5)
    }

    func testOscillationHz() {
        // oscillationHz is the standard watch industry Hz (half the beat rate)
        XCTAssertEqual(StandardBeatRate.bph28800.oscillationHz, 4.0)
        XCTAssertEqual(StandardBeatRate.bph21600.oscillationHz, 3.0)
        XCTAssertEqual(StandardBeatRate.bph19800.oscillationHz, 2.75)
        XCTAssertEqual(StandardBeatRate.bph18000.oscillationHz, 2.5)
        XCTAssertEqual(StandardBeatRate.bph36000.oscillationHz, 5.0)
    }

    func testNominalPeriod() {
        XCTAssertEqual(StandardBeatRate.bph28800.nominalPeriodSeconds, 0.125, accuracy: 1e-9)
    }

    func testNearestSnapping() {
        XCTAssertEqual(StandardBeatRate.nearest(toHz: 8.05), .bph28800)
        XCTAssertEqual(StandardBeatRate.nearest(toHz: 5.8), .bph21600)
        XCTAssertEqual(StandardBeatRate.nearest(toHz: 9.5), .bph36000)
        XCTAssertEqual(StandardBeatRate.nearest(toHz: 5.5), .bph19800)
    }

    func testAllRatesPresent() {
        let rates = StandardBeatRate.allCases.map { $0.rawValue }
        XCTAssertTrue(rates.contains(18000))
        XCTAssertTrue(rates.contains(19800))
        XCTAssertTrue(rates.contains(21600))
        XCTAssertTrue(rates.contains(25200))
        XCTAssertTrue(rates.contains(28800))
        XCTAssertTrue(rates.contains(36000))
        XCTAssertFalse(rates.contains(14400))  // removed
        XCTAssertFalse(rates.contains(3600))   // removed
    }
}
