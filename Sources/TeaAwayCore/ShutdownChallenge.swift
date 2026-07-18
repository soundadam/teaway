import Darwin
import Foundation

public protocol ShutdownChallenging {
  func confirm(expectedPhrase: String) -> Bool
}

public struct SystemShutdownChallenger: ShutdownChallenging {
  public init() {}

  public func confirm(expectedPhrase: String) -> Bool {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
      return false
    }

    FileHandle.standardError.write(
      Data("Type exactly '\(expectedPhrase)' to commit this shutdown: ".utf8)
    )
    return readLine(strippingNewline: true) == expectedPhrase
  }
}
