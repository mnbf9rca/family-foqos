import XCTest

@testable import FamilyFoqos

final class AppBuildInfoTests: XCTestCase {
  func testGivenGitShaAndCleanBuild_WhenDisplayCommit_ThenShowsShaOnly() {
    let info = AppBuildInfo(
      infoDictionary: [
        "GitCommitSHA": "f4fca03",
        "GitHasUncommittedChanges": "NO",
      ])

    XCTAssertEqual(info.commitDisplay, "f4fca03")
  }

  func testGivenGitShaAndDirtyBuild_WhenDisplayCommit_ThenShowsWipSuffix() {
    let info = AppBuildInfo(
      infoDictionary: [
        "GitCommitSHA": "f4fca03",
        "GitHasUncommittedChanges": "YES",
      ])

    XCTAssertEqual(info.commitDisplay, "f4fca03+wip")
  }

  func testGivenMissingGitSha_WhenDisplayCommit_ThenShowsUnknown() {
    let info = AppBuildInfo(infoDictionary: [:])

    XCTAssertEqual(info.commitDisplay, "unknown")
  }
}
