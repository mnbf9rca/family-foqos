@preconcurrency import FamilyControls

/// Seam over AuthorizationCenter's async request so RequestAuthorizer can await the real outcome.
@MainActor
protocol AuthorizationRequesting {
  func requestAuthorization(for member: FamilyControlsMember) async throws
}

extension AuthorizationCenter: AuthorizationRequesting {}
