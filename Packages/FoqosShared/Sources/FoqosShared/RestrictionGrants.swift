import Foundation

extension SharedData {
  /// Thin applier for a derived decision.
  static func applyDecision(
    _ decision: RestrictionDecision, session: SessionSnapshot?, applier: RestrictionApplying
  ) {
    switch decision {
    case .deactivate:
      applier.deactivateRestrictions(
        keepingSafeguardsFor: session?.endTime == nil ? session?.pinnedProfileConfig : nil)
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
    let committed = withLockStatus(blocking: true) { outcome in
      guard outcome == .acquired else { return false }
      guard let checked = checkedActiveSession(), var session = checked, session.endTime == nil,
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
      return true
    }
    if committed {
      applyRestrictionsForCurrentState(process: .mainApp, liveSnapshot: liveSnapshot, applier: applier)
    }
    return committed
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
    let committed = withLockStatus(blocking: true) { outcome in
      guard outcome == .acquired else { return false }
      guard let checked = checkedActiveSession(), var session = checked, session.endTime == nil,
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
      return true
    }
    if committed {
      applyRestrictionsForCurrentState(process: .mainApp, liveSnapshot: liveSnapshot, applier: applier)
    }
    return committed
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
    var fallback: (previous: SessionSnapshot, closed: SessionSnapshot)?
    let committed = withLockStatus(blocking: process == .mainApp) { outcome in
      guard outcome == .acquired || process == .monitorExtension else { return false }
      guard let checked = checkedActiveSession(), var session = checked, session.endTime == nil,
        session.id == expectedSessionId
      else { return false }
      guard session.breakStartTime != nil, session.breakEndTime == nil else { return false }

      let previous = session
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
          if didStamp, outcome == .acquired { _ = commit(session) }
          return false
        }
      }

      session.breakEndTime = now
      guard outcome == .acquired else {
        fallback = (previous, session)
        return false
      }
      return commit(session)
    }
    if committed {
      applyRestrictionsForCurrentState(process: process, liveSnapshot: liveSnapshot, applier: applier)
    } else if let fallback {
      applyExpiredGrantFallback(
        previous: fallback.previous, closed: fallback.closed, liveSnapshot: liveSnapshot, applier: applier)
    }
    return committed
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
    var fallback: (previous: SessionSnapshot, closed: SessionSnapshot)?
    let committed = withLockStatus(blocking: process == .mainApp) { outcome in
      guard outcome == .acquired || process == .monitorExtension else { return false }
      guard let checked = checkedActiveSession(), var session = checked, session.endTime == nil,
        session.id == expectedSessionId
      else { return false }
      guard session.oneMoreMinuteStartTime != nil else { return false }

      let breakOpen = session.breakStartTime != nil && session.breakEndTime == nil
      let previous = session
      var didStamp = false
      if !breakOpen && !force {
        var deadline = session.oneMoreMinuteDeadline
        if deadline == nil, let start = session.oneMoreMinuteStartTime {
          deadline = start.addingTimeInterval(60)
          session.oneMoreMinuteDeadline = deadline
          didStamp = true
        }
        guard let deadline, now >= deadline else {
          if didStamp, outcome == .acquired { _ = commit(session) }
          return false
        }
      }

      session.oneMoreMinuteStartTime = nil
      session.oneMoreMinuteDeadline = nil
      guard outcome == .acquired else {
        fallback = (previous, session)
        return false
      }
      return commit(session)
    }
    if committed {
      applyRestrictionsForCurrentState(process: process, liveSnapshot: liveSnapshot, applier: applier)
    } else if let fallback {
      applyExpiredGrantFallback(
        previous: fallback.previous, closed: fallback.closed, liveSnapshot: liveSnapshot, applier: applier)
    }
    return committed
  }

  /// A contended monitor can re-block an expired grant without overwriting the owner.
  private static func applyExpiredGrantFallback(
    previous: SessionSnapshot, closed: SessionSnapshot, liveSnapshot: ProfileSnapshot?, applier: RestrictionApplying
  ) {
    guard let checked = checkedActiveSession(), checked == previous else { return }
    let profile =
      profileSnapshots[closed.blockedProfileId.uuidString]
      ?? (liveSnapshot?.id == closed.blockedProfileId ? liveSnapshot : nil)
    let decision = deriveRestriction(session: closed, liveSnapshot: profile, process: .monitorExtension)
    guard case .activate = decision else { return }
    applyDecision(decision, session: closed, applier: applier)
    if let checked = checkedActiveSession(), checked != previous {
      applyRestrictionsForCurrentState(
        process: .monitorExtension, liveSnapshot: nil, applier: applier, deactivateWhenIdle: true)
    }
  }

  /// §6.4 — normalize open grant fields at session end for bookkeeping only.
  public static func closeGrantsForSessionEnd(expectedSessionId: String, now: Date) {
    withLockStatus(blocking: true) { outcome in
      guard outcome == .acquired, let checked = checkedActiveSession(),
        var session = checked, session.id == expectedSessionId
      else { return }
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
    out.timerEndTime = nil
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

  /// Apply synchronously after unlocking and repair any effect overtaken by another writer.
  @discardableResult
  public static func applyRestrictionsForCurrentState(
    process: RestrictionProcess,
    liveSnapshot: ProfileSnapshot?,
    applier: RestrictionApplying = AppBlockerUtil(),
    deactivateWhenIdle: Bool = false
  ) -> RestrictionDecision {
    func readBasis() -> RestrictionBasis? {
      withLockStatus(blocking: process == .mainApp) { outcome in
        guard outcome == .acquired, let session = checkedActiveSession() else { return nil }
        let profile = session.flatMap { owner in
          profileSnapshots[owner.blockedProfileId.uuidString] ?? (liveSnapshot?.id == owner.blockedProfileId ? liveSnapshot : nil)
        }
        return RestrictionBasis(session: session, profile: profile)
      }
    }

    var repairing = deactivateWhenIdle
    var lastDecision = RestrictionDecision.bailPreserve
    while let basis = readBasis() {
      if process == .mainApp, let ended = basis.session, ended.endTime != nil,
        recoverEndedSession(ended)
      {
        continue
      }
      let decision = deriveRestriction(
        session: basis.session, liveSnapshot: basis.profile, process: repairing ? .mainApp : process)
      applyDecision(decision, session: basis.session, applier: applier)
      lastDecision = decision
      guard let current = readBasis(), current != basis else { return decision }
      if decision != .bailPreserve { repairing = true }
    }
    return lastDecision
  }

  private struct RestrictionBasis: Equatable {
    let session: SessionSnapshot?
    let profile: ProfileSnapshot?
  }

  /// §7.5 reconciler core. Never mutates DeviceActivity registrations.
  public static func reconcileExpiredGrants(
    process: RestrictionProcess,
    now: Date,
    liveSnapshot: ProfileSnapshot?,
    breakDurationMinutes: Int?,
    applier: RestrictionApplying = AppBlockerUtil()
  ) {
    // Intentional lockless id peek: the child closers re-acquire and re-check session identity
    // inside their own non-reentrant lock sections. Wrapping this function would nest locks.
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
    if process == .monitorExtension, let session = rawActiveSession, hasOpenGrant(session) {
      let breakDeadline =
        session.breakEndDeadline
        ?? session.breakStartTime.flatMap { start in
          breakDurationMinutes.map { start.addingTimeInterval(TimeInterval($0 * 60)) }
        }
      let ommDeadline = session.oneMoreMinuteDeadline ?? session.oneMoreMinuteStartTime?.addingTimeInterval(60)
      let openBreak = session.breakStartTime != nil && session.breakEndTime == nil
      let expired = openBreak ? breakDeadline.map { now >= $0 } : ommDeadline.map { now >= $0 }
      if expired == true { return }
    }
    applyRestrictionsForCurrentState(process: process, liveSnapshot: liveSnapshot, applier: applier)
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
    withLockStatus(blocking: true) { outcome in
      guard outcome == .acquired, let checked = checkedActiveSession(), var session = checked, session.endTime == nil,
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
