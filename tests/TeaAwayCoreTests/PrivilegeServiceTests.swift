import Foundation
import XCTest

@testable import TeaAwayCore

final class PrivilegeServiceTests: XCTestCase {
  private let userID: UInt32 = 501

  func testOrdinarySudoUsesCachedAuthorizationWithoutInvalidatingIt() throws {
    let executor = FakeExecutor()
    let runner = SystemPrivilegedCommandExecutor(
      executor: executor,
      userID: userID,
      fileExists: { _ in false }
    )

    try runner.run(.setDisableSleep(1))

    XCTAssertEqual(
      executor.interactiveRunCommands,
      [
        ExternalCommand(SystemCommand.sudo, ["-v"]),
        ExternalCommand(
          SystemCommand.sudo,
          [SystemCommand.pmset, "-a", "disablesleep", "1"]
        ),
      ]
    )
    XCTAssertFalse(executor.interactiveRunCommands.contains { $0.arguments == ["-k"] })
    XCTAssertTrue(executor.runCommands.isEmpty)
  }

  func testRegisteredHelperUsesOnlyNonInteractiveNarrowCommands() throws {
    let executor = FakeExecutor()
    let helperPath = TeaAwayPrivilegeConfiguration.helperPath(userID: userID)
    let sudoersPath = TeaAwayPrivilegeConfiguration.sudoersPath(userID: userID)
    executor.runHandler = { command in
      if command.arguments.last == "version" {
        return CommandResult(
          exitCode: 0,
          standardOutput: "teaway-privileged-helper \(TeaAwayVersion.current)\n"
        )
      }
      return CommandResult(exitCode: 0)
    }
    let runner = SystemPrivilegedCommandExecutor(
      executor: executor,
      userID: userID,
      fileExists: { $0 == helperPath || $0 == sudoersPath }
    )

    try runner.run(
      .scheduleShutdown(
        date: "11/14/23 22:23:20",
        owner: "teaway:action-1"
      )
    )

    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
    XCTAssertEqual(
      executor.runCommands,
      [
        ExternalCommand(
          SystemCommand.sudo,
          [
            "-n",
            helperPath,
            TeaAwayPrivilegeConfiguration.internalCommand,
            "version",
          ]
        ),
        ExternalCommand(
          SystemCommand.sudo,
          [
            "-n",
            helperPath,
            TeaAwayPrivilegeConfiguration.internalCommand,
            "version",
          ]
        ),
        ExternalCommand(
          SystemCommand.sudo,
          [
            "-n",
            helperPath,
            TeaAwayPrivilegeConfiguration.internalCommand,
            "schedule-shutdown",
            "11/14/23 22:23:20",
            "teaway:action-1",
          ]
        ),
      ]
    )
  }

  func testStaleRegisteredHelperFallsBackToOrdinarySudo() throws {
    let executor = FakeExecutor()
    let helperPath = TeaAwayPrivilegeConfiguration.helperPath(userID: userID)
    let sudoersPath = TeaAwayPrivilegeConfiguration.sudoersPath(userID: userID)
    executor.runHandler = { command in
      if command.arguments.last == "version" {
        return CommandResult(
          exitCode: 0,
          standardOutput: "teaway-privileged-helper 0.2.3\n"
        )
      }
      return CommandResult(exitCode: 0)
    }
    let runner = SystemPrivilegedCommandExecutor(
      executor: executor,
      userID: userID,
      fileExists: { $0 == helperPath || $0 == sudoersPath }
    )

    try runner.run(.setDisableSleep(0))

    XCTAssertEqual(
      executor.interactiveRunCommands,
      [
        ExternalCommand(SystemCommand.sudo, ["-v"]),
        ExternalCommand(
          SystemCommand.sudo,
          [SystemCommand.pmset, "-a", "disablesleep", "0"]
        ),
      ]
    )
    XCTAssertFalse(
      executor.runCommands.contains { $0.arguments.contains("set-disablesleep") }
    )
  }

  func testHelperRequestValidationIsFailClosed() {
    XCTAssertEqual(
      PrivilegedHelperRequest.parse(arguments: ["set-disablesleep", "0"]),
      .operation(.setDisableSleep(0))
    )
    XCTAssertEqual(
      PrivilegedHelperRequest.parse(arguments: ["set-disablesleep", "1"]),
      .operation(.setDisableSleep(1))
    )
    XCTAssertNil(
      PrivilegedHelperRequest.parse(arguments: ["set-disablesleep", "2"])
    )
    XCTAssertNil(
      PrivilegedHelperRequest.parse(arguments: ["set-disablesleep", "1", "extra"])
    )

    XCTAssertEqual(
      PrivilegedHelperRequest.parse(
        arguments: [
          "schedule-shutdown",
          "11/14/23 22:23:20",
          "teaway:action-1",
        ]
      ),
      .operation(
        .scheduleShutdown(
          date: "11/14/23 22:23:20",
          owner: "teaway:action-1"
        )
      )
    )
    XCTAssertNil(
      PrivilegedHelperRequest.parse(
        arguments: [
          "schedule-shutdown",
          "not-a-date",
          "teaway:action-1",
        ]
      )
    )
    XCTAssertNil(
      PrivilegedHelperRequest.parse(
        arguments: [
          "schedule-shutdown",
          "11/14/23 22:23:20",
          "tea-away:legacy",
        ]
      )
    )
    XCTAssertNil(
      PrivilegedHelperRequest.parse(
        arguments: [
          "schedule-shutdown",
          "11/14/23 22:23:20",
          "teaway:action with spaces",
        ]
      )
    )

    XCTAssertEqual(
      PrivilegedHelperRequest.parse(
        arguments: [
          "cancel-shutdown",
          "11/14/23 22:23:20",
          "tea-away:legacy-action",
        ]
      ),
      .operation(
        .cancelShutdown(
          date: "11/14/23 22:23:20",
          owner: "tea-away:legacy-action"
        )
      )
    )
    XCTAssertNil(PrivilegedHelperRequest.parse(arguments: ["shell", "-c", "id"]))
  }

  func testRegistrationStatusReportsUnregisteredWithoutCommands() throws {
    let executor = FakeExecutor()
    let service = SystemPrivilegeRegistrationService(
      executor: executor,
      executablePath: "/bin/echo",
      userName: "adam",
      userID: userID,
      fileExists: { _ in false }
    )

    XCTAssertEqual(try service.status(), .unregistered)
    XCTAssertTrue(executor.runCommands.isEmpty)
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
  }

  func testRegistrationStatusValidatesHelperVersionNoninteractively() throws {
    let executor = FakeExecutor()
    let helperPath = TeaAwayPrivilegeConfiguration.helperPath(userID: userID)
    let sudoersPath = TeaAwayPrivilegeConfiguration.sudoersPath(userID: userID)
    executor.runHandler = { command in
      XCTAssertEqual(
        command,
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
      return CommandResult(
        exitCode: 0,
        standardOutput: "teaway-privileged-helper \(TeaAwayVersion.current)\n"
      )
    }
    let service = SystemPrivilegeRegistrationService(
      executor: executor,
      executablePath: "/bin/echo",
      userName: "adam",
      userID: userID,
      fileExists: { $0 == helperPath || $0 == sudoersPath }
    )

    XCTAssertEqual(
      try service.status(),
      .registered(helperVersion: TeaAwayVersion.current)
    )
    XCTAssertTrue(executor.interactiveRunCommands.isEmpty)
  }

  func testRegistrationStatusRequiresRepairForStaleHelper() throws {
    let executor = FakeExecutor()
    let helperPath = TeaAwayPrivilegeConfiguration.helperPath(userID: userID)
    let sudoersPath = TeaAwayPrivilegeConfiguration.sudoersPath(userID: userID)
    executor.runHandler = { _ in
      CommandResult(
        exitCode: 0,
        standardOutput: "teaway-privileged-helper 0.2.3\n"
      )
    }
    let service = SystemPrivilegeRegistrationService(
      executor: executor,
      executablePath: "/bin/echo",
      userName: "adam",
      userID: userID,
      fileExists: { $0 == helperPath || $0 == sudoersPath }
    )

    guard case .needsRepair(let detail) = try service.status() else {
      return XCTFail("expected needs-repair status")
    }
    XCTAssertTrue(detail.contains("0.2.3"))
    XCTAssertTrue(detail.contains(TeaAwayVersion.current))
  }

  func testTouchIDStatusDetectsActivePAMRuleAndIgnoresComments() {
    let enabled = SystemPrivilegeRegistrationService(
      executor: FakeExecutor(),
      executablePath: "/bin/echo",
      userName: "adam",
      userID: userID,
      fileExists: { $0 == "/etc/pam.d/sudo_local" },
      readTextFile: { _ in
        """
        #auth       sufficient     pam_tid.so
        auth sufficient pam_tid.so
        """
      }
    )
    XCTAssertEqual(enabled.sudoTouchIDStatus(), .enabled)

    let disabled = SystemPrivilegeRegistrationService(
      executor: FakeExecutor(),
      executablePath: "/bin/echo",
      userName: "adam",
      userID: userID,
      fileExists: { $0 == "/etc/pam.d/sudo_local" },
      readTextFile: { _ in "#auth sufficient pam_tid.so\n" }
    )
    XCTAssertEqual(disabled.sudoTouchIDStatus(), .disabled)
  }

  func testTouchIDStatusReportsUnreadablePAMConfiguration() {
    struct TestReadError: LocalizedError {
      var errorDescription: String? { "permission denied" }
    }
    let service = SystemPrivilegeRegistrationService(
      executor: FakeExecutor(),
      executablePath: "/bin/echo",
      userName: "adam",
      userID: userID,
      fileExists: { $0 == "/etc/pam.d/sudo_local" },
      readTextFile: { _ in throw TestReadError() }
    )

    XCTAssertEqual(service.sudoTouchIDStatus(), .unknown("permission denied"))
  }

  func testRegistrationPrevalidatesNarrowSudoersAndUsesFixedInstallCommands() throws {
    let executor = FakeExecutor()
    let helperPath = TeaAwayPrivilegeConfiguration.helperPath(userID: userID)
    let sudoersPath = TeaAwayPrivilegeConfiguration.sudoersPath(userID: userID)
    var renderedSudoers = ""
    executor.runHandler = { command in
      if command.executable == SystemCommand.visudo {
        guard let path = command.arguments.last else {
          return CommandResult(exitCode: 64, standardError: "missing sudoers path")
        }
        renderedSudoers = try String(contentsOfFile: path, encoding: .utf8)
        return try SystemProcessExecutor().run(command)
      }
      if command.executable == SystemCommand.cmp {
        return CommandResult(exitCode: 0)
      }
      if command.executable == SystemCommand.sudo, command.arguments.last == "version" {
        return CommandResult(
          exitCode: 0,
          standardOutput: "teaway-privileged-helper \(TeaAwayVersion.current)\n"
        )
      }
      return CommandResult(
        exitCode: 64,
        standardError: "unexpected noninteractive command: \(command.executable)"
      )
    }
    let service = SystemPrivilegeRegistrationService(
      executor: executor,
      executablePath: "/bin/echo",
      userName: "adam",
      userID: userID,
      fileExists: { _ in false }
    )

    let result = try service.register()

    XCTAssertEqual(result.helperPath, helperPath)
    XCTAssertEqual(result.sudoersPath, sudoersPath)
    XCTAssertEqual(result.helperVersion, TeaAwayVersion.current)
    XCTAssertTrue(renderedSudoers.contains("adam ALL=(root) NOPASSWD:"))
    XCTAssertTrue(renderedSudoers.contains("\(helperPath) __teaway_privileged version"))
    XCTAssertTrue(renderedSudoers.contains("__teaway_privileged set-disablesleep 0"))
    XCTAssertTrue(renderedSudoers.contains("__teaway_privileged set-disablesleep 1"))
    XCTAssertTrue(renderedSudoers.contains("__teaway_privileged schedule-shutdown *"))
    XCTAssertTrue(renderedSudoers.contains("__teaway_privileged cancel-shutdown *"))
    XCTAssertFalse(renderedSudoers.contains(SystemCommand.pmset))
    XCTAssertFalse(renderedSudoers.contains("__teaway_privileged probe"))
    XCTAssertEqual(executor.interactiveRunCommands.first, ExternalCommand(SystemCommand.sudo, ["-v"]))
    XCTAssertTrue(
      executor.interactiveRunCommands.contains(
        ExternalCommand(
          SystemCommand.sudo,
          [
            SystemCommand.install,
            "-o", "root",
            "-g", "wheel",
            "-m", "0755",
            "/bin/echo",
            helperPath,
          ]
        )
      )
    )
    XCTAssertTrue(
      executor.interactiveRunCommands.contains(
        ExternalCommand(
          SystemCommand.sudo,
          [SystemCommand.visudo, "-c", "-f", sudoersPath]
        )
      )
    )
  }
}
