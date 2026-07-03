import Foundation

/// I6: on a zone-deletion/recreation event the controller flushes SessionSyncService's
/// CAS cache so the first post-recreation write is create-if-absent (§6/S-20/S-21). The
/// SessionSyncFlushing seam lets the controller flush without a hard singleton dependency.
///
/// `SessionSyncService` is its own `actor` (not `@MainActor`), and Swift 6 does not permit an
/// actor to conform directly to a `@MainActor`-isolated protocol — the two isolation domains
/// conflict at the type level, which is a hard compiler error, not just a warning. This thin
/// `@MainActor` adapter satisfies the seam instead, forwarding the flush to the actor's
/// existing (previously uncalled) `clearCache()`.
@MainActor
final class SessionSyncCacheFlusher: SessionSyncFlushing {
  private let service: SessionSyncService

  init(service: SessionSyncService = .shared) {
    self.service = service
  }

  func flushSessionCache() async {
    await service.clearCache()
  }
}
