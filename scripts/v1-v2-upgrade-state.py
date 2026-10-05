#!/usr/bin/env python3
"""Owned, pinned simulator install-over evidence; enter through xcode-stream.sh."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import uuid

BUNDLE = "com.cynexia.family-foqos"
GROUP = "group.com.cynexia.family-foqos"
PERSONAS = ("manual", "nfc", "qr", "nfc-timer", "qr-timer", "shortcut-timer", "manual-nfc", "manual-qr", "schedule", "break", "emergency", "parent", "child", "library")
PHASES = ("first-launch", "journey", "relaunch")


def fail(message, status=1):
    print(f"v1-v2-upgrade-state: {message}", file=sys.stderr)
    raise SystemExit(status)


def run(*command, input=None):
    result = subprocess.run(command, input=input, capture_output=True)
    if result.returncode:
        sys.stderr.buffer.write(result.stderr)
        raise SystemExit(result.returncode if result.returncode > 0 else 128 - result.returncode)
    return result.stdout


def digest(path):
    """Hash names and bytes, including symlink targets; refuse escaping product links."""
    path = path.resolve(strict=True)
    value = hashlib.sha256()
    for item in sorted(path.rglob("*")):
        value.update(str(item.relative_to(path)).encode() + b"\0")
        if item.is_symlink():
            if not item.resolve(strict=True).is_relative_to(path):
                fail("product symlink escapes its bundle")
            value.update(os.readlink(item).encode())
        elif item.is_file():
            value.update(item.read_bytes())
    return value.hexdigest()


def product(path, version=None, runner=False):
    path = path.resolve(strict=True)
    info = plistlib.loads((path / "Info.plist").read_bytes())
    bundle = info["CFBundleIdentifier"]
    if (not runner and bundle != BUNDLE) or (runner and not bundle.endswith(".xctrunner")):
        fail("unexpected application/runner bundle identifier")
    actual_version = info["CFBundleShortVersionString"]
    if version and not actual_version.startswith(version):
        fail(f"product requires version {version}")
    if runner and not (path / "PlugIns/FoqosUITests.xctest").is_dir():
        fail("runner lacks the expected external FoqosUITests bundle")
    return {"bundle": bundle, "version": actual_version, "build": str(info["CFBundleVersion"]), "sha256": digest(path)}


def write(path, value):
    # Evidence files are new, never overwritten by another attempt.
    with path.open("x") as output:
        json.dump(value, output, indent=2)
        output.write("\n")


def pin_xctestrun(source, destination, runner, runner_path, app_path):
    tree = plistlib.loads(source.read_bytes())
    configurations = tree.get("TestConfigurations")
    if not isinstance(configurations, list) or len(configurations) != 1:
        fail("fixtures out of date: unexpected xctestrun configurations")
    targets = configurations[0].get("TestTargets")
    if not isinstance(targets, list) or len(targets) != 1:
        fail("fixtures out of date: expected one external UI target")
    target = targets[0]
    if target.get("BlueprintName") != "FoqosUITests" or not target.get("IsUITestBundle"):
        fail("fixtures out of date: unexpected external runner structure")
    for key in ("UseDestinationArtifacts", "TestBundleDestinationRelativePath"):
        target.pop(key, None)
    target.update(TestHostBundleIdentifier=runner["bundle"], UITargetAppBundleIdentifier=BUNDLE,
                  TestHostPath=str(runner_path), TestBundlePath=str(runner_path / "PlugIns/FoqosUITests.xctest"),
                  UITargetAppPath=str(app_path))
    target["DependentProductPaths"] = [target[key] for key in ("TestHostPath", "TestBundlePath", "UITargetAppPath")]
    tree.pop("CodeCoverageBuildableInfos", None)
    with destination.open("xb") as output:
        plistlib.dump(tree, output)


def compare_scans(persona, phase, generation, entries):
    entries = list(entries)
    values = []
    if phase in ("journey", "relaunch"):
        if persona in ("nfc", "qr"): values = ["wrong", "correct", "correct", "correct"]
        elif persona in ("manual-nfc", "manual-qr"): values = ["wrong", "correct", "wrong", "wrong", "correct"]
        elif persona in ("nfc-timer", "qr-timer"): values = ["correct", "correct"]
    kind = "qr" if "qr" in persona else "nfc"
    if phase == "relaunch" and entries:
        generation = entries[0].get("generation")  # Preserve the already-verified journey log; relaunch must append nothing.
    expected = [{"phase": "journey", "generation": generation, "kind": kind, "requestIndex": i,
                 "scriptIndex": i, "value": value} for i, value in enumerate(values)]
    if entries != expected:
        fail(f"FAIL: {phase}: required scan delivery sequence differs")


def compare_report(seed, report, phase, session_report=None, scan_entries=()):
    """Assert hidden persisted facts; screenshots/UI remain the behavioral oracle."""
    def require(condition, message):
        if not condition:
            fail(f"FAIL: {phase}: {message}")
    rows = {p["id"]: p for p in report["profiles"]}
    sessions = {s["id"]: s for s in report["sessions"]}
    persona = seed["persona"]
    compare_scans(persona, phase, report.get("generation"), scan_entries)
    original_session_ids = {seed["historyID"]} | ({seed["sessionID"]} if seed.get("sessionID") else set())
    new_sessions = [session for key, session in sessions.items() if key not in original_session_ids]
    expected_new = 0 if phase == "first-launch" else 2 if persona == "library" else 1
    require(len(sessions) == len(report["sessions"]) == len(original_session_ids) + expected_new, "session count changed (duplicate or refused start persisted)")
    accepted = {}
    if phase != "first-launch":
        if session_report is None: fail("UNRUN: missing accepted session supplement")
        accepted = {key: row for key, row in session_report["sessions"].items() if key not in original_session_ids}
        require(set(accepted) == {row["id"] for row in new_sessions}, "accepted session snapshots missing or unexpected")
        expected_origin = persona if persona in ("nfc", "qr") else "manual"
        for key, row in accepted.items():
            require(row["active"] is True and row["schema"] == 3 and row["profileID"] == sessions[key]["profileID"]
                    and row["startTime"] == sessions[key]["startTime"], "accepted session identity/start/schema differs")
            require(isinstance(row.get("origin"), dict) and row["origin"].get("kind") == expected_origin,
                    "post-update session did not originate through its required start method")
    if persona == "break" and phase == "first-launch" and report["writtenAt"] >= seed["session"]["breakStartTime"] + 1800:
        fail("UNRUN: the seeded break expired before first-launch evidence")
    expected_count = len(seed["profiles"]) + (2 if persona == "child" and phase != "first-launch" else 0)
    require(report["profileCount"] == len(rows) == expected_count, "profile count/identity changed")
    require(report["mode"] == seed["mode"] and report["syncEnabled"] is False, "mode or sync changed")
    require(report["emergencyResetDays"] == seed["emergencyWeeks"] * 7, "emergency reset period changed")
    remaining = seed["emergencyRemaining"] - (1 if persona in ("emergency", "shortcut-timer", "library") and phase != "first-launch" else 0)
    require(report["emergencyRemaining"] == remaining, "emergency allowance changed/refilled")
    active_id = seed.get("sessionID")
    require(report["activeSessionCount"] == (1 if active_id and phase == "first-launch" else 0), "active session count changed")
    retained = ("name", "order", "isManaged", "domains", "enableBreaks", "breakTimeInMinutes", "enableStrictMode",
                "reminderTimeInSeconds", "customReminderMessage", "enableAllowMode", "enableAllowModeDomains", "enableSafariBlocking")
    for original in seed["profiles"]:
        require(original["id"] in rows, "original profile missing")
        row = rows[original["id"]]
        for key in retained:
            if key in original:
                require(row.get(key) == original[key], f"retained profile setting changed: {key}")
        deferred = phase == "first-launch" and active_id and original["id"] == seed["session"].get("blockedProfileId", original["id"] if len(seed["profiles"]) == 1 else None)
        require(row["schema"] == (1 if deferred else 3), "conversion was premature or incomplete")
        require(row["needsMigration"] == bool(deferred) and not row["newerSchema"], "migration flags differ")
        invalid_timer = persona == "library" and original["name"] == "RC Library 06" and phase == "first-launch"
        if not deferred:
            require(row["invalid"] == invalid_timer, "converted validity differs")
            strategy = original.get("blockingStrategyId")
            if strategy:
                start, stop = row["startTriggers"], row["stopConditions"]
                plain_nfc, plain_qr = strategy == "NFCBlockingStrategy", strategy == "QRCodeBlockingStrategy"
                require(start["anyNFC"] == plain_nfc and start["anyQR"] == plain_qr and start["manual"] == (not plain_nfc and not plain_qr), "converted start methods differ")
                require(stop["manual"] == (strategy == "ManualBlockingStrategy"), "converted Tap stop differs")
                if strategy in ("NFCTimerBlockingStrategy", "QRTimerBlockingStrategy", "ShortcutTimerBlockingStrategy"):
                    minutes = None if invalid_timer else 60 if persona == "library" and original["name"] == "RC Library 06" else 37
                    require(stop["timer"] and stop.get("timerDurationMinutes") == minutes, "saved/repaired timer duration differs")
                if strategy == "NFCBlockingStrategy": require(stop["nfc"] == "same", "NFC Same stop lost")
                if strategy == "QRCodeBlockingStrategy": require(stop["qr"] == "same", "QR Same stop lost")
                if strategy == "NFCManualBlockingStrategy": require(stop["nfc"] == "specific" and row["stopNFCTagIds"] == ["04AABBCCDD"], "Specific NFC stop lost")
                if strategy == "QRManualBlockingStrategy": require(stop["qr"] == "specific" and len(row["stopQRCodeIds"]) == 1, "Specific QR stop lost")
    if persona == "child" and phase != "first-launch":
        created = [row for key, row in rows.items() if key not in {p["id"] for p in seed["profiles"]}]
        require({row["name"] for row in created} == {"RC Child Created", "RC child Copy"}
                and all(row["isManaged"] is False and row["schema"] == 3 for row in created), "Child-created/duplicated profiles must remain unlocked")
        require(all(row["startTriggers"]["manual"] is True and row["stopConditions"]["manual"] is True for row in created),
                "Child-created/duplicated manual start or stop missing")
    if active_id:
        require(active_id in sessions, "original session missing/replaced")
        original, current = seed["session"], sessions[active_id]
        for key in ("startTime", "breakStartTime", "breakUsed"):
            if key in original:
                require(current.get(key) == original[key], f"original session field changed: {key}")
        require(current["active"] == (phase == "first-launch"), "original session end state differs")
        if phase == "first-launch" and persona == "break":
            require(current.get("breakEndTime") is None, "retained break ended before first launch")
        if phase != "first-launch" and persona == "break":
            require(current.get("breakEndTime") is not None, "used break state was lost")
    require(seed["historyID"] in sessions and sessions[seed["historyID"]]["active"] is False, "completed history lost")
    for key in ("startTime", "endTime"):
        if "history" in seed:
            require(sessions[seed["historyID"]].get(key) == seed["history"][key], "completed history time changed")
    if phase != "first-launch" and persona in ("nfc-timer", "qr-timer", "shortcut-timer", "library"):
        minutes = 60 if persona == "library" else 37
        timers = [row for row in accepted.values() if row.get("timerEndTime") is not None]
        require(len(timers) == 1, "missing or duplicate accepted countdown")
        timer = timers[0]
        expected_deadline = math.floor((timer["startTime"] + minutes * 60) / 60) * 60
        require(abs(timer["timerEndTime"] - expected_deadline) <= 0.001, "accepted timer deadline differs from canonical minute boundary")
    if persona == "schedule":
        main = rows[seed["profiles"][0]["id"]]
        if phase != "first-launch":
            require(main["startTriggers"]["schedule"] and main["stopConditions"]["schedule"] and main["scheduleLastStoppedAt"] is not None, "schedule conversion/occurrence stop lost")
            original = seed["profiles"][0]["schedule"]
            for key, prefix in (("startSchedule", "start"), ("stopSchedule", "end")):
                converted = main[key]
                require(converted["days"] == original["days"] and converted["hour"] == original[prefix + "Hour"]
                        and converted["minute"] == original[prefix + "Minute"], "converted schedule recurrence changed")
    if persona == "library":
        require(len(report["locations"]) == 1, "saved location count changed")
        location = report["locations"][0]
        require((location["name"], location["latitude"], location["longitude"], location["radius"]) == ("RC Study", 51.5054, -0.0235, 500), "saved location changed")
        reference = rows[seed["profiles"][22]["id"]].get("geofenceRule")
        require(reference is not None and location["id"] in json.dumps(reference), "saved location reference lost")
    return {"phase": phase, "hiddenAssertions": "PASS"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "install-runner", "prepare-run", "capture-v1", "install-v2", "capture-v2", "verify-run", "compare-reports", "preserve-products", "begin-optout", "verify-optout"))
    parser.add_argument("artifacts", type=Path)
    parser.add_argument("--persona", choices=PERSONAS)
    parser.add_argument("--v1-app", type=Path)
    parser.add_argument("--v2-app", type=Path)
    parser.add_argument("--runner-app", type=Path)
    parser.add_argument("--xctestrun", type=Path)
    parser.add_argument("--phase", choices=("v1", *PHASES))
    parser.add_argument("--generation")
    parser.add_argument("--source-revision")
    parser.add_argument("--report-count", type=int)
    args = parser.parse_args(argv)
    required = {"prepare": (args.persona, args.v1_app), "install-runner": (args.runner_app, args.xctestrun),
                "install-v2": (args.v2_app, args.source_revision), "capture-v2": (args.phase in PHASES, args.generation, args.report_count is not None and args.report_count > 0),
                "prepare-run": (args.phase, args.generation), "verify-run": (args.phase,), "preserve-products": (args.phase in ("v1", "first-launch"), args.source_revision)}
    if not all(required.get(args.action, (True,))):
        fail("missing required persona, product, phase or generation")
    if args.source_revision and not re.fullmatch(r"[0-9a-f]{40}", args.source_revision):
        fail("source revision must be a full commit SHA")
    for tool in ("xcrun", "plutil"):
        if not shutil.which(tool):
            fail(f"{tool} is required", 127)
    env = os.environ
    agent, session = env.get("IOS_SIM_GATE_AGENT", ""), env.get("IOS_SIM_GATE_SESSION", "")
    if env.get("IOS_SIM_GATE_PROJECT") != "family-foqos" or session not in ("collab", "collab-ios27") or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", agent):
        fail("requires the Family Foqos collab (or authorized collab-ios27) gate")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", env.get("IOS_SIM_GATE_RUNTIME_VERSION", "")):
        fail("gate runtime version is missing or unusable")
    if session == "collab-ios27" and not env["IOS_SIM_GATE_RUNTIME_VERSION"].startswith("27."):
        fail("authorized collab-ios27 owner must actually run iOS 27")
    udid = env.get("IOS_SIM_GATE_UDID", "")
    uuid.UUID(udid)
    if env.get("IOS_SIM_GATE_DESTINATION") != f"platform=iOS Simulator,id={udid}":
        fail("gate destination does not match UUID")
    cache = Path(env.get("IOS_SIM_GATE_CACHE_HOME", Path.home() / "Library/Caches/ios-sim-gate"))
    expected = cache / "DerivedData/family-foqos" / agent / f"session-{session}"
    dd = Path(env.get("IOS_SIM_GATE_DERIVED_DATA_PATH", ""))
    if not dd.is_absolute() or ".." in dd.parts or dd.resolve() != expected.resolve():
        fail("refusing DerivedData outside this gate owner")
    for app_path in (args.v1_app, args.v2_app, args.runner_app):
        if app_path:
            resolved = app_path.resolve(strict=True)
            derived_root = (cache / "DerivedData").resolve()
            if resolved.is_relative_to(derived_root) and not resolved.is_relative_to(dd.resolve()):
                fail("refusing another owner's build product")
    root = args.artifacts.resolve(strict=True)
    if root.parent != Path("/private/tmp").resolve() or not root.name.startswith("family-foqos-v1-v2."):
        fail("requires a fresh /private/tmp/family-foqos-v1-v2.* evidence directory")
    owner = {"agent": agent, "session": session, "simulator": udid}
    marker = root / "owner.json"
    if args.action == "preserve-products":
        version = "v1" if args.phase == "v1" else "v2"
        products = dd / "Build/Products"
        source_app = products / "Debug-iphonesimulator/FamilyFoqos.app"
        selected = product(source_app, "1.31.3" if version == "v1" else "2.")
        if version == "v1" and selected["version"] != "1.31.3":
            fail("requires exact frozen V1")
        if version == "v2":
            sources = list(products.glob("FoqosScreenshots*.xctestrun"))
            if len(sources) != 1:
                fail("fixtures out of date: expected one generated UI xctestrun")
            tree = plistlib.loads(sources[0].read_bytes())
            configurations = tree["TestConfigurations"]
            if len(configurations) != 1 or len(configurations[0]["TestTargets"]) != 1:
                fail("fixtures out of date: expected one generated UI target")
            target = configurations[0]["TestTargets"][0]
            if target.get("BlueprintName") != "FoqosUITests" or not target.get("IsUITestBundle"):
                fail("fixtures out of date: external UI target missing")
            runner_path = Path(target["TestHostPath"].replace("__TESTROOT__", str(products))).resolve(strict=True)
            if not runner_path.is_relative_to(products.resolve(strict=True)):
                fail("runner path escapes owned products")
            runner = product(runner_path, runner=True)
        # Validate every input before copying; existing evidence is never overwritten.
        for name in ([f"{version}.app"] + (["runner.app", "generated.xctestrun"] if version == "v2" else [])):
            if (root / name).exists(): fail("product snapshot already exists")
        shutil.copytree(source_app, root / f"{version}.app", symlinks=True)
        if product(root / f"{version}.app") != selected: fail("app changed while preserving products")
        if version == "v2":
            shutil.copytree(runner_path, root / "runner.app", symlinks=True)
            if product(root / "runner.app", runner=True) != runner: fail("runner changed while preserving products")
            shutil.copy2(sources[0], root / "generated.xctestrun")
        write(root / f"products-{version}.json", {**owner, "source": args.source_revision, "app": selected,
              "runtime": env.get("IOS_SIM_GATE_RUNTIME_VERSION", "unknown"), **({"runner": runner} if version == "v2" else {})})
        print(json.dumps({"products": str(root), "phase": version, **selected}))
        return
    if args.action == "prepare":
        if marker.exists():
            fail("prepare already ran; preserve evidence and use a new directory")
        selected = product(args.v1_app, "1.31.3")
        if selected["version"] != "1.31.3":
            fail("requires exact frozen V1 1.31.3")
    else:
        if json.loads(marker.read_text()) != owner:
            fail("evidence belongs to another gate owner")
        state = json.loads((root / "prepared.json").read_text())
        if args.action == "compare-reports":
            seed = json.loads((root / "v1-app-data/Documents/rc-v1-seed.json").read_text())
            session_path = root / "v2-journey-session-report.json"
            session_report = json.loads(session_path.read_text()) if session_path.is_file() else None
            results = [compare_report(seed, json.loads((root / f"v2-{phase}-report.json").read_text()), phase, session_report,
                                      json.loads((root / f"v2-{phase}-scans.json").read_text())) for phase in PHASES]
            write(root / "hidden-comparisons.json", results)
            print(json.dumps(results))
            return
        if args.action == "install-v2":
            if not (root / "v1-installed.json").is_file() or (root / "v2-installed.json").exists():
                fail("install-over requires a preserved V1 capture and no prior V2 installation")
            selected = product(args.v2_app, "2.")
        elif args.action == "install-runner":
            if (root / "runner.json").exists():
                fail("runner is already pinned")
            selected = product(args.runner_app, runner=True)
            if args.xctestrun:
                # Validate before any simulator change.
                pin_xctestrun(args.xctestrun, root / "ui.xctestrun", selected, root / "runner.app", root / "v1.app")
                shutil.copy2(args.xctestrun, root / "generated.xctestrun")
        elif args.action == "prepare-run":
            uuid.UUID(args.generation)
            runner = json.loads((root / "runner.json").read_text())
            version = "v1" if args.phase == "v1" else "v2"
            candidate = state["product"] if version == "v1" else json.loads((root / "v2-installed.json").read_text())
            if product(root / "runner.app", runner=True) != runner or product(root / f"{version}.app") != candidate:
                fail("pinned runner or phase app changed")
            destination = root / f"{args.phase}.{args.generation}.xctestrun"
            pin_xctestrun(root / "generated.xctestrun", destination, runner, root / "runner.app", root / f"{version}.app")
            tree = plistlib.loads(destination.read_bytes())
            target = tree["TestConfigurations"][0]["TestTargets"][0]
            expected_paths = {"TestHostPath": str(root / "runner.app"),
                              "TestBundlePath": str(root / "runner.app/PlugIns/FoqosUITests.xctest"),
                              "UITargetAppPath": str(root / f"{version}.app")}
            if any(target[key] != value for key, value in expected_paths.items()) or set(target["DependentProductPaths"]) != set(expected_paths.values()):
                fail("xctestrun contains unpinned phase products")
            target.setdefault("EnvironmentVariables", {}).update(
                UPGRADE_PERSONA=state["persona"], UPGRADE_STORE_TOKEN=state["storeToken"], UPGRADE_GENERATION=args.generation,
                UPGRADE_SOURCE_REVISION=("V1-589bee9228abb5b32cc3506f7c0e23782a571d03" if version == "v1" else json.loads((root / "v2-source.json").read_text())["commit"]),
                UPGRADE_SCANS=("wrong,correct,wrong,wrong,correct" if state["persona"] in ("manual-nfc", "manual-qr")
                               else "wrong,correct,correct,correct" if state["persona"] in ("nfc", "qr") else "correct,correct,correct"))
            destination.write_bytes(plistlib.dumps(tree))
            print(json.dumps({"xctestrun": str(destination), "phase": args.phase, "generation": args.generation, "product": candidate}))
            return
        elif args.action in ("begin-optout", "verify-optout") or (args.action == "verify-run" and args.phase != "v1"):
            if not (root / "v2-installed.json").is_file(): fail("UNRUN: no pinned V2 install")
        elif args.action == "capture-v2":
            uuid.UUID(args.generation)
            if not (root / "v2-installed.json").is_file():
                fail("capture requires a pinned V2 install")
            if (root / f"v2-{args.phase}-installed.json").exists():
                fail("phase already captured; preserve evidence")
        elif args.action == "capture-v1" and (root / "v1-installed.json").exists():
            fail("V1 already captured; preserve evidence")

    def sim(*words):
        return run("xcrun", "simctl", *words).decode().strip()

    devices = json.loads(sim("list", "devices", "--json"))["devices"]
    matches = [d for rows in devices.values() for d in rows if d["udid"] == udid]
    if len(matches) != 1 or not matches[0].get("isAvailable"):
        fail("owned simulator inventory is unusable")
    if matches[0]["state"] == "Shutdown":
        sim("boot", udid)
    sim("bootstatus", udid, "-b")
    containers = Path.home() / "Library/Developer/CoreSimulator/Devices" / udid / "data/Containers"

    def container(kind, subtree):
        path = Path(sim("get_app_container", udid, BUNDLE, kind))
        boundary = (containers / subtree).resolve()
        if not path.is_absolute() or not path.resolve(strict=True).is_relative_to(boundary) or path.resolve() == boundary:
            fail(f"refusing {kind} container outside owned simulator")
        return path.resolve()

    if args.action == "prepare":
        apps = json.loads(run("plutil", "-convert", "json", "-o", "-", "--", "-", input=run("xcrun", "simctl", "listapps", udid)))
        if not isinstance(apps, dict):
            fail("installed application inventory is unusable")
        if BUNDLE in apps:
            data, group = container("data", "Data/Application"), container(GROUP, "Shared/AppGroup")
            sim("shutdown", udid)
            shutil.copytree(data, root / "prior-app-data", symlinks=True)
            shutil.copytree(group, root / "prior-app-group", symlinks=True)
            sim("boot", udid)
            sim("bootstatus", udid, "-b")
            sim("uninstall", udid, BUNDLE)
            for rel in ("Library/Application Support/default.store", "Library/Application Support/default.store-shm", "Library/Application Support/default.store-wal", f"Library/Preferences/{GROUP}.plist"):
                target = group / rel
                if target.exists():
                    if not target.resolve().is_relative_to(group):
                        fail("refusing app-group file outside backed-up container")
                    target.unlink()
        shutil.copytree(args.v1_app, root / "v1.app", symlinks=True)
        if product(root / "v1.app") != selected:
            fail("V1 changed while pinning")
        sim("install", udid, str(root / "v1.app"))
        disposable = {"persona": args.persona, "token": str(uuid.uuid4())}
        documents = container("data", "Data/Application") / "Documents"
        documents.mkdir(exist_ok=True)
        write(documents / "upgrade-disposable.json", disposable)
        write(marker, owner)
        write(root / "prepared.json", {**owner, "persona": args.persona, "product": selected,
                                      "storeToken": disposable["token"],
                                      "runtime": env.get("IOS_SIM_GATE_RUNTIME_VERSION", "unknown")})
        print(json.dumps({**owner, "persona": args.persona, "product": selected}))
        return
    if args.action in ("install-runner", "install-v2"):
        name, source = ("runner", args.runner_app) if args.action == "install-runner" else ("v2", args.v2_app)
        shutil.copytree(source, root / f"{name}.app", symlinks=True)
        if product(root / f"{name}.app", runner=name == "runner") != selected:
            fail("product changed while pinning")
        sim("install", udid, str(root / f"{name}.app"))
        write(root / ("runner.json" if name == "runner" else "v2-installed.json"), selected)
        if name == "v2":
            write(root / "v2-source.json", {"commit": args.source_revision})
        return

    app = container("app", "Bundle/Application")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    selected = state["product"] if args.action == "capture-v1" or (args.action == "verify-run" and args.phase == "v1") else json.loads((root / "v2-installed.json").read_text())
    if any(str(info[key]) != selected[field] for key, field in (("CFBundleIdentifier", "bundle"), ("CFBundleShortVersionString", "version"), ("CFBundleVersion", "build"))):
        fail("UNRUN: installed app differs from pinned product")
    data, group = container("data", "Data/Application"), container(GROUP, "Shared/AppGroup")
    seed_path = data / "Documents/rc-v1-seed.json"
    seed = json.loads(seed_path.read_text())
    if seed["persona"] != state["persona"] or Path(seed["store"]).resolve(strict=True) != (group / "Library/Application Support/default.store").resolve(strict=True):
        fail("seed is not this persona's captured app-group store")
    if args.action in ("begin-optout", "verify-optout"):
        if seed_path.read_bytes() != (root / "v1-app-data/Documents/rc-v1-seed.json").read_bytes():
            fail("UNRUN: V1 sentinel changed during opt-out check")
        report_path = data / "Documents/upgrade-report.json"
        snapshot = {"exists": report_path.exists()}
        if snapshot["exists"]:
            snapshot.update(sha256=hashlib.sha256(report_path.read_bytes()).hexdigest(), mtimeNs=report_path.stat().st_mtime_ns)
        if args.action == "begin-optout":
            write(root / "optout-before.json", snapshot)
        elif snapshot != json.loads((root / "optout-before.json").read_text()):
            fail("FAIL: unflagged Debug created or changed the diagnostic report")
        else:
            write(root / "optout-result.json", {"diagnosticsOptOut": "PASS", **snapshot})
        print(json.dumps(snapshot))
        return
    if args.action == "verify-run":
        baseline = root / "v1-app-data/Documents/rc-v1-seed.json"
        if baseline.exists() and seed_path.read_bytes() != baseline.read_bytes():
            fail("UNRUN: V1 sentinel changed after the test")
        if not baseline.exists() and args.phase != "v1":
            fail("UNRUN: missing captured V1 sentinel")
        print(json.dumps({"phase": args.phase, "installed": selected, "sentinel": "verified"}))
        return
    stage = "v1" if args.action == "capture-v1" else f"v2-{args.phase}"
    if args.action == "capture-v2":
        if seed_path.read_bytes() != (root / "v1-app-data/Documents/rc-v1-seed.json").read_bytes():
            fail("V1 sentinel changed during install-over")
        report = json.loads((data / "Documents/upgrade-report.json").read_text())
        if report.get("phase") != args.phase or report.get("generation") != args.generation or report.get("persona") != seed["persona"] or report.get("build") != selected["build"] or report.get("version") != selected["version"] or report.get("source") != json.loads((root / "v2-source.json").read_text())["commit"]:
            fail("missing/stale/wrong-phase diagnostic report")
        if not isinstance(report.get("count"), int) or report["count"] < args.report_count:
            fail("UNRUN: diagnostic report predates the UI completion marker")
        scan_path = data / "Documents/upgrade-scans.jsonl"
        scan_entries = [json.loads(line) for line in scan_path.read_text().splitlines()] if scan_path.exists() else []
        compare_scans(seed["persona"], args.phase, args.generation, scan_entries)
        write(root / f"{stage}-scans.json", scan_entries)
        session_report = None
        if args.phase == "journey":
            session_report = json.loads((data / "Documents/upgrade-session-report.json").read_text())
            if any(session_report.get(key) != report.get(key) for key in ("phase", "generation", "persona", "source", "version", "build", "timeZone")):
                fail("UNRUN: missing/stale/wrong-phase accepted session supplement")
    sim("shutdown", udid)
    if stage == "v1":
        prefs = plistlib.loads((group / f"Library/Preferences/{GROUP}.plist").read_bytes())
        if any(key.startswith("family_foqos_") for key in prefs):
            fail("V1 capture contains V2 preference keys")
        profiles = json.loads(prefs["profileSnapshots"])
        active = json.loads(prefs["activeScheduleSession"]) if prefs.get("activeScheduleSession") else None
        if set(profiles) != {p["id"] for p in seed["profiles"]} or (active or {}).get("id") != seed.get("sessionID") or (active and "oneMoreMinuteUsed" in active):
            fail("V1 shared JSON differs from actual legacy seed shape")
        write(root / "v1-active-session.json", active)
        write(root / "v1-profile-snapshots.json", profiles)
    shutil.copytree(data, root / f"{stage}-app-data", symlinks=True)
    shutil.copytree(group, root / f"{stage}-app-group", symlinks=True)
    manifest = {**owner, "persona": seed["persona"], **selected, "profiles": len(seed["profiles"])}
    if args.action == "capture-v2":
        manifest.update(phase=args.phase, generation=args.generation)
        write(root / f"{stage}-report.json", report)
        if session_report is not None: write(root / f"{stage}-session-report.json", session_report)
    write(root / f"{stage}-installed.json", manifest)
    sim("boot", udid)
    sim("bootstatus", udid, "-b")
    print(json.dumps(manifest))


def entry(argv=None):
    try:
        main(argv)
    except (OSError, ValueError, KeyError, TypeError) as error:
        fail(f"unusable input/state: {error}")


if __name__ == "__main__":
    entry()
