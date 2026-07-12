import Combine
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
  var authorizationStatus: AuthorizationStatus {
    statusSubject.value
  }
  var authorizationStatusPublisher: AnyPublisher<AuthorizationStatus, Never> {
    statusSubject.eraseToAnyPublisher()
  }
  private(set) var requestedMembers: [FamilyControlsMember] = []

  private let statusSubject: CurrentValueSubject<AuthorizationStatus, Never>

  init(initialStatus: AuthorizationStatus = .notDetermined) {
    self.statusSubject = CurrentValueSubject(initialStatus)
  }

  func requestAuthorization(for member: FamilyControlsMember) async throws {
    requestedMembers.append(member)
    if case .failure(let error) = outcome {
      throw error
    }
  }

  func sendStatus(_ status: AuthorizationStatus) {
    statusSubject.send(status)
  }
}
