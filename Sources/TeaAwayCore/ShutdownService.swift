import Foundation

public enum ShutdownObservation: Equatable, Sendable {
  case none
  case planned
  case scheduled
  case missingFromSystem
  case needsRecovery
  case conflict
}

public struct ShutdownStatus: Equatable, Sendable {
  public let observation: ShutdownObservation
  public let record: ShutdownRecord?

  public init(observation: ShutdownObservation, record: ShutdownRecord?) {
    self.observation = observation
    self.record = record
  }
}

struct SystemScheduledPowerEvent: Equatable, Sendable {
  let type: String
  let date: String
  let owner: String

  var summary: String {
    "\(type) at \(date) by '\(owner)'"
  }
}

public final class ShutdownService: @unchecked Sendable {
  public static let planLifetime: TimeInterval = 5 * 60

  private let store: StateStore
  private let executor: any ProcessExecuting
  private let clock: any TeaAwayClock
  private let identifiers: any IdentifierGenerating
  private let dateFormatter: DateFormatter
  private let scheduleTimeZoneIdentifier: String
  private let saveState: @Sendable (TeaAwayState) throws -> Void

  public init(
    store: StateStore,
    executor: any ProcessExecuting,
    clock: any TeaAwayClock = SystemClock(),
    identifiers: any IdentifierGenerating = UUIDIdentifierGenerator(),
    timeZone: TimeZone = .current,
    stateSaver: (@Sendable (TeaAwayState) throws -> Void)? = nil
  ) {
    self.store = store
    self.executor = executor
    self.clock = clock
    self.identifiers = identifiers
    self.dateFormatter = DateFormatter()
    self.dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    self.dateFormatter.calendar = Calendar(identifier: .gregorian)
    self.dateFormatter.timeZone = timeZone
    self.dateFormatter.dateFormat = "MM/dd/yy HH:mm:ss"
    self.scheduleTimeZoneIdentifier = timeZone.identifier
    self.saveState =
      stateSaver ?? { state in
        try store.save(state)
      }
  }

  public func plan(afterSeconds: Int) throws -> ShutdownRecord {
    try store.withExclusiveLock {
      var state = try store.load()
      if let existing = state.shutdown {
        throw TeaAwayError.shutdownAlreadyExists(existing.id)
      }

      let id = identifiers.makeIdentifier()
      let now = clock.now
      let record = ShutdownRecord(
        id: id,
        owner: "teaway:\(id)",
        createdAt: now,
        scheduledAt: now.addingTimeInterval(TimeInterval(afterSeconds)),
        phase: .planned
      )
      state.shutdown = record
      try saveState(state)
      return record
    }
  }

  public func pendingPlan(actionID: String) throws -> ShutdownRecord {
    let state = try store.load()
    guard let record = state.shutdown else {
      throw TeaAwayError.noShutdown
    }
    guard record.id == actionID else {
      throw TeaAwayError.actionIDMismatch
    }
    guard record.phase == .planned else {
      throw TeaAwayError.shutdownAlreadyExists(record.id)
    }
    try validatePlan(record)
    return record
  }

  public func commit(actionID: String) throws -> ShutdownRecord {
    try store.withExclusiveLock {
      var state = try store.load()
      guard var record = state.shutdown else {
        throw TeaAwayError.noShutdown
      }
      guard record.id == actionID else {
        throw TeaAwayError.actionIDMismatch
      }
      guard record.phase == .planned else {
        throw TeaAwayError.shutdownAlreadyExists(record.id)
      }
      try validatePlan(record)

      let existingEvents = try inspectSystemSchedule()
      if let conflict = firstConflict(in: existingEvents) {
        throw TeaAwayError.shutdownScheduleConflict(conflict.summary)
      }

      record.phase = .committing
      record.systemScheduleDate = dateFormatter.string(from: record.scheduledAt)
      record.systemScheduleTimeZone = scheduleTimeZoneIdentifier
      state.shutdown = record
      try saveState(state)

      let target = try targetEvent(for: record)
      do {
        _ = try executor.checkedInteractiveRun(ExternalCommand(SystemCommand.sudo, ["-k"]))
        _ = try executor.checkedInteractiveRun(ExternalCommand(SystemCommand.sudo, ["-v"]))
        _ = try executor.checkedInteractiveRun(
          ExternalCommand(
            SystemCommand.sudo,
            [SystemCommand.pmset] + scheduleArguments(for: target, cancel: false)
          )
        )
      } catch {
        try recoverAfterScheduleFailure(record: record, state: &state, cause: error)
      }

      let scheduledEvents: [SystemScheduledPowerEvent]
      do {
        scheduledEvents = try inspectSystemSchedule()
      } catch {
        try compensateScheduledEvent(record: record, event: target, state: &state, cause: error)
      }

      let ownerEvents = scheduledEvents.filter { $0.owner == record.owner }
      guard ownerEvents.contains(target) else {
        if let observed = ownerEvents.first {
          try compensateScheduledEvent(
            record: record,
            event: observed,
            state: &state,
            cause: TeaAwayError.shutdownScheduleVerificationFailed(record.id)
          )
        }
        try resetPlanAfterVerifiedAbsence(
          record: record,
          state: &state,
          cause: TeaAwayError.shutdownScheduleVerificationFailed(record.id)
        )
      }

      if let conflict = firstConflict(in: scheduledEvents, allowing: target) {
        try compensateScheduledEvent(
          record: record,
          event: target,
          state: &state,
          cause: TeaAwayError.shutdownScheduleConflict(conflict.summary)
        )
      }

      record.phase = .committed
      record.committedAt = clock.now
      state.shutdown = record
      do {
        try saveState(state)
      } catch {
        try compensateScheduledEvent(record: record, event: target, state: &state, cause: error)
      }
      return record
    }
  }

  public func status() throws -> ShutdownStatus {
    let state = try store.load()
    guard let record = state.shutdown else {
      return ShutdownStatus(observation: .none, record: nil)
    }

    let events = try inspectSystemSchedule()
    let ownerEvents = events.filter { $0.owner == record.owner }
    if ownerEvents.contains(where: { $0.type != "shutdown" }) || ownerEvents.count > 1 {
      return ShutdownStatus(observation: .conflict, record: record)
    }

    let exactTarget = try? targetEvent(for: record)
    let exactExists = exactTarget.map(ownerEvents.contains) ?? false
    let ownerShutdownExists = ownerEvents.contains(where: { $0.type == "shutdown" })
    let unrelatedConflict = events.contains { event in
      guard event.owner != record.owner else { return false }
      return event.type == "shutdown" || Self.isRecognizedOwner(event.owner)
    }

    if unrelatedConflict || (ownerShutdownExists && !exactExists && exactTarget != nil) {
      return ShutdownStatus(observation: .conflict, record: record)
    }

    switch record.phase {
    case .planned:
      return ShutdownStatus(
        observation: ownerShutdownExists ? .needsRecovery : .planned,
        record: record
      )
    case .committing:
      return ShutdownStatus(observation: .needsRecovery, record: record)
    case .committed:
      return ShutdownStatus(
        observation: exactExists ? .scheduled : .missingFromSystem,
        record: record
      )
    }
  }

  public func cancel(actionID: String) throws -> ShutdownRecord {
    try store.withExclusiveLock {
      var state = try store.load()
      guard let record = state.shutdown else {
        throw TeaAwayError.noShutdown
      }
      guard record.id == actionID else {
        throw TeaAwayError.actionIDMismatch
      }

      let events = try inspectSystemSchedule()
      let ownerEvents = events.filter { $0.owner == record.owner }
      guard ownerEvents.allSatisfy({ $0.type == "shutdown" }), ownerEvents.count <= 1 else {
        throw TeaAwayError.shutdownScheduleConflict(
          ownerEvents.map(\.summary).joined(separator: "; ")
        )
      }

      if let event = ownerEvents.first {
        do {
          _ = try executor.checkedInteractiveRun(ExternalCommand(SystemCommand.sudo, ["-k"]))
          _ = try executor.checkedInteractiveRun(ExternalCommand(SystemCommand.sudo, ["-v"]))
          _ = try executor.checkedInteractiveRun(
            ExternalCommand(
              SystemCommand.sudo,
              [SystemCommand.pmset] + scheduleArguments(for: event, cancel: true)
            )
          )
        } catch {
          throw TeaAwayError.shutdownRecoveryRequired(
            record.id,
            "The exact teaway event could not be cancelled: \(error.localizedDescription)"
          )
        }

        let remainingEvents: [SystemScheduledPowerEvent]
        do {
          remainingEvents = try inspectSystemSchedule()
        } catch {
          throw TeaAwayError.shutdownRecoveryRequired(
            record.id,
            "Cancellation returned success, but its result could not be verified: \(error.localizedDescription)"
          )
        }
        guard !remainingEvents.contains(where: { $0.owner == record.owner }) else {
          throw TeaAwayError.shutdownRecoveryRequired(
            record.id,
            "macOS still reports an event with this teaway owner after cancellation."
          )
        }
      }

      state.shutdown = nil
      try saveState(state)
      return record
    }
  }

  public func formattedScheduleDate(for record: ShutdownRecord) -> String {
    record.systemScheduleDate ?? dateFormatter.string(from: record.scheduledAt)
  }

  static func parseScheduleOutput(_ output: String) throws -> [SystemScheduledPowerEvent] {
    let expression = try NSRegularExpression(
      pattern:
        #"^\s*\[[0-9]+\]\s+(sleep|wake|poweron|shutdown|wakeorpoweron)\s+at\s+([0-9]{2}/[0-9]{2}/[0-9]{2}\s+[0-9]{2}:[0-9]{2}:[0-9]{2})\s+by\s+'([^']+)'(?:\s+leeway secs:\s+[0-9]+)?(?:\s+User visible:\s+true)?\s*$"#,
      options: [.caseInsensitive]
    )
    let eventPrefix = try NSRegularExpression(pattern: #"^\s*\[[0-9]+\]"#)
    var events: [SystemScheduledPowerEvent] = []

    for (lineNumber, line) in output.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
    {
      let text = String(line)
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      guard let match = expression.firstMatch(in: text, range: range) else {
        if eventPrefix.firstMatch(in: text, range: range) != nil {
          throw TeaAwayError.shutdownScheduleUnreadable(
            "unrecognized event line \(lineNumber + 1): \(text.trimmingCharacters(in: .whitespaces))"
          )
        }
        let normalized = text.lowercased()
        if normalized.contains("teaway:") || normalized.contains("tea-away:") {
          throw TeaAwayError.shutdownScheduleConflict(
            text.trimmingCharacters(in: .whitespaces)
          )
        }
        if normalized.range(of: #"\bshutdown\b"#, options: .regularExpression) != nil {
          events.append(
            SystemScheduledPowerEvent(
              type: "shutdown",
              date: text.trimmingCharacters(in: .whitespaces),
              owner: "<unindexed-system-event>"
            )
          )
        }
        continue
      }

      guard
        let typeRange = Range(match.range(at: 1), in: text),
        let dateRange = Range(match.range(at: 2), in: text),
        let ownerRange = Range(match.range(at: 3), in: text)
      else {
        throw TeaAwayError.shutdownScheduleUnreadable(
          "could not extract event line \(lineNumber + 1)"
        )
      }
      events.append(
        SystemScheduledPowerEvent(
          type: text[typeRange].lowercased(),
          date: String(text[dateRange]),
          owner: String(text[ownerRange])
        )
      )
    }
    return events
  }

  private func validatePlan(_ record: ShutdownRecord) throws {
    let age = clock.now.timeIntervalSince(record.createdAt)
    guard age >= 0, age <= Self.planLifetime, record.scheduledAt > clock.now else {
      throw TeaAwayError.planExpired
    }
  }

  private func inspectSystemSchedule() throws -> [SystemScheduledPowerEvent] {
    let result = try executor.checkedRun(
      ExternalCommand(SystemCommand.pmset, ["-g", "sched"])
    )
    return try Self.parseScheduleOutput(result.standardOutput)
  }

  private func firstConflict(
    in events: [SystemScheduledPowerEvent],
    allowing allowed: SystemScheduledPowerEvent? = nil
  ) -> SystemScheduledPowerEvent? {
    events.first { event in
      if let allowed, event == allowed {
        return false
      }
      return event.type == "shutdown" || Self.isRecognizedOwner(event.owner)
    }
  }

  private func targetEvent(for record: ShutdownRecord) throws -> SystemScheduledPowerEvent {
    guard let date = record.systemScheduleDate else {
      throw TeaAwayError.shutdownScheduleVerificationFailed(record.id)
    }
    return SystemScheduledPowerEvent(type: "shutdown", date: date, owner: record.owner)
  }

  private func scheduleArguments(for event: SystemScheduledPowerEvent, cancel: Bool) -> [String] {
    var arguments = ["schedule"]
    if cancel {
      arguments.append("cancel")
    }
    arguments += [event.type, event.date, event.owner]
    return arguments
  }

  private func recoverAfterScheduleFailure(
    record: ShutdownRecord,
    state: inout TeaAwayState,
    cause: Error
  ) throws -> Never {
    let events: [SystemScheduledPowerEvent]
    do {
      events = try inspectSystemSchedule()
    } catch {
      throw TeaAwayError.shutdownRecoveryRequired(
        record.id,
        "Scheduling returned an error and macOS state could not be inspected: \(error.localizedDescription)"
      )
    }

    let ownerEvents = events.filter { $0.owner == record.owner && $0.type == "shutdown" }
    guard ownerEvents.count <= 1 else {
      throw TeaAwayError.shutdownRecoveryRequired(
        record.id,
        "Scheduling returned an error and macOS reports multiple matching owner events."
      )
    }
    if let event = ownerEvents.first {
      try compensateScheduledEvent(record: record, event: event, state: &state, cause: cause)
    }
    try resetPlanAfterVerifiedAbsence(record: record, state: &state, cause: cause)
  }

  private func compensateScheduledEvent(
    record: ShutdownRecord,
    event: SystemScheduledPowerEvent,
    state: inout TeaAwayState,
    cause: Error
  ) throws -> Never {
    let cancellation: CommandResult
    do {
      cancellation = try executor.runInteractive(
        ExternalCommand(
          SystemCommand.sudo,
          [SystemCommand.pmset] + scheduleArguments(for: event, cancel: true)
        )
      )
    } catch {
      throw TeaAwayError.shutdownRecoveryRequired(
        record.id,
        "Automatic compensation could not start: \(error.localizedDescription)"
      )
    }
    guard cancellation.exitCode == 0 else {
      throw TeaAwayError.shutdownRecoveryRequired(
        record.id,
        "Automatic compensation failed with exit code \(cancellation.exitCode)."
      )
    }

    let remainingEvents: [SystemScheduledPowerEvent]
    do {
      remainingEvents = try inspectSystemSchedule()
    } catch {
      throw TeaAwayError.shutdownRecoveryRequired(
        record.id,
        "Automatic compensation returned success, but verification failed: \(error.localizedDescription)"
      )
    }
    guard !remainingEvents.contains(where: { $0.owner == record.owner }) else {
      throw TeaAwayError.shutdownRecoveryRequired(
        record.id,
        "macOS still reports this teaway owner after automatic compensation."
      )
    }
    try resetPlanAfterVerifiedAbsence(record: record, state: &state, cause: cause)
  }

  private func resetPlanAfterVerifiedAbsence(
    record: ShutdownRecord,
    state: inout TeaAwayState,
    cause: Error
  ) throws -> Never {
    var plannedRecord = record
    plannedRecord.phase = .planned
    plannedRecord.committedAt = nil
    plannedRecord.systemScheduleDate = nil
    plannedRecord.systemScheduleTimeZone = nil
    state.shutdown = plannedRecord
    do {
      try saveState(state)
    } catch {
      throw TeaAwayError.shutdownRecoveryRequired(
        record.id,
        "No matching macOS event was found, but the committing record could not be reset: \(error.localizedDescription)"
      )
    }
    throw cause
  }

  private static func isRecognizedOwner(_ owner: String) -> Bool {
    owner.hasPrefix("teaway:") || owner.hasPrefix("tea-away:")
  }
}
