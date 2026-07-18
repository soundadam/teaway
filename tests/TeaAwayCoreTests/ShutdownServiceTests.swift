import Foundation
import XCTest

@testable import TeaAwayCore

final class ShutdownServiceTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let utc = TimeZone(secondsFromGMT: 0)!
  private let scheduleDate = "11/14/23 23:13:20"
  private let owner = "teaway:action-1"

  func testPlanCreatesUniqueOwnerWithoutExecutingSystemCommand() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    let service = makeService(store: store, executor: executor)

    let record = try service.plan(afterSeconds: 3_600)

    XCTAssertEqual(record.id, "action-1")
    XCTAssertEqual(record.owner, owner)
    XCTAssertEqual(record.phase, .planned)
    XCTAssertEqual(record.scheduledAt, now.addingTimeInterval(3_600))
    XCTAssertTrue(executor.runCommands.isEmpty)
    XCTAssertEqual(try store.load().shutdown, record)
  }

  func testCommitPersistsCommittingThenUsesFreshSudoAndVerifiesExactEvent() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    var inspection = 0
    executor.runHandler = { command in
      XCTAssertEqual(command, ExternalCommand(SystemCommand.pmset, ["-g", "sched"]))
      inspection += 1
      if inspection == 1 {
        return CommandResult(
          exitCode: 0,
          standardOutput: self.scheduleOutput(
            "[0] wake at 11/15/23 01:00:00 by 'com.apple.alarm.user-visible-test'"
          )
        )
      }
      return CommandResult(exitCode: 0, standardOutput: self.targetScheduleOutput())
    }
    let service = makeService(store: store, executor: executor)
    _ = try service.plan(afterSeconds: 3_600)

    let record = try service.commit(actionID: "action-1")

    XCTAssertEqual(record.phase, .committed)
    XCTAssertEqual(record.systemScheduleDate, scheduleDate)
    XCTAssertEqual(record.systemScheduleTimeZone, "GMT")
    XCTAssertEqual(
      executor.interactiveRunCommands,
      [
        ExternalCommand(SystemCommand.sudo, ["-k"]),
        ExternalCommand(SystemCommand.sudo, ["-v"]),
        scheduleCommand(cancel: false),
      ]
    )
    XCTAssertEqual(inspection, 2)
    XCTAssertEqual(try store.load().shutdown, record)
  }

  func testExpiredPlanNeverInspectsSystemOrInvokesSudo() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    let planner = makeService(store: store, executor: executor)
    _ = try planner.plan(afterSeconds: 3_600)
    let expiredService = ShutdownService(
      store: store,
      executor: executor,
      clock: FixedClock(now: now.addingTimeInterval(301)),
      identifiers: FixedIdentifierGenerator(value: "unused"),
      timeZone: utc
    )

    XCTAssertThrowsError(try expiredService.commit(actionID: "action-1")) { error in
      XCTAssertEqual(error as? TeaAwayError, .planExpired)
    }
    XCTAssertTrue(executor.runCommands.isEmpty)
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
  }

  func testSudoValidationFailureRestoresPlannedStateBeforePmsetRuns() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    executor.runHandler = { _ in
      CommandResult(exitCode: 0, standardOutput: self.scheduleOutput())
    }
    executor.interactiveRunHandler = { command in
      if command == ExternalCommand(SystemCommand.sudo, ["-v"]) {
        return CommandResult(exitCode: 1, standardError: "authorization rejected")
      }
      return CommandResult(exitCode: 0)
    }
    let service = makeService(store: store, executor: executor)
    _ = try service.plan(afterSeconds: 3_600)

    XCTAssertThrowsError(try service.commit(actionID: "action-1")) { error in
      guard case TeaAwayError.commandFailed = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try store.load().shutdown?.phase, .planned)
    XCTAssertEqual(
      executor.interactiveRunCommands,
      [
        ExternalCommand(SystemCommand.sudo, ["-k"]),
        ExternalCommand(SystemCommand.sudo, ["-v"]),
      ]
    )
  }

  func testCommitRejectsExistingShutdownBeforeAnySudo() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    executor.runHandler = { _ in
      CommandResult(
        exitCode: 0,
        standardOutput: self.scheduleOutput(
          "[0] shutdown at 11/15/23 02:00:00 by 'com.example.admin'"
        )
      )
    }
    let service = makeService(store: store, executor: executor)
    _ = try service.plan(afterSeconds: 3_600)

    XCTAssertThrowsError(try service.commit(actionID: "action-1")) { error in
      guard case TeaAwayError.shutdownScheduleConflict = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
    XCTAssertEqual(try store.load().shutdown?.phase, .planned)
  }

  func testCommitRejectsStaleTeaOwnerEvenWhenItIsNotShutdown() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    executor.runHandler = { _ in
      CommandResult(
        exitCode: 0,
        standardOutput: self.scheduleOutput(
          "[0] wake at 11/15/23 02:00:00 by 'tea-away:stale-action'"
        )
      )
    }
    let service = makeService(store: store, executor: executor)
    _ = try service.plan(afterSeconds: 3_600)

    XCTAssertThrowsError(try service.commit(actionID: "action-1")) { error in
      guard case TeaAwayError.shutdownScheduleConflict = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
  }

  func testCommitFailsClosedOnUnindexedRepeatingShutdown() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    executor.runHandler = { _ in
      CommandResult(
        exitCode: 0,
        standardOutput:
          "Repeating power events:\n  shutdown at 23:00:00 every day\nScheduled power events:\n"
      )
    }
    let service = makeService(store: store, executor: executor)
    _ = try service.plan(afterSeconds: 3_600)

    XCTAssertThrowsError(try service.commit(actionID: "action-1")) { error in
      guard case TeaAwayError.shutdownScheduleConflict = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
  }

  func testTypicalPmsetOutputParsesAndStatusRequiresExactSameLineTuple() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let record = makeRecord(phase: .committed)
    try store.save(TeaAwayState(shutdown: record))
    let executor = FakeExecutor()
    executor.runHandler = { command in
      XCTAssertEqual(command, ExternalCommand(SystemCommand.pmset, ["-g", "sched"]))
      return CommandResult(
        exitCode: 0,
        standardOutput: self.scheduleOutput(
          "[0] wake at 11/14/23 22:00:00 by 'com.apple.alarm.user-visible-Weekly Usage Report' leeway secs: 60 User visible: true",
          "[1] shutdown at \(self.scheduleDate) by '\(self.owner)'"
        )
      )
    }
    let service = makeService(store: store, executor: executor)

    XCTAssertEqual(
      try service.status(),
      ShutdownStatus(observation: .scheduled, record: record)
    )
  }

  func testStatusDoesNotCombineOwnerFromWakeLineWithAnotherShutdownLine() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let record = makeRecord(phase: .committed)
    try store.save(TeaAwayState(shutdown: record))
    let executor = FakeExecutor()
    executor.runHandler = { _ in
      CommandResult(
        exitCode: 0,
        standardOutput: self.scheduleOutput(
          "[0] wake at \(self.scheduleDate) by '\(self.owner)'",
          "[1] shutdown at \(self.scheduleDate) by 'com.example.other'"
        )
      )
    }
    let service = makeService(store: store, executor: executor)

    XCTAssertEqual(try service.status().observation, .conflict)
  }

  func testUnrecognizedPmsetEventLineFailsClosed() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    try store.save(TeaAwayState(shutdown: makeRecord(phase: .committed)))
    let executor = FakeExecutor()
    executor.runHandler = { _ in
      CommandResult(
        exitCode: 0,
        standardOutput: "Scheduled power events:\n [0] shutdown someday by magic\n"
      )
    }
    let service = makeService(store: store, executor: executor)

    XCTAssertThrowsError(try service.status()) { error in
      guard case TeaAwayError.shutdownScheduleUnreadable = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testCancelReconcilesCommittingCrashWindowAndCancelsObservedTuple() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let record = makeRecord(phase: .committing)
    try store.save(TeaAwayState(shutdown: record))
    let executor = FakeExecutor()
    var inspection = 0
    executor.runHandler = { _ in
      inspection += 1
      return CommandResult(
        exitCode: 0,
        standardOutput: inspection == 1 ? self.targetScheduleOutput() : self.scheduleOutput()
      )
    }
    let service = makeService(store: store, executor: executor)

    XCTAssertEqual(try service.cancel(actionID: "action-1"), record)
    XCTAssertEqual(
      executor.interactiveRunCommands,
      [
        ExternalCommand(SystemCommand.sudo, ["-k"]),
        ExternalCommand(SystemCommand.sudo, ["-v"]),
        scheduleCommand(cancel: true),
      ]
    )
    XCTAssertNil(try store.load().shutdown)
  }

  func testStatusAndCancelRecoverLegacyTeaAwayOwner() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let legacyOwner = "tea-away:action-1"
    let record = ShutdownRecord(
      id: "action-1",
      owner: legacyOwner,
      createdAt: now,
      scheduledAt: now.addingTimeInterval(3_600),
      phase: .committed,
      committedAt: now,
      systemScheduleDate: scheduleDate,
      systemScheduleTimeZone: "GMT"
    )
    try store.save(TeaAwayState(shutdown: record))
    let executor = FakeExecutor()
    var inspection = 0
    executor.runHandler = { _ in
      inspection += 1
      let output =
        inspection < 3
        ? self.scheduleOutput(
          "[0] shutdown at \(self.scheduleDate) by '\(legacyOwner)'"
        )
        : self.scheduleOutput()
      return CommandResult(exitCode: 0, standardOutput: output)
    }
    let service = makeService(store: store, executor: executor)

    XCTAssertEqual(
      try service.status(),
      ShutdownStatus(observation: .scheduled, record: record)
    )
    XCTAssertEqual(try service.cancel(actionID: "action-1"), record)
    XCTAssertEqual(
      executor.interactiveRunCommands.last,
      ExternalCommand(
        SystemCommand.sudo,
        [
          SystemCommand.pmset,
          "schedule",
          "cancel",
          "shutdown",
          scheduleDate,
          legacyOwner,
        ]
      )
    )
    XCTAssertNil(try store.load().shutdown)
  }

  func testCancelRemovesExactTeaEventWhileLeavingUnrelatedRepeatingShutdown() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let record = makeRecord(phase: .committed)
    try store.save(TeaAwayState(shutdown: record))
    let executor = FakeExecutor()
    var inspection = 0
    executor.runHandler = { _ in
      inspection += 1
      let repeating = "Repeating power events:\n  shutdown at 23:00:00 every day\n"
      if inspection == 1 {
        return CommandResult(
          exitCode: 0,
          standardOutput: repeating + self.targetScheduleOutput()
        )
      }
      return CommandResult(exitCode: 0, standardOutput: repeating)
    }
    let service = makeService(store: store, executor: executor)

    XCTAssertEqual(try service.cancel(actionID: "action-1"), record)
    XCTAssertEqual(executor.interactiveRunCommands.last, scheduleCommand(cancel: true))
    XCTAssertNil(try store.load().shutdown)
  }

  func testCancelPlannedActionInspectsSystemBeforeClearingWithoutSudo() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    executor.runHandler = { command in
      XCTAssertEqual(command, ExternalCommand(SystemCommand.pmset, ["-g", "sched"]))
      return CommandResult(exitCode: 0, standardOutput: self.scheduleOutput())
    }
    let service = makeService(store: store, executor: executor)
    _ = try service.plan(afterSeconds: 3_600)

    _ = try service.cancel(actionID: "action-1")

    XCTAssertEqual(executor.runCommands.count, 1)
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
    XCTAssertNil(try store.load().shutdown)
  }

  func testCommittedStateSaveFailureCancelsVerifiedEventAndRestoresPlan() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    var inspection = 0
    executor.runHandler = { _ in
      inspection += 1
      switch inspection {
      case 1: return CommandResult(exitCode: 0, standardOutput: self.scheduleOutput())
      case 2: return CommandResult(exitCode: 0, standardOutput: self.targetScheduleOutput())
      default: return CommandResult(exitCode: 0, standardOutput: self.scheduleOutput())
      }
    }
    let service = makeService(
      store: store,
      executor: executor,
      stateSaver: { state in
        if state.shutdown?.phase == .committed {
          throw TestStateSaveError.committed
        }
        try store.save(state)
      }
    )
    _ = try service.plan(afterSeconds: 3_600)

    XCTAssertThrowsError(try service.commit(actionID: "action-1")) { error in
      XCTAssertEqual(error as? TestStateSaveError, .committed)
    }
    XCTAssertEqual(try store.load().shutdown?.phase, .planned)
    XCTAssertEqual(executor.interactiveRunCommands.last, scheduleCommand(cancel: true))
    XCTAssertEqual(inspection, 3)
  }

  func testCompensationFailureRetainsCommittingRecordAndReturnsHighRiskError() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    var inspection = 0
    executor.runHandler = { _ in
      inspection += 1
      return CommandResult(
        exitCode: 0,
        standardOutput: inspection == 1 ? self.scheduleOutput() : self.targetScheduleOutput()
      )
    }
    executor.interactiveRunHandler = { command in
      if command.arguments.contains("cancel") {
        return CommandResult(exitCode: 1, standardError: "cancel rejected")
      }
      return CommandResult(exitCode: 0)
    }
    let service = makeService(
      store: store,
      executor: executor,
      stateSaver: { state in
        if state.shutdown?.phase == .committed {
          throw TestStateSaveError.committed
        }
        try store.save(state)
      }
    )
    _ = try service.plan(afterSeconds: 3_600)

    XCTAssertThrowsError(try service.commit(actionID: "action-1")) { error in
      guard case TeaAwayError.shutdownRecoveryRequired(let id, _) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(id, "action-1")
    }
    XCTAssertEqual(try store.load().shutdown?.phase, .committing)
    XCTAssertEqual(executor.interactiveRunCommands.last, scheduleCommand(cancel: true))
  }

  private func makeService(
    store: StateStore,
    executor: FakeExecutor,
    stateSaver: (@Sendable (TeaAwayState) throws -> Void)? = nil
  ) -> ShutdownService {
    ShutdownService(
      store: store,
      executor: executor,
      clock: FixedClock(now: now),
      identifiers: FixedIdentifierGenerator(value: "action-1"),
      timeZone: utc,
      stateSaver: stateSaver
    )
  }

  private func makeRecord(phase: ShutdownPhase) -> ShutdownRecord {
    ShutdownRecord(
      id: "action-1",
      owner: owner,
      createdAt: now,
      scheduledAt: now.addingTimeInterval(3_600),
      phase: phase,
      committedAt: phase == .committed ? now : nil,
      systemScheduleDate: scheduleDate,
      systemScheduleTimeZone: "GMT"
    )
  }

  private func scheduleCommand(cancel: Bool) -> ExternalCommand {
    var arguments = [SystemCommand.pmset, "schedule"]
    if cancel {
      arguments.append("cancel")
    }
    arguments += ["shutdown", scheduleDate, owner]
    return ExternalCommand(SystemCommand.sudo, arguments)
  }

  private func scheduleOutput(_ lines: String...) -> String {
    (["Scheduled power events:"] + lines.map { " \($0)" }).joined(separator: "\n") + "\n"
  }

  private func targetScheduleOutput() -> String {
    scheduleOutput("[0] shutdown at \(scheduleDate) by '\(owner)'")
  }
}

private enum TestStateSaveError: Error, Equatable {
  case committed
}
