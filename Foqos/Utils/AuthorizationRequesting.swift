import Combine
@preconcurrency import FamilyControls

/// Seam over AuthorizationCenter's async request so RequestAuthorizer can await the real outcome.
@MainActor
protocol AuthorizationRequesting {
  var authorizationStatus: AuthorizationStatus { get }
  var authorizationStatusPublisher: AnyPublisher<AuthorizationStatus, Never> { get }

  func requestAuthorization(for member: FamilyControlsMember) async throws
}

@MainActor
final class AuthorizationCenterRequester: AuthorizationRequesting {
  static let shared = AuthorizationCenterRequester()

  private let authorizationCenter: AuthorizationCenter

  init(authorizationCenter: AuthorizationCenter = .shared) {
    self.authorizationCenter = authorizationCenter
  }

  var authorizationStatus: AuthorizationStatus {
    authorizationCenter.authorizationStatus
  }

  var authorizationStatusPublisher: AnyPublisher<AuthorizationStatus, Never> {
    authorizationCenter.$authorizationStatus.eraseToAnyPublisher()
  }

  func requestAuthorization(for member: FamilyControlsMember) async throws {
    try await authorizationCenter.requestAuthorization(for: member)
  }
}
