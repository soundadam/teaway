import Foundation

public final class TeaAwayApplication {
  private let powerService: PowerService
  private let shutdownService: ShutdownService
  private let privilegeRegistrationService: (any PrivilegeRegistering)?
  private let output: (String) -> Void
  private let errorOutput: (String) -> Void
  private let input: () -> String?
  private let displayDateFormatter: DateFormatter
  private let hostName: String

  public init(
    powerService: PowerService,
    shutdownService: ShutdownService,
    privilegeRegistrationService: (any PrivilegeRegistering)? = nil,
    output: @escaping (String) -> Void = { print($0) },
    errorOutput: @escaping (String) -> Void = { message in
      FileHandle.standardError.write(Data("\(message)\n".utf8))
    },
    input: @escaping () -> String? = { readLine(strippingNewline: true) },
    timeZone: TimeZone = .current,
    hostName: String = ProcessInfo.processInfo.hostName
  ) {
    self.powerService = powerService
    self.shutdownService = shutdownService
    self.privilegeRegistrationService = privilegeRegistrationService
    self.output = output
    self.errorOutput = errorOutput
    self.input = input
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
    let privilegedExecutor = SystemPrivilegedCommandExecutor(executor: executor)
    self.init(
      powerService: PowerService(
        store: store,
        executor: executor,
        privilegedExecutor: privilegedExecutor
      ),
      shutdownService: ShutdownService(
        store: store,
        executor: executor,
        privilegedExecutor: privilegedExecutor
      ),
      privilegeRegistrationService: SystemPrivilegeRegistrationService(
        executor: executor
      ),
      output: output,
      errorOutput: errorOutput,
      input: { readLine(strippingNewline: true) }
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
      teaway
      teaway status
      teaway on
      teaway off
      teaway shutdown after DURATION
      teaway shutdown status
      teaway shutdown cancel [ACTION_ID]
      teaway interactive
      teaway auth status
      teaway auth register
      teaway auth unregister
      teaway version

    'on' disables lid-close sleep and records the exact value needed by 'off'.
    'off' never changes a setting teaway does not own.
    Run without arguments for the guided status and action menu.
    """

  private func execute(arguments: [String]) throws -> Int32 {
    guard let command = arguments.first else {
      return try runInteractive()
    }

    switch command {
    case "on":
      guard arguments.count == 1 else { throw TeaAwayError.usage(Self.usage) }
      let record = try powerService.turnOn()
      if record.originalDisableSleep == record.expectedDisableSleep {
        output("✓ Awake mode was already enabled. Teaway is now tracking it.")
      } else {
        output("✓ Awake mode is on. This Mac will stay awake until you run `teaway off`.")
      }
      output("  Previous setting saved: disablesleep=\(record.originalDisableSleep)")
      output("  Keep this Mac powered and well ventilated.")
      return 0
    case "off":
      guard arguments.count == 1 else { throw TeaAwayError.usage(Self.usage) }
      let result = try powerService.turnOff()
      if result.hadRecord {
        output("✓ Awake mode is off. The previous sleep setting was restored.")
      } else if result.restoredDisableSleep == 0 {
        output("✓ Awake mode is already off. Nothing changed.")
      } else {
        output("Awake mode is controlled elsewhere. Nothing changed.")
      }
      output("  Current setting: disablesleep=\(result.restoredDisableSleep)")
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
    case "interactive", "tui":
      guard arguments.count == 1 else { throw TeaAwayError.usage(Self.usage) }
      return try runInteractive()
    case "auth":
      return try runAuthorization(Array(arguments.dropFirst()))
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

  private func runAuthorization(_ arguments: [String]) throws -> Int32 {
    guard let service = privilegeRegistrationService else {
      throw TeaAwayError.authorizationConfiguration(
        "authorization management is unavailable in this build"
      )
    }
    guard let command = arguments.first, arguments.count == 1 else {
      throw TeaAwayError.usage(Self.usage)
    }

    switch command {
    case "status":
      outputAuthorizationStatus(try service.status())
      outputSudoTouchIDStatus(service.sudoTouchIDStatus())
    case "register":
      output("Set up passwordless Teaway controls")
      output("  macOS will ask for your account password once.")
      output("  Password input is hidden; no characters appear while you type.")
      output("  Teaway never reads or stores your password.")
      output(
        "  After setup, only awake-mode and teaway-owned shutdown operations run without a password."
      )
      let result = try service.register()
      output("✓ Passwordless Teaway controls are ready.")
      output("  Helper version: \(result.helperVersion)")
      output("  Helper: \(result.helperPath)")
      output("  Sudoers rule: \(result.sudoersPath)")
      output("  Scope: awake mode and teaway-owned shutdown operations only")
      output("  This permission is available to processes running as this macOS user.")
    case "unregister":
      try service.unregister()
      output("authorization: unregistered")
    default:
      throw TeaAwayError.usage(Self.usage)
    }
    return 0
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
      output("Scheduling shutdown for \(format(record.scheduledAt))…")
      let committedRecord = try shutdownService.commit(actionID: record.id)
      output("✓ Shutdown scheduled for \(format(committedRecord.scheduledAt)).")
      output("  Host: \(hostName)")
      output("  Cancel it with: teaway shutdown cancel")
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
      output("✓ Scheduled shutdown cancelled.")
      output("  Action: \(record.id)")
    default:
      throw TeaAwayError.usage(Self.usage)
    }
    return 0
  }

  private func outputPowerStatus(_ status: PowerStatus) {
    output("Teaway status")
    output("  Awake mode: \(powerDescription(status.observation))")
    output("  Power: \(status.powerSource)")
    output("  Sleep setting: disablesleep=\(status.liveDisableSleep)")
    if let record = status.record {
      output("  Saved setting: disablesleep=\(record.originalDisableSleep)")
    }
  }

  private func outputShutdownStatus(_ status: ShutdownStatus) {
    guard let record = status.record else {
      output("  Shutdown: Not scheduled")
      return
    }
    output("  Shutdown: \(shutdownDescription(status.observation))")
    output("  Scheduled for: \(format(record.scheduledAt))")
    output("  Action: \(record.id)")
  }

  private func runInteractive() throws -> Int32 {
    output("Teaway")
    output("Keep this Mac awake, then restore its previous sleep setting when you're done.")

    while true {
      output("")
      outputPowerStatus(try powerService.status())
      outputShutdownStatus(try shutdownService.status())
      let authorizationStatus = try privilegeRegistrationService?.status()
      if let authorizationStatus {
        outputInteractiveAuthorizationStatus(authorizationStatus)
      }
      output("")
      output("What would you like to do?")
      output("  1  Turn awake mode on")
      output("  2  Turn awake mode off")
      output("  3  Schedule a shutdown")
      output("  4  Cancel the scheduled shutdown")
      if privilegeRegistrationService != nil {
        output("  5  Set up passwordless controls (one-time admin check)")
      }
      output("  r  Refresh status")
      output("  q  Quit")
      output("Choose an option:")

      guard let choice = input()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        output("Goodbye.")
        return 0
      }

      do {
        switch choice.lowercased() {
        case "1":
          _ = try execute(arguments: ["on"])
          return 0
        case "2":
          _ = try execute(arguments: ["off"])
          return 0
        case "3":
          output("Enter a delay such as 30m, 2h, or 1d:")
          guard let duration = input()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !duration.isEmpty
          else {
            output("No duration entered; nothing changed.")
            return 0
          }
          _ = try runShutdown(["after", duration])
          return 0
        case "4":
          _ = try runShutdown(["cancel"])
          return 0
        case "5" where privilegeRegistrationService != nil:
          _ = try runAuthorization(["register"])
          return 0
        case "r":
          continue
        case "q", "quit", "exit":
          output("Goodbye.")
          return 0
        default:
          output("I didn't recognize that option. Choose 1–5, r, or q.")
        }
      } catch {
        errorOutput("Could not complete that action: \(error.localizedDescription)")
        return 1
      }
    }
  }

  private func powerDescription(_ observation: PowerObservation) -> String {
    switch observation {
    case .off: return "Off"
    case .on: return "On — managed by teaway"
    case .borrowed: return "On — teaway is preserving an existing setting"
    case .external: return "On — controlled outside teaway"
    case .needsRecovery: return "Needs recovery — run `teaway off`"
    case .conflict: return "Conflict — inspect before making changes"
    }
  }

  private func shutdownDescription(_ observation: ShutdownObservation) -> String {
    switch observation {
    case .none: return "Not scheduled"
    case .planned: return "Being prepared"
    case .scheduled: return "Scheduled"
    case .missingFromSystem: return "No longer present in macOS"
    case .needsRecovery: return "Needs recovery"
    case .conflict: return "Conflict"
    }
  }

  private func outputAuthorizationStatus(_ status: PrivilegeRegistrationStatus) {
    switch status {
    case .unregistered:
      output("authorization: unregistered")
      output("mode: ordinary sudo with the system credential cache")
    case .registered(let helperVersion):
      output("authorization: registered")
      output("helper version: \(helperVersion)")
      output("mode: passwordless narrow helper")
    case .needsRepair(let detail):
      output("authorization: needs-repair")
      output("detail: \(detail)")
    }
  }

  private func outputInteractiveAuthorizationStatus(_ status: PrivilegeRegistrationStatus) {
    switch status {
    case .unregistered:
      output("  Passwordless controls: Not set up — choose 5 to enable them")
    case .registered:
      output("  Passwordless controls: Ready")
    case .needsRepair:
      output("  Passwordless controls: Need refresh — choose 5 to repair them")
    }
  }

  private func outputSudoTouchIDStatus(_ status: SudoTouchIDStatus) {
    switch status {
    case .enabled:
      output("touch id for sudo: configured")
    case .disabled:
      output("touch id for sudo: not configured")
      output("touch id note: macOS PAM controls this; teaway does not modify PAM")
    case .unknown(let detail):
      output("touch id for sudo: unknown")
      output("touch id detail: \(detail)")
    }
  }

  private func format(_ date: Date) -> String {
    displayDateFormatter.string(from: date)
  }
}
