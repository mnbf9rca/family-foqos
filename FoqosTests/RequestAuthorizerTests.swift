import FamilyControls
import XCTest

@testable import FamilyFoqos

@MainActor
final class RequestAuthorizerTests: XCTestCase {

  func testGivenAuthApproved_WhenRequestingChild_ThenReturnsTrueAndClearsError() async {
    let mock = MockAuthorizationRequesting()
    mock.outcome = .success
    let authorizer = RequestAuthorizer(authorizationCenter: mock)

    let result = await authorizer.requestAuthorization(for: .child)

    XCTAssertTrue(result)
    XCTAssertNil(authorizer.authorizationError)
    XCTAssertEqual(mock.requestedMembers, [.child])
  }

  func testGivenAuthFails_WhenRequestingChild_ThenReturnsFalseAndSetsError() async {
    let mock = MockAuthorizationRequesting()
    mock.outcome = .failure(MockAuthorizationRequesting.StubError())
    let authorizer = RequestAuthorizer(authorizationCenter: mock)

    let result = await authorizer.requestAuthorization(for: .child)

    XCTAssertFalse(result, "A failed request must not report success")
    XCTAssertNotNil(authorizer.authorizationError)
  }

  func testGivenParentMode_WhenRequesting_ThenUsesIndividualMember() async {
    let mock = MockAuthorizationRequesting()
    let authorizer = RequestAuthorizer(authorizationCenter: mock)

    _ = await authorizer.requestAuthorization(for: .parent)

    XCTAssertEqual(mock.requestedMembers, [.individual])
  }
}
