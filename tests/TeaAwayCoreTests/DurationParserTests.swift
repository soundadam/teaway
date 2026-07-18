import XCTest

@testable import TeaAwayCore

final class DurationParserTests: XCTestCase {
  func testParsesSupportedUnits() throws {
    XCTAssertEqual(try DurationParser.parse("90s"), 90)
    XCTAssertEqual(try DurationParser.parse("30m"), 1_800)
    XCTAssertEqual(try DurationParser.parse("4h"), 14_400)
    XCTAssertEqual(try DurationParser.parse("2d"), 172_800)
  }

  func testRejectsMissingOrInvalidUnits() {
    for value in ["", "0m", "1.5h", "30", "-1h", "1w"] {
      XCTAssertThrowsError(try DurationParser.parse(value), value)
    }
  }

  func testLeaseIsBounded() throws {
    XCTAssertEqual(try DurationParser.parseLease("1m"), 60)
    XCTAssertEqual(try DurationParser.parseLease("7d"), 604_800)
    XCTAssertThrowsError(try DurationParser.parseLease("59s"))
    XCTAssertThrowsError(try DurationParser.parseLease("8d"))
  }

  func testShutdownHasTenMinuteMinimum() throws {
    XCTAssertEqual(try DurationParser.parseShutdown("10m"), 600)
    XCTAssertThrowsError(try DurationParser.parseShutdown("9m"))
  }
}
