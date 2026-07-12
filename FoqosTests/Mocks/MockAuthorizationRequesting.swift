import FamilyControls

@testable import FamilyFoqos

@MainActor
final class MockAuthorizationRequesting: AuthorizationRequesting {
  enum Outcome {
    case success
    case failure(Error)
  }

  struct StubError: Error {}

  var outcome: Outcome = .success
  private(set) var requestedMembers: [FamilyControlsMember] = []

  func requestAuthorization(for member: FamilyControlsMember) async throws {
    requestedMembers.append(member)
    if case .failure(let error) = outcome {
      throw error
    }
  }
}
