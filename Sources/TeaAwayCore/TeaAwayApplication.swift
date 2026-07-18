import Foundation

public final class TeaAwayApplication {
  private let powerService: PowerService
  private let shutdownService: ShutdownService
  private let shutdownChallenger: any ShutdownChallenging
  private let output: (String) -> Void
  private let errorOutput: (String) -> Void
  private let displayDateFormatter: DateFormatter
  private let hostName: String

  public init(
    powerService: PowerService,
    shutdownService: ShutdownService,
    shutdownChallenger: any ShutdownChallenging = SystemShutdownChallenger(),
    output: @escaping (String) -> Void = { print($0) },
    errorOutput: @escaping (String) -> Void = { message in
      FileHandle.standardError.write(Data("\(message)\n".utf8))
    },
    timeZone: TimeZone = .current,
    hostName: String = ProcessInfo.processInfo.hostName
  ) {
    self.powerService = powerService
    self.shutdownService = shutdownService
    self.shutdownChallenger = shutdownChallenger
    self.output = output
    self.errorOutput = errorOutput
    self.hostName = hostName
    self.displayDateFormatter = DateFormatter()
    self.displayDateFormatter.locale = Locale(identifier: "en_US_POSIX")
    self.displayDateFormatter.timeZone = timeZone
    self.displayDateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
  }

  public convenience init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    output: @escaping (String) -> Void = { print($0) },
    errorOutput: @escaping (String) -> Void = { message in
      FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
  ) {
    let executor = SystemProcessExecutor()
    let store = StateStore(paths: .resolve(environment: environment))
    self.init(
      powerService: PowerService(store: store, executor: executor),
      shutdownService: ShutdownService(store: store, executor: executor),
      output: output,
      errorOutput: errorOutput
    )
  }

  @discardableResult
  public func run(arguments: [String]) -> Int32 {
    do {
      return try execute(arguments: arguments)
    } catch let error as TeaAwayError {
      errorOutput("teaway: \(error.localizedDescription)")
      if case .usage = error {
        return 2
      }
      return 1
    } catch {
      errorOutput("teaway: \(error.localizedDescription)")
      return 1
    }
  }

  public static let usage = """
    Usage:
      teaway [status]
      teaway on
      teaway off
      teaway shutdown after DURATION
      teaway shutdown status
      teaway shutdown cancel [ACTION_ID]
      teaway version

    'on' disables lid-close sleep and records the exact value needed by 'off'.
    'on' requires AC power; 'off' never changes a setting teaway does not own.
    Run 'status' before leaving and verify remote reachability independently.
    """

  private func execute(arguments: [String]) throws -> Int32 {
    let command = arguments.first ?? "status"

    switch command {
    case "on":
      guard arguments.count == 1 else { throw TeaAwayError.usage(Self.usage) }
      let record = try powerService.turnOn()
      output(
        record.originalDisableSleep == record.expectedDisableSleep
          ? "teaway: borrowed" : "teaway: on"
      )
      output("disablesleep: \(record.expectedDisableSleep)")
      output("restore: \(record.originalDisableSleep)")
      output("warning: verify remote reachability before closing the lid")
      output("warning: keep this Mac powered, stationary, and well ventilated")
      return 0
    case "off":
      guard arguments.count == 1 else { throw TeaAwayError.usage(Self.usage) }
      let result = try powerService.turnOff()
      if result.hadRecord {
        output("teaway: off")
      } else if result.restoredDisableSleep == 0 {
        output("teaway: already off")
      } else {
        output("teaway: external; unchanged")
      }
      output("disablesleep: \(result.restoredDisableSleep)")
      return 0
    case "status":
      guard arguments.count <= 1 else { throw TeaAwayError.usage(Self.usage) }
      let powerStatus = try powerService.status()
      let shutdownStatus = try shutdownService.status()
      outputPowerStatus(powerStatus)
      outputShutdownStatus(shutdownStatus)
      return 0
    case "shutdown":
      return try runShutdown(Array(arguments.dropFirst()))
    case "version", "--version":
      guard arguments.count == 1 else { throw TeaAwayError.usage(Self.usage) }
      output("teaway \(TeaAwayVersion.current)")
      return 0
    case "help", "-h", "--help":
      guard arguments.count == 1 else { throw TeaAwayError.usage(Self.usage) }
      output(Self.usage)
      return 0
    default:
      throw TeaAwayError.usage(Self.usage)
    }
  }

  private func runShutdown(_ arguments: [String]) throws -> Int32 {
    guard let command = arguments.first else {
      throw TeaAwayError.usage(Self.usage)
    }
    let tail = Array(arguments.dropFirst())

    switch command {
    case "after":
      guard tail.count == 1 else { throw TeaAwayError.usage(Self.usage) }
      let seconds = try DurationParser.parseShutdown(tail[0])
      let record = try shutdownService.plan(afterSeconds: seconds)
      output("shutdown action: \(record.id)")
      output("scheduled for: \(format(record.scheduledAt))")
      output("host: \(hostName)")
      output("owner: \(record.owner)")
      let expectedPhrase = shutdownChallenge(for: record)
      guard shutdownChallenger.confirm(expectedPhrase: expectedPhrase) else {
        discardUncommittedShutdownPlan(record)
        throw TeaAwayError.shutdownChallengeFailed
      }
      let committedRecord = try shutdownService.commit(actionID: record.id)
      output("shutdown committed: \(committedRecord.id)")
      output("scheduled for: \(format(committedRecord.scheduledAt))")
      output("cancel: teaway shutdown cancel")
    case "status":
      guard tail.isEmpty else { throw TeaAwayError.usage(Self.usage) }
      outputShutdownStatus(try shutdownService.status())
    case "cancel":
      guard tail.count <= 1 else { throw TeaAwayError.usage(Self.usage) }
      let actionID: String
      if let suppliedActionID = tail.first {
        actionID = suppliedActionID
      } else {
        guard let recordedAction = try shutdownService.status().record else {
          throw TeaAwayError.noShutdown
        }
        actionID = recordedAction.id
      }
      let record = try shutdownService.cancel(actionID: actionID)
      output("shutdown cancelled: \(record.id)")
    default:
      throw TeaAwayError.usage(Self.usage)
    }
    return 0
  }

  private func discardUncommittedShutdownPlan(_ record: ShutdownRecord) {
    do {
      _ = try shutdownService.cancel(actionID: record.id)
      output("shutdown plan discarded: \(record.id)")
    } catch {
      errorOutput(
        "teaway: warning: shutdown plan \(record.id) could not be discarded; "
          + "run 'teaway shutdown cancel \(record.id)'. \(error.localizedDescription)"
      )
    }
  }

  private func outputPowerStatus(_ status: PowerStatus) {
    output("teaway: \(status.observation.rawValue)")
    output("power source: \(status.powerSource)")
    output("disablesleep: \(status.liveDisableSleep)")
    if let record = status.record {
      output("phase: \(record.phase.rawValue)")
      output("restore: \(record.originalDisableSleep)")
    }
  }

  private func outputShutdownStatus(_ status: ShutdownStatus) {
    guard let record = status.record else {
      output("shutdown: none")
      return
    }
    output("shutdown: \(status.observation)")
    output("id: \(record.id)")
    output("owner: \(record.owner)")
    output("scheduled for: \(format(record.scheduledAt))")
  }

  private func format(_ date: Date) -> String {
    displayDateFormatter.string(from: date)
  }

  private func shutdownChallenge(for record: ShutdownRecord) -> String {
    "SHUTDOWN \(hostName) AT \(format(record.scheduledAt)) ID \(record.id)"
  }
}
