# Three-Stream Xcode and Simulator Concurrency

**Date:** 2026-08-09
**Issue:** #362
**Status:** Proposed design for maintainer review
**Scope:** Agent coordination, Xcode/simulator resource claims, and the `AGENTS.md` rule that
currently permits only one implementation stream per machine

## Problem

`AGENTS.md` currently bans all parallel development on one machine because Xcode, the iOS
Simulator, and default DerivedData were treated as one shared resource. That rule is now too
broad. This host has empirically supported three concurrent simulators, and today's fastlane
work showed that Ruby, shell, and documentation streams can safely run beside an Xcode stream.
The old wording stopped a fastlane-only stream even though it never invoked Xcode or a
simulator.

Simply changing “one” to “three” would create a different failure mode. Three independent
agents can accidentally select the same simulator, reuse the same DerivedData directory, or
run cleanup that deletes another stream's resources. The current coordination is convention
only, so the cap and resource ownership cannot be observed atomically.

Today's session supplied three concrete examples:

- Phase A/D fastlane, Ruby, shell, and docs work ran safely alongside build2's app work because
  it did not invoke Xcode or the simulator. Such work should not consume an Xcode stream slot.
- The screenshots lane cleanup shipped in `85593e0` with a model-name filter as an interim
  narrowing. A sibling stream can still create a same-model XCTestDevices clone during the
  lane and have that clone mistaken for the screenshots lane's. Cleanup must move to exact
  UUIDs created inside the owning lane's creation window.
- `scripts/clean-build.sh` currently removes every
  `~/Library/Developer/Xcode/DerivedData/FamilyFoqos-*` directory. Under concurrency that can
  erase another stream's active build output. Per-stream DerivedData is ineffective unless
  cleanup is also per-stream.

The session's dead production-schema gate is a related process lesson: fastlane lane bodies run
with `fastlane/` as their working directory, and `FastFile#sh` intercepts the call before the
`chdir("..")` behavior used by real actions. A repo-relative script therefore resolved somewhere
else. Concurrency helpers must resolve the worktree and resource paths to absolute paths before
starting a child command; they must not rely on a caller's current directory.

## Constraints

- At most three Xcode/simulator-mutating streams may run concurrently on this machine.
- Every writing stream uses its own git worktree and coordinator-assigned disjoint file set.
  Git isolation does not replace resource isolation.
- Every Xcode stream receives one explicit simulator UUID and one absolute, unique DerivedData
  path. Device names remain forbidden in `xcodebuild -destination`.
- The coordinator assigns the UUID, DerivedData path, file ownership, and merge order before a
  worker starts. An agent does not silently self-select or borrow another stream's assignment.
- Read-only work and work that invokes neither Xcode nor the simulator do not consume one of the
  three slots. Writing work still requires a worktree and disjoint files.
- `bundle exec fastlane screenshots` counts as one Xcode/simulator-mutating unit from its
  pre-run XCTestDevices inventory through its final cleanup. `snapshot` invokes `xcodebuild`
  and creates XCTestDevices clones even though the outer command is Ruby.
- The semaphore is advisory. A process that does not call the wrapper is invisible to it. The
  design must state this honestly and make the wrapper the only documented agent entrypoint for
  build, test, archive, screenshot, and mutating `simctl` commands.
- Lock state must survive long enough to diagnose a crash but must not require time-based PID
  guessing. PID reuse and delayed jobs make timestamp-only reclamation unsafe.
- Simulator cleanup must never delete by model or display name. It deletes exact UUIDs owned by
  the lane and created after that lane recorded its start/baseline.
- This design changes documentation and proposes follow-up code. This commit adds no executable
  helper and runs no Xcode command.

## Options considered

### 1. Three-slot `File.flock` wrapper plus resource locks — recommended

A Ruby wrapper holds one of three machine-wide slot locks while its child command runs. It also
holds a lock for the assigned simulator UUID and a lock for the canonical DerivedData path. Ruby
is already present for fastlane, and `File.flock` avoids adding a non-default macOS `flock` CLI
dependency.

Benefits:

- The three-stream cap and duplicate UUID/DerivedData claims are atomic.
- Kernel locks release after the wrapper and the resource-using child have both closed their
  inherited descriptors, including after either process dies.
- Persistent JSON metadata makes active and crashed holders diagnosable.
- Worktrees and clones coordinate through one machine-wide path.

Costs and limits:

- Every Xcode-mutating agent command must use the wrapper.
- It is advisory rather than sandbox enforcement; an unwrapped process can interfere.
- The wrapper must forward signals, preserve the child's exit status, and be tested under
  contention and process death.

### 2. Convention plus a coordinator-owned assignment table

The planner records three slots, UUIDs, DerivedData paths, and file sets in its task messages.
This requires no helper and remains easy to understand. It does not atomically prevent a fourth
worker, duplicate claims, stale assignments, or an uncoordinated cleanup. Today's screenshots
cleanup race is exactly the kind of cross-stream interference that convention cannot stop.

### 3. One global Xcode lock

A single advisory lock preserves today's serialization while making the owner observable. It is
the simplest safe fallback if three-stream isolation cannot be made reliable. It discards the
verified capacity of the host and does not meet #362's throughput objective.

## Recommendation

**DECIDED:** implement option 1. No core design decision remains open; maintainer acceptance of
this proposal is the adoption gate.

### Lock and claim model

Use this machine-wide root, independent of repository/worktree location:

```text
~/Library/Caches/family-foqos/xcode-streams/
  slots/1.lock
  slots/1.json
  slots/2.lock
  slots/2.json
  slots/3.lock
  slots/3.json
  simulators/<UUID>.lock
  simulators/<UUID>.json
  derived-data/<sha256-of-canonical-absolute-path>.lock
  derived-data/<sha256-of-canonical-absolute-path>.json
  resources/screenshots-xctestdevices.lock
  resources/screenshots-xctestdevices.json
```

The root is mode `0700`; files are mode `0600`. Each slot's `.json` sidecar contains metadata while
held:

```json
{
  "version": 1,
  "slot": 2,
  "pid": 41027,
  "child_pid": 41031,
  "started_at": "2026-08-09T10:00:00Z",
  "worktree": "/absolute/path/to/worktree",
  "branch": "feat/example",
  "simulator_uuid": "B9E4A679-BDF3-4541-A59F-DA4BE21F80ED",
  "derived_data": "/Users/rob/Library/Developer/Xcode/DerivedData/FamilyFoqos-stream-a",
  "command": ["xcodebuild", "test", "..."]
}
```

The wrapper acquires locks in one fixed order: slot, simulator UUID, canonical DerivedData path,
then any command-specific resource lock. A duplicate simulator or DerivedData claim fails before
the child starts and releases everything already acquired. Before `Process.spawn`, the wrapper
sets every lock descriptor's `close_on_exec` to `false` and explicitly maps the descriptors into
the child. The resource-using child therefore remains a kernel lock holder even if the wrapper is
`SIGKILL`ed: the lock tracks the process actually using the resource, not merely the process that
requested it. The wrapper starts the child in its own process group, forwards `INT`/`TERM` to that
group, waits for it, and exits with the child's status. If the wrapper is exiting abnormally but
can still run cleanup, it terminates the entire child group, waits through a bounded grace period,
then escalates the group to `KILL`; a hard-killed wrapper instead relies on the child's inherited
locks until that resource user exits.

The kernel lock is the source of truth. Lock files are stable inodes and are never replaced.
Diagnostic JSON lives in separate sidecars: the wrapper writes a same-directory temporary file,
sets mode `0600`, then atomically renames it over the `.json` sidecar. Readers can therefore inspect
complete metadata without touching the lock or observing a torn write. On normal release the
wrapper atomically publishes an inactive record and unlocks. If the wrapper dies while its child
runs, the inherited child descriptors keep every lock held; the metadata still identifies both
PIDs. Once the final holder exits, the kernel releases the locks but the last JSON remains. The
next successful holder reports that stale metadata and overwrites it. It never kills or reclaims
based only on age or a recorded PID. If a live holder is hung, a human inspects the metadata and
explicitly terminates the recorded process group.

The implementation shape is:

```ruby
# Specification snippet only; the implementation lands in a follow-up.
root = File.expand_path("~/Library/Caches/family-foqos/xcode-streams")
slot = try_lock_first((1..3).map { |n| "#{root}/slots/#{n}.lock" }, metadata)
abort("all three Xcode stream slots are busy") unless slot

simulator = try_lock("#{root}/simulators/#{simulator_uuid}.lock", metadata)
abort("simulator UUID is already claimed: #{simulator_uuid}") unless simulator

derived_key = Digest::SHA256.hexdigest(File.realpath(derived_data_parent) +
                                       File::SEPARATOR + File.basename(derived_data))
derived = try_lock("#{root}/derived-data/#{derived_key}.lock", metadata)
abort("DerivedData path is already claimed: #{derived_data}") unless derived

# Both parent and child keep the flock descriptors. Explicit descriptor mappings avoid Ruby's
# close-on-exec/default close-others behavior, so an orphan child cannot outlive its locks.
lock_ios.each { |io| io.close_on_exec = false }
inherited_locks = lock_ios.to_h { |io| [io.fileno, io.fileno] }
child_pid = Process.spawn(*command, inherited_locks.merge(pgroup: true))
status = Process.wait2(child_pid).last
exit(status.exitstatus || 1)
```

The real helper must use `ensure` to publish inactive metadata and close parent descriptors in
reverse order, and must forward signals to the child process group. Closing the parent's copy does
not release a lock while the child still holds its inherited copy. It must canonicalize paths
without requiring the not-yet-created leaf directory.

### Advisory enforcement

The wrapper cannot police a command that bypasses it. Mitigation is layered:

1. `AGENTS.md` makes the wrapper the only permitted agent entrypoint for `xcodebuild`, Xcode
   archive/screenshot lanes, and mutating `simctl` commands.
2. Every plan and task assignment provides the wrapper command, UUID, DerivedData path, and file
   set rather than a raw `xcodebuild` command.
3. The wrapper emits a warning if it observes an `xcodebuild` process whose ancestor chain does
   not reach an active slot's recorded `child_pid`. Checking only the immediate parent would
   falsely flag the compliant wrapper → Bundler → fastlane → `xcodebuild` chain. This remains a
   cheap detector, not proof of enforcement.
4. Read-only `simctl list` discovery may run outside a slot. Boot, clone, delete, erase, test,
   build, archive, and screenshot operations may not.

### Simulator and DerivedData assignment

At planner initialization, the coordinator lists available devices once, chooses distinct UUIDs,
and records a table like:

| Stream | Simulator UUID | DerivedData | Owned files |
|---|---|---|---|
| `stream-a` | explicit UUID A | `~/Library/Developer/Xcode/DerivedData/FamilyFoqos-stream-a` | paths A |
| `stream-b` | explicit UUID B | `~/Library/Developer/Xcode/DerivedData/FamilyFoqos-stream-b` | paths B |
| `stream-c` | explicit UUID C | `~/Library/Developer/Xcode/DerivedData/FamilyFoqos-stream-c` | paths C |

The assignment appears in each worker's first message as `FOQOS_SIMULATOR_UUID` and
`FOQOS_DERIVED_DATA`. The wrapper validates UUID syntax, requires an absolute DerivedData path,
locks both, and exports the validated values to its child. For a direct `xcodebuild`, it also
requires the command arguments to contain the exact assigned destination and DerivedData path.
Fastlane integration tests must assert that `gym` consumes both values and `snapshot` consumes the
DerivedData assignment plus its singleton claim; until that plumbing lands, declared locks are not
evidence of actual resource use. Direct `xcodebuild` receives both:

```bash
-destination "platform=iOS Simulator,id=$FOQOS_SIMULATOR_UUID" \
-derivedDataPath "$FOQOS_DERIVED_DATA"
```

`scripts/clean-build.sh` must be changed to accept and validate exactly one assigned DerivedData
path. Its current `FamilyFoqos-*` wildcard is forbidden once concurrent streams are enabled.

### Screenshots lane

The entire command is wrapped as one unit:

```bash
ruby scripts/with-xcode-stream.rb \
  --simulator "$FOQOS_SIMULATOR_UUID" \
  --derived-data "$FOQOS_DERIVED_DATA" \
  --resource screenshots-xctestdevices \
  -- bundle exec fastlane screenshots
```

The singleton screenshots resource prevents two snapshot clone/cleanup windows from overlapping.
Cleanup ownership is a three-part invariant, not something the before/after UUID diff establishes
alone:

1. every compliant non-screenshot stream uses an explicit simulator UUID and never causes a
   device-name XCTestDevices clone;
2. only one lane holds `screenshots-xctestdevices` from inventory through cleanup; and
3. that lane deletes only exact UUIDs absent from its baseline and created after its start.

The wrapper atomically enforces the singleton among compliant commands, and the Fastfile enforces
the timestamp/UUID filter plus an assertion of the wrapper-exported singleton claim before deleting
anything. The explicit-UUID rule is advisory for indirect Fastlane commands and argument-validated
for direct `xcodebuild`; plans, wrapper validation, and integration tests keep that leg visible. A
future change may not drop either the explicit-UUID rule or singleton on the theory that the UUID
diff is sufficient: an unrelated clone created inside the window would also be new. The model-name
filter in `85593e0` is explicitly interim and is superseded by this composed ownership rule. No
code may delete all simulators, all XCTestDevices entries, or entries selected only by model/name.

`Snapfile` currently selects `iPhone 17 Pro Max` by name, so snapshot creates arbitrary clone UUIDs
and does not use `FOQOS_SIMULATOR_UUID`. Reserving the assigned UUID remains harmless and keeps one
uniform wrapper interface, but the singleton—not that UUID lock—is what protects the screenshots
clone window.

An `ensure` cleanup cannot run after `SIGKILL`. Before snapshot, the wrapper atomically records the
lane start, expected snapshot model, and baseline UUID set in the singleton's metadata sidecar.
When a later holder acquires an otherwise-free singleton and finds prior active metadata, it
reconstructs exact candidates that were absent from the baseline, created after the prior start,
and match the expected snapshot-clone pattern. It reports candidates immediately. Candidates with
no live singleton holder enter a 24-hour quarantine; after that threshold the helper may offer an
operator-confirmed deletion listing every exact UUID, but it never auto-deletes. Age and a dead PID
are filters for the confirmation list, not authority to reclaim by themselves.

### File ownership and integration

The semaphore protects machine resources, not source files. The coordinator must assign disjoint
file sets before work begins and stop any stream whose requested edit overlaps another active
stream. Dependencies and merge order are recorded up front. A worktree does not make overlapping
edits safe; it only separates indexes and working copies.

Non-Xcode implementation work does not consume a slot, which is why today's Phase A/D could run
beside Phase B. It still follows the worktree, file ownership, commit, and review rules.

## Exact `AGENTS.md` diff

Replace the current bullet beginning `NO parallel development on the same machine` with this
literal text when the helper and cleanup fixes land:

```markdown
  - **UP TO THREE concurrent Xcode/simulator implementation streams per machine.** A coordinator
    may run at most three streams that build, test, archive, take screenshots, or mutate iOS
    simulators. Before a stream starts, the coordinator MUST assign it: (1) its own git worktree,
    (2) an explicit simulator UUID, never a device name, (3) a unique absolute DerivedData path,
    and (4) a disjoint file set and merge order. Never share or silently substitute any of these.
  - **ALL Xcode/simulator mutations MUST use the advisory stream wrapper.** Invoke
    `ruby scripts/with-xcode-stream.rb --simulator <UUID> --derived-data <ABSOLUTE_PATH> -- <command>`
    as the only agent entrypoint for `xcodebuild`, build/test/archive/screenshot fastlane lanes,
    and mutating `xcrun simctl` commands. The wrapper caps activity at three holders and refuses a
    simulator UUID or DerivedData path already claimed by another holder. It is advisory: an
    unwrapped process is invisible, so raw Xcode-mutating commands are prohibited in agent plans.
    Read-only discovery such as `xcrun simctl list devices available` does not require a slot.
  - **`fastlane screenshots` is one Xcode-mutating stream.** Wrap the complete
    `bundle exec fastlane screenshots` command, from its pre-run XCTestDevices inventory through
    cleanup. Simulator cleanup may delete only exact UUIDs created by that lane after its recorded
    start, while every other stream uses an explicit UUID destination and the screenshots lane
    holds its singleton XCTestDevices-cleanup resource. All three conditions are required; the UUID
    diff alone is not ownership. Never select cleanup targets only by model/name, and never reset or
    blanket-purge simulators. A hard-killed lane's candidates are reported and require explicit
    operator confirmation after the documented quarantine before exact-UUID deletion.
  - **DerivedData cleanup is stream-local.** Every build passes its assigned
    `-derivedDataPath`. Clean only that exact validated path; never use a `FamilyFoqos-*` wildcard
    while streams may overlap.
  - **Non-Xcode work is outside the three-stream count.** Ruby/fastlane configuration, shell
    scripts, documentation, planning, investigation, and review that invoke neither Xcode nor the
    simulator may run alongside Xcode streams. Writing work still requires its own worktree and a
    coordinator-assigned disjoint file set. Read-only sessions use their own working copy and do
    not run builds or tests.
```

`<UUID>`, `<ABSOLUTE_PATH>`, and `<command>` are documented command parameters, not unresolved
design decisions; every real task message substitutes concrete values.

## Rollout

1. Land and test `scripts/with-xcode-stream.rb` before or atomically with the `AGENTS.md` change.
   Tests cover three simultaneous holders, fourth-holder refusal, duplicate UUID/path refusal,
   fixed acquisition order, signal forwarding to the child process group, child exit propagation,
   normal cleanup, atomic metadata reads, and stale metadata recovery. Kill a wrapper around a
   long-running child and prove the inherited child descriptors prevent a duplicate claim until
   that child exits.
2. Replace `scripts/clean-build.sh` wildcard deletion with one validated absolute-path argument.
   Refuse an empty path, `/`, a home directory, the DerivedData root itself, or any path outside
   the expected FamilyFoqos DerivedData prefix.
3. Update every documented build/test command to pass the assigned UUID and
   `-derivedDataPath`, wrapped by the helper. Update fastlane `gym`/`snapshot` plumbing to consume
   the same assignment.
4. Update the merged screenshots Fastfile: outer wrapper for the whole lane, asserted singleton
   cleanup resource, exact before/after UUID candidates, created-after-start filtering, and a
   startup sweep using prior singleton metadata. Test immediate reporting, the 24-hour quarantine,
   refusal without operator confirmation, and confirmed deletion of only the displayed UUIDs.
   Remove the interim model-name-only cleanup from `85593e0`.
5. Land the literal `AGENTS.md` replacement above in the same reviewed change as the working
   helper and safe cleanup. Do not publish a mandate for a helper that does not yet exist.
6. Validate without Xcode first: three wrapped `sleep` children acquire slots, a fourth fails,
   duplicate simulator/DerivedData claims fail, and killing a holder makes its slot reclaimable
   with stale metadata reported.
7. With the maintainer present, run three minimal Xcode streams on three assigned UUID/path pairs.
   Confirm no shared DerivedData, no unexpected XCTestDevices deletion, and no unwrapped-process
   warnings. Fall back to one global slot if the empirical validation fails.
8. For the first week, planners include the assignment table in every multi-stream task and audit
   wrapper metadata after runs. Any interference incident temporarily reduces the cap until its
   ownership hole is understood.
