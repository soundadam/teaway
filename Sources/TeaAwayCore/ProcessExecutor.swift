import Foundation

public struct ExternalCommand: Equatable, Sendable {
  public let executable: String
  public let arguments: [String]

  public init(_ executable: String, _ arguments: [String] = []) {
    self.executable = executable
    self.arguments = arguments
  }
}

public struct CommandResult: Equatable, Sendable {
  public let exitCode: Int32
  public let standardOutput: String
  public let standardError: String

  public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

public protocol ProcessExecuting: Sendable {
  func run(_ command: ExternalCommand) throws -> CommandResult
  func runInteractive(_ command: ExternalCommand) throws -> CommandResult
}

public final class SystemProcessExecutor: ProcessExecuting, @unchecked Sendable {
  public init() {}

  public func run(_ command: ExternalCommand) throws -> CommandResult {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
    return CommandResult(
      exitCode: process.terminationStatus,
      standardOutput: String(decoding: output, as: UTF8.self),
      standardError: String(decoding: error, as: UTF8.self)
    )
  }

  public func runInteractive(_ command: ExternalCommand) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    return CommandResult(exitCode: process.terminationStatus)
  }
}

public enum SystemCommand {
  public static let pmset = "/usr/bin/pmset"
  public static let sudo = "/usr/bin/sudo"
}

extension ProcessExecuting {
  func checkedRun(_ command: ExternalCommand) throws -> CommandResult {
    let result = try run(command)
    guard result.exitCode == 0 else {
      throw TeaAwayError.commandFailed(
        command.executable,
        result.exitCode,
        result.standardError
      )
    }
    return result
  }

  func checkedInteractiveRun(_ command: ExternalCommand) throws -> CommandResult {
    let result = try runInteractive(command)
    guard result.exitCode == 0 else {
      throw TeaAwayError.commandFailed(
        command.executable,
        result.exitCode,
        result.standardError
      )
    }
    return result
  }
}
