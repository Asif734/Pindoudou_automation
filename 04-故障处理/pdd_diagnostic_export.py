#!/usr/bin/env python3
"""Export an allowlisted PDD diagnostic ZIP without customer or credential data."""

from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import subprocess
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path


RUNTIME_NAME = "拼多多AX记录-任务隔离候选版"
APP_PATH = Path("/Applications/拼多多全自动客服-任务隔离候选版.app")


def _tree_bytes(path: Path) -> int:
    total = 0
    if not path.exists() or path.is_symlink():
        return 0
    for directory, names, files in os.walk(path, followlinks=False):
        names[:] = [name for name in names if not (Path(directory) / name).is_symlink()]
        for name in files:
            item = Path(directory) / name
            if not item.is_symlink():
                try:
                    total += item.stat().st_size
                except OSError:
                    pass
    return total


def _app_summary(app: Path) -> dict:
    result = {"installed": app.is_dir(), "path": str(app)}
    plist = app / "Contents/Info.plist"
    if plist.is_file():
        with plist.open("rb") as handle:
            info = plistlib.load(handle)
        result.update(bundleIdentifier=info.get("CFBundleIdentifier"), version=info.get("CFBundleShortVersionString"))
    if app.is_dir():
        check = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True)
        result["signatureValid"] = check.returncode == 0
    return result


def export(runtime: Path, output_directory: Path, now: datetime, app: Path = APP_PATH) -> Path:
    runtime = runtime.expanduser()
    if runtime.name != RUNTIME_NAME:
        raise ValueError("invalid runtime root")
    output_directory.mkdir(parents=True, exist_ok=True)
    output = output_directory / f"拼多多客服-脱敏诊断包-{now.strftime('%Y%m%d-%H%M%S')}.zip"
    video_state = runtime / "videos" / "transfer-state.json"
    phase_counts: dict[str, int] = {}
    if video_state.is_file() and not video_state.is_symlink():
        try:
            for record in json.loads(video_state.read_text(encoding="utf-8")).get("records", []):
                phase = str(record.get("phase", "unknown"))
                phase_counts[phase] = phase_counts.get(phase, 0) + 1
        except (OSError, UnicodeError, json.JSONDecodeError):
            phase_counts = {"unreadable": 1}
    summary = {
        "schemaVersion": 1,
        "createdAt": now.astimezone(timezone.utc).isoformat(),
        "macOS": platform.mac_ver()[0],
        "machine": platform.machine(),
        "runtimeBytes": _tree_bytes(runtime),
        "videoPhaseCounts": phase_counts,
        "app": _app_summary(app),
        "privacy": {
            "customerMessagesIncluded": False,
            "customerMediaIncluded": False,
            "codexCredentialsIncluded": False,
            "operatorIdentityIncluded": False,
        },
    }
    with tempfile.TemporaryDirectory(prefix="pdd-diagnostic-") as temp:
        report = Path(temp) / "system-summary.json"
        report.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.write(report, report.name)
    return output


def self_test() -> None:
    with tempfile.TemporaryDirectory() as temp:
        base = Path(temp)
        root = base / RUNTIME_NAME
        root.mkdir()
        (root / "secret-customer-message.txt").write_text("绝密客户正文", encoding="utf-8")
        output = export(root, base / "out", datetime(2026, 9, 4, tzinfo=timezone.utc), base / "missing.app")
        with zipfile.ZipFile(output) as archive:
            assert archive.namelist() == ["system-summary.json"]
            assert "绝密客户正文" not in archive.read("system-summary.json").decode()
    print("pdd_diagnostic_export self-test PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-root", type=Path, default=Path.home() / "Library/Application Support/PDDAutoReplyTaskIsolationCandidate" / RUNTIME_NAME)
    parser.add_argument("--output-directory", type=Path, default=Path.home() / "Desktop")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    print(export(args.runtime_root, args.output_directory, datetime.now(timezone.utc)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
