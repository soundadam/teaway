import Darwin
import Foundation

public enum PrivilegeRegistrationStatus: Equatable, Sendable {
  case unregistered
  case registered(helperVersion: String)
  case needsRepair(String)
}

public enum SudoTouchIDStatus: Equatable, Sendable {
  case enabled
  case disabled
  case unknown(String)
}

public struct PrivilegeRegistrationResult: Equatable, Sendable {
  public let helperPath: String
  public let sudoersPath: String
  public let helperVersion: String

  public init(helperPath: String, sudoersPath: String, helperVersion: String) {
    self.helperPath = helperPath
    self.sudoersPath = sudoersPath
    self.helperVersion = helperVersion
  }
}

public protocol PrivilegeRegistering: Sendable {
  func status() throws -> PrivilegeRegistrationStatus
  func sudoTouchIDStatus() -> SudoTouchIDStatus
  func register() throws -> PrivilegeRegistrationResult
  func unregister() throws
}

public final class SystemPrivilegeRegistrationService: PrivilegeRegistering,
  @unchecked Sendable
{
  private let executor: any ProcessExecuting
  private let executablePath: String
  private let userName: String
  private let userID: UInt32
  private let helperPath: String
  private let sudoersPath: String
  private let legacySudoersPath: String
  private let fileExists: @Sendable (String) -> Bool
  private let readTextFile: @Sendable (String) throws -> String

  public init(
    executor: any ProcessExecuting,
    executablePath: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
    userName: String? = nil,
    userID: UInt32 = getuid(),
    fileExists: @escaping @Sendable (String) -> Bool = {
      FileManager.default.fileExists(atPath: $0)
    },
    readTextFile: @escaping @Sendable (String) throws -> String = {
      try String(contentsOfFile: $0, encoding: .utf8)
    }
  ) {
    self.executor = executor
    self.executablePath = URL(fileURLWithPath: executablePath)
      .resolvingSymlinksInPath().path
    self.userName = userName ?? Self.resolveUserName(userID: userID)
    self.userID = userID
    self.helperPath = TeaAwayPrivilegeConfiguration.helperPath(userID: userID)
    self.sudoersPath = TeaAwayPrivilegeConfiguration.sudoersPath(userID: userID)
    self.legacySudoersPath = TeaAwayPrivilegeConfiguration.legacySudoersPath(userID: userID)
    self.fileExists = fileExists
    self.readTextFile = readTextFile
  }

  public func status() throws -> PrivilegeRegistrationStatus {
    let helperExists = fileExists(helperPath)
    let sudoersExists = fileExists(sudoersPath)
    let legacySudoersExists = fileExists(legacySudoersPath)
    if legacySudoersExists && !sudoersExists {
      return .needsRepair(
        "the legacy sudoers filename contains dots and is ignored by macOS; run 'teaway auth register'"
      )
    }
    guard helperExists || sudoersExists else {
      return .unregistered
    }
    guard helperExists, sudoersExists else {
      return .needsRepair(
        helperExists
          ? "the sudoers rule is missing"
          : "the privileged helper is missing"
      )
    }

    let result = try executor.run(helperVersionCommand(nonInteractive: true))
    guard result.exitCode == 0 else {
      let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      return .needsRepair(
        detail.isEmpty ? "the registered helper is not authorized" : detail
      )
    }
    guard let version = parseHelperVersion(result.standardOutput) else {
      return .needsRepair("the registered helper returned an invalid version")
    }
    guard version == TeaAwayVersion.current else {
      return .needsRepair(
        "helper version \(version) does not match teaway \(TeaAwayVersion.current)"
      )
    }
    return .registered(helperVersion: version)
  }

  public func sudoTouchIDStatus() -> SudoTouchIDStatus {
    let paths = ["/etc/pam.d/sudo_local", "/etc/pam.d/sudo"]
    do {
      for path in paths where fileExists(path) {
        let contents = try readTextFile(path)
        if containsActiveTouchIDRule(contents) {
          return .enabled
        }
      }
      return .disabled
    } catch {
      return .unknown(error.localizedDescription)
    }
  }

  public func register() throws -> PrivilegeRegistrationResult {
    try validateRegistrationInputs()
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("teaway-auth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let temporarySudoers = temporaryDirectory.appendingPathComponent("sudoers")
    try Data(sudoersContents().utf8).write(to: temporarySudoers, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: temporarySudoers.path
    )

    _ = try executor.checkedRun(
      ExternalCommand(SystemCommand.visudo, ["-c", "-f", temporarySudoers.path])
    )

    _ = try executor.checkedInteractiveRun(ExternalCommand(SystemCommand.sudo, ["-v"]))
    _ = try executor.checkedInteractiveRun(
      ExternalCommand(
        SystemCommand.sudo,
        [
          SystemCommand.install,
          "-d",
          "-o", "root",
          "-g", "wheel",
          "-m", "0755",
          TeaAwayPrivilegeConfiguration.helperDirectory,
        ]
      )
    )
    _ = try executor.checkedInteractiveRun(
      ExternalCommand(
        SystemCommand.sudo,
        [
          SystemCommand.install,
          "-o", "root",
          "-g", "wheel",
          "-m", "0755",
          executablePath,
          helperPath,
        ]
      )
    )
    _ = try executor.checkedRun(ExternalCommand(SystemCommand.cmp, ["-s", executablePath, helperPath]))
    _ = try executor.checkedInteractiveRun(
      ExternalCommand(
        SystemCommand.sudo,
        [
          SystemCommand.install,
          "-o", "root",
          "-g", "wheel",
          "-m", "0440",
          temporarySudoers.path,
          sudoersPath,
        ]
      )
    )
    _ = try executor.checkedInteractiveRun(
      ExternalCommand(
        SystemCommand.sudo,
        [SystemCommand.visudo, "-c", "-f", sudoersPath]
      )
    )
    _ = try executor.checkedInteractiveRun(
      ExternalCommand(SystemCommand.sudo, [SystemCommand.rm, "-f", legacySudoersPath])
    )

    let versionResult = try executor.checkedRun(helperVersionCommand(nonInteractive: true))
    guard let helperVersion = parseHelperVersion(versionResult.standardOutput) else {
      throw TeaAwayError.authorizationConfiguration(
        "the installed helper returned an invalid version"
      )
    }
    guard helperVersion == TeaAwayVersion.current else {
      throw TeaAwayError.authorizationConfiguration(
        "the installed helper version \(helperVersion) does not match teaway \(TeaAwayVersion.current)"
      )
    }
    return PrivilegeRegistrationResult(
      helperPath: helperPath,
      sudoersPath: sudoersPath,
      helperVersion: helperVersion
    )
  }

  public func unregister() throws {
    _ = try executor.checkedInteractiveRun(ExternalCommand(SystemCommand.sudo, ["-v"]))
    _ = try executor.checkedInteractiveRun(
      ExternalCommand(SystemCommand.sudo, [SystemCommand.rm, "-f", helperPath])
    )
    _ = try executor.checkedInteractiveRun(
      ExternalCommand(SystemCommand.sudo, [SystemCommand.rm, "-f", sudoersPath])
    )
    _ = try executor.checkedInteractiveRun(
      ExternalCommand(SystemCommand.sudo, [SystemCommand.rm, "-f", legacySudoersPath])
    )
  }

  private func validateRegistrationInputs() throws {
    guard userID != 0 else {
      throw TeaAwayError.authorizationConfiguration(
        "registration must be run from the target user account, not root"
      )
    }
    guard isValidUserName(userName) else {
      throw TeaAwayError.authorizationConfiguration(
        "unsupported macOS short user name: \(userName)"
      )
    }
    guard executablePath != helperPath else {
      throw TeaAwayError.authorizationConfiguration(
        "run registration from the normal teaway executable"
      )
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: executablePath, isDirectory: &isDirectory),
      !isDirectory.boolValue,
      FileManager.default.isExecutableFile(atPath: executablePath)
    else {
      throw TeaAwayError.authorizationConfiguration(
        "cannot resolve the current teaway executable: \(executablePath)"
      )
    }
  }

  private func sudoersContents() -> String {
    let prefix = "\(userName) ALL=(root) NOPASSWD: \(helperPath) \(TeaAwayPrivilegeConfiguration.internalCommand)"
    return """
      # Managed by teaway auth register for uid \(userID).
      # The root-owned helper validates every dynamic date and owner argument.
      \(prefix) version
      \(prefix) set-disablesleep 0
      \(prefix) set-disablesleep 1
      \(prefix) schedule-shutdown *
      \(prefix) cancel-shutdown *
      """ + "\n"
  }

  private func helperVersionCommand(nonInteractive: Bool) -> ExternalCommand {
    var arguments: [String] = []
    if nonInteractive {
      arguments.append("-n")
    }
    arguments += [
      helperPath,
      TeaAwayPrivilegeConfiguration.internalCommand,
      "version",
    ]
    return ExternalCommand(SystemCommand.sudo, arguments)
  }

  private func parseHelperVersion(_ output: String) -> String? {
    let fields = output.split(whereSeparator: \Character.isWhitespace)
    guard fields.count == 2, fields[0] == "teaway-privileged-helper" else {
      return nil
    }
    return String(fields[1])
  }

  private func isValidUserName(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 64 else { return false }
    return value.utf8.allSatisfy { byte in
      (byte >= 48 && byte <= 57)
        || (byte >= 65 && byte <= 90)
        || (byte >= 97 && byte <= 122)
        || byte == 45
        || byte == 46
        || byte == 95
    }
  }

  private func containsActiveTouchIDRule(_ contents: String) -> Bool {
    contents.split(whereSeparator: \Character.isNewline).contains { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { return false }
      let fields = line.split(whereSeparator: \Character.isWhitespace)
      return fields.count >= 3
        && fields[0] == "auth"
        && fields[1] == "sufficient"
        && fields[2] == "pam_tid.so"
    }
  }

  private static func resolveUserName(userID: UInt32) -> String {
    guard let record = getpwuid(userID), let name = record.pointee.pw_name else {
      return NSUserName()
    }
    return String(cString: name)
  }
}
