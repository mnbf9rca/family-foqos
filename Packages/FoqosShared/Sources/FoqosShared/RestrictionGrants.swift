import Foundation

extension SharedData {
  /// Thin applier for a derived decision.
  static func applyDecision(_ decision: RestrictionDecision, applier: RestrictionApplying) {
    switch decision {
    case .deactivate:
      applier.deactivateRestrictions()
    case .activate(let profile):
      applier.activateRestrictions(for: profile)
    case .bailPreserve:
      break
    }
  }

  @discardableResult
  public static func openBreakGrant(
    startDate: Date,
    deadline: Date,
    expectedSessionId: String,
    liveSnapshot: ProfileSnapshot?,
    applier: RestrictionApplying = AppBlockerUtil()
  ) -> Bool {
    openBreakGrant(
      startDate: startDate,
      deadline: deadline,
      expectedSessionId: expectedSessionId,
      liveSnapshot: liveSnapshot,
      applier: applier,
      commit: { rawCommitActiveSession($0) })
  }

  /// §6.2 — open a break grant in one main-app critical section.
  @discardableResult
  internal static func openBreakGrant(
    startDate: Date,
    deadline: Date,
    expectedSessionId: String,
    liveSnapshot: ProfileSnapshot?,
    applier: RestrictionApplying = AppBlockerUtil(),
    commit: (SessionSnapshot?) -> Bool
  ) -> Bool {
    withLockStatus(blocking: true) { outcome in
      guard outcome == .acquired else { return false }
      guard var session = rawActiveSession, session.endTime == nil,
        session.id == expectedSessionId
      else { return false }
      guard session.breakStartTime == nil else { return false }
      guard let pinned = liveSnapshot else { return false }

      session.breakStartTime = startDate
      session.breakEndDeadline = deadline
      session.pinnedProfileConfig = pinned
      session.oneMoreMinuteStartTime = nil
      session.oneMoreMinuteDeadline = nil

      guard commit(session) else { return false }
      applyDecision(
        deriveRestriction(session: session, liveSnapshot: pinned, process: .mainApp),
        applier: applier)
      return true
    }
  }

  @discardableResult
  public static func openOneMoreMinuteGrant(
    startDate: Date,
    deadline: Date,
    expectedSessionId: String,
    liveSnapshot: ProfileSnapshot?,
    applier: RestrictionApplying = AppBlockerUtil()
  ) -> Bool {
    openOneMoreMinuteGrant(
      startDate: startDate,
      deadline: deadline,
      expectedSessionId: expectedSessionId,
      liveSnapshot: liveSnapshot,
      applier: applier,
      commit: { rawCommitActiveSession($0) })
  }

  /// §6.3 — open a one-more-minute grant in one main-app critical section.
  @discardableResult
  internal static func openOneMoreMinuteGrant(
    startDate: Date,
    deadline: Date,
    expectedSessionId: String,
    liveSnapshot: ProfileSnapshot?,
    applier: RestrictionApplying = AppBlockerUtil(),
    commit: (SessionSnapshot?) -> Bool
  ) -> Bool {
    withLockStatus(blocking: true) { outcome in
      guard outcome == .acquired else { return false }
      guard var session = rawActiveSession, session.endTime == nil,
        session.id == expectedSessionId
      else { return false }
      guard !(session.breakStartTime != nil && session.breakEndTime == nil) else { return false }
      guard session.oneMoreMinuteStartTime == nil else { return false }
      guard let pinned = liveSnapshot else { return false }

      session.oneMoreMinuteStartTime = startDate
      session.oneMoreMinuteDeadline = deadline
      session.oneMoreMinuteUsed = true
      session.pinnedProfileConfig = pinned

      guard commit(session) else { return false }
      applyDecision(
        deriveRestriction(session: session, liveSnapshot: pinned, process: .mainApp),
        applier: applier)
      return true
    }
  }

  @discardableResult
  public static func closeBreakGrantIfExpiredOrExplicit(
    expectedSessionId: String,
    explicit: Bool,
    now: Date,
    process: RestrictionProcess,
    durationMinutes: Int?,
    liveSnapshot: ProfileSnapshot?,
    applier: RestrictionApplying = AppBlockerUtil()
  ) -> Bool {
    closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: expectedSessionId,
      explicit: explicit,
      now: now,
      process: process,
      durationMinutes: durationMinutes,
      liveSnapshot: liveSnapshot,
      applier: applier,
      commit: { rawCommitActiveSession($0) })
  }

  /// §6.5 — close a break grant if expired, or explicitly early-ended.
  @discardableResult
  internal static func closeBreakGrantIfExpiredOrExplicit(
    expectedSessionId: String,
    explicit: Bool,
    now: Date,
    process: RestrictionProcess,
    durationMinutes: Int?,
    liveSnapshot: ProfileSnapshot?,
    applier: RestrictionApplying = AppBlockerUtil(),
    commit: (SessionSnapshot?) -> Bool
  ) -> Bool {
    withLockStatus(blocking: process == .mainApp) { _ in
      guard var session = rawActiveSession, session.endTime == nil,
        session.id == expectedSessionId
      else { return false }
      guard session.breakStartTime != nil, session.breakEndTime == nil else { return false }

      var didStamp = false
      if !explicit {
        var deadline = session.breakEndDeadline
        if deadline == nil {
          guard let minutes = durationMinutes, let start = session.breakStartTime else {
            return false
          }
          deadline = start.addingTimeInterval(TimeInterval(minutes * 60))
          session.breakEndDeadline = deadline
          didStamp = true
        }
        guard let deadline, now >= deadline else {
          if didStamp { _ = commit(session) }
          return false
        }
      }

      session.breakEndTime = now
      guard commit(session) else { return false }
      applyDecision(
        deriveRestriction(session: session, liveSnapshot: liveSnapshot, process: process),
        applier: applier)
      return true
    }
  }

  @discardableResult
  public static func closeOneMoreMinuteGrantIfExpired(
    expectedSessionId: String,
    now: Date,
    process: RestrictionProcess,
    liveSnapshot: ProfileSnapshot?,
    force: Bool = false,
    applier: RestrictionApplying = AppBlockerUtil()
  ) -> Bool {
    closeOneMoreMinuteGrantIfExpired(
      expectedSessionId: expectedSessionId,
      now: now,
      process: process,
      liveSnapshot: liveSnapshot,
      force: force,
      applier: applier,
      commit: { rawCommitActiveSession($0) })
  }

  /// §6.5 — close a one-more-minute grant if expired. Break-active branch clears without re-blocking.
  @discardableResult
  internal static func closeOneMoreMinuteGrantIfExpired(
    expectedSessionId: String,
    now: Date,
    process: RestrictionProcess,
    liveSnapshot: ProfileSnapshot?,
    force: Bool = false,
    applier: RestrictionApplying = AppBlockerUtil(),
    commit: (SessionSnapshot?) -> Bool
  ) -> Bool {
    withLockStatus(blocking: process == .mainApp) { _ in
      guard var session = rawActiveSession, session.endTime == nil,
        session.id == expectedSessionId
      else { return false }
      guard session.oneMoreMinuteStartTime != nil else { return false }

      let breakOpen = session.breakStartTime != nil && session.breakEndTime == nil
      var didStamp = false
      if !breakOpen && !force {
        var deadline = session.oneMoreMinuteDeadline
        if deadline == nil, let start = session.oneMoreMinuteStartTime {
          deadline = start.addingTimeInterval(60)
          session.oneMoreMinuteDeadline = deadline
          didStamp = true
        }
        guard let deadline, now >= deadline else {
          if didStamp { _ = commit(session) }
          return false
        }
      }

      session.oneMoreMinuteStartTime = nil
      session.oneMoreMinuteDeadline = nil
      guard commit(session) else { return false }
      applyDecision(
        deriveRestriction(session: session, liveSnapshot: liveSnapshot, process: process),
        applier: applier)
      return true
    }
  }

  /// §6.4 — normalize open grant fields at session end for bookkeeping only.
  public static func closeGrantsForSessionEnd(expectedSessionId: String, now: Date) {
    withLockStatus(blocking: true) { _ in
      guard var session = rawActiveSession, session.id == expectedSessionId else { return }
      if session.breakStartTime != nil && session.breakEndTime == nil {
        session.breakEndTime = now
      }
      session.oneMoreMinuteStartTime = nil
      session.oneMoreMinuteDeadline = nil
      _ = rawCommitActiveSession(session)
    }
  }

  /// §6.4 — pure normalization for an ended incoming snapshot.
  public static func normalizedForEnd(_ s: SessionSnapshot) -> SessionSnapshot {
    guard let end = s.endTime else { return s }
    var out = s
    if out.breakStartTime != nil && out.breakEndTime == nil {
      out.breakEndTime = min(end, out.breakEndDeadline ?? end)
    }
    out.oneMoreMinuteStartTime = nil
    out.oneMoreMinuteDeadline = nil
    return out
  }

  /// True iff an ended snapshot still carried an open break or OMM grant.
  public static func endedSessionHadOpenGrant(_ s: SessionSnapshot) -> Bool {
    guard s.endTime != nil else { return false }
    let breakOpen = s.breakStartTime != nil && s.breakEndTime == nil
    return breakOpen || s.oneMoreMinuteStartTime != nil
  }

  /// D-C2-4 standalone derive-and-apply. Main app also flushes ended-but-present stale entries.
  @discardableResult
  public static func applyRestrictionsForCurrentState(
    process: RestrictionProcess,
    liveSnapshot: ProfileSnapshot?,
    applier: RestrictionApplying = AppBlockerUtil()
  ) -> RestrictionDecision {
    withLockStatus(blocking: process == .mainApp) { _ in
      let session = rawActiveSession
      if process == .mainApp, let session, session.endTime != nil {
        _ = rawCommitActiveSession(nil)
      }
      let decision = deriveRestriction(session: session, liveSnapshot: liveSnapshot, process: process)
      applyDecision(decision, applier: applier)
      return decision
    }
  }

  /// §7.5 reconciler core. Never mutates DeviceActivity registrations.
  public static func reconcileExpiredGrants(
    process: RestrictionProcess,
    now: Date,
    liveSnapshot: ProfileSnapshot?,
    breakDurationMinutes: Int?,
    applier: RestrictionApplying = AppBlockerUtil()
  ) {
    if let session = rawActiveSession, session.endTime == nil {
      let sid = session.id
      _ = closeOneMoreMinuteGrantIfExpired(
        expectedSessionId: sid,
        now: now,
        process: process,
        liveSnapshot: liveSnapshot,
        applier: applier)
      _ = closeBreakGrantIfExpiredOrExplicit(
        expectedSessionId: sid,
        explicit: false,
        now: now,
        process: process,
        durationMinutes: breakDurationMinutes,
        liveSnapshot: liveSnapshot,
        applier: applier)
    }
    applyRestrictionsForCurrentState(
      process: process,
      liveSnapshot: liveSnapshot,
      applier: applier)
  }

  @discardableResult
  public static func completeGrantMigration(
    expectedSessionId: String,
    breakDurationMinutes: Int,
    pinned: ProfileSnapshot?,
    now: Date
  ) -> Bool {
    completeGrantMigration(
      expectedSessionId: expectedSessionId,
      breakDurationMinutes: breakDurationMinutes,
      pinned: pinned,
      now: now,
      commit: { rawCommitActiveSession($0) })
  }

  /// §7.5.1 M full migration: complete any missing deadline/pin pieces for an open grant.
  @discardableResult
  internal static func completeGrantMigration(
    expectedSessionId: String,
    breakDurationMinutes: Int,
    pinned: ProfileSnapshot?,
    now: Date,
    commit: (SessionSnapshot?) -> Bool
  ) -> Bool {
    withLockStatus(blocking: true) { _ in
      guard var session = rawActiveSession, session.endTime == nil,
        session.id == expectedSessionId
      else { return false }

      var changed = false
      if session.breakStartTime != nil && session.breakEndTime == nil {
        if session.breakEndDeadline == nil, let start = session.breakStartTime {
          session.breakEndDeadline = start.addingTimeInterval(
            TimeInterval(breakDurationMinutes * 60))
          changed = true
        }
        if session.pinnedProfileConfig == nil, let pinned {
          session.pinnedProfileConfig = pinned
          changed = true
        }
      }
      if session.oneMoreMinuteStartTime != nil {
        if session.oneMoreMinuteDeadline == nil, let start = session.oneMoreMinuteStartTime {
          session.oneMoreMinuteDeadline = start.addingTimeInterval(60)
          changed = true
        }
        if session.pinnedProfileConfig == nil, let pinned {
          session.pinnedProfileConfig = pinned
          changed = true
        }
      }
      guard changed else { return false }
      return commit(session)
    }
  }
}
