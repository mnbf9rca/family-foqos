# Agent-run V1 → V2 source upgrade verification

Agents execute this procedure and inspect its screenshots; the human does not seed stores or interpret simulator output. Run the 14 personas on iOS 26.5 and iOS 27 for release-candidate acceptance under [Agent Acceptance](development-workflow.md#agent-acceptance-runbooks).

Build frozen V1 **1.31.3 / 4 at `589bee9228abb5b32cc3506f7c0e23782a571d03`**, launch its normal persisted app with a one-shot synthetic seed, and install the chosen V2 app over that data. An external `FoqosUITests` runner drives actual views; never host this procedure in `FoqosTests`, use `--screenshot-demo`, seed V2, call migration/start/stop APIs from tests, or dismiss an unexpected failure to obtain a pass.

Expected behavior and the persona matrix are in the [approved plan](superpowers/plans/2026-10-04-simulated-users-upgrade.md#persona-matrix), [conditions rulebook](superpowers/specs/2026-10-02-508-v2-conditions-rulebook.md) and [#507 rulings](https://github.com/mnbf9rca/family-foqos/issues/507). Slugs: `manual`, `nfc`, `qr`, `nfc-timer`, `qr-timer`, `shortcut-timer`, `manual-nfc`, `manual-qr`, `schedule`, `break`, `emergency`, `parent`, `child`, `library`; no silent skips.

| Persona evidence detail | Required proof |
| --- | --- |
| Emergency user | Show the retained allowance of 1 and successful last unblock in the UI. On idle relaunch, Emergency is reachable only during an active session, so the mandatory fresh report proves exactly 0 remaining and 14 reset days; keep the idle screenshot and global no-Stop check. A missing or stale report is UNRUN. |

## 1. Pin sources and compile fixtures before touching app data

Use Bash for the blocks below. Start in the clean fixture-bearing feature head; choose the requested V2 revision explicitly. Every simulator operation uses the same owner gate and UUID destination; never provide a destination/DerivedData override or borrow another owner. A second runtime/session requires orchestrator authorization; the standing build1 exception is `collab-ios27` with installed iOS 27.0 for a new owner. An override cannot change an existing owner's runtime.

```bash
set -euo pipefail
for tool in git cp mktemp python3 shasum xcrun; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 127; }
done
UPGRADE_REPO=$(git rev-parse --show-toplevel)
UPGRADE_AGENT=build1
UPGRADE_SESSION=collab
UPGRADE_V1_SHA=589bee9228abb5b32cc3506f7c0e23782a571d03
UPGRADE_TARGET=$(git rev-parse origin/main) # Replace with the requested clean V2 revision.
UPGRADE_RUN=$(mktemp -d /private/tmp/family-foqos-v1-v2.XXXXXXXX)
UPGRADE_PRODUCTS=$(mktemp -d /private/tmp/family-foqos-v1-v2.XXXXXXXX)
UPGRADE_V1="$UPGRADE_RUN/source-v1"
UPGRADE_V2="$UPGRADE_RUN/source-v2"
UPGRADE_GATE="$UPGRADE_REPO/scripts/xcode-stream.sh"
UPGRADE_STATE="$UPGRADE_REPO/scripts/v1-v2-upgrade-state.py"
git worktree add --detach "$UPGRADE_V1" "$UPGRADE_V1_SHA"
git worktree add --detach "$UPGRADE_V2" "$UPGRADE_TARGET"
for version in V1 V2; do
  if [[ "$version" == V1 ]]; then tree="$UPGRADE_V1"; else tree="$UPGRADE_V2"; fi
  git -C "$tree" apply --check "$UPGRADE_REPO/docs/fixtures/${version}UpgradeUI.patch"
  git -C "$tree" apply "$UPGRADE_REPO/docs/fixtures/${version}UpgradeUI.patch"
done
[[ ! -e "$UPGRADE_V1/Foqos/Utils/V1UpgradeSeedData.swift" &&
   ! -e "$UPGRADE_V2/Foqos/Utils/UpgradeDiagnostics.swift" &&
   ! -e "$UPGRADE_V2/FoqosUITests/UpgradePersonaUITests.swift" ]] \
  || { echo 'Fixture target already exists' >&2; exit 1; }
cp "$UPGRADE_REPO/docs/fixtures/V1UpgradeSeedData.swift" "$UPGRADE_V1/Foqos/Utils/"
cp "$UPGRADE_REPO/docs/fixtures/UpgradeDiagnostics.swift" "$UPGRADE_V2/Foqos/Utils/"
cp "$UPGRADE_REPO/docs/fixtures/UpgradePersonaUITests.swift" "$UPGRADE_V2/FoqosUITests/"
"$UPGRADE_REPO/scripts/test-v1-v2-upgrade-state.sh"
(cd "$UPGRADE_V1"
 "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" --xcbeautify -- \
  xcodebuild build -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug \
  > "$UPGRADE_RUN/preflight-v1.log" 2>&1)
"$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" -- \
 python3 "$UPGRADE_STATE" preserve-products "$UPGRADE_PRODUCTS" --phase v1 --source-revision "$UPGRADE_V1_SHA"
(cd "$UPGRADE_V2"
 "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" --xcbeautify -- \
  xcodebuild build-for-testing -project FamilyFoqos.xcodeproj -scheme FoqosScreenshots \
  -configuration Debug -only-testing:FoqosUITests/UpgradePersonaUITests \
  > "$UPGRADE_RUN/preflight-v2.log" 2>&1)
"$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" -- \
 python3 "$UPGRADE_STATE" preserve-products "$UPGRADE_PRODUCTS" --phase first-launch --source-revision "$UPGRADE_TARGET"
shasum -a 256 "$UPGRADE_REPO"/docs/fixtures/*Upgrade* "$UPGRADE_REPO/docs/fixtures/UpgradePersonaUITests.swift" \
 > "$UPGRADE_RUN/fixture-hashes.txt"
declare -p UPGRADE_REPO UPGRADE_AGENT UPGRADE_SESSION UPGRADE_V1_SHA UPGRADE_TARGET \
 UPGRADE_RUN UPGRADE_PRODUCTS UPGRADE_V1 UPGRADE_V2 UPGRADE_GATE UPGRADE_STATE > "$UPGRADE_RUN/env.sh"
echo "$UPGRADE_RUN/env.sh"
```

Preserve each product immediately after its successful build, before the other version overwrites the owner's DerivedData. The helper discovers the generated UI runner, validates its structure and bundle, and copies/hash-pins app and runner products outside DerivedData. Compile or patch drift stops as **“fixtures out of date: update them in a PR”**, with the original log retained; never improvise an unrecorded substitution. `AppPicker.swift` needs no compatibility patch: the missing-Combine message observed with Xcode 27 was a warning in successful builds too.

The patches exist only in disposable source trees: every hook compiles inside `#if DEBUG` and requires `--upgrade-ui-check`. Substitutions cover authorization, CloudKit/lock-record responses, restrictions, DeviceActivity registration/backstops and hardware scan delivery. Migration, mode/lock checks, real scan callbacks, routing, validation and persistence remain production behavior. The public CodeScanner `simulatedData` seam still requires tapping its simulator scanner UI.

## 2. Fresh V1 setup, then install-over UI phases

Set `UPGRADE_ENV` to the exact `env.sh` printed above in each new shell; never source a past run. Each persona attempt gets a new evidence directory and fresh disposable V1 store. `prepare` backs up the previous app/group before uninstalling that disposable app and clearing only its backed-up store/preferences remnants; obtain an orchestrator ruling first if the existing app is not known to be disposable.

```bash
set -euo pipefail
: "${UPGRADE_ENV:?Set the current env.sh path}"
source "$UPGRADE_ENV"
UPGRADE_PERSONA=manual # Repeat for every slug, using a fresh attempt directory.
UPGRADE_ATTEMPT=$(mktemp -d /private/tmp/family-foqos-v1-v2.XXXXXXXX)
"$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" -- \
 python3 "$UPGRADE_STATE" prepare "$UPGRADE_ATTEMPT" --persona "$UPGRADE_PERSONA" --v1-app "$UPGRADE_PRODUCTS/v1.app"
"$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" -- \
 python3 "$UPGRADE_STATE" install-runner "$UPGRADE_ATTEMPT" \
 --runner-app "$UPGRADE_PRODUCTS/runner.app" --xctestrun "$UPGRADE_PRODUCTS/generated.xctestrun"
for phase in v1 first-launch journey relaunch; do
  if [[ "$phase" == first-launch ]]; then
    "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" -- \
     python3 "$UPGRADE_STATE" install-v2 "$UPGRADE_ATTEMPT" \
     --v2-app "$UPGRADE_PRODUCTS/v2.app" --source-revision "$UPGRADE_TARGET"
  fi
  generation=$(python3 -c 'import uuid; print(uuid.uuid4())')
  case "$phase" in
    v1) test=testV1Setup;; first-launch) test=testV2FirstLaunch;;
    journey) test=testV2Journey;; relaunch) test=testV2Relaunch;;
  esac
  "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" -- \
   python3 "$UPGRADE_STATE" prepare-run "$UPGRADE_ATTEMPT" --phase "$phase" --generation "$generation"
  test_status=0
  "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" -- \
   xcodebuild test-without-building -xctestrun "$UPGRADE_ATTEMPT/$phase.$generation.xctestrun" \
   -only-testing:"FoqosUITests/UpgradePersonaUITests/$test" -collect-test-diagnostics never \
   -resultBundlePath "$UPGRADE_ATTEMPT/$phase.xcresult" \
   > "$UPGRADE_ATTEMPT/$phase.log" 2>&1 || test_status=$?
  # Required even when XCTest fails: mismatched installation/sentinel means UNRUN.
  "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" -- \
   python3 "$UPGRADE_STATE" verify-run "$UPGRADE_ATTEMPT" --phase "$phase"
  [[ "$test_status" == 0 ]] || { echo "Test failed: $phase ($test_status)" >&2; exit "$test_status"; }
  xcrun xcresulttool export attachments --path "$UPGRADE_ATTEMPT/$phase.xcresult" \
   --output-path "$UPGRADE_ATTEMPT/$phase-attachments"
  if [[ "$phase" == v1 ]]; then
    "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" -- \
     python3 "$UPGRADE_STATE" capture-v1 "$UPGRADE_ATTEMPT"
  else
    report_count=$(python3 - "$UPGRADE_ATTEMPT/$phase-attachments/manifest.json" "$phase" <<'PYCOUNT'
import json, re, sys
manifest = json.load(open(sys.argv[1]))
pattern = re.compile(r"upgrade-report-count-" + sys.argv[2] + r"-([0-9]+)")
counts = [int(match.group(1)) for test in manifest for item in test["attachments"]
          if (match := pattern.search(item["suggestedHumanReadableName"]))]
if len(counts) != 1: raise SystemExit("Missing or ambiguous UI report completion count")
print(counts[0])
PYCOUNT
)
    "$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" -- \
     python3 "$UPGRADE_STATE" capture-v2 "$UPGRADE_ATTEMPT" --phase "$phase" --generation "$generation" --report-count "$report_count"
  fi
done
"$UPGRADE_GATE" --agent "$UPGRADE_AGENT" --session "$UPGRADE_SESSION" -- \
 python3 "$UPGRADE_STATE" compare-reports "$UPGRADE_ATTEMPT"
```

The approved plan's `UseDestinationArtifacts` command was corrected through reviewer approval: Xcode rejects it for simulators (“the destination must be an iOS device”). Use the normal generated `.xctestrun`, with `TestHostPath`, `TestBundlePath`, `UITargetAppPath` and `DependentProductPaths` rewritten to the immutable hashed runner and the intended phase app. `prepare-run` rechecks hashes and all four path fields before each invocation; V1 must contain no V2 build-product path. Xcode installs that pinned app in place, preserving data; the separate V2 install pins/verifies the same product.

After **every** test, including reds, require the intended installed `CFBundleVersion` and unchanged V1 sentinel; mismatch is UNRUN, never PASS. V1 capture verifies actual legacy app-group JSON and schema. From that capture until the final V2 relaunch, never uninstall, clear preferences, restore another store or reseed; restarting/rebooting an owner cannot change that premise. Captures stop only the owner's simulator to copy SQLite, sidecars and preferences, then boot that UUID through the same gate.

Reports are read-only, Debug-only and opt-in with `--upgrade-diagnostics`; each must match the source revision, installed build, persona, phase and fresh generation. They supplement hidden persistence assertions and never run migration/repair. `compare-reports` checks original IDs/settings/history, deferred conversion while the original session runs, subsequent conversion, accepted session origins and timer deadlines (one foreground-written supplement retained after Stop), mode/locked flags, saved locations and Emergency carry-over. Missing/stale reports or missing executed tests/screenshots are UNRUN. Compare `writtenAt - setupTime` before accepting the Break first-launch report; exceeding its 30-minute window is UNRUN; use a fresh seed for retry and retain the failed attempt.

Every synthetic NFC request and QR scanner consumption appends phase/generation, request/script index, kind and delivered value to `upgrade-scans.jsonl` at the existing hardware boundary; an exhausted script takes the existing read-error path. The helper requires the exact journey sequence, zero scans in other personas/phases, and the correct persisted origin for every new session. QR also requires its actual scanner UI; NFC calls CoreNFC directly, so no artificial NFC screen is added.

The manual-NFC/QR Specific stop sequence is `wrong,correct` for the legacy alert, then `wrong,wrong,correct` for V2: the first wrong scan opens confirmation, the second shows its inline refusal, and the correct scan dismisses the sheet and stops the session.

Also run `testV2DiagnosticsOptOut` once after a Manual journey using its pinned runner, between helper `begin-optout` and `verify-optout` actions. The helper compares report existence, bytes and modification time through the owner gate; unflagged Debug must create no new report or overwrite the old one. Use a fresh `prepare-run --phase relaunch --generation <new-UUID>` and select only that test; always run `verify-run --phase relaunch` afterward too. This check is additional to the 28 persona journeys.

After each new start, background/return and wait for the fixture-only `upgrade-report-<phase>-<count>` accessibility marker before Stop; wait again before final termination. The marker advances only after successful atomic writes, and its exported count is a lower bound required by capture alongside phase/generation. It has no visible content or routing; confirm XCTest sees it and screenshots remain unchanged.

The same report call retains `upgrade-session-report.json`, keyed by session ID, only while sessions are active; final stopped reports do not overwrite it. Normal Stop clears both origin and timerEndTime, so compare the accepted snapshots instead of stopped rows; Library requires two new snapshots. Capture requires matching source/build/persona/phase/generation/timezone. Timers must visibly decrease; compare their accepted deadline to `floor((startTime + minutes*60)/60)*60` in reference-date seconds within 1 ms, matching production minute-aligned registration, and retain the simulator timezone.

## 3. Inspect, classify and report

The Stats menu driver waits up to two seconds for a hittable row with the same frame across two samples at least 100 ms apart; it permits one retry only if the sheet is still absent and exactly one hittable menu row remains. Record its `stats-menu-retry-1` attachment and screenshot in that persona’s evidence/table; sheet, unique Stats scope and exact history checks still must pass.

Open the exported `.keepAlways` images for V1 immediately before update, V2 first launch/foreground, meaningful actions/refusals/settings and final relaunch. Check actual wording, enabled controls, clipping and visibility; AX existence alone is insufficient. The driver derives weekday order from the simulator's locale, validates saved reminders/domains/30-minute breaks and exercises retained history and Parent/Child edit-lock flows. Timers must visibly decrease; an active-looking card alone is not countdown proof.

For unexplained hangs/errors, [research online early](multi-agent-coordination.md#investigate-unexplained-behavior); preserve links alongside local logs. [Apple forum 805060](https://developer.apple.com/forums/thread/805060) reports simulator-only XCTest connection hangs and an uninstall workaround, which is forbidden after V1 capture. Use `-collect-test-diagnostics never` for these deliberate failure runs; if diagnosis already stalls, follow [Test](development-workflow.md#test). AX recovery uses only the [supported owner-gated reboot](simulator-ui-verification.md#recover-only-your-simulator), after the previous test exits; never erase or ignore errors.

Record PASS/FAIL/UNRUN per persona/runtime and phase, executed test IDs/counts, exact wrapper statuses, product/fixture hashes, the driver source commit and runner product hash for each result, exact V1/V2 commits and installed versions, UUID/`IOS_SIM_GATE_RUNTIME_VERSION`, locale/timezone, report comparisons, inspected screenshot paths and every substituted boundary. Identify any persona passing on an earlier driver so exact-head review can assess whether its evidence still applies. A product regression is FAIL and requires a separate reviewed product repair; never alter expectations or patch the fixture to conceal it. Overall PASS requires all 28 journeys and the opt-out check; send the detailed packet to the orchestrator and record per-persona results on [#506](https://github.com/mnbf9rca/family-foqos/issues/506) once when requested.

Simulator evidence never substitutes for device rows on [#506](https://github.com/mnbf9rca/family-foqos/issues/506) and the [#509 RC checklist](https://github.com/mnbf9rca/family-foqos/issues/509#issuecomment-5968985898); those receive one iOS 27 TestFlight pass after all changes merge.

## 4. Restore only the recorded fixture footprint

After success or failure, inspect each disposable worktree's status against its recorded footprint. Allowed tracked edits are the V1/V2 app entry point, `Foqos/Utils/{StrategyManager,DeviceActivityCenterUtil,NFCScannerUtil,LockCodeManager,RequestAuthorizer}.swift`, `Foqos/Components/Strategy/QRCodeScanner.swift` and `Foqos/Views/HomeView.swift`; allowed copied files are V1 `Foqos/Utils/V1UpgradeSeedData.swift`, V2 `Foqos/Utils/UpgradeDiagnostics.swift` and V2 `FoqosUITests/UpgradePersonaUITests.swift`. Refuse cleanup if any other change exists; never use a blanket reset/clean or touch another stream's worktree.

Restore only those tracked paths from their recorded detached HEAD; remove only the three copied files. Require `git diff --exit-code HEAD -- <recorded tracked paths>` and empty `git status --porcelain`, then `git worktree remove` only the two created worktrees. Keep all immutable products, backups, failures and result bundles; cleanup does not restore previous sessions or erase a simulator.

The feature worktree never receives either patch. Check its diff against the reservations, run fixture/helper checks, and run clean normal Debug/Release builds plus appropriate normal regressions through the gate after fixtures are removed. Preserve existing screenshot-scheme tests and captures. Obtain reviewer exact-head approval before reporting the ready PR; production code carries no seed, diagnostic hook or simulated boundary.
