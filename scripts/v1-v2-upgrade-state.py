#!/usr/bin/env python3
"""Owned simulator app state for docs/v1-v2-upgrade-runbook.md; always enter through xcode-stream."""
import argparse
import json
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


def fail(message, status=1):
    print(f"v1-v2-upgrade-state: {message}", file=sys.stderr)
    raise SystemExit(status)


def run(*command, input=None):
    result = subprocess.run(command, input=input, capture_output=True)
    if result.returncode:
        sys.stderr.buffer.write(result.stderr)
        raise SystemExit(result.returncode if result.returncode > 0 else 128 - result.returncode)
    return result.stdout


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "capture-v1", "capture-v2"))
    parser.add_argument("artifacts", type=Path)
    args = parser.parse_args(argv)
    for tool in ("xcrun", "plutil"):
        if not shutil.which(tool):
            fail(f"{tool} is required", 127)
    env = os.environ
    agent = env.get("IOS_SIM_GATE_AGENT", "")
    if env.get("IOS_SIM_GATE_PROJECT") != "family-foqos" or env.get("IOS_SIM_GATE_SESSION") != "collab" or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", agent):
        fail("requires the Family Foqos agent/collab simulator gate")
    udid = env.get("IOS_SIM_GATE_UDID", "")
    try:
        uuid.UUID(udid)
    except ValueError:
        fail("requires a gate UUID")
    if env.get("IOS_SIM_GATE_DESTINATION") != f"platform=iOS Simulator,id={udid}":
        fail("gate destination does not match UUID")
    cache = Path(env.get("IOS_SIM_GATE_CACHE_HOME", Path.home() / "Library/Caches/ios-sim-gate"))
    expected = cache / "DerivedData/family-foqos" / agent / "session-collab"
    dd = Path(env.get("IOS_SIM_GATE_DERIVED_DATA_PATH", ""))
    if not dd.is_absolute() or ".." in dd.parts or dd.resolve() != expected.resolve():
        fail("refusing DerivedData outside this gate owner")
    root = args.artifacts.resolve(strict=True)
    if root.parent != Path("/private/tmp").resolve() or not root.name.startswith("family-foqos-v1-v2."):
        fail("requires a fresh /private/tmp/family-foqos-v1-v2.* evidence directory")
    owner = {"agent": agent, "session": "collab", "simulator": udid}
    marker = root / "owner.json"
    if args.action == "prepare":
        if marker.exists():
            fail("prepare already ran; use a new evidence directory")
    elif json.loads(marker.read_text()) != owner:
        fail("evidence directory belongs to another gate owner")

    def sim(*words):
        return run("xcrun", "simctl", *words).decode().strip()

    devices = json.loads(sim("list", "devices", "--json"))["devices"]
    matches = [d for rows in devices.values() for d in rows if d["udid"] == udid]
    if len(matches) != 1 or not matches[0].get("isAvailable"):
        fail("owned simulator is unavailable or inventory is unusable")
    if matches[0]["state"] == "Shutdown":
        sim("boot", udid)
    sim("bootstatus", udid, "-b")
    containers = Path.home() / "Library/Developer/CoreSimulator/Devices" / udid / "data/Containers"

    def container(kind, subtree):
        path = Path(sim("get_app_container", udid, BUNDLE, kind))
        if not path.is_absolute() or not path.resolve(strict=True).is_relative_to((containers / subtree).resolve()) or path.resolve() == (containers / subtree).resolve():
            fail(f"refusing {kind} container outside owned simulator storage")
        return path.resolve()

    product = dd / "Build/Products/Debug-iphonesimulator/FamilyFoqos.app"
    product_info = plistlib.loads((product / "Info.plist").read_bytes())
    if product_info["CFBundleIdentifier"] != BUNDLE:
        fail("gate build product is not Family Foqos")
    if args.action == "prepare":
        if product_info["CFBundleShortVersionString"] != "1.31.3":
            fail("prepare requires the preflight-built V1 1.31.3 app")
        apps = json.loads(run("plutil", "-convert", "json", "-o", "-", "--", "-", input=run("xcrun", "simctl", "listapps", udid)))
        if not isinstance(apps, dict):
            fail("installed application inventory is unusable")
        if BUNDLE in apps:
            data = container("data", "Data/Application")
            group = container(GROUP, "Shared/AppGroup")
            sim("shutdown", udid)
            shutil.copytree(data, root / "prior-app-data", symlinks=True)
            shutil.copytree(group, root / "prior-app-group", symlinks=True)
            sim("boot", udid)
            sim("bootstatus", udid, "-b")
            sim("uninstall", udid, BUNDLE)
            # Clear only backed-up remnants if uninstall retains the app-group directory.
            for rel in ("Library/Application Support/default.store", "Library/Application Support/default.store-shm", "Library/Application Support/default.store-wal", f"Library/Preferences/{GROUP}.plist"):
                target = group / rel
                if target.exists():
                    if not target.resolve().is_relative_to(group):
                        fail("refusing app-group file outside captured container")
                    target.unlink()
        shutil.copytree(product, root / "v1.app")
        sim("install", udid, str(product))
        marker.write_text(json.dumps(owner, indent=2) + "\n")
        print(json.dumps({**owner, "preparedVersion": "1.31.3"}))
        return

    app = container("app", "Bundle/Application")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if info["CFBundleIdentifier"] != BUNDLE or version != product_info["CFBundleShortVersionString"] or info["CFBundleVersion"] != product_info["CFBundleVersion"]:
        fail("installed app differs from gate build product")
    data = container("data", "Data/Application")
    group = container(GROUP, "Shared/AppGroup")
    seed = json.loads((data / "Documents/rc-v1-seed.json").read_text())
    if Path(seed["store"]).resolve(strict=True) != (group / "Library/Application Support/default.store").resolve(strict=True):
        fail("seed store is not the captured app-group store")
    stage = args.action.removeprefix("capture-")
    if (root / f"{stage}-app-data").exists() or (root / f"{stage}-app-group").exists():
        fail("capture already exists; preserve it and use a new run for a retry")
    if stage == "v1" and version != "1.31.3":
        fail("V1 capture requires installed 1.31.3")
    if stage == "v2":
        if not version.startswith("2.") or not (root / "v1-app-group").is_dir():
            fail("V2 capture requires a V2 build and preserved V1 capture")
        proof = json.loads((data / "Documents/rc-upgrade-verification.json").read_text())
        if len(proof) != len(seed["profiles"]):
            fail("upgrade evidence does not cover the seeded matrix")
    sim("shutdown", udid)
    if stage == "v1":
        prefs = plistlib.loads((group / f"Library/Preferences/{GROUP}.plist").read_bytes())
        if any(key.startswith("family_foqos_") for key in prefs):
            fail("V1 capture contains stale V2 keys; do not call this an upgrade pass")
        active = json.loads(prefs["activeScheduleSession"])
        profiles = json.loads(prefs["profileSnapshots"])
        if active["id"] != seed["sessionID"] or "oneMoreMinuteUsed" in active or set(profiles) != {p["id"] for p in seed["profiles"]}:
            fail("V1 shared JSON is not the freshly seeded legacy shape")
        (root / "v1-active-session.json").write_text(json.dumps(active, indent=2) + "\n")
        (root / "v1-profile-snapshots.json").write_text(json.dumps(profiles, indent=2) + "\n")
    shutil.copytree(data, root / f"{stage}-app-data", symlinks=True)
    shutil.copytree(group, root / f"{stage}-app-group", symlinks=True)
    manifest = {**owner, "version": version, "build": info["CFBundleVersion"], "profiles": len(seed["profiles"])}
    (root / f"{stage}-installed.json").write_text(json.dumps(manifest, indent=2) + "\n")
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
