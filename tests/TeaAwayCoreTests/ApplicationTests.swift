import Foundation
import XCTest

@testable import TeaAwayCore

final class ApplicationTests: XCTestCase {
  func testVersionIsStable() throws {
    let fixture = try makeApplicationFixture()
    defer { removeTemporaryStore(fixture.directory) }

    XCTAssertEqual(fixture.application.run(arguments: ["version"]), 0)
    XCTAssertEqual(fixture.output, ["teaway 0.4.1"])
    XCTAssertTrue(fixture.errors.isEmpty)
  }

  func testAuthorizationStatusAndRegistrationCommands() throws {
    let fixture = try makeApplicationFixture()
    defer { removeTemporaryStore(fixture.directory) }

    XCTAssertEqual(fixture.application.run(arguments: ["auth", "status"]), 0)
    XCTAssertTrue(fixture.output.contains("authorization: unregistered"))
    XCTAssertTrue(
      fixture.output.contains("mode: ordinary sudo with the system credential cache")
    )
    XCTAssertTrue(fixture.output.contains("touch id for sudo: not configured"))

    XCTAssertEqual(fixture.application.run(arguments: ["auth", "register"]), 0)
    XCTAssertEqual(fixture.privilegeRegistration.registerCalls, 1)
    XCTAssertTrue(fixture.output.contains("Set up passwordless Teaway controls"))
    XCTAssertTrue(
      fixture.output.contains("  Password input is hidden; no characters appear while you type.")
    )
    XCTAssertTrue(fixture.output.contains("  Teaway never reads or stores your password."))
    XCTAssertTrue(fixture.output.contains("✓ Passwordless Teaway controls are ready."))
    XCTAssertTrue(fixture.output.contains("  Helper version: 0.4.1"))
    XCTAssertTrue(
      fixture.output.contains(
        "  Scope: awake mode and teaway-owned shutdown operations only"
      )
    )

    XCTAssertEqual(fixture.application.run(arguments: ["auth", "unregister"]), 0)
    XCTAssertEqual(fixture.privilegeRegistration.unregisterCalls, 1)
  }

  func testNoArgumentsEntersInteractiveMode() throws {
    let fixture = try makeApplicationFixture(interactiveInput: ["q"])
    defer { removeTemporaryStore(fixture.directory) }

    XCTAssertEqual(fixture.application.run(arguments: []), 0)
    XCTAssertTrue(fixture.output.contains("What would you like to do?"))
    XCTAssertTrue(
      fixture.output.contains(
        "  Passwordless controls: Not set up — choose 5 to enable them"
      )
    )
    XCTAssertTrue(
      fixture.output.contains("  5  Set up passwordless controls (one-time admin check)")
    )
    XCTAssertTrue(fixture.output.contains("Goodbye."))
    XCTAssertEqual(
      fixture.executor.runCommands,
      [
        ExternalCommand(SystemCommand.pmset, ["-g"]),
        ExternalCommand(SystemCommand.pmset, ["-g", "batt"]),
      ]
    )
  }

  func testExplicitStatusRemainsNoninteractive() throws {
    let fixture = try makeApplicationFixture()
    defer { removeTemporaryStore(fixture.directory) }

    XCTAssertEqual(fixture.application.run(arguments: ["status"]), 0)
    XCTAssertEqual(
      fixture.output,
      [
        "Teaway status",
        "  Awake mode: Off",
        "  Power: AC Power",
        "  Sleep setting: disablesleep=0",
        "  Shutdown: Not scheduled",
      ]
    )
  }

  func testExternalOneIsReportedAndOffLeavesItUnchanged() throws {
    let fixture = try makeApplicationFixture(disableSleep: 1)
    defer { removeTemporaryStore(fixture.directory) }

    XCTAssertEqual(fixture.application.run(arguments: ["status"]), 0)
    XCTAssertEqual(
      fixture.output,
      [
        "Teaway status",
        "  Awake mode: On — controlled outside teaway",
        "  Power: AC Power",
        "  Sleep setting: disablesleep=1",
        "  Shutdown: Not scheduled",
      ]
    )
    XCTAssertEqual(fixture.application.run(arguments: ["off"]), 0)
    XCTAssertTrue(fixture.output.contains("Awake mode is controlled elsewhere. Nothing changed."))
    XCTAssertTrue(fixture.executor.interactiveRunCommands.isEmpty)
  }

  func testTopLevelOnAndOffUseExactPowerCommands() throws {
    let fixture = try makeApplicationFixture()
    defer { removeTemporaryStore(fixture.directory) }
    let machine = ApplicationPowerMachine(liveValue: 0)
    machine.install(on: fixture.executor)

    XCTAssertEqual(fixture.application.run(arguments: ["on"]), 0)
    XCTAssertTrue(
      fixture.output.contains(
        "✓ Awake mode is on. This Mac will stay awake until you run `teaway off`."
      )
    )
    XCTAssertFalse(fixture.output.contains(where: { $0.contains("remote reachability") }))
    XCTAssertEqual(machine.liveValue, 1)

    XCTAssertEqual(fixture.application.run(arguments: ["off"]), 0)
    XCTAssertTrue(
      fixture.output.contains("✓ Awake mode is off. The previous sleep setting was restored.")
    )
    XCTAssertEqual(machine.liveValue, 0)
    XCTAssertEqual(
      fixture.executor.interactiveRunCommands,
      privilegedMutationCommands(value: 1) + privilegedMutationCommands(value: 0)
    )
  }

  func testSessionEntryPointWasRemovedWithoutSpawningAnything() throws {
    let fixture = try makeApplicationFixture()
    defer { removeTemporaryStore(fixture.directory) }

    XCTAssertEqual(fixture.application.run(arguments: ["session", "status"]), 2)
    XCTAssertTrue(fixture.executor.runCommands.isEmpty)
    XCTAssertTrue(fixture.executor.interactiveRunCommands.isEmpty)
    XCTAssertFalse(fixture.errors.isEmpty)
  }

  func testShutdownAfterCommitsDirectlyAndCancelWithoutIDUsesRecordedAction() throws {
    let fixture = try makeApplicationFixture()
    defer { removeTemporaryStore(fixture.directory) }
    let machine = ApplicationShutdownMachine()
    machine.install(on: fixture.executor)

    XCTAssertEqual(
      fixture.application.run(arguments: ["shutdown", "after", "10m"]),
      0
    )
    XCTAssertTrue(machine.scheduled)
    XCTAssertEqual(try fixture.store.load().shutdown?.phase, .committed)
    XCTAssertTrue(fixture.output.contains("✓ Shutdown scheduled for 2023-11-14 22:23:20 Z."))
    XCTAssertTrue(fixture.output.contains("  Cancel it with: teaway shutdown cancel"))

    XCTAssertEqual(fixture.application.run(arguments: ["status"]), 0)
    XCTAssertTrue(fixture.output.contains("  Awake mode: Off"))
    XCTAssertTrue(fixture.output.contains("  Shutdown: Scheduled"))
    XCTAssertTrue(fixture.output.contains("  Action: action-1"))

    XCTAssertEqual(fixture.application.run(arguments: ["shutdown", "cancel"]), 0)
    XCTAssertFalse(machine.scheduled)
    XCTAssertNil(try fixture.store.load().shutdown)
    XCTAssertTrue(fixture.output.contains("✓ Scheduled shutdown cancelled."))
    XCTAssertEqual(
      fixture.executor.interactiveRunCommands,
      privilegedShutdownCommands(cancel: false) + privilegedShutdownCommands(cancel: true)
    )
  }

  func testShutdownAfterRejectsLessThanTenMinutes() throws {
    let fixture = try makeApplicationFixture()
    defer { removeTemporaryStore(fixture.directory) }

    XCTAssertEqual(
      fixture.application.run(arguments: ["shutdown", "after", "9m"]),
      1
    )
    XCTAssertTrue(fixture.executor.runCommands.isEmpty)
    XCTAssertTrue(fixture.executor.interactiveRunCommands.isEmpty)
  }

  func testShutdownPlanAndCommitAreNoLongerPublicCommands() throws {
    let fixture = try makeApplicationFixture()
    defer { removeTemporaryStore(fixture.directory) }

    XCTAssertFalse(TeaAwayApplication.usage.contains("shutdown plan"))
    XCTAssertFalse(TeaAwayApplication.usage.contains("shutdown commit"))
    XCTAssertEqual(
      fixture.application.run(arguments: ["shutdown", "plan", "--after", "10m"]),
      2
    )
    XCTAssertNil(try fixture.store.load().shutdown)
    XCTAssertTrue(fixture.executor.runCommands.isEmpty)
    XCTAssertTrue(fixture.executor.interactiveRunCommands.isEmpty)
  }

  func testInteractiveAndTUIAliasesShowTheSameGuidedMenu() throws {
    for command in ["interactive", "tui"] {
      let fixture = try makeApplicationFixture(interactiveInput: ["q"])
      defer { removeTemporaryStore(fixture.directory) }

      XCTAssertEqual(fixture.application.run(arguments: [command]), 0)
      XCTAssertTrue(fixture.output.contains("Teaway"))
      XCTAssertTrue(fixture.output.contains("What would you like to do?"))
      XCTAssertTrue(fixture.output.contains("  1  Turn awake mode on"))
      XCTAssertTrue(fixture.output.contains("Goodbye."))
      XCTAssertTrue(fixture.executor.interactiveRunCommands.isEmpty)
    }
  }

  func testInteractiveModeExitsAfterOneCompletedAction() throws {
    let fixture = try makeApplicationFixture(interactiveInput: ["1", "2"])
    defer { removeTemporaryStore(fixture.directory) }
    let machine = ApplicationPowerMachine(liveValue: 0)
    machine.install(on: fixture.executor)

    XCTAssertEqual(fixture.application.run(arguments: ["interactive"]), 0)
    XCTAssertEqual(machine.liveValue, 1)
    XCTAssertEqual(
      fixture.output.filter { $0 == "What would you like to do?" }.count,
      1
    )
  }

  func testInteractiveModeCanSetUpPasswordlessControlsAndExit() throws {
    let fixture = try makeApplicationFixture(interactiveInput: ["5", "1"])
    defer { removeTemporaryStore(fixture.directory) }

    XCTAssertEqual(fixture.application.run(arguments: ["tui"]), 0)
    XCTAssertEqual(fixture.privilegeRegistration.registerCalls, 1)
    XCTAssertTrue(fixture.output.contains("Set up passwordless Teaway controls"))
    XCTAssertEqual(
      fixture.output.filter { $0 == "What would you like to do?" }.count,
      1
    )
  }

  private func makeApplicationFixture(
    disableSleep: Int = 0,
    interactiveInput: [String] = []
  ) throws -> ApplicationFixture {
    let (store, directory) = try makeTemporaryStore()
    let executor = FakeExecutor()
    executor.runHandler = { command in
      if command == ExternalCommand(SystemCommand.pmset, ["-g"]) {
        return CommandResult(
          exitCode: 0,
          standardOutput: "System-wide power settings:\n SleepDisabled \(disableSleep)\n"
        )
      }
      if command == ExternalCommand(SystemCommand.pmset, ["-g", "sched"]) {
        return CommandResult(exitCode: 0, standardOutput: "Scheduled power events:\n")
      }
      if command == ExternalCommand(SystemCommand.pmset, ["-g", "batt"]) {
        return CommandResult(exitCode: 0, standardOutput: "Now drawing from 'AC Power'\n")
      }
      return CommandResult(exitCode: 1, standardError: "unexpected command")
    }
    let clock = FixedClock(now: Date(timeIntervalSince1970: 1_700_000_000))
    var output: [String] = []
    var errors: [String] = []
    var inputs = interactiveInput
    let privilegeRegistration = FakePrivilegeRegistrationService()
    let application = TeaAwayApplication(
      powerService: PowerService(
        store: store,
        executor: executor,
        privilegedExecutor: ordinarySudoPrivilegeExecutor(executor),
        clock: clock
      ),
      shutdownService: ShutdownService(
        store: store,
        executor: executor,
        privilegedExecutor: ordinarySudoPrivilegeExecutor(executor),
        clock: clock,
        identifiers: FixedIdentifierGenerator(value: "action-1"),
        timeZone: TimeZone(secondsFromGMT: 0)!
      ),
      privilegeRegistrationService: privilegeRegistration,
      output: { output.append($0) },
      errorOutput: { errors.append($0) },
      input: { inputs.isEmpty ? nil : inputs.removeFirst() },
      timeZone: TimeZone(secondsFromGMT: 0)!,
      hostName: "mac.example"
    )
    return ApplicationFixture(
      application: application,
      store: store,
      executor: executor,
      privilegeRegistration: privilegeRegistration,
      directory: directory,
      outputReader: { output },
      errorReader: { errors }
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

  private func privilegedShutdownCommands(cancel: Bool) -> [ExternalCommand] {
    var arguments = [SystemCommand.pmset, "schedule"]
    if cancel {
      arguments.append("cancel")
    }
    arguments += ["shutdown", "11/14/23 22:23:20", "teaway:action-1"]
    return [
      ExternalCommand(SystemCommand.sudo, ["-v"]),
      ExternalCommand(SystemCommand.sudo, arguments),
    ]
  }
}

private final class ApplicationFixture {
  let application: TeaAwayApplication
  let store: StateStore
  let executor: FakeExecutor
  let privilegeRegistration: FakePrivilegeRegistrationService
  let directory: URL
  private let outputReader: () -> [String]
  private let errorReader: () -> [String]

  init(
    application: TeaAwayApplication,
    store: StateStore,
    executor: FakeExecutor,
    privilegeRegistration: FakePrivilegeRegistrationService,
    directory: URL,
    outputReader: @escaping () -> [String],
    errorReader: @escaping () -> [String]
  ) {
    self.application = application
    self.store = store
    self.executor = executor
    self.privilegeRegistration = privilegeRegistration
    self.directory = directory
    self.outputReader = outputReader
    self.errorReader = errorReader
  }

  var output: [String] { outputReader() }
  var errors: [String] { errorReader() }
}

private final class ApplicationShutdownMachine: @unchecked Sendable {
  private let scheduleDate = "11/14/23 22:23:20"
  private let owner = "teaway:action-1"
  var scheduled = false

  func install(on executor: FakeExecutor) {
    executor.runHandler = { command in
      if command == ExternalCommand(SystemCommand.pmset, ["-g"]) {
        return CommandResult(
          exitCode: 0,
          standardOutput: "System-wide power settings:\n SleepDisabled 0\n"
        )
      }
      if command == ExternalCommand(SystemCommand.pmset, ["-g", "sched"]) {
        let event =
          self.scheduled
          ? " [0] shutdown at \(self.scheduleDate) by '\(self.owner)'\n"
          : ""
        return CommandResult(
          exitCode: 0,
          standardOutput: "Scheduled power events:\n" + event
        )
      }
      if command == ExternalCommand(SystemCommand.pmset, ["-g", "batt"]) {
        return CommandResult(exitCode: 0, standardOutput: "Now drawing from 'AC Power'\n")
      }
      return CommandResult(exitCode: 1, standardError: "unexpected command")
    }
    executor.interactiveRunHandler = { command in
      let schedulePrefix = [SystemCommand.pmset, "schedule"]
      if command.arguments.starts(with: schedulePrefix) {
        self.scheduled = !command.arguments.contains("cancel")
      }
      return CommandResult(exitCode: 0)
    }
  }
}

private final class ApplicationPowerMachine: @unchecked Sendable {
  var liveValue: Int

  init(liveValue: Int) {
    self.liveValue = liveValue
  }

  func install(on executor: FakeExecutor) {
    executor.runHandler = { command in
      if command == ExternalCommand(SystemCommand.pmset, ["-g", "batt"]) {
        return CommandResult(
          exitCode: 0,
          standardOutput: "Now drawing from 'AC Power'\n"
        )
      }
      if command == ExternalCommand(SystemCommand.pmset, ["-g"]) {
        return CommandResult(
          exitCode: 0,
          standardOutput: "System-wide power settings:\n SleepDisabled \(self.liveValue)\n"
        )
      }
      return CommandResult(exitCode: 1, standardError: "unexpected command")
    }
    executor.interactiveRunHandler = { command in
      if command.arguments.first == SystemCommand.pmset,
        let value = command.arguments.last.flatMap(Int.init)
      {
        self.liveValue = value
      }
      return CommandResult(exitCode: 0)
    }
  }
}
