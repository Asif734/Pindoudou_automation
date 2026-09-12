# PDD Background Video Parity Verification — 2026-09-03

## Scope

Verified the approved PDD chain only: arm CEF baseline, open video, start unlimited background transfer, close preview, validate MP4, extract Qianniu-equivalent frames, export audio, transcribe, admit one durable batch, and submit all frames in one Codex invocation.

## Automated evidence

- Full XCTest command: `swift test`
- Result after concurrency/recovery fixes: 417 tests executed, 7 explicitly conditional tests skipped, 0 failures.
- Targeted race/recovery tests cover:
  - terminal transfer event before pending-batch persistence;
  - video recovery with no matching visible video never creates an ordinary job;
  - a later video open failure does not discard earlier pending IDs;
  - stale stop lifecycle revision cannot override a newer restart;
  - 20 ordered JPEG frames enter one Codex invocation while MP4, M4A, and manifest do not enter image arguments.

## Security and identity evidence

- Transfer identity is SHA-256(uid) plus SHA-256(messageID).
- Temporary signed URLs are not members of any Codable model and are not included in event details or prompts.
- Multiple live watchers claim the SHA-256 of a source URL, preventing one cache candidate from being assigned to two message IDs during the same runtime.
- Recovery is keyed by exact UID and messageID.

## Build evidence

- Final full suite after same-UID queue/hash-dedup fix: 419 tests executed, 7 named environment-dependent tests skipped, 0 failures; elapsed 13.192 seconds.
- Release build: `./scripts/build_app.sh --task-isolation-candidate` exited 0.
- Bundle: `outputs/拼多多全自动客服-任务隔离候选版.app`.
- Bundle identifier: `com.scy.pdd-auto-reply.task-isolation-candidate`.
- `codesign --verify --deep --strict --verbose=2`: valid on disk; satisfies Designated Requirement.
- Executable SHA-256: `7fa6353039b3ffac0b22e6e420ca19de75738d778e33e85252c997cac2dd4b03`.
- Fresh process after rebuild: PID 66145.
- Run intent after launch: `desiredRunning: false`; no Start action or real send was performed.
- Runtime `videos` directory did not yet exist, so there was no new live-video artifact to inspect and no runtime signed URL to report.

## Live acceptance boundary

No real customer message is sent during packaging. The candidate launches stopped. A new PDD video end-to-end timing and a real reply require an explicit live test/real-send instruction while a controlled test conversation is available.

## Same-UID queue and duplicate-video regression

- Added a regression proving an existing text job is the only generation started when a completed video job for the same UID is queued behind it.
- Added a regression proving `video:<hash>` in a pending supplement is covered by an existing `video-analysis:<hash>`/attachment SHA-256 and cannot create a third job.
- `AutoReplySchedulerTests`: 60 executed, 0 failures after this change.

## Qianniu parity: overlap repair and real-content video dedup

- Same-UID overlap is repaired before persistence; waiting jobs never count as concurrent execution.
- Priority is `sending > generating > capturing`; lower-priority/equal-later work moves to the UID tail.
- A send with a durable invocation marker completes uncertain and is never requeued.
- Downloaded MP4 SHA-256 is claimed per UID before frame/audio/transcript preparation.
- Same UID + same MP4 bytes + different messageID emits `video-duplicate` and creates no AI/reply job.
- Different UIDs may independently process identical MP4 bytes; exact-message restart recovery remains allowed.
- Existing scheduler and archive video attachments seed the new durable content-hash inbox.
- Final full suite: 428 tests executed, 7 named environment-dependent tests skipped, 0 failures; elapsed 8.891 seconds.
- Final executable SHA-256: `4938118a08f5a0042766dedf1492605875f93c09b10e73fba72553f56341ad88`.
- Fresh process after rebuild: PID 97546; UI remained stopped and no real send was performed.
