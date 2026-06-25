import XCTest
@testable import OpenSuperWhisper

/// `Diag.measure` wraps potentially-blocking calls with logging. It must be a
/// transparent pass-through (same return value, propagates throws) and must
/// leave no in-flight operation behind once it returns — the watchdog relies on
/// `currentInFlight()` being nil when nothing is running.
final class DiagTests: XCTestCase {

    func testMeasureReturnsBodyValue() {
        let result = Diag.measure("test-return") { 21 * 2 }
        XCTAssertEqual(result, 42)
    }

    func testMeasureClearsInFlightAfterReturn() {
        Diag.measure("test-inflight") { _ = 1 }
        XCTAssertNil(Diag.currentInFlight())
    }

    func testMeasureClearsInFlightAfterThrow() {
        struct Boom: Error {}
        XCTAssertThrowsError(try Diag.measure("test-throw") { throw Boom() })
        XCTAssertNil(Diag.currentInFlight())
    }
}
