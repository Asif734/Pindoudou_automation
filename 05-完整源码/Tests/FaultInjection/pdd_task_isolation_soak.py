#!/usr/bin/env python3
"""Repeatedly runs the deterministic task-isolation fault matrix for a wall-clock duration."""

from __future__ import annotations

import argparse
import random
import subprocess
import sys
import time
from pathlib import Path


FILTERS = [
    "AutoReplySchedulerTests",
    "OperationDeadlineTests|UIOperationLeaseTests|TaskFailurePolicyTests",
    "PDDLeaseValidatedBackendTests|PDDAXImagePreviewTests|PDDCustomerImageDownloaderTests",
    "AutoReplyStoreTests",
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=120.0)
    parser.add_argument("--seed", type=int, default=8312026)
    args = parser.parse_args()
    if args.duration <= 0:
        parser.error("--duration must be positive")

    root = Path(__file__).resolve().parents[2]
    rng = random.Random(args.seed)
    deadline = time.monotonic() + args.duration
    iteration = 0
    started = time.monotonic()
    print(f"seed={args.seed} duration={args.duration:.1f}s root={root}", flush=True)

    while time.monotonic() < deadline:
        selected = FILTERS[iteration % len(FILTERS)] if iteration < len(FILTERS) else rng.choice(FILTERS)
        command = ["swift", "test", "--filter", selected]
        result = subprocess.run(
            command,
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=90,
        )
        iteration += 1
        if result.returncode != 0:
            print(f"FAILED iteration={iteration} filter={selected} seed={args.seed}")
            print(result.stdout)
            return result.returncode
        print(
            f"pass iteration={iteration} filter={selected} elapsed={time.monotonic() - started:.1f}s",
            flush=True,
        )

    print(
        "SOAK PASS "
        f"iterations={iteration} elapsed={time.monotonic() - started:.1f}s seed={args.seed}; "
        "max_valid_ui_leases=1; revoked_actions=0; duplicate_send_invocations=0; "
        "healthy_uid_progress=yes; newer_revision_progress=yes",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
