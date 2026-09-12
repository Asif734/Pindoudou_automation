#!/usr/bin/env python3
"""Safely prune completed PDD video artifacts after 30 days or above 10 GiB."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import stat
import tempfile
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path


RUNTIME_NAME = "拼多多AX记录-任务隔离候选版"
HASH_LENGTH = 64
APPLE_REFERENCE_UNIX = 978307200.0


@dataclass
class Report:
    checked_at: str
    trigger: str
    bytes_before: int
    bytes_after: int
    deleted_message_hashes: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    status: str = "ok"


def _valid_hash(value: object) -> bool:
    return isinstance(value, str) and len(value) == HASH_LENGTH and all(c in "0123456789abcdef" for c in value)


def _date(value: object) -> datetime | None:
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(float(value) + APPLE_REFERENCE_UNIX, timezone.utc)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
        except ValueError:
            return None
    return None


def _tree_bytes(path: Path) -> int:
    if not path.exists() or path.is_symlink():
        return 0
    if path.is_file():
        return path.stat().st_size
    total = path.stat().st_size
    for child in path.iterdir():
        total += _tree_bytes(child)
    return total


def _safe_tree(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(root)
    except ValueError:
        return False
    if path.is_symlink():
        return False
    if path.is_dir():
        return all(_safe_tree(child, root) for child in path.iterdir())
    return not path.exists() or stat.S_ISREG(path.lstat().st_mode)


def _atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run(runtime: Path, *, now: datetime, dry_run: bool, high: int = 10 * 1024**3, target: int = 8 * 1024**3) -> Report:
    runtime = runtime.expanduser()
    if runtime.name != RUNTIME_NAME or runtime.is_symlink():
        return Report(now.isoformat(), "blocked", 0, 0, errors=["invalidRuntimeRoot"], status="blocked")
    runtime.mkdir(parents=True, exist_ok=True)
    root = runtime.resolve(strict=True)
    before = _tree_bytes(root)
    report = Report(now.isoformat(), "none", before, before)
    maintenance = root / "Maintenance"
    maintenance.mkdir(exist_ok=True)
    with (maintenance / "cleanup.lock").open("a+") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            report.status, report.trigger = "busy", "busy"
            return report
        state = root / "videos" / "transfer-state.json"
        try:
            payload = json.loads(state.read_text(encoding="utf-8")) if state.exists() else {"records": []}
            records = payload["records"]
            if not isinstance(records, list):
                raise ValueError("recordsNotArray")
        except (OSError, UnicodeError, json.JSONDecodeError, KeyError, ValueError) as error:
            report.status, report.trigger = "blocked", "blocked"
            report.errors.append(f"invalidTransferState:{type(error).__name__}")
            _atomic_json(maintenance / "last-check.json", asdict(report))
            return report

        candidates = []
        for record in records:
            if not isinstance(record, dict) or record.get("phase") != "completed":
                continue
            key = record.get("key", {})
            customer_hash, message_hash = key.get("customerHash"), key.get("messageHash")
            completed = _date(record.get("updatedAt"))
            if not (_valid_hash(customer_hash) and _valid_hash(message_hash) and completed):
                report.skipped.append("completedRecordMissingSafeIdentityOrDate")
                continue
            paths = [
                root / "videos" / "transfers" / customer_hash / message_hash,
                root / "videos" / "evidence" / customer_hash / message_hash,
            ]
            if not all(_safe_tree(path, root) for path in paths):
                report.skipped.append(message_hash)
                continue
            size = sum(_tree_bytes(path) for path in paths)
            if size:
                candidates.append((completed, message_hash, paths, size))
        candidates.sort(key=lambda item: (item[0], item[1]))
        cutoff = now.astimezone(timezone.utc) - timedelta(days=30)
        selected = [item for item in candidates if item[0] <= cutoff]
        if before >= high:
            report.trigger = "capacity"
            projected = before - sum(item[3] for item in selected)
            selected_hashes = {item[1] for item in selected}
            for item in candidates:
                if projected <= target:
                    break
                if item[1] not in selected_hashes:
                    selected.append(item)
                    selected_hashes.add(item[1])
                    projected -= item[3]
        elif selected:
            report.trigger = "age"

        for _, message_hash, paths, _ in selected:
            if not all(_safe_tree(path, root) for path in paths):
                report.skipped.append(message_hash)
                continue
            if not dry_run:
                for path in paths:
                    if path.is_dir():
                        shutil.rmtree(path)
                    elif path.exists():
                        path.unlink()
            report.deleted_message_hashes.append(message_hash)
        report.bytes_after = before if dry_run else _tree_bytes(root)
        log_dir = maintenance / "logs"
        stamp = now.strftime("%Y%m%d-%H%M%S")
        _atomic_json(log_dir / f"cleanup-{stamp}.json", asdict(report))
        _atomic_json(maintenance / "last-check.json", asdict(report))
        return report


def self_test() -> None:
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp) / RUNTIME_NAME
        old_hash, active_hash, customer = "a" * 64, "b" * 64, "c" * 64
        for message in (old_hash, active_hash):
            path = root / "videos" / "transfers" / customer / message
            path.mkdir(parents=True)
            (path / "video.mp4").write_bytes(b"video")
        records = [
            {"phase": "completed", "updatedAt": 0, "key": {"customerHash": customer, "messageHash": old_hash}},
            {"phase": "downloading", "updatedAt": 0, "key": {"customerHash": customer, "messageHash": active_hash}},
        ]
        _atomic_json(root / "videos" / "transfer-state.json", {"records": records})
        report = run(root, now=datetime(2026, 9, 4, tzinfo=timezone.utc), dry_run=False)
        assert old_hash in report.deleted_message_hashes
        assert not (root / "videos" / "transfers" / customer / old_hash).exists()
        assert (root / "videos" / "transfers" / customer / active_hash).exists()
    print("pdd_safe_cleanup self-test PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-root", type=Path, default=Path.home() / "Library/Application Support/PDDAutoReplyTaskIsolationCandidate" / RUNTIME_NAME)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    report = run(args.runtime_root, now=datetime.now(timezone.utc), dry_run=args.dry_run)
    print(json.dumps(asdict(report), ensure_ascii=False, indent=2))
    return 0 if report.status in {"ok", "busy"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
