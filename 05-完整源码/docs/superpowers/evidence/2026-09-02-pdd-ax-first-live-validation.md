# PDD AX-First / OCR-Fallback Validation Evidence

Date: 2026-09-02 (Asia/Dhaka)

## Automated verification

- Command: `swift test`
- Result after the red-dot authorization fix: 360 tests executed, 4 skipped, 0 failures.
- Focused TDD checks additionally proved:
  - AX fingerprint ignores incidental whitespace-only changes.
  - An elapsed stale-probe deadline cannot replace the required third spaced AX sample.
  - A bottom service-side OCR bubble prevents reaching backward to an older customer bubble.
  - Missing/unusable composer makes AX evidence invalid and enters the scoped fallback path.

## Candidate package

- App: `outputs/拼多多全自动客服-任务隔离候选版.app`
- Build command: `zsh scripts/build_app.sh --task-isolation-candidate`
- Package verification: `zsh scripts/verify_task_isolation_candidate.sh` passed.
- `codesign --verify --deep --strict --verbose=2` passed and satisfied its designated requirement.
- Executable SHA-256: `1f38ee92ee49e894c878cad7b63c66951622999fb0db650cc48fbcfb4e596ff1`

## Red-dot authorization regression fix

- A current conversation without screenshot red-dot evidence creates no capture work.
- The former ten-second passive capture cannot create a task.
- A generic AX change notification accelerates red-dot discovery only; it cannot authorize capture.
- A completed or uncertain send no longer schedules unprompted tail captures.
- Internally requested ordinary recaptures require a fresh one-shot red-dot authorization and cannot extend an old authorization indefinitely.
- Preflight never invokes OCR when no red-dot authorization exists, including when AX structure is missing.
- A second genuine red dot still authorizes a supplement/new batch for the same user.
- Relaunched UI text was inspected and reads: `等待红点触发；无红点不会读取正文、生成或发送…`.

## Read-only live AX probe

- Current PDD conversation key: `GZC-000001`.
- The independent AX reader parsed 40 ordered messages and correctly exposed customer/service direction and image message kinds.
- Raw AX was saved at `/Users/scy/Desktop/拼多多AX记录/用户/GZC-000001/ax.txt`.
- Three malformed/empty `middlePanel_list_*` nodes were diagnosed and excluded rather than promoted to actionable messages.
- The latest valid message was service-side, so the reader correctly reported that no reply was required.

## Relaunch and persistent state

- Relaunched executable PID: 6703.
- UI is intentionally stopped and shows `开始`.
- Dry-run checkbox value: `0`.
- UI source description: `截图红点触发 · AX 权威读取正文 · AX 失效才用尾部 OCR · AX 点击和发送`.
- `run-intent.json`: `desiredRunning = false`.
- Persistent schema: 6.
- Schema-5 backup: `state.schema5-backup-1788333159818.json`.
- Existing 172 terminal/audit jobs were retained; AX-first baselines, receipts, and selector snapshots start empty for the new generation.

## Still required before completion claim

- Run one controlled unique customer message through discovery, AX sampling or scoped OCR fallback, Codex generation, sending, and AX recovery.
- Confirm exactly one reply, no feedback-loop job, dry-run remains off, and queue/CLI counts settle.

## Formal-mode idle gate check

- The user confirmed the action-time start on 2026-09-02.
- Formal mode is running with dry-run value `0` and `允许 AX 发送`.
- After waiting 12 seconds—past the removed legacy ten-second passive-capture interval—the UI remained on the red-dot waiting state.
- Persistent state remained unchanged at 172 historical jobs, sequence 172, 0 active jobs, and 0 pending captures.
- `run-intent.json` records `desiredRunning = true`.
