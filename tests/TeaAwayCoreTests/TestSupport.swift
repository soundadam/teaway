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
