import Foundation

public enum TeaAwayVersion {
  public static let current = "0.2.2"
}

public enum PowerPhase: String, Codable, Equatable, Sendable {
  case enabling
  case enabled
  case restoring
}

public struct PowerRecord: Codable, Equatable, Sendable {
  public let originalDisableSleep: Int
  public let expectedDisableSleep: Int
  public let createdAt: Date
  public var phase: PowerPhase

  public init(
    originalDisableSleep: Int,
    expectedDisableSleep: Int = 1,
    createdAt: Date,
    phase: PowerPhase
  ) {
    self.originalDisableSleep = originalDisableSleep
    self.expectedDisableSleep = expectedDisableSleep
    self.createdAt = createdAt
    self.phase = phase
  }
}

public enum ShutdownPhase: String, Codable, Equatable, Sendable {
  case planned
  case committing
  case committed
}

public struct ShutdownRecord: Codable, Equatable, Sendable {
  public let id: String
  public let owner: String
  public let createdAt: Date
  public let scheduledAt: Date
  public var phase: ShutdownPhase
  public var committedAt: Date?
  public var systemScheduleDate: String?
  public var systemScheduleTimeZone: String?

  public init(
    id: String,
    owner: String,
    createdAt: Date,
    scheduledAt: Date,
    phase: ShutdownPhase,
    committedAt: Date? = nil,
    systemScheduleDate: String? = nil,
    systemScheduleTimeZone: String? = nil
  ) {
    self.id = id
    self.owner = owner
    self.createdAt = createdAt
    self.scheduledAt = scheduledAt
    self.phase = phase
    self.committedAt = committedAt
    self.systemScheduleDate = systemScheduleDate
    self.systemScheduleTimeZone = systemScheduleTimeZone
  }
}

public struct TeaAwayState: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var power: PowerRecord?
  public var shutdown: ShutdownRecord?

  public init(
    schemaVersion: Int = 1,
    power: PowerRecord? = nil,
    shutdown: ShutdownRecord? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.power = power
    self.shutdown = shutdown
  }

  public static let empty = TeaAwayState()
}

public protocol TeaAwayClock: Sendable {
  var now: Date { get }
}

public struct SystemClock: TeaAwayClock {
  public init() {}

  public var now: Date { Date() }
}

public protocol IdentifierGenerating: Sendable {
  func makeIdentifier() -> String
}

public struct UUIDIdentifierGenerator: IdentifierGenerating {
  public init() {}

  public func makeIdentifier() -> String {
    UUID().uuidString.lowercased()
  }
}

public enum TeaAwayError: LocalizedError, Equatable {
  case usage(String)
  case invalidDuration(String)
  case durationOutOfRange(minimum: Int, maximum: Int)
  case stateLocked
  case stateCorrupt(String)
  case requiresACPower
  case powerSettingUnreadable(String)
  case powerConflict(expected: Int, actual: Int)
  case powerRecoveryRequired(String)
  case shutdownAlreadyExists(String)
  case noShutdown
  case actionIDMismatch
  case planExpired
  case shutdownChallengeFailed
  case shutdownScheduleConflict(String)
  case shutdownScheduleUnreadable(String)
  case shutdownScheduleVerificationFailed(String)
  case shutdownRecoveryRequired(String, String)
  case commandFailed(String, Int32, String)

  public var errorDescription: String? {
    switch self {
    case .usage(let message):
      return message
    case .invalidDuration(let value):
      return "invalid duration: \(value); use values such as 30m, 4h, or 1d"
    case .durationOutOfRange(let minimum, let maximum):
      return "duration must be between \(minimum) and \(maximum) seconds"
    case .stateLocked:
      return "another teaway operation is updating state"
    case .stateCorrupt(let message):
      return "teaway state is unreadable: \(message)"
    case .requiresACPower:
      return "teaway on requires AC power"
    case .powerSettingUnreadable(let detail):
      return "cannot safely read macOS disablesleep state: \(detail)"
    case .powerConflict(let expected, let actual):
      return
        "refusing to change disablesleep because teaway expected \(expected) but macOS reports \(actual); the recovery record was retained"
    case .powerRecoveryRequired(let detail):
      return
        "power state needs recovery; teaway retained the original disablesleep value. \(detail)"
    case .shutdownAlreadyExists(let id):
      return "shutdown action \(id) already exists; cancel it before planning another"
    case .noShutdown:
      return "no teaway shutdown action is recorded"
    case .actionIDMismatch:
      return "action ID does not match the recorded shutdown plan"
    case .planExpired:
      return "shutdown plan expired; create a new plan before committing"
    case .shutdownChallengeFailed:
      return
        "shutdown commit requires an interactive terminal and the exact displayed SHUTDOWN phrase"
    case .shutdownScheduleConflict(let detail):
      return
        "refusing to change shutdown state because macOS reports a conflicting event: \(detail)"
    case .shutdownScheduleUnreadable(let detail):
      return "cannot safely interpret macOS scheduled power events: \(detail)"
    case .shutdownScheduleVerificationFailed(let id):
      return "macOS did not report the exact teaway shutdown after scheduling action \(id)"
    case .shutdownRecoveryRequired(let id, let detail):
      return
        "HIGH RISK: shutdown action \(id) may still be active; teaway retained its recovery record. Run 'teaway shutdown status' and then 'teaway shutdown cancel \(id)'. \(detail)"
    case .commandFailed(let path, let status, let stderr):
      let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      return detail.isEmpty
        ? "command failed (\(status)): \(path)"
        : "command failed (\(status)): \(path): \(detail)"
    }
  }
}
