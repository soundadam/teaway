import Foundation

public enum DurationParser {
  public static func parse(_ value: String) throws -> Int {
    let pattern = #"^([1-9][0-9]*)([smhd])$"#
    let expression = try NSRegularExpression(pattern: pattern)
    let range = NSRange(value.startIndex..<value.endIndex, in: value)

    guard
      let match = expression.firstMatch(in: value, range: range),
      match.range == range,
      let amountRange = Range(match.range(at: 1), in: value),
      let unitRange = Range(match.range(at: 2), in: value),
      let amount = Int(value[amountRange])
    else {
      throw TeaAwayError.invalidDuration(value)
    }

    let multiplier: Int
    switch value[unitRange] {
    case "s": multiplier = 1
    case "m": multiplier = 60
    case "h": multiplier = 3_600
    case "d": multiplier = 86_400
    default: throw TeaAwayError.invalidDuration(value)
    }

    let (seconds, overflow) = amount.multipliedReportingOverflow(by: multiplier)
    guard !overflow else {
      throw TeaAwayError.invalidDuration(value)
    }
    return seconds
  }

  public static func parseLease(_ value: String) throws -> Int {
    let seconds = try parse(value)
    let minimum = 60
    let maximum = 7 * 86_400
    guard (minimum...maximum).contains(seconds) else {
      throw TeaAwayError.durationOutOfRange(minimum: minimum, maximum: maximum)
    }
    return seconds
  }

  public static func parseShutdown(_ value: String) throws -> Int {
    let seconds = try parse(value)
    let minimum = 10 * 60
    let maximum = 7 * 86_400
    guard (minimum...maximum).contains(seconds) else {
      throw TeaAwayError.durationOutOfRange(minimum: minimum, maximum: maximum)
    }
    return seconds
  }
}
