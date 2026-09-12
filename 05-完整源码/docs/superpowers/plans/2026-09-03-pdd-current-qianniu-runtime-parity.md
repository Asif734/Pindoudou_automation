# PDD Current-Qianniu Runtime Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the seven approved runtime reliability behaviors from the current Qianniu implementation into PDD without changing PDD's existing message identity, media detection, frame extraction, prompt, or customer-ordering algorithms.

**Architecture:** Keep `AutoReplyScheduler` as the only owner of queue ordering, make UI access a short leased operation guarded by a fresh persistent-state checkpoint, and move video transfer durability behind the existing relay/registry boundary. Preserve PDD's pending-video placeholder so later messages cannot overtake a video, while adopting Qianniu's bounded attempts, durable retries, fallback notice, and later recovery.

**Tech Stack:** Swift 6, Swift Package Manager, Swift concurrency (`actor`, `Task`, `async/await`), Foundation `URLSession`, AppKit/Accessibility APIs, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-03-pdd-current-qianniu-runtime-parity-design.md`

## Global Constraints

- Implement exactly the seven approved parity items; do not invent a new recognition, OCR, AX, prompt, or scheduling algorithm.
- Preserve PDD-NAME/identifier identity, red-dot discovery, message hashing, video content SHA-256 deduplication, pending-video ordering, and the existing 4–20 frame extraction algorithm.
- Ordinary per-customer failures must never stop the whole scheduler; only persistent-state integrity failures may stop it.
- Do not weaken HTTPS, host, redirect, or TLS validation for video fallback routes.
- Never persist signed video URLs, cookies, or login data.
- Execute inline in this task; do not delegate to subagents.
- This directory is not a Git repository, so the commit steps below are verification checkpoints only and must not invoke `git commit`.

---

### Task 1: Prioritize Ready Replies and Shorten Delivery

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Modify: `Sources/PDDAXReader/AutoReplyRetryPolicy.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`

**Interfaces:**
- Consumes: `AutoReplyAutomationDriver.send(uid:text:expectedCustomerCursor:lease:)` and its existing in-sender UID/cursor verification.
- Produces: `nextReadyJobIndex()` selected before supplement capture; `AutoReplyRetryPolicy.deliveryDelay(after:) -> TimeInterval` using 2, 4, 8, 16, then 30 seconds.

- [ ] **Step 1: Write failing scheduler tests**

Add tests proving that a ready job is sent before a pending supplement capture, that delivery does not call `preflight`, and that repeated `.failedBeforeSend` results keep the job ready with delays `2, 4, 8, 16, 30, 30` rather than failing or stopping the scheduler.

- [ ] **Step 2: Run the focused tests and confirm RED**

Run: `swift test --filter AutoReplySchedulerTests`

Expected: the supplement currently runs first, the spy records a preflight call, and retry delays differ from the required sequence.

- [ ] **Step 3: Implement the minimal scheduler change**

In `tick()`, select `nextReadyJobIndex()` before `nextSupplementCaptureRequest()`. In `deliverJob(at:)`, remove the scheduler-level `driver.preflight(...)` block and call the sender directly. Convert `.failedBeforeSend` into a durable ready retry using:

```swift
static func deliveryDelay(after attempt: Int) -> TimeInterval {
    [2, 4, 8, 16][safe: max(0, attempt - 1)] ?? 30
}
```

Keep `.uncertain` on the existing receipt-reconciliation path and keep cursor changes routed back into capture.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run: `swift test --filter AutoReplySchedulerTests`

Expected: all scheduler tests pass, and the driver spy records `send` without `preflight`.

- [ ] **Step 5: Checkpoint**

Record the passing command and continue without a Git commit because the workspace is not a repository.

### Task 2: Re-admit Persistent Red Dots and Persist Image Capture Attempts

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyModels.swift`
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Modify: `Sources/PDDAXReader/PDDAXConversationDriver.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyStoreTests.swift`
- Test: `Tests/PDDAXReaderTests/PDDAXConversationDriverTests.swift`

**Interfaces:**
- Produces: `AutoReplyJob.imageCaptureAttempted: Bool`, decoded as `false` for old state files.
- Produces: `capture(uid:after:includeImages:lease:)`, where `includeImages == false` skips image clicking/downloading but retains text, cursor, and video detection.
- Removes: lifetime `suppressedOrdinaryCaptureUIDs` behavior for a continuously unread UID.

- [ ] **Step 1: Write failing compatibility and behavior tests**

Add tests that old JSON decodes with `imageCaptureAttempted == false`; a job round-trips `true`; a retry after the first image-bearing capture calls the driver with `includeImages == false`; and two capture failures park only that attempt while a later discovery with the same still-red UID can create a fresh capture request.

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `swift test --filter 'AutoReply(Store|Scheduler)|PDDAXConversationDriver'`

Expected: the field and overload do not exist, and persistent red dots remain suppressed.

- [ ] **Step 3: Add the persisted field and capture option**

Add `imageCaptureAttempted` to `AutoReplyJob`, its initializer, coding keys, and backward-compatible decoder. Extend the driver protocol and concrete driver with `includeImages`; gate only the image interaction branch with that flag. Set the field durably before initiating image UI work so cancellation or a later-stage failure cannot cause the same image to be clicked again.

- [ ] **Step 4: Replace lifetime suppression with attempt parking**

After the second ordinary capture failure, clear the failed attempt's active execution state and leave the unread UID eligible for the next discovery cycle. Keep per-message/cursor deduplication so the same successfully captured message does not re-enter.

- [ ] **Step 5: Run focused tests and confirm GREEN**

Run: `swift test --filter 'AutoReply(Store|Scheduler)|PDDAXConversationDriver'`

Expected: all new persistence, no-repeat-image, and red-dot re-admission tests pass.

### Task 3: Apply 75-Second Capture Fuses

**Files:**
- Modify: `Sources/PDDAXReader/PDDUIStageTimeouts.swift`
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Test: `Tests/PDDAXReaderTests/PDDUIStageTimeoutsTests.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`

**Interfaces:**
- Produces: scheduler operation deadlines: discovery `8`, capture `75`, supplement `75`, delivery `25` seconds.
- Preserves: shorter driver-internal AX/OCR step timeouts; only the scheduler's outer fuse changes.

- [ ] **Step 1: Write failing timeout tests**

Assert `outerFuseSeconds(for: .capture) == 75` and prove both initial and supplement capture leases receive a 75-second deadline while delivery remains 25 seconds.

- [ ] **Step 2: Run tests and confirm RED**

Run: `swift test --filter PDDUIStageTimeoutsTests && swift test --filter AutoReplySchedulerTests`

Expected: capture reports 35/25 seconds or the scheduler still uses `innerSeconds(forOperationNamed:)`.

- [ ] **Step 3: Route scheduler leases through outer fuses**

Make scheduler operation names distinguish `capture` and `supplement`, map both to 75 seconds, and retain existing driver inner timeouts for individual open/OCR actions.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run: `swift test --filter PDDUIStageTimeoutsTests && swift test --filter AutoReplySchedulerTests`

Expected: all timeout tests pass without extending send beyond 25 seconds.

### Task 4: Validate Persistent State Before Every UI Operation

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyTransactionalStore.swift`
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyTransactionalStoreTests.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`

**Interfaces:**
- Consumes: `AutoReplyTransactionalStore.loadCheckpoint() throws -> AutoReplyCheckpoint`.
- Produces: `validatePersistentStateBeforeUI() throws`, called immediately before discover, capture, supplement capture, and send leases.

- [ ] **Step 1: Write failing mutation tests**

Add tests for state-file deletion and replacement after scheduler start but before each UI operation. The spy driver must record zero UI calls, and the scheduler must stop with an integrity diagnostic. Add a control test proving ordinary driver errors still isolate the task and keep the scheduler running.

- [ ] **Step 2: Run tests and confirm RED**

Run: `swift test --filter 'AutoReplyTransactionalStore|AutoReplyScheduler'`

Expected: at least one operation reaches the driver before the missing/replaced file is detected.

- [ ] **Step 3: Add the shared checkpoint gate**

Immediately before issuing every UI lease, reload the checkpoint and verify the expected file identity/revision token. Throw a dedicated integrity error on deletion or replacement. Catch that error only at the scheduler boundary and stop globally; continue routing ordinary UI failures through per-job retry/parking.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run: `swift test --filter 'AutoReplyTransactionalStore|AutoReplyScheduler'`

Expected: mutation tests pass and no ordinary task error stops the scheduler.

### Task 5: Add the Durable Video Transfer V2 State Machine

**Files:**
- Modify: `Sources/PDDAXReader/PDDBackgroundVideoModels.swift`
- Create: `Sources/PDDAXReader/PDDResilientVideoDownloader.swift`
- Create: `Sources/PDDAXReader/PDDVideoAlternateRoute.swift`
- Create: `Sources/PDDAXReader/PDDVideoTransferCoordinator.swift`
- Modify: `Sources/PDDAXReader/PDDVideoTransferArmer.swift`
- Modify: `Sources/PDDAXReader/PDDBackgroundVideoRecovery.swift`
- Test: `Tests/PDDAXReaderTests/PDDBackgroundVideoModelsTests.swift`
- Create: `Tests/PDDAXReaderTests/PDDResilientVideoDownloaderTests.swift`
- Create: `Tests/PDDAXReaderTests/PDDVideoTransferCoordinatorTests.swift`
- Modify: `Tests/PDDAXReaderTests/PDDVideoTransferArmerTests.swift`
- Modify: `Tests/PDDAXReaderTests/PDDBackgroundVideoRecoveryTests.swift`

**Interfaces:**
- Produces durable phases: `discovered`, `opening`, `addressCaptured`, `downloading`, `validating`, `downloaded`, `preparingEvidence`, `readyForGeneration`, `admitted`, `completed`, `waitingForRetry`, `terminalFailure`.
- Produces: `PDDVideoTransferCoordinator.start(uid:messageID:)`, `resumeDueTransfers(at:)`, and `handleDownloadedFile(...)`.
- Produces: bounded primary attempts with 5-second connection and 15-second resource limits, a 30-second immediate budget, and durable retry dates near 60, 180, and 600 seconds.

- [ ] **Step 1: Write failing model migration tests**

Test decoding every old PDD video phase into the nearest V2 phase, retry-attempt/date persistence, app restart during download, and confirmation that no signed URL is encoded.

- [ ] **Step 2: Write failing downloader/coordinator tests**

Use stub transports to cover: primary success; primary timeout then validated alternate-route success; unsafe alternate URL rejection; immediate budget exhaustion emitting one fallback-required event; retries at 60/180/600; permanent terminal failure; and a later retry succeeding and continuing to evidence preparation.

- [ ] **Step 3: Run video tests and confirm RED**

Run: `swift test --filter 'PDDBackgroundVideo|PDDResilientVideo|PDDVideoTransferCoordinator|PDDVideoTransferArmer'`

Expected: V2 types/coordinator are absent and current downloader can wait forever.

- [ ] **Step 4: Implement bounded attempts and safe alternate routes**

Port the current Qianniu state transitions and retry policy into PDD-named types. Use PDD's existing URL/host validation before every request and redirect. Persist only hashes, phase, attempt count, timestamps, and local paths. If no safe alternate route exists, skip directly to durable retry.

- [ ] **Step 5: Connect arming and restart recovery**

Keep PDD's current AX/video detection and click logic. Once a click exposes an address, hand ownership to the coordinator, close the preview after the background request starts, and let startup recovery resume incomplete transfers without holding the scheduler's UI lease.

- [ ] **Step 6: Run video tests and confirm GREEN**

Run: `swift test --filter 'PDDBackgroundVideo|PDDResilientVideo|PDDVideoTransferCoordinator|PDDVideoTransferArmer'`

Expected: all state, timeout, alternate-route, retry, restart, and no-secret-persistence tests pass.

### Task 6: Preserve PDD Queue Ordering Through Failure and Recovery

**Files:**
- Modify: `Sources/PDDAXReader/PDDBackgroundVideoModels.swift`
- Modify: `Sources/PDDAXReader/PDDVideoTransferRelay.swift`
- Modify: `Sources/PDDAXReader/PDDVideoTransferRegistry.swift`
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Test: `Tests/PDDAXReaderTests/PDDVideoTransferRelayTests.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`

**Interfaces:**
- Produces relay events for `fallbackRequired`, `waitingForRetry`, and recovered `readyForGeneration`.
- Preserves: `PDDPendingVideoBatch` sequence reservation and same-batch multi-video merge.
- Produces exactly-once fallback copy: `亲，视频暂时无法加载，麻烦您先简单描述一下需要我们查看的问题。`

- [ ] **Step 1: Write failing end-to-end scheduler tests**

Cover: immediate video success keeps its reserved sequence; two videos in one capture produce one analysis job; immediate failure releases the pending batch; a pure-video failure produces exactly one fixed ready reply; mixed text/image content still generates normally; later recovery creates one independent video-analysis job; duplicate recovery events do not duplicate replies; and another customer's ready reply is not blocked.

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `swift test --filter 'PDDVideoTransferRelay|AutoReplyScheduler'`

Expected: current relay only reports terminal `.failed`, pending batches can remain blocked, and later success cannot re-enter analysis.

- [ ] **Step 3: Extend relay/registry events**

Represent immediate fallback and durable waiting separately from terminal failure. Make event handling idempotent by `(customerHash, messageHash, phase-generation)` and keep the content SHA claim as the final same-customer deduplication authority.

- [ ] **Step 4: Integrate events into the scheduler**

On immediate success, promote the original pending batch in place. On immediate failure, remove that video from the batch's wait set; emit the fixed ready reply once for a pure-video batch, while allowing retained text/images to continue through Codex. On later recovery, enqueue a new video-analysis job at the then-current tail for that UID, never a second executing job.

- [ ] **Step 5: Run focused tests and confirm GREEN**

Run: `swift test --filter 'PDDVideoTransferRelay|AutoReplyScheduler'`

Expected: ordering, exact-once fallback, mixed-content continuation, and later-analysis tests all pass.

### Task 7: Startup Integration, UI Status, and Full Regression Verification

**Files:**
- Modify: `Sources/PDDAXReader/PDDAXReaderApp.swift`
- Modify: `Sources/PDDAXReader/FloatingProgressPanel.swift`
- Modify: `Tests/PDDAXReaderTests/FloatingProgressPanelTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: coordinator recovery events and scheduler state.
- Produces: user-visible video states for retry waiting, fallback sent, recovered download, evidence extraction, Codex submission, and completion.

- [ ] **Step 1: Write failing startup/UI tests**

Add tests that startup resumes due video transfers before normal scanning, does not block UI discovery, and renders persistent status for fallback, retry, recovery, and later successful analysis.

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `swift test --filter FloatingProgressPanelTests`

Expected: the new V2 statuses are absent.

- [ ] **Step 3: Wire startup and progress display**

Install the relay before recovery begins, launch due-transfer recovery in a background task, and map V2 phases to concise UI text without changing red-dot scanning or message parsing.

- [ ] **Step 4: Run all automated tests**

Run: `swift test`

Expected: zero failures; compare the executed count with the current 428-test baseline and explain any skip-count change.

- [ ] **Step 5: Build and inspect the application**

Run: `swift build -c release`

Expected: exit 0 with no new concurrency warnings attributable to these changes. Launch the locally built app, verify it reaches running state, then inspect logs for one discovery cycle without sending a test message.

- [ ] **Step 6: Update handoff documentation**

Document the seven aligned behaviors, video retry intervals, fixed fallback wording, state-file stop boundary, and the fact that PDD-specific identity/media algorithms remain unchanged. Record exact verification commands and results.

- [ ] **Step 7: Final self-review**

Re-read the spec and map every numbered requirement to a passing test. Search changed source for `.greatestFiniteMagnitude`, scheduler `preflight(` calls, `suppressedOrdinaryCaptureUIDs`, and persisted signed URL fields; each must be absent from the new runtime path or explicitly justified as dead compatibility code.
