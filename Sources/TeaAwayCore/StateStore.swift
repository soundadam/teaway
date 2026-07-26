import Darwin
import Foundation

public struct TeaAwayPaths: Equatable, Sendable {
  public let stateDirectory: URL
  public let legacyStateDirectory: URL?

  public init(stateDirectory: URL, legacyStateDirectory: URL? = nil) {
    self.stateDirectory = stateDirectory
    self.legacyStateDirectory = legacyStateDirectory
  }

  public var stateFile: URL { stateDirectory.appendingPathComponent("state.json") }
  public var lockFile: URL { stateDirectory.appendingPathComponent("state.lock") }

  public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> TeaAwayPaths
  {
    if let override = environment["TEAWAY_STATE_DIR"], !override.isEmpty {
      return TeaAwayPaths(stateDirectory: URL(fileURLWithPath: override, isDirectory: true))
    }

    if let override = environment["TEA_STATE_DIR"], !override.isEmpty {
      let legacyOverride = environment["TEA_AWAY_STATE_DIR"].flatMap { value in
        value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
      }
      return TeaAwayPaths(
        stateDirectory: URL(fileURLWithPath: override, isDirectory: true),
        legacyStateDirectory: legacyOverride
      )
    }

    if let override = environment["TEA_AWAY_STATE_DIR"], !override.isEmpty {
      return TeaAwayPaths(stateDirectory: URL(fileURLWithPath: override, isDirectory: true))
    }

    let home = environment["HOME"] ?? NSHomeDirectory()
    if let xdgState = environment["XDG_STATE_HOME"], !xdgState.isEmpty {
      let base = URL(fileURLWithPath: xdgState, isDirectory: true)
      return TeaAwayPaths(
        stateDirectory: base.appendingPathComponent("teaway", isDirectory: true),
        legacyStateDirectory: base.appendingPathComponent("tea-away", isDirectory: true)
      )
    }

    let applicationSupport = URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return TeaAwayPaths(
      stateDirectory: applicationSupport.appendingPathComponent("teaway", isDirectory: true),
      legacyStateDirectory: applicationSupport.appendingPathComponent("tea-away", isDirectory: true)
    )
  }
}

public final class StateStore: @unchecked Sendable {
  public let paths: TeaAwayPaths
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(paths: TeaAwayPaths, fileManager: FileManager = .default) {
    self.paths = paths
    self.fileManager = fileManager
    self.encoder = JSONEncoder()
    self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    self.encoder.dateEncodingStrategy = .iso8601
    self.decoder = JSONDecoder()
    self.decoder.dateDecodingStrategy = .iso8601
  }

  public func prepare() throws {
    for directory in activeDirectories() {
      try prepare(directory: directory)
    }
  }

  public func load() throws -> TeaAwayState {
    let candidates = existingStateFiles()
    guard !candidates.isEmpty else {
      return .empty
    }

    let states = try candidates.map(decodeState)
    guard let first = states.first else {
      return .empty
    }
    guard states.dropFirst().allSatisfy({ $0 == first }) else {
      throw TeaAwayError.stateCorrupt(
        "conflicting canonical and legacy state files; refusing to discard ownership"
      )
    }
    return first
  }

  public func save(_ state: TeaAwayState) throws {
    let destinations = activeStateFiles()
    let data = try encoder.encode(state)
    for destination in destinations {
      try prepare(directory: destination.deletingLastPathComponent())
      try data.write(to: destination, options: .atomic)
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: destination.path
      )
    }
  }

  public func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
    let lockFiles = candidateStateFiles()
      .map { $0.deletingLastPathComponent() }
      .map { $0.appendingPathComponent("state.lock") }
      .sorted { $0.path < $1.path }
    var descriptors: [Int32] = []
    defer {
      for descriptor in descriptors.reversed() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
      }
    }

    for lockFile in lockFiles {
      try prepare(directory: lockFile.deletingLastPathComponent())
      let descriptor = open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
      guard descriptor >= 0 else {
        throw TeaAwayError.stateLocked
      }
      descriptors.append(descriptor)
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw TeaAwayError.stateLocked
      }
    }
    return try body()
  }

  private func existingStateFiles() -> [URL] {
    candidateStateFiles().filter { fileManager.fileExists(atPath: $0.path) }
  }

  private func activeStateFiles() -> [URL] {
    let existing = existingStateFiles()
    if !existing.isEmpty {
      return existing
    }
    return [paths.stateFile]
  }

  private func activeDirectories() -> [URL] {
    let existing = existingStateFiles().map { $0.deletingLastPathComponent() }
    if !existing.isEmpty {
      return existing
    }
    return [paths.stateDirectory]
  }

  private func candidateStateFiles() -> [URL] {
    var candidates = [paths.stateFile]
    if let legacyDirectory = paths.legacyStateDirectory,
      legacyDirectory.standardizedFileURL != paths.stateDirectory.standardizedFileURL
    {
      let legacyStateFile = legacyDirectory.appendingPathComponent("state.json")
      if fileManager.fileExists(atPath: legacyStateFile.path) {
        candidates.append(legacyStateFile)
      }
    }
    return candidates
  }

  private func decodeState(at file: URL) throws -> TeaAwayState {
    do {
      let data = try Data(contentsOf: file)
      let state = try decoder.decode(TeaAwayState.self, from: data)
      guard state.schemaVersion == 1 else {
        throw TeaAwayError.stateCorrupt("unsupported schema version \(state.schemaVersion)")
      }
      return state
    } catch let error as TeaAwayError {
      throw error
    } catch {
      throw TeaAwayError.stateCorrupt("\(file.path): \(error.localizedDescription)")
    }
  }

  private func prepare(directory: URL) throws {
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )
  }
}
