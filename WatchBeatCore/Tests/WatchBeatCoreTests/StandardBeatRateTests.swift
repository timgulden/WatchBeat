import XCTest
@testable import WatchBeatCore

final class StandardBeatRateTests: XCTestCase {

    func testHzValues() {
        XCTAssertEqual(StandardBeatRate.bph3600.hz, 1.0)
        XCTAssertEqual(StandardBeatRate.bph28800.hz, 8.0)
        XCTAssertEqual(StandardBeatRate.bph36000.hz, 10.0)
    }

    func testNominalPeriod() {
        XCTAssertEqual(StandardBeatRate.bph28800.nominalPeriodSeconds, 0.125, accuracy: 1e-9)
    }

    func testNearestSnapping() {
        XCTAssertEqual(StandardBeatRate.nearest(toHz: 8.05), .bph28800)
        XCTAssertEqual(StandardBeatRate.nearest(toHz: 5.8), .bph21600)
        XCTAssertEqual(StandardBeatRate.nearest(toHz: 1.1), .bph3600)
        XCTAssertEqual(StandardBeatRate.nearest(toHz: 9.5), .bph36000)
    }

    func testIsQuartz() {
        XCTAssertTrue(StandardBeatRate.bph3600.isQuartz)
        XCTAssertFalse(StandardBeatRate.bph28800.isQuartz)
    }
}
