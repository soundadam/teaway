import Darwin
import Foundation

public enum TeaAwayPrivilegeConfiguration {
  public static let helperDirectory = "/Library/PrivilegedHelperTools"
  public static let sudoersDirectory = "/etc/sudoers.d"
  public static let internalCommand = "__teaway_privileged"

  public static func helperPath(userID: UInt32) -> String {
    "\(helperDirectory)/com.soundadam.teaway.helper.\(userID)"
  }

  public static func sudoersPath(userID: UInt32) -> String {
    "\(sudoersDirectory)/soundadam-teaway-\(userID)"
  }

  public static func legacySudoersPath(userID: UInt32) -> String {
    "\(sudoersDirectory)/com.soundadam.teaway.\(userID)"
  }
}

public enum PrivilegedOperation: Equatable, Sendable {
  case setDisableSleep(Int)
  case scheduleShutdown(date: String, owner: String)
  case cancelShutdown(date: String, owner: String)

  fileprivate var pmsetArguments: [String] {
    switch self {
    case .setDisableSleep(let value):
      return ["-a", "disablesleep", String(value)]
    case .scheduleShutdown(let date, let owner):
      return ["schedule", "shutdown", date, owner]
    case .cancelShutdown(let date, let owner):
      return ["schedule", "cancel", "shutdown", date, owner]
    }
  }

  fileprivate var helperArguments: [String] {
    switch self {
    case .setDisableSleep(let value):
      return ["set-disablesleep", String(value)]
    case .scheduleShutdown(let date, let owner):
      return ["schedule-shutdown", date, owner]
    case .cancelShutdown(let date, let owner):
      return ["cancel-shutdown", date, owner]
    }
  }
}

public protocol PrivilegedCommandExecuting: Sendable {
  func authorize() throws
  func runAuthorized(_ operation: PrivilegedOperation) throws
}

extension PrivilegedCommandExecuting {
  func run(_ operation: PrivilegedOperation) throws {
    try authorize()
    try runAuthorized(operation)
  }
}

public final class SystemPrivilegedCommandExecutor: PrivilegedCommandExecuting,
  @unchecked Sendable
{
  private let executor: any ProcessExecuting
  private let helperPath: String
  private let sudoersPath: String
  private let fileExists: @Sendable (String) -> Bool

  public init(
    executor: any ProcessExecuting,
    userID: UInt32 = getuid(),
    fileExists: @escaping @Sendable (String) -> Bool = {
      FileManager.default.fileExists(atPath: $0)
    }
  ) {
    self.executor = executor
    self.helperPath = TeaAwayPrivilegeConfiguration.helperPath(userID: userID)
    self.sudoersPath = TeaAwayPrivilegeConfiguration.sudoersPath(userID: userID)
    self.fileExists = fileExists
  }

  public func authorize() throws {
    guard try !registeredHelperIsUsable() else { return }
    _ = try executor.checkedInteractiveRun(
      ExternalCommand(SystemCommand.sudo, ["-v"])
    )
  }

  public func runAuthorized(_ operation: PrivilegedOperation) throws {
    if try registeredHelperIsUsable() {
      _ = try executor.checkedRun(
        ExternalCommand(
          SystemCommand.sudo,
          [
            "-n",
            helperPath,
            TeaAwayPrivilegeConfiguration.internalCommand,
          ] + operation.helperArguments
        )
      )
      return
    }

    _ = try executor.checkedInteractiveRun(
      ExternalCommand(SystemCommand.sudo, [SystemCommand.pmset] + operation.pmsetArguments)
    )
  }

  private func registeredHelperIsUsable() throws -> Bool {
    guard fileExists(helperPath), fileExists(sudoersPath) else {
      return false
    }
    let result = try executor.run(
      ExternalCommand(
        SystemCommand.sudo,
        [
          "-n",
          helperPath,
          TeaAwayPrivilegeConfiguration.internalCommand,
          "version",
        ]
      )
    )
    guard result.exitCode == 0 else { return false }
    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      == "teaway-privileged-helper \(TeaAwayVersion.current)"
  }
}

enum PrivilegedHelperRequest: Equatable {
  case probe
  case version
  case operation(PrivilegedOperation)

  static func parse(arguments: [String]) -> PrivilegedHelperRequest? {
    guard let command = arguments.first else { return nil }
    switch command {
    case "probe" where arguments.count == 1:
      return .probe
    case "version" where arguments.count == 1:
      return .version
    case "set-disablesleep" where arguments.count == 2:
      let value = arguments[1]
      guard let parsed = Int(value), parsed == 0 || parsed == 1 else { return nil }
      return .operation(.setDisableSleep(parsed))
    case "schedule-shutdown" where arguments.count == 3:
      let date = arguments[1]
      let owner = arguments[2]
      guard isValidScheduleDate(date), isValidOwner(owner, allowLegacy: false) else {
        return nil
      }
      return .operation(.scheduleShutdown(date: date, owner: owner))
    case "cancel-shutdown" where arguments.count == 3:
      let date = arguments[1]
      let owner = arguments[2]
      guard isValidScheduleDate(date), isValidOwner(owner, allowLegacy: true) else {
        return nil
      }
      return .operation(.cancelShutdown(date: date, owner: owner))
    default:
      return nil
    }
  }

  private static func isValidScheduleDate(_ value: String) -> Bool {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "MM/dd/yy HH:mm:ss"
    formatter.isLenient = false
    guard let date = formatter.date(from: value) else { return false }
    return formatter.string(from: date) == value
  }

  private static func isValidOwner(_ value: String, allowLegacy: Bool) -> Bool {
    let prefixes = allowLegacy ? ["teaway:", "tea-away:"] : ["teaway:"]
    guard let prefix = prefixes.first(where: value.hasPrefix) else { return false }
    let identifier = value.dropFirst(prefix.count)
    guard (1...80).contains(identifier.count) else { return false }
    return identifier.utf8.allSatisfy { byte in
      (byte >= 48 && byte <= 57)
        || (byte >= 65 && byte <= 90)
        || (byte >= 97 && byte <= 122)
        || byte == 45
    }
  }
}

public enum PrivilegedHelperMain {
  public static func run(arguments: [String]) -> Int32 {
    guard geteuid() == 0 else {
      writeError("teaway privileged helper must run as root")
      return 77
    }
    guard let request = PrivilegedHelperRequest.parse(arguments: arguments) else {
      writeError("invalid teaway privileged helper request")
      return 64
    }

    switch request {
    case .probe:
      print("ok")
      return 0
    case .version:
      print("teaway-privileged-helper \(TeaAwayVersion.current)")
      return 0
    case .operation(let operation):
      do {
        let result = try SystemProcessExecutor().run(
          ExternalCommand(SystemCommand.pmset, operation.pmsetArguments)
        )
        write(result.standardOutput, to: FileHandle.standardOutput)
        write(result.standardError, to: FileHandle.standardError)
        return result.exitCode
      } catch {
        writeError(error.localizedDescription)
        return 1
      }
    }
  }

  private static func writeError(_ message: String) {
    write("teaway: \(message)\n", to: FileHandle.standardError)
  }

  private static func write(_ value: String, to handle: FileHandle) {
    guard !value.isEmpty else { return }
    handle.write(Data(value.utf8))
  }
}
