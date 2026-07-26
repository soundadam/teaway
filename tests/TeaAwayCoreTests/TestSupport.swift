import Foundation

@testable import TeaAwayCore

final class FakeExecutor: ProcessExecuting, @unchecked Sendable {
  var runHandler: (ExternalCommand) throws -> CommandResult = { _ in
    CommandResult(exitCode: 0)
  }
  var interactiveRunHandler: (ExternalCommand) throws -> CommandResult = { _ in
    CommandResult(exitCode: 0)
  }
  private(set) var runCommands: [ExternalCommand] = []
  private(set) var interactiveRunCommands: [ExternalCommand] = []

  func run(_ command: ExternalCommand) throws -> CommandResult {
    runCommands.append(command)
    return try runHandler(command)
  }

  func runInteractive(_ command: ExternalCommand) throws -> CommandResult {
    interactiveRunCommands.append(command)
    return try interactiveRunHandler(command)
  }
}

func ordinarySudoPrivilegeExecutor(
  _ executor: any ProcessExecuting
) -> SystemPrivilegedCommandExecutor {
  SystemPrivilegedCommandExecutor(
    executor: executor,
    fileExists: { _ in false }
  )
}

final class FakePrivilegeRegistrationService: PrivilegeRegistering, @unchecked Sendable {
  var statusValue: PrivilegeRegistrationStatus = .unregistered
  var touchIDStatusValue: SudoTouchIDStatus = .disabled
  var registerResult = PrivilegeRegistrationResult(
    helperPath: "/Library/PrivilegedHelperTools/com.soundadam.teaway.helper.501",
    sudoersPath: "/etc/sudoers.d/soundadam-teaway-501",
    helperVersion: TeaAwayVersion.current
  )
  private(set) var registerCalls = 0
  private(set) var unregisterCalls = 0

  func status() throws -> PrivilegeRegistrationStatus {
    statusValue
  }

  func sudoTouchIDStatus() -> SudoTouchIDStatus {
    touchIDStatusValue
  }

  func register() throws -> PrivilegeRegistrationResult {
    registerCalls += 1
    statusValue = .registered(helperVersion: registerResult.helperVersion)
    return registerResult
  }

  func unregister() throws {
    unregisterCalls += 1
    statusValue = .unregistered
  }
}

struct FixedClock: TeaAwayClock {
  let now: Date
}

struct FixedIdentifierGenerator: IdentifierGenerating {
  let value: String

  func makeIdentifier() -> String { value }
}

final class FixedShutdownChallenger: ShutdownChallenging {
  let confirmed: Bool
  private(set) var expectedPhrases: [String] = []

  init(confirmed: Bool) {
    self.confirmed = confirmed
  }

  func confirm(expectedPhrase: String) -> Bool {
    expectedPhrases.append(expectedPhrase)
    return confirmed
  }
}

func makeTemporaryStore() throws -> (StateStore, URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaway-tests-\(UUID().uuidString)", isDirectory: true)
  let store = StateStore(paths: TeaAwayPaths(stateDirectory: directory))
  try store.prepare()
  return (store, directory)
}

func removeTemporaryStore(_ directory: URL) {
  try? FileManager.default.removeItem(at: directory)
}
