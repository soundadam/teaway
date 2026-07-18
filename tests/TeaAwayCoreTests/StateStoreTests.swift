import Foundation
import XCTest

@testable import TeaAwayCore

final class StateStoreTests: XCTestCase {
  func testPathResolutionPrefersCanonicalTeawayStateDirectory() {
    let paths = TeaAwayPaths.resolve(
      environment: [
        "TEAWAY_STATE_DIR": "/tmp/teaway-canonical",
        "TEA_STATE_DIR": "/tmp/teaway-new",
        "TEA_AWAY_STATE_DIR": "/tmp/teaway-old",
        "HOME": "/tmp/home",
      ]
    )

    XCTAssertEqual(paths.stateDirectory.path, "/tmp/teaway-canonical")
    XCTAssertNil(paths.legacyStateDirectory)
  }

  func testPathResolutionPrefersTeaStateDirectoryAndKeepsLegacyOverride() {
    let paths = TeaAwayPaths.resolve(
      environment: [
        "TEA_STATE_DIR": "/tmp/teaway-new",
        "TEA_AWAY_STATE_DIR": "/tmp/teaway-old",
        "HOME": "/tmp/home",
      ]
    )

    XCTAssertEqual(paths.stateDirectory.path, "/tmp/teaway-new")
    XCTAssertEqual(paths.legacyStateDirectory?.path, "/tmp/teaway-old")
  }

  func testPathResolutionStillHonorsLegacyOverride() {
    let paths = TeaAwayPaths.resolve(
      environment: [
        "TEA_AWAY_STATE_DIR": "/tmp/teaway-old",
        "HOME": "/tmp/home",
      ]
    )

    XCTAssertEqual(paths.stateDirectory.path, "/tmp/teaway-old")
    XCTAssertNil(paths.legacyStateDirectory)
  }

  func testDefaultPathsUseTeawayAndRetainLegacyFallback() {
    let paths = TeaAwayPaths.resolve(
      environment: [
        "XDG_STATE_HOME": "/tmp/xdg-state",
        "HOME": "/tmp/home",
      ]
    )

    XCTAssertEqual(paths.stateDirectory.path, "/tmp/xdg-state/teaway")
    XCTAssertEqual(paths.legacyStateDirectory?.path, "/tmp/xdg-state/tea-away")
  }

  func testRoundTripsStateAndUsesPrivatePermissions() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }

    let state = TeaAwayState(
      power: PowerRecord(
        originalDisableSleep: 0,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        phase: .enabled
      )
    )
    try store.save(state)

    XCTAssertEqual(try store.load(), state)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.paths.stateFile.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testRejectsCorruptState() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }
    try Data("not json".utf8).write(to: store.paths.stateFile)

    XCTAssertThrowsError(try store.load()) { error in
      guard case TeaAwayError.stateCorrupt = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testExclusiveLockRejectsNestedMutation() throws {
    let (store, directory) = try makeTemporaryStore()
    defer { removeTemporaryStore(directory) }

    try store.withExclusiveLock {
      XCTAssertThrowsError(try store.withExclusiveLock {}) { error in
        XCTAssertEqual(error as? TeaAwayError, .stateLocked)
      }
    }
  }

  func testLegacyStateFallbackPreservesOwnershipAndContinuesWritingLegacyFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("teaway-fallback-tests-\(UUID().uuidString)", isDirectory: true)
    defer { removeTemporaryStore(root) }
    let primary = root.appendingPathComponent("teaway", isDirectory: true)
    let legacy = root.appendingPathComponent("tea-away", isDirectory: true)
    let legacyStore = StateStore(paths: TeaAwayPaths(stateDirectory: legacy))
    let original = TeaAwayState(
      power: PowerRecord(
        originalDisableSleep: 0,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        phase: .enabled
      ),
      shutdown: ShutdownRecord(
        id: "legacy-action",
        owner: "tea-away:legacy-action",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        scheduledAt: Date(timeIntervalSince1970: 1_700_003_600),
        phase: .committed
      )
    )
    try legacyStore.save(original)
    let store = StateStore(
      paths: TeaAwayPaths(stateDirectory: primary, legacyStateDirectory: legacy)
    )

    XCTAssertEqual(try store.load(), original)
    var updated = original
    updated.shutdown = nil
    try store.withExclusiveLock {
      try store.save(updated)
    }

    XCTAssertEqual(try legacyStore.load(), updated)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.stateFile.path))
  }

  func testConflictingPrimaryAndLegacyOwnershipFailsClosed() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("teaway-conflict-tests-\(UUID().uuidString)", isDirectory: true)
    defer { removeTemporaryStore(root) }
    let primary = root.appendingPathComponent("teaway", isDirectory: true)
    let legacy = root.appendingPathComponent("tea-away", isDirectory: true)
    let primaryStore = StateStore(paths: TeaAwayPaths(stateDirectory: primary))
    let legacyStore = StateStore(paths: TeaAwayPaths(stateDirectory: legacy))
    try primaryStore.save(
      TeaAwayState(
        power: PowerRecord(
          originalDisableSleep: 0,
          createdAt: Date(timeIntervalSince1970: 1_700_000_000),
          phase: .enabled
        )
      )
    )
    try legacyStore.save(
      TeaAwayState(
        shutdown: ShutdownRecord(
          id: "legacy-action",
          owner: "tea-away:legacy-action",
          createdAt: Date(timeIntervalSince1970: 1_700_000_000),
          scheduledAt: Date(timeIntervalSince1970: 1_700_003_600),
          phase: .committed
        )
      )
    )
    let store = StateStore(
      paths: TeaAwayPaths(stateDirectory: primary, legacyStateDirectory: legacy)
    )

    XCTAssertThrowsError(try store.load()) { error in
      guard case TeaAwayError.stateCorrupt(let detail) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(detail.contains("refusing to discard ownership"))
    }
  }
}
