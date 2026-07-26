import Foundation
import XCTest

@testable import TeaAwayCore

final class PowerServiceTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testParserAcceptsExactlyOneBooleanDisableSleepValue() throws {
    XCTAssertEqual(
      try PowerService.parseDisableSleep(
        from: "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n"
      ),
      1
    )
    XCTAssertEqual(
      try PowerService.parseDisableSleep(from: " disablesleep 0\n"),
      0
    )

    for malformed in [
      "Currently in use:\n sleep 1\n",
      "SleepDisabled 2\n",
      "SleepDisabled 1 extra\n",
      "SleepDisabled 1\ndisablesleep 1\n",
    ] {
      XCTAssertThrowsError(try PowerService.parseDisableSleep(from: malformed))
    }
  }

  func testOnPersistsIntentBeforeExactSudoMutationAndPreservesShutdownState() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let shutdown = makeShutdownRecord()
    try store.save(TeaAwayState(shutdown: shutdown))
    let executor = FakeExecutor()
    let machine = FakePowerMachine(liveValue: 0)
    machine.install(on: executor)
    executor.interactiveRunHandler = { command in
      if command.arguments.first == SystemCommand.pmset {
        let persisted = try store.load()
        XCTAssertEqual(persisted.power?.phase, .enabling)
        XCTAssertEqual(persisted.power?.originalDisableSleep, 0)
        XCTAssertEqual(persisted.shutdown, shutdown)
        machine.liveValue = 1
      }
      return CommandResult(exitCode: 0)
    }
    let service = makeService(store: store, executor: executor)

    let record = try service.turnOn()

    XCTAssertEqual(
      record,
      PowerRecord(
        originalDisableSleep: 0,
        createdAt: now,
        phase: .enabled
      )
    )
    XCTAssertEqual(
      executor.runCommands,
      [
        ExternalCommand(SystemCommand.pmset, ["-g", "batt"]),
        ExternalCommand(SystemCommand.pmset, ["-g"]),
        ExternalCommand(SystemCommand.pmset, ["-g", "batt"]),
        ExternalCommand(SystemCommand.pmset, ["-g"]),
      ]
    )
    XCTAssertEqual(
      executor.interactiveRunCommands,
      privilegedMutationCommands(value: 1)
    )
    let finalState = try store.load()
    XCTAssertEqual(finalState.power, record)
    XCTAssertEqual(finalState.shutdown, shutdown)
  }

  func testOriginalValueOneIsBorrowedAndOffLeavesItOneWithoutPrivilegedMutation() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    let machine = FakePowerMachine(liveValue: 1)
    machine.install(on: executor)
    let service = makeService(store: store, executor: executor)

    let record = try service.turnOn()
    XCTAssertEqual(record.originalDisableSleep, 1)
    XCTAssertEqual(record.phase, .enabled)
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
    XCTAssertEqual(
      try service.status(),
      PowerStatus(observation: .borrowed, liveDisableSleep: 1, record: record)
    )

    let result = try service.turnOff()
    XCTAssertEqual(result, PowerOffResult(restoredDisableSleep: 1, hadRecord: true))
    XCTAssertEqual(machine.liveValue, 1)
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
    XCTAssertNil(try store.load().power)
  }

  func testOnFailsBeforeSavingOrSudoWhenInitiallyOnBattery() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    FakePowerMachine(liveValue: 0, powerSources: ["Battery Power"]).install(on: executor)
    let service = makeService(store: store, executor: executor)

    XCTAssertThrowsError(try service.turnOn()) { error in
      XCTAssertEqual(error as? TeaAwayError, .requiresACPower)
    }
    XCTAssertEqual(
      executor.runCommands,
      [ExternalCommand(SystemCommand.pmset, ["-g", "batt"])]
    )
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
    XCTAssertNil(try store.load().power)
  }

  func testOnRechecksACAfterSudoValidationBeforePmsetAndRetainsIntentIfPowerWasLost() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    let machine = FakePowerMachine(
      liveValue: 0,
      powerSources: ["AC Power", "Battery Power"]
    )
    machine.install(on: executor)
    let service = makeService(store: store, executor: executor)

    assertRecoveryError(try service.turnOn())

    XCTAssertEqual(
      executor.interactiveRunCommands,
      [
        ExternalCommand(SystemCommand.sudo, ["-v"]),
      ]
    )
    XCTAssertEqual(machine.sudoValidationStatesAtACReads, [false, true])
    XCTAssertEqual(try store.load().power, makePowerRecord(phase: .enabling))
  }

  func testOnDoesNotMutateWhenInitialIntentSaveFails() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    FakePowerMachine(liveValue: 0).install(on: executor)
    let service = PowerService(
      store: store,
      executor: executor,
      privilegedExecutor: ordinarySudoPrivilegeExecutor(executor),
      clock: FixedClock(now: now),
      stateSaver: { _ in throw TestFailure.save }
    )

    XCTAssertThrowsError(try service.turnOn())
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
    XCTAssertNil(try store.load().power)
  }

  func testOnMutationFailureRetainsEnablingRecord() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    let machine = FakePowerMachine(liveValue: 0, mutationExitCode: 1)
    machine.install(on: executor)
    let service = makeService(store: store, executor: executor)

    assertRecoveryError(try service.turnOn())

    XCTAssertEqual(try store.load().power, makePowerRecord(phase: .enabling))
    XCTAssertEqual(executor.interactiveRunCommands, privilegedMutationCommands(value: 1))
  }

  func testOnVerificationFailureRetainsEnablingRecord() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    let machine = FakePowerMachine(liveValue: 0, applyMutation: false)
    machine.install(on: executor)
    let service = makeService(store: store, executor: executor)

    assertRecoveryError(try service.turnOn())

    XCTAssertEqual(try store.load().power, makePowerRecord(phase: .enabling))
    XCTAssertEqual(machine.liveValue, 0)
  }

  func testOnFinalSaveFailureRetainsEnablingRecordAfterVerifiedMutation() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    let machine = FakePowerMachine(liveValue: 0)
    machine.install(on: executor)
    let saver = ControlledStateSaver(store: store, failingCalls: [2])
    let service = makeService(store: store, executor: executor, saver: saver)

    assertRecoveryError(try service.turnOn())

    XCTAssertEqual(machine.liveValue, 1)
    XCTAssertEqual(try store.load().power, makePowerRecord(phase: .enabling))
  }

  func testOffClearsRecordWithoutMutationWhenLiveAlreadyReturnedToBaseline() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let record = makePowerRecord(phase: .enabled)
    try store.save(TeaAwayState(power: record))
    let executor = FakeExecutor()
    FakePowerMachine(liveValue: 0).install(on: executor)
    let service = makeService(store: store, executor: executor)

    XCTAssertEqual(
      try service.turnOff(),
      PowerOffResult(restoredDisableSleep: 0, hadRecord: true)
    )

    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
    XCTAssertNil(try store.load().power)
  }

  func testOffClearsBorrowedRecordAfterExternalChangeWithoutRestoringOne() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let record = PowerRecord(
      originalDisableSleep: 1,
      createdAt: now,
      phase: .enabled
    )
    try store.save(TeaAwayState(power: record))
    let executor = FakeExecutor()
    let machine = FakePowerMachine(liveValue: 0)
    machine.install(on: executor)
    let service = makeService(store: store, executor: executor)

    XCTAssertEqual(
      try service.turnOff(),
      PowerOffResult(restoredDisableSleep: 0, hadRecord: true)
    )
    XCTAssertEqual(machine.liveValue, 0)
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
    XCTAssertNil(try store.load().power)
  }

  func testOffMutationFailureRetainsRestoringRecord() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    try store.save(TeaAwayState(power: makePowerRecord(phase: .enabled)))
    let executor = FakeExecutor()
    let machine = FakePowerMachine(liveValue: 1, mutationExitCode: 1)
    machine.install(on: executor)
    let service = makeService(store: store, executor: executor)

    assertRecoveryError(try service.turnOff())

    XCTAssertEqual(try store.load().power, makePowerRecord(phase: .restoring))
    XCTAssertEqual(machine.liveValue, 1)
  }

  func testOffVerificationFailureRetainsRestoringRecord() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    try store.save(TeaAwayState(power: makePowerRecord(phase: .enabled)))
    let executor = FakeExecutor()
    let machine = FakePowerMachine(liveValue: 1, applyMutation: false)
    machine.install(on: executor)
    let service = makeService(store: store, executor: executor)

    assertRecoveryError(try service.turnOff())

    XCTAssertEqual(try store.load().power, makePowerRecord(phase: .restoring))
    XCTAssertEqual(machine.liveValue, 1)
  }

  func testOffFinalSaveFailureRetainsRestoringRecordAfterVerifiedRestore() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    try store.save(TeaAwayState(power: makePowerRecord(phase: .enabled)))
    let executor = FakeExecutor()
    let machine = FakePowerMachine(liveValue: 1)
    machine.install(on: executor)
    let saver = ControlledStateSaver(store: store, failingCalls: [2])
    let service = makeService(store: store, executor: executor, saver: saver)

    assertRecoveryError(try service.turnOff())

    XCTAssertEqual(machine.liveValue, 0)
    XCTAssertEqual(try store.load().power, makePowerRecord(phase: .restoring))
  }

  func testOffCompletesRestoringCrashWindowWithoutAnotherPrivilegedMutation() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    try store.save(TeaAwayState(power: makePowerRecord(phase: .restoring)))
    let executor = FakeExecutor()
    FakePowerMachine(liveValue: 0).install(on: executor)
    let service = makeService(store: store, executor: executor)

    XCTAssertEqual(
      try service.turnOff(),
      PowerOffResult(restoredDisableSleep: 0, hadRecord: true)
    )
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
    XCTAssertNil(try store.load().power)
  }

  func testOffClearsAbortedEnableAtOriginalValueWithoutPrivilegedMutation() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    try store.save(TeaAwayState(power: makePowerRecord(phase: .enabling)))
    let executor = FakeExecutor()
    FakePowerMachine(liveValue: 0).install(on: executor)
    let service = makeService(store: store, executor: executor)

    XCTAssertEqual(
      try service.turnOff(),
      PowerOffResult(restoredDisableSleep: 0, hadRecord: true)
    )
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
    XCTAssertNil(try store.load().power)
  }

  func testStatusDistinguishesExternalOnRecoveryAndConflict() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    let machine = FakePowerMachine(liveValue: 1)
    machine.install(on: executor)
    let service = makeService(store: store, executor: executor)

    XCTAssertEqual(
      try service.status(),
      PowerStatus(observation: .external, liveDisableSleep: 1, record: nil)
    )

    let enabled = makePowerRecord(phase: .enabled)
    try store.save(TeaAwayState(power: enabled))
    XCTAssertEqual(
      try service.status(),
      PowerStatus(observation: .on, liveDisableSleep: 1, record: enabled)
    )

    let restoring = makePowerRecord(phase: .restoring)
    try store.save(TeaAwayState(power: restoring))
    XCTAssertEqual(
      try service.status(),
      PowerStatus(observation: .needsRecovery, liveDisableSleep: 1, record: restoring)
    )

    try store.save(TeaAwayState(power: enabled))
    machine.liveValue = 0
    XCTAssertEqual(
      try service.status(),
      PowerStatus(observation: .conflict, liveDisableSleep: 0, record: enabled)
    )
  }

  func testOffWithoutRecordLeavesExternalOneUnchanged() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    let executor = FakeExecutor()
    let machine = FakePowerMachine(liveValue: 1)
    machine.install(on: executor)
    let service = makeService(store: store, executor: executor)

    XCTAssertEqual(
      try service.turnOff(),
      PowerOffResult(restoredDisableSleep: 1, hadRecord: false)
    )
    XCTAssertEqual(machine.liveValue, 1)
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
    XCTAssertNil(try store.load().power)
  }

  private func makeService(
    store: StateStore,
    executor: FakeExecutor,
    saver: ControlledStateSaver? = nil
  ) -> PowerService {
    let stateSaver: (@Sendable (TeaAwayState) throws -> Void)?
    if let saver {
      stateSaver = { @Sendable state in try saver.save(state) }
    } else {
      stateSaver = nil
    }
    return PowerService(
      store: store,
      executor: executor,
      privilegedExecutor: ordinarySudoPrivilegeExecutor(executor),
      clock: FixedClock(now: now),
      stateSaver: stateSaver
    )
  }

  private func makePowerRecord(phase: PowerPhase) -> PowerRecord {
    PowerRecord(
      originalDisableSleep: 0,
      createdAt: now,
      phase: phase
    )
  }

  private func makeShutdownRecord() -> ShutdownRecord {
    ShutdownRecord(
      id: "action-1",
      owner: "teaway:action-1",
      createdAt: now,
      scheduledAt: now.addingTimeInterval(3_600),
      phase: .planned
    )
  }

  private func privilegedMutationCommands(value: Int) -> [ExternalCommand] {
    [
      ExternalCommand(SystemCommand.sudo, ["-v"]),
      ExternalCommand(
        SystemCommand.sudo,
        [SystemCommand.pmset, "-a", "disablesleep", String(value)]
      ),
    ]
  }

  private func assertRecoveryError<T>(
    _ expression: @autoclosure () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
      guard case TeaAwayError.powerRecoveryRequired = error else {
        return XCTFail("unexpected error: \(error)", file: file, line: line)
      }
    }
  }
}

private enum TestFailure: Error {
  case save
}

private final class ControlledStateSaver: @unchecked Sendable {
  private let store: StateStore
  private let failingCalls: Set<Int>
  private var callCount = 0

  init(store: StateStore, failingCalls: Set<Int>) {
    self.store = store
    self.failingCalls = failingCalls
  }

  func save(_ state: TeaAwayState) throws {
    callCount += 1
    if failingCalls.contains(callCount) {
      throw TestFailure.save
    }
    try store.save(state)
  }
}

private final class FakePowerMachine: @unchecked Sendable {
  var liveValue: Int
  private(set) var sudoValidationStatesAtACReads: [Bool] = []
  let mutationExitCode: Int32
  let applyMutation: Bool
  private let powerSources: [String]
  private var powerSourceReadCount = 0
  private var sudoWasValidated = false

  init(
    liveValue: Int,
    mutationExitCode: Int32 = 0,
    applyMutation: Bool = true,
    powerSources: [String] = ["AC Power"]
  ) {
    self.liveValue = liveValue
    self.mutationExitCode = mutationExitCode
    self.applyMutation = applyMutation
    self.powerSources = powerSources
  }

  func install(on executor: FakeExecutor) {
    executor.runHandler = { command in
      if command == ExternalCommand(SystemCommand.pmset, ["-g", "batt"]) {
        self.sudoValidationStatesAtACReads.append(self.sudoWasValidated)
        let index = min(self.powerSourceReadCount, self.powerSources.count - 1)
        self.powerSourceReadCount += 1
        return CommandResult(
          exitCode: 0,
          standardOutput: "Now drawing from '\(self.powerSources[index])'\n"
        )
      }
      guard command == ExternalCommand(SystemCommand.pmset, ["-g"]) else {
        return CommandResult(exitCode: 1, standardError: "unexpected command")
      }
      return CommandResult(
        exitCode: 0,
        standardOutput: "System-wide power settings:\n SleepDisabled \(self.liveValue)\n"
      )
    }
    executor.interactiveRunHandler = { command in
      guard command.executable == SystemCommand.sudo else {
        return CommandResult(exitCode: 1, standardError: "unexpected executable")
      }
      if command.arguments == ["-v"] {
        self.sudoWasValidated = true
      }
      guard command.arguments.first == SystemCommand.pmset else {
        return CommandResult(exitCode: 0)
      }
      guard self.mutationExitCode == 0 else {
        return CommandResult(exitCode: self.mutationExitCode, standardError: "pmset failed")
      }
      if self.applyMutation, let value = command.arguments.last.flatMap(Int.init) {
        self.liveValue = value
      }
      return CommandResult(exitCode: 0)
    }
  }
}
