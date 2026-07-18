import Foundation

public enum PowerObservation: String, Equatable, Sendable {
  case off
  case on
  case external
  case borrowed
  case needsRecovery = "needs-recovery"
  case conflict
}

public struct PowerStatus: Equatable, Sendable {
  public let observation: PowerObservation
  public let liveDisableSleep: Int
  public let powerSource: String
  public let record: PowerRecord?

  public init(
    observation: PowerObservation,
    liveDisableSleep: Int,
    powerSource: String = "AC Power",
    record: PowerRecord?
  ) {
    self.observation = observation
    self.liveDisableSleep = liveDisableSleep
    self.powerSource = powerSource
    self.record = record
  }
}

public struct PowerOffResult: Equatable, Sendable {
  public let restoredDisableSleep: Int
  public let hadRecord: Bool

  public init(restoredDisableSleep: Int, hadRecord: Bool) {
    self.restoredDisableSleep = restoredDisableSleep
    self.hadRecord = hadRecord
  }
}

public final class PowerService: @unchecked Sendable {
  private let store: StateStore
  private let executor: any ProcessExecuting
  private let clock: any TeaAwayClock
  private let saveState: @Sendable (TeaAwayState) throws -> Void

  public init(
    store: StateStore,
    executor: any ProcessExecuting,
    clock: any TeaAwayClock = SystemClock(),
    stateSaver: (@Sendable (TeaAwayState) throws -> Void)? = nil
  ) {
    self.store = store
    self.executor = executor
    self.clock = clock
    self.saveState = stateSaver ?? { state in try store.save(state) }
  }

  public func turnOn() throws -> PowerRecord {
    try store.withExclusiveLock {
      var state = try store.load()
      guard try isOnACPower() else {
        throw TeaAwayError.requiresACPower
      }
      let liveValue = try inspectDisableSleep()

      if var record = state.power {
        try validate(record)
        switch record.phase {
        case .enabled:
          guard liveValue == record.expectedDisableSleep else {
            throw TeaAwayError.powerConflict(
              expected: record.expectedDisableSleep,
              actual: liveValue
            )
          }
          return record
        case .enabling:
          if liveValue == record.expectedDisableSleep {
            record.phase = .enabled
            state.power = record
            try saveRetainingRecovery(
              state,
              detail: "macOS is enabled, but the enabled phase could not be saved."
            )
            return record
          }
          guard liveValue == record.originalDisableSleep else {
            throw TeaAwayError.powerConflict(
              expected: record.expectedDisableSleep,
              actual: liveValue
            )
          }
          return try applyEnable(record: record, state: &state)
        case .restoring:
          throw TeaAwayError.powerRecoveryRequired(
            "Run 'teaway off' to finish the interrupted restore before enabling again."
          )
        }
      }

      let record = PowerRecord(
        originalDisableSleep: liveValue,
        createdAt: clock.now,
        phase: .enabling
      )
      state.power = record
      try saveState(state)
      return try applyEnable(record: record, state: &state)
    }
  }

  public func turnOff() throws -> PowerOffResult {
    try store.withExclusiveLock {
      var state = try store.load()
      let liveValue = try inspectDisableSleep()
      guard var record = state.power else {
        return PowerOffResult(restoredDisableSleep: liveValue, hadRecord: false)
      }
      try validate(record)

      if liveValue == record.originalDisableSleep
        || record.originalDisableSleep == record.expectedDisableSleep
      {
        return try finishRestoreWithoutMutation(
          record: record,
          liveValue: liveValue,
          state: &state
        )
      }

      switch record.phase {
      case .enabled:
        guard liveValue == record.expectedDisableSleep else {
          throw TeaAwayError.powerConflict(
            expected: record.expectedDisableSleep,
            actual: liveValue
          )
        }
      case .enabling:
        guard liveValue == record.expectedDisableSleep else {
          throw TeaAwayError.powerConflict(
            expected: record.expectedDisableSleep,
            actual: liveValue
          )
        }
      case .restoring:
        guard liveValue == record.expectedDisableSleep else {
          throw TeaAwayError.powerConflict(
            expected: record.expectedDisableSleep,
            actual: liveValue
          )
        }
      }

      record.phase = .restoring
      state.power = record
      try saveRetainingRecovery(
        state,
        detail: "the restore phase could not be saved, so no pmset change was attempted."
      )

      if record.originalDisableSleep != record.expectedDisableSleep {
        do {
          try setDisableSleep(
            record.originalDisableSleep,
            requireACPowerBeforeMutation: false
          )
        } catch {
          throw TeaAwayError.powerRecoveryRequired(
            "Restoring disablesleep failed: \(error.localizedDescription)"
          )
        }
      }

      let verifiedValue: Int
      do {
        verifiedValue = try inspectDisableSleep()
      } catch {
        throw TeaAwayError.powerRecoveryRequired(
          "The restore command ran, but verification failed: \(error.localizedDescription)"
        )
      }
      guard verifiedValue == record.originalDisableSleep else {
        throw TeaAwayError.powerRecoveryRequired(
          "The restore command ran, but macOS reports disablesleep=\(verifiedValue) instead of \(record.originalDisableSleep)."
        )
      }

      state.power = nil
      try saveRetainingRecovery(
        state,
        detail: "macOS was restored, but the recovery record could not be cleared."
      )
      return PowerOffResult(
        restoredDisableSleep: record.originalDisableSleep,
        hadRecord: true
      )
    }
  }

  public func status() throws -> PowerStatus {
    try store.withExclusiveLock {
      let state = try store.load()
      let liveValue = try inspectDisableSleep()
      let powerSource = try inspectPowerSource()
      guard let record = state.power else {
        return PowerStatus(
          observation: liveValue == 0 ? .off : .external,
          liveDisableSleep: liveValue,
          powerSource: powerSource,
          record: nil
        )
      }
      try validate(record)

      let observation: PowerObservation
      switch record.phase {
      case .enabled:
        if liveValue == record.expectedDisableSleep {
          observation =
            record.originalDisableSleep == record.expectedDisableSleep
            ? .borrowed : .on
        } else {
          observation = .conflict
        }
      case .enabling, .restoring:
        if liveValue == record.expectedDisableSleep
          || liveValue == record.originalDisableSleep
        {
          observation = .needsRecovery
        } else {
          observation = .conflict
        }
      }
      return PowerStatus(
        observation: observation,
        liveDisableSleep: liveValue,
        powerSource: powerSource,
        record: record
      )
    }
  }

  static func parseDisableSleep(from output: String) throws -> Int {
    var values: [Int] = []
    for line in output.split(whereSeparator: \Character.isNewline) {
      let fields = line.split(whereSeparator: \Character.isWhitespace)
      guard let key = fields.first?.lowercased(),
        key == "sleepdisabled" || key == "disablesleep"
      else {
        continue
      }
      guard fields.count == 2, let value = Int(fields[1]), value == 0 || value == 1 else {
        throw TeaAwayError.powerSettingUnreadable(
          "the disablesleep line is malformed"
        )
      }
      values.append(value)
    }
    guard values.count == 1, let value = values.first else {
      throw TeaAwayError.powerSettingUnreadable(
        values.isEmpty ? "pmset did not report disablesleep" : "pmset reported it more than once"
      )
    }
    return value
  }

  private func applyEnable(
    record: PowerRecord,
    state: inout TeaAwayState
  ) throws -> PowerRecord {
    if record.originalDisableSleep != record.expectedDisableSleep {
      do {
        try setDisableSleep(
          record.expectedDisableSleep,
          requireACPowerBeforeMutation: true
        )
      } catch {
        throw TeaAwayError.powerRecoveryRequired(
          "Enabling disablesleep failed: \(error.localizedDescription)"
        )
      }
    }

    let verifiedValue: Int
    do {
      verifiedValue = try inspectDisableSleep()
    } catch {
      throw TeaAwayError.powerRecoveryRequired(
        "The enable command ran, but verification failed: \(error.localizedDescription)"
      )
    }
    guard verifiedValue == record.expectedDisableSleep else {
      throw TeaAwayError.powerRecoveryRequired(
        "The enable command ran, but macOS reports disablesleep=\(verifiedValue) instead of \(record.expectedDisableSleep)."
      )
    }

    var enabledRecord = record
    enabledRecord.phase = .enabled
    state.power = enabledRecord
    try saveRetainingRecovery(
      state,
      detail: "macOS is enabled, but the enabled phase could not be saved."
    )
    return enabledRecord
  }

  private func finishRestoreWithoutMutation(
    record: PowerRecord,
    liveValue: Int,
    state: inout TeaAwayState
  ) throws -> PowerOffResult {
    state.power = nil
    try saveRetainingRecovery(
      state,
      detail: "macOS already has the original value, but the recovery record could not be cleared."
    )
    return PowerOffResult(
      restoredDisableSleep: liveValue,
      hadRecord: true
    )
  }

  private func inspectDisableSleep() throws -> Int {
    let result = try executor.checkedRun(
      ExternalCommand(SystemCommand.pmset, ["-g"])
    )
    return try Self.parseDisableSleep(from: result.standardOutput)
  }

  private func isOnACPower() throws -> Bool {
    try inspectPowerSource() == "AC Power"
  }

  private func inspectPowerSource() throws -> String {
    let result = try executor.checkedRun(
      ExternalCommand(SystemCommand.pmset, ["-g", "batt"])
    )
    let sourceLines = result.standardOutput
      .split(whereSeparator: \Character.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("Now drawing from ") }
    guard sourceLines.count == 1,
      let source = sourceLines.first,
      source.hasSuffix("'"),
      let openingQuote = source.firstIndex(of: "'")
    else {
      throw TeaAwayError.powerSettingUnreadable(
        "pmset did not report one unambiguous power source"
      )
    }
    return String(
      source[
        source.index(after: openingQuote)..<source.index(before: source.endIndex)
      ]
    )
  }

  private func setDisableSleep(
    _ value: Int,
    requireACPowerBeforeMutation: Bool
  ) throws {
    _ = try executor.checkedInteractiveRun(
      ExternalCommand(SystemCommand.sudo, ["-k"])
    )
    _ = try executor.checkedInteractiveRun(
      ExternalCommand(SystemCommand.sudo, ["-v"])
    )
    if requireACPowerBeforeMutation {
      guard try isOnACPower() else {
        throw TeaAwayError.requiresACPower
      }
    }
    _ = try executor.checkedInteractiveRun(
      ExternalCommand(
        SystemCommand.sudo,
        [SystemCommand.pmset, "-a", "disablesleep", String(value)]
      )
    )
  }

  private func validate(_ record: PowerRecord) throws {
    guard record.originalDisableSleep == 0 || record.originalDisableSleep == 1,
      record.expectedDisableSleep == 1
    else {
      throw TeaAwayError.powerSettingUnreadable(
        "the saved teaway power record contains unsupported values"
      )
    }
  }

  private func saveRetainingRecovery(
    _ state: TeaAwayState,
    detail: String
  ) throws {
    do {
      try saveState(state)
    } catch {
      throw TeaAwayError.powerRecoveryRequired(
        "\(detail) Save error: \(error.localizedDescription)"
      )
    }
  }
}
