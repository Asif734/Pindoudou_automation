# PDD Qianniu-Kernel Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve PDD-specific AX/OCR/image/send adapters while upgrading scheduling, continuous-message semantics, persistence, Codex sessions/processes, V2 retrieval, and lifecycle behavior to the approved Qianniu-kernel design.

**Architecture:** Keep `PDDAXConversationDriver`, PDD red-dot routing, OCR-authoritative text, AX-authoritative images, and `PDDAXReplySender` as the platform adapter. Introduce durable scheduler/store primitives underneath `AutoReplyScheduler`, then layer asynchronous UI scheduling, supplement/tail capture, bounded Codex execution, incremental per-UID sessions, persistent V2, and resumable app intent on top. Every behavioral change is introduced through a failing test and preserves the durable-send and single-valid-UI-lease invariants.

**Tech Stack:** Swift 5.9, Swift Concurrency, SwiftUI/AppKit, ApplicationServices AX, ScreenCaptureKit, Foundation `Process`, POSIX process groups/signals, CryptoKit SHA-256, JSON/JSONL, Python 3.12 V2 retriever, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-01-pdd-qianniu-kernel-parity-design.md`

## Global Constraints

- macOS deployment floor remains 14.0.
- PDD bundle ID remains `com.pinduoduo.merchantMac`; customer IDs remain `^GZC-[0-9]+$`.
- Preserve PDD red-dot detection, AX/OCR hybrid parsing, image-preview URL resolution, Web AX recovery, send reconciliation, dry-run, AX notifications, and shared legacy/candidate locks.
- UI work remains globally serial with at most one valid lease; Codex generation may run concurrently.
- A reply remains valid when B/C are appended after A; A sends first and B/C form a later batch.
- A single UID failure never changes global desired-running state.
- Any legal non-empty model reply is routed to automatic send regardless of reported risk.
- Once send may have been invoked, never automatically resend that job.
- Only inability to durably store send-critical evidence pauses new real sends; discovery, capture, generation, and persistence retry continue.
- Do not initialize a Git repository. This workspace currently has no `.git`; replace commit steps with recorded verification checkpoints unless the user later supplies a repository.
- Use `apply_patch` for source/document edits.

---

## File Structure Locked by This Plan

### New production files

- `Sources/PDDAXReader/AutoReplyRevision.swift` — digest-backed revision identity and legacy decoding.
- `Sources/PDDAXReader/AutoReplyTransactionalStore.swift` — compare-and-commit checkpoint API, archive manifests, compaction, external-modification detection.
- `Sources/PDDAXReader/AutoReplyDiskHealth.swift` — startup writable/fsync/free-space check and retry classification.
- `Sources/PDDAXReader/AutoReplyRetryPolicy.swift` — exponential Codex retry, identity-error budget, 60-second backpressure classification.
- `Sources/PDDAXReader/PDDUIStageTimeouts.swift` — named inner/outer UI timeouts.
- `Sources/PDDAXReader/FrozenImageStore.swift` — content-addressed immutable image copies.
- `Sources/PDDAXReader/CodexExecutionTrace.swift` — bounded metadata-only execution diagnostics.
- `Sources/PDDAXReader/BoundedCodexProcessRunner.swift` — process group, streaming JSONL, soft/hard timeout, cleanup, early reply event.
- `Sources/PDDAXReader/CodexHomeManager.swift` — candidate-local `CODEX_HOME` preparation.
- `Sources/PDDAXReader/CodexHistoryCheckpoint.swift` — canonical history prefix and incremental payload calculation.
- `Sources/PDDAXReader/PersistentV2Worker.swift` — request-ID protocol, 2/5-second timeout, worker restart.
- `Sources/PDDAXReader/PortableKnowledgeRuntime.swift` — bundled Python/knowledge validation and hash-aware deployment.
- `Sources/PDDAXReader/AutoReplyRunIntentStore.swift` — explicit start/stop intent.

### Major modified files

- `AutoReplyModels.swift`, `AutoReplyStore.swift`, `AutoReplyScheduler.swift`
- `PDDAXConversationDriver.swift`, `AutoReplyTimeline.swift`, `PDDChatMessage.swift`
- `AutoReplyCodexGenerator.swift`, `CodexProcessRunner.swift`, `CodexLoginCache.swift`, `CodexSessionRegistry.swift`
- `AutoReplyPromptBuilder.swift`, `CustomerServicePrompt.swift`, `Resources/CustomerService/customer-reply-prompt.md`, `Resources/reply-output.schema.json`
- `KnowledgeEvidenceService.swift`, `KnowledgeResourceLocator.swift`, `V2KnowledgeRetriever.swift`
- `AutoReplyViewModel.swift`, `AutoReplyView.swift`, `AutoReplyProgressPresentation.swift`, `AutoReplyFloatingProgress.swift`
- `scripts/build_app.sh`, `scripts/verify_task_isolation_candidate.sh`

### New test files

- `Tests/PDDAXReaderTests/AutoReplyTransactionalStoreTests.swift`
- `Tests/PDDAXReaderTests/AutoReplyDiskHealthTests.swift`
- `Tests/PDDAXReaderTests/AutoReplyContinuousMessageTests.swift`
- `Tests/PDDAXReaderTests/AutoReplySchedulingFairnessTests.swift`
- `Tests/PDDAXReaderTests/AutoReplyRetryPolicyTests.swift`
- `Tests/PDDAXReaderTests/FrozenImageStoreTests.swift`
- `Tests/PDDAXReaderTests/BoundedCodexProcessRunnerTests.swift`
- `Tests/PDDAXReaderTests/CodexHistoryCheckpointTests.swift`
- `Tests/PDDAXReaderTests/PersistentV2WorkerTests.swift`
- `Tests/PDDAXReaderTests/AutoReplyRunIntentStoreTests.swift`

---

### Task 1: Establish schema 4 and digest-backed revisions

**Files:**
- Create: `Sources/PDDAXReader/AutoReplyRevision.swift`
- Modify: `Sources/PDDAXReader/AutoReplyModels.swift`
- Modify: `Sources/PDDAXReader/AutoReplyStore.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyStoreTests.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`

**Interfaces:**
- Produces: `struct AutoReplyRevision: Codable, Hashable, Sendable { let digest: String; let ordinal: Int }`
- Produces: schema-4 `AutoReplyPersistentState` fields for desired-running, pending captures, terminal summaries, and checkpoint metadata.
- Consumes: `FrozenCustomerBatch.endCursor.digest`.

- [ ] **Step 1: Add failing revision and schema migration tests**

Add tests asserting:

```swift
func testSchema3JobRevisionMigratesFromFrozenBatchDigest() throws {
    let migrated = try fixture.loadSchema3AsCurrent()
    XCTAssertEqual(migrated.jobs[0].revision.digest, fixture.batch.endCursor.digest)
    XCTAssertEqual(migrated.schemaVersion, 4)
}

func testLegacySendingJobWithInvokedSendNeverBecomesReadyDuringMigration() throws {
    let migrated = try fixture.loadSchema3Sending(sendWasInvoked: true)
    XCTAssertEqual(migrated.jobs[0].state, .completed)
    XCTAssertEqual(migrated.jobs[0].deliveryOutcome, .uncertain)
}
```

- [ ] **Step 2: Run focused tests and confirm red**

Run: `swift test --filter 'AutoReplyStoreTests|AutoReplySchedulerTests'`  
Expected: compile/test failure because `revision` and schema 4 are absent.

- [ ] **Step 3: Implement the revision type and backward decoding**

Use a strict 64-lowercase-hex digest validator. Preserve legacy `customerRevision` decoding only for migration/display; new identity comparisons use `AutoReplyRevision.digest`.

```swift
struct AutoReplyRevision: Codable, Hashable, Sendable {
    let digest: String
    let ordinal: Int

    init(endCursor: AutoReplyCursor, ordinal: Int) throws {
        guard endCursor.digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw AutoReplyRevisionError.invalidDigest
        }
        self.digest = endCursor.digest
        self.ordinal = ordinal
    }
}
```

- [ ] **Step 4: Implement schema-3-to-4 migration**

Before changing the original file, write `state.schema3-backup-<milliseconds>.json`. Reconstruct revision from batch end cursor; keep `sendWasInvoked=true` recovery uncertain and cursor-forward. Reject unsupported schemas without overwriting.

- [ ] **Step 5: Run store/scheduler tests**

Run: `swift test --filter 'AutoReplyStoreTests|AutoReplySchedulerTests'`  
Expected: all focused tests pass.

- [ ] **Step 6: Record checkpoint evidence**

Append command, exit code, test count, and timestamp to `docs/superpowers/evidence/2026-09-01-pdd-kernel-parity-verification.md` using `apply_patch`.

---

### Task 2: Add transactional checkpoint commits and immutable terminal archives

**Files:**
- Create: `Sources/PDDAXReader/AutoReplyTransactionalStore.swift`
- Modify: `Sources/PDDAXReader/AutoReplyStore.swift`
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Create: `Tests/PDDAXReaderTests/AutoReplyTransactionalStoreTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyStoreTests.swift`

**Interfaces:**
- Produces: `AutoReplyCheckpointToken(hash: String, schemaVersion: Int)`.
- Produces: `commit(expected: AutoReplyCheckpointToken?, mutation: (inout AutoReplyPersistentState) throws -> [AutoReplyImmutableEvidence]) throws -> AutoReplyCheckpointToken`.
- Produces: `AutoReplyPersistenceHealth` published by scheduler.

- [ ] **Step 1: Write failing transaction tests**

Cover exact cases:

```swift
func testCommitRejectsExternallyModifiedCheckpoint() throws
func testCommitRejectsAnsweredCursorRegression() throws
func testTerminalJobMovesFullRecordToHashedArchiveAndLeavesSummary() throws
func testCheckpointRetainsOnlyNewestOneHundredEvents() throws
func testArchiveManifestDetectsByteOrSHAConflict() throws
func testGenerationTransitionDoesNotIgnoreWriteFailure() throws
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter 'AutoReplyTransactionalStoreTests|AutoReplyStoreTests'`  
Expected: missing transactional API failures.

- [ ] **Step 3: Implement canonical checkpoint hashing**

Encode sorted-key JSON excluding the stored checkpoint hash itself, compute SHA-256, and store the resulting token. On load, recompute and validate when a token exists.

- [ ] **Step 4: Implement immutable evidence order**

Write record/reply/event segment to temporary files, synchronize them, atomically move them, verify byte count/SHA, then write the new checkpoint. Existing same-hash evidence is idempotent; existing different content is a conflict.

- [ ] **Step 5: Replace scheduler `try? persist()` paths**

All job state transitions use the transaction API. `generationFinished` must never silently retain a ready reply that was not checkpointed. Ordinary failure sets persistence health degraded and retries; send-critical transitions set `realDeliveryPausedForPersistence=true`.

- [ ] **Step 6: Bound state growth**

Keep only active jobs plus terminal summaries needed by UI/reconciliation; preserve complete terminal content in archive. Keep newest 100 checkpoint events and segment older events. Keep UI presentation cache at 200.

- [ ] **Step 7: Run focused and existing scheduler tests**

Run: `swift test --filter 'AutoReplyTransactionalStoreTests|AutoReplyStoreTests|AutoReplySchedulerTests'`  
Expected: pass with no ignored write-failure assertion.

---

### Task 3: Add disk health and persistent run intent

**Files:**
- Create: `Sources/PDDAXReader/AutoReplyDiskHealth.swift`
- Create: `Sources/PDDAXReader/AutoReplyRunIntentStore.swift`
- Modify: `Sources/PDDAXReader/AutoReplyViewModel.swift`
- Modify: `Sources/PDDAXReader/PDDRuntimeIdentity.swift`
- Create: `Tests/PDDAXReaderTests/AutoReplyDiskHealthTests.swift`
- Create: `Tests/PDDAXReaderTests/AutoReplyRunIntentStoreTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyViewModelTests.swift`

**Interfaces:**
- Produces: `AutoReplyDiskHealthChecking.check(root:minimumFreeBytes:) throws`.
- Produces: `AutoReplyRunIntentStore.load() -> Bool` and `save(desiredRunning:) throws`.
- Consumes: candidate `identity.dataRoot` and existing lock/permission services.

- [ ] **Step 1: Write failing health/intent tests**

Test writable temp creation, file synchronize, atomic rename, 512 MiB threshold, start persistence, explicit stop persistence, normal disappearance not changing intent, and delayed environment recovery.

- [ ] **Step 2: Verify red**

Run: `swift test --filter 'AutoReplyDiskHealthTests|AutoReplyRunIntentStoreTests|AutoReplyViewModelTests'`.

- [ ] **Step 3: Implement disk check**

Create a unique file inside the exact data root, write fixed bytes, call `synchronize()`, close, atomically rename, remove, and query volume available capacity for important usage. Never test a different parent directory.

- [ ] **Step 4: Implement explicit run intent**

Store a small atomic JSON file under data root. `start()` writes true after the user requests start; `stop()` writes false before releasing runtime. Process exit and view disappearance do not change it.

- [ ] **Step 5: Add environment recovery loop**

When desired-running is true but permission/lock/disk/Codex/resources are unavailable, publish a waiting reason and retry with bounded exponential delay. Do not spawn multiple loops. Once healthy, acquire locks and start runtime automatically.

- [ ] **Step 6: Run focused tests**

Expected: all intent/health/ViewModel tests pass, including candidate restart with desired-running true.

---

### Task 4: Separate UI operations from tick and add staged deadlines

**Files:**
- Create: `Sources/PDDAXReader/PDDUIStageTimeouts.swift`
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Modify: `Sources/PDDAXReader/PDDLiveAutoReplyDriver.swift`
- Modify: `Sources/PDDAXReader/PDDAXConversationDriver.swift`
- Modify: `Sources/PDDAXReader/OperationDeadline.swift`
- Create: `Tests/PDDAXReaderTests/AutoReplySchedulingFairnessTests.swift`
- Modify: `Tests/PDDAXReaderTests/OperationDeadlineTests.swift`
- Modify: `Tests/PDDAXReaderTests/UIOperationLeaseTests.swift`

**Interfaces:**
- Produces: `enum PDDUIStage { case discovery, openConversation, ocr, preflight, send }`.
- Produces: `PDDUIStageTimeouts.inner(for:)` and `outerFuse(for:)`.
- Produces: scheduler `activeUITask: Task<Void, Never>?`.

- [ ] **Step 1: Write failing async scheduling tests**

Assert that a hanging UI task does not keep later tick calls from publishing status or starting allowed Codex work, while backend press remains globally serialized. Assert stop synchronously revokes the active lease.

- [ ] **Step 2: Write failing timeout table tests**

Expected inner values: discovery 5, open 5, OCR 20, preflight 8, send 15 seconds. Assert outer fuse is larger and a non-cooperative operation returns at fuse time.

- [ ] **Step 3: Verify red**

Run: `swift test --filter 'AutoReplySchedulingFairnessTests|OperationDeadlineTests|UIOperationLeaseTests'`.

- [ ] **Step 4: Refactor scheduler UI launch**

`tick()` selects work and creates a bounded Task, then returns. Completion re-enters `@MainActor`, validates operation ID, commits state, clears `activeUITask`, and signals `onStateChange`. Never clear a newer task from a stale completion.

- [ ] **Step 5: Expose driver stage boundaries**

Split open and OCR calls sufficiently to apply their distinct inner deadlines. Outer operation fuse always revokes both registry lease and `PDDUIOperationLeaseGate` before returning.

- [ ] **Step 6: Run focused tests and existing lease/backend tests**

Run: `swift test --filter 'AutoReplySchedulingFairnessTests|OperationDeadlineTests|UIOperationLeaseTests|PDDLeaseValidatedBackendTests|AutoReplySchedulerTests'`.

---

### Task 5: Implement generation-first scheduling and three-send fairness

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Modify: `Sources/PDDAXReader/AutoReplyModels.swift`
- Modify: `Sources/PDDAXReader/AutoReplyProgressPresentation.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplySchedulingFairnessTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`

**Interfaces:**
- Produces: persistent `consecutiveDeliveryCount` or equivalent restart-safe fairness state.
- Consumes: Task 4 asynchronous UI selection.

- [ ] **Step 1: Write failing priority tests**

```swift
func testTickFillsGenerationCapacityBeforeSelectingUIWork() async throws
func testStartingGenerationDoesNotPreventReadyDeliveryInSameSchedulingPass() async throws
func testThreeConsecutiveDeliveriesForceDiscoveryBeforeFourth() async throws
func testDiscoveryResetsConsecutiveDeliveryCount() async throws
```

- [ ] **Step 2: Verify red**

Run the fairness test class and confirm current send-first/early-return behavior fails.

- [ ] **Step 3: Implement a single scheduling pass**

Change `launchQueuedGenerations()` from “launch and return” to “launch up to capacity and continue”. After generation launch, select at most one UI task. Track completed delivery attempts; at count 3 schedule discovery even with ready jobs.

- [ ] **Step 4: Make fairness persistent**

Save the counter and pending forced-discovery flag in schema 4 so restart cannot create indefinite send starvation.

- [ ] **Step 5: Run scheduler suite**

Run: `swift test --filter 'AutoReplySchedulingFairnessTests|AutoReplySchedulerTests|AutoReplyProgressPresentationTests'`.

---

### Task 6: Implement supplement capture, prefix-valid preflight, and two tail captures

**Files:**
- Create: `Tests/PDDAXReaderTests/AutoReplyContinuousMessageTests.swift`
- Modify: `Sources/PDDAXReader/AutoReplyModels.swift`
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Modify: `Sources/PDDAXReader/AutoReplyTimeline.swift`
- Modify: `Sources/PDDAXReader/PDDAXConversationDriver.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyTimelineTests.swift`

**Interfaces:**
- Produces: persistent `AutoReplyCaptureRequest(kind: .ordinary/.supplement/.tail(attempt: Int), uid:, baseCursor:)`.
- Produces: `AutoReplyTimeline.validatesPrefix(_ cursor:)` independent of current tail length.
- Consumes: digest-backed revision from Task 1.

- [ ] **Step 1: Write the A/B/C failing tests**

Model exact sequence: capture A → generating A → discover/capture B/C → finish A → preflight full timeline A/B/C → send A → create B/C job. Assert A reply is not discarded and answered cursor advances only to A end.

- [ ] **Step 2: Write tail persistence tests**

Assert sent and uncertain both schedule tail attempts 1 and 2, attempts survive scheduler restart, and completion marker prevents a third permanent loop.

- [ ] **Step 3: Verify red**

Run: `swift test --filter 'AutoReplyContinuousMessageTests|AutoReplyTimelineTests'`.

- [ ] **Step 4: Replace UID-only pending queue**

Persist typed capture requests. Allow supplement request while same UID job is generating/ready. Deduplicate by `(uid, kind, baseCursor/revision)` rather than blocking on `hasActiveJob(uid:)`.

- [ ] **Step 5: Implement prefix-valid preflight**

Verify the job batch end cursor remains an exact prefix of current customer timeline. Appended B/C is valid; changed/missing A prefix is invalid. Do not compare current total cursor to A end cursor.

- [ ] **Step 6: Freeze B/C separately**

Store observed tail without mutating A capture. After A completion, freeze from A end cursor and enqueue the next job.

- [ ] **Step 7: Run scheduler/conversation/timeline tests**

Run: `swift test --filter 'AutoReplyContinuousMessageTests|AutoReplySchedulerTests|PDDAXConversationDriverTests|AutoReplyTimelineTests'`.

---

### Task 7: Replace fixed retry/concurrency limits with backpressure policy

**Files:**
- Create: `Sources/PDDAXReader/AutoReplyRetryPolicy.swift`
- Modify: `Sources/PDDAXReader/AdaptiveConcurrencyPolicy.swift`
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Create: `Tests/PDDAXReaderTests/AutoReplyRetryPolicyTests.swift`
- Modify: `Tests/PDDAXReaderTests/RuntimeResourceMonitorTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`

**Interfaces:**
- Produces: `AutoReplyRetryDecision.retry(at:)`, `.rebuildSessionAndRetry(at:)`, `.failRevision`.
- Produces: `recordBackpressure(reason:now:)` wired into production failures.

- [ ] **Step 1: Write failing retry tests**

Assert ordinary failures at attempts 1…20 all retry with capped exponential delay and never advance cursor. Assert session identity mismatch rebuilds once and fails revision on second mismatch. Assert 429/rate-limit/allocation messages activate 60-second backpressure.

- [ ] **Step 2: Write failing memory policy tests**

Assert no fixed 6 minimum or 24 maximum; capacity is zero below 1 GiB estimated free and increases as memory permits.

- [ ] **Step 3: Implement centralized policy**

Keep delay calculation deterministic with injected clock/random jitter source. Classify structured errors first, bounded text matching second. Truncate diagnostic error text to 4000 trailing characters.

- [ ] **Step 4: Wire production backpressure**

Call `recordBackpressure` from generation completion on rate-limit/429/allocation classification. Scheduler resumes new generation after cooldown without user action.

- [ ] **Step 5: Run focused suites**

Run: `swift test --filter 'AutoReplyRetryPolicyTests|AutoReplySchedulerTests|RuntimeResourceMonitorTests'`.

---

### Task 8: Freeze images by content and include SHA in event identity

**Files:**
- Create: `Sources/PDDAXReader/FrozenImageStore.swift`
- Modify: `Sources/PDDAXReader/PDDCustomerImageModels.swift`
- Modify: `Sources/PDDAXReader/PDDAXConversationDriver.swift`
- Modify: `Sources/PDDAXReader/AutoReplyTimeline.swift`
- Create: `Tests/PDDAXReaderTests/FrozenImageStoreTests.swift`
- Modify: `Tests/PDDAXReaderTests/PDDAXConversationDriverTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyTimelineTests.swift`

**Interfaces:**
- Produces: `freeze(_ attachment: AutoReplyImageAttachment) throws -> AutoReplyImageAttachment` whose local URL is under `frozen-images`.
- Produces: customer event canonical JSON containing optional `imageSHA256`.

- [ ] **Step 1: Write failing frozen-store tests**

Assert SHA-addressed destination, idempotent reuse, rejection of source whose bytes no longer match declared SHA, atomic copy, and job survival after original download deletion.

- [ ] **Step 2: Write image cursor tests**

Assert same message ID with different image SHA creates a different cursor; read/unread-only changes do not.

- [ ] **Step 3: Verify red**

Run: `swift test --filter 'FrozenImageStoreTests|AutoReplyTimelineTests|PDDAXConversationDriverTests'`.

- [ ] **Step 4: Implement content-addressed freezing**

Validate file type/bytes/hash before copying. Use `<data-root>/frozen-images/<64hex>.<jpg|png>`, a same-directory temporary file, synchronize, then atomic move.

- [ ] **Step 5: Make pure-image failure replyable**

Replace the current `invalidImageData` terminal capture error for pure-image batches with a frozen image placeholder event and diagnostic. The prompt must be able to produce a generic request for clarification if no valid attachment is available.

- [ ] **Step 6: Run image, timeline, generator tests**

Run: `swift test --filter 'FrozenImageStoreTests|PDDCustomerImageDownloaderTests|PDDAXImagePreviewTests|PDDAXConversationDriverTests|AutoReplyTimelineTests|AutoReplyCodexGeneratorTests'`.

---

### Task 9: Unify prompt source and upgrade reply schema/routing

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyPromptBuilder.swift`
- Modify: `Sources/PDDAXReader/CustomerServicePrompt.swift`
- Modify: `Sources/PDDAXReader/AutoReplyCodexGenerator.swift`
- Modify: `Resources/CustomerService/customer-reply-prompt.md`
- Modify: `Resources/reply-output.schema.json`
- Modify: `Tests/PDDAXReaderTests/AutoReplyPromptBuilderTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyCodexGeneratorTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyPackagingTests.swift`

**Interfaces:**
- Produces: `AutoReplyDecision(decision:riskLevel:replyText:reason:)`.
- Produces: one runtime-loaded prompt resource with version/hash.

- [ ] **Step 1: Write failing prompt/schema tests**

Assert prompt explicitly describes batch-wide answer, B/C non-cancellation, real image attachments, untrusted content, and runtime knowledge evidence. Assert no “禁止使用图片附件” or hard-coded desktop ZIP path remains.

- [ ] **Step 2: Write routing tests**

Decode the four-field schema; assert low/medium/high all return `replyText` for automatic send; assert empty reply fails; assert >1000 characters is accepted.

- [ ] **Step 3: Verify red**

Run prompt/generator/packaging tests and capture current contradictory failure.

- [ ] **Step 4: Establish single source of truth**

Load the bundled markdown at runtime, validate nonempty, compute SHA-256 version, and inject it into generator/session compatibility. Remove duplicated policy strings from `AutoReplyPromptBuilder` except safe structural delimiters.

- [ ] **Step 5: Upgrade schema and decode**

Require `decision == auto_send`, valid risk enum, nonempty `reply_text`, and reason. Routing ignores risk as a gate. Retain only a platform-derived technical text limit if actual composer tests prove one.

- [ ] **Step 6: Run focused suites**

Run: `swift test --filter 'AutoReplyPromptBuilderTests|AutoReplyCodexGeneratorTests|AutoReplyPackagingTests|CustomerReplyPromptBuilderTests'`.

---

### Task 10: Implement bounded Codex process groups and early reply handoff

**Files:**
- Create: `Sources/PDDAXReader/CodexExecutionTrace.swift`
- Create: `Sources/PDDAXReader/BoundedCodexProcessRunner.swift`
- Modify: `Sources/PDDAXReader/CodexProcessRunner.swift`
- Modify: `Sources/PDDAXReader/CodexInvocation.swift`
- Modify: `Sources/PDDAXReader/AutoReplyCodexGenerator.swift`
- Create: `Tests/PDDAXReaderTests/BoundedCodexProcessRunnerTests.swift`
- Modify: `Tests/PDDAXReaderTests/CodexReplyServiceTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyCodexGeneratorTests.swift`

**Interfaces:**
- Produces: async event stream `CodexProcessEvent.stdoutLine`, `.stderrChunk`, `.softTimeout`, `.terminated`, `.cleanup`.
- Produces: early `CodexReplyHandoff` exactly once when a complete valid reply object is observed.
- Produces: metadata-only `CodexExecutionTrace`.

- [ ] **Step 1: Write executable-fixture tests**

Use temporary shell helper executables that: print valid reply then sleep; fork a child; flood stdout/stderr; ignore TERM; emit tool events after reply. Assert early handoff precedes process exit, pipes do not deadlock, TERM escalates to KILL, and no process-group member remains.

- [ ] **Step 2: Verify red**

Run: `swift test --filter 'BoundedCodexProcessRunnerTests|CodexReplyServiceTests'`.

- [ ] **Step 3: Implement POSIX process-group runner**

Launch in a dedicated group, drain both pipes continuously, parse newline-delimited output incrementally, emit soft timeout at 45 seconds, hard-stop at 100 seconds, TERM then KILL after a bounded grace period, and verify cleanup with `kill(-pgid, 0)`.

- [ ] **Step 4: Implement early handoff**

As soon as output schema decoding succeeds, resume a one-shot continuation/send stream event to scheduler. Keep collecting diagnostic events until process cleanup. Later tool/command/MCP/web events mark session contamination but do not revoke reply.

- [ ] **Step 5: Bound diagnostics**

Store durations, bytes, image counts, session mode, event category flags, timeout and exit/cleanup. Do not persist full command, reasoning, or unbounded stderr.

- [ ] **Step 6: Run focused tests**

Expected: early-handoff time is less than process exit time; ignored TERM helper is killed; no child remains.

---

### Task 11: Merge login checks and isolate CODEX_HOME

**Files:**
- Create: `Sources/PDDAXReader/CodexHomeManager.swift`
- Modify: `Sources/PDDAXReader/CodexLoginCache.swift`
- Modify: `Sources/PDDAXReader/CodexProcessRunner.swift`
- Modify: `Sources/PDDAXReader/AutoReplyViewModel.swift`
- Modify: `Tests/PDDAXReaderTests/CodexLoginCacheTests.swift`
- Create: `Tests/PDDAXReaderTests/CodexHomeManagerTests.swift`

**Interfaces:**
- Produces: candidate-local `CodexRuntimeEnvironment` with `homeURL` and sanitized environment.
- Produces: one actor-owned in-flight login task per executable/home identity.

- [ ] **Step 1: Write failing concurrent login test**

Launch 20 simultaneous `status()` calls after cache expiry; checker invocation count must equal 1. Test all callers receive the same result/error and a later call retries after failure.

- [ ] **Step 2: Write CODEX_HOME isolation tests**

Assert home is under candidate data root, no host skills/rules are copied, API-key variables are absent, and required login material is prepared only through the explicit manager policy.

- [ ] **Step 3: Verify red**

Run: `swift test --filter 'CodexLoginCacheTests|CodexHomeManagerTests'`.

- [ ] **Step 4: Implement in-flight coalescing and 1/5-second boundaries**

Actor stores a task keyed by executable path plus Codex home. Clear it on completion. Fast status timeout produces retryable state; hard boundary cancels/cleans the process.

- [ ] **Step 5: Inject environment into every Codex invocation**

Never rely on ambient `CODEX_HOME`. Show the resolved home in diagnostics without exposing credentials.

- [ ] **Step 6: Run login/process/generator tests**

Run: `swift test --filter 'CodexLoginCacheTests|CodexHomeManagerTests|BoundedCodexProcessRunnerTests|AutoReplyCodexGeneratorTests'`.

---

### Task 12: Implement incremental session registry, rotation, recovery, and contamination

**Files:**
- Create: `Sources/PDDAXReader/CodexHistoryCheckpoint.swift`
- Modify: `Sources/PDDAXReader/CodexSessionRegistry.swift`
- Modify: `Sources/PDDAXReader/AutoReplyCodexGenerator.swift`
- Create: `Tests/PDDAXReaderTests/CodexHistoryCheckpointTests.swift`
- Modify: `Tests/PDDAXReaderTests/CodexSessionRegistryTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyCodexGeneratorTests.swift`

**Interfaces:**
- Produces: extended `CodexSessionBinding` fields from design section 12.
- Produces: `CodexHistoryCheckpoint.delta(from:history:images:)` returning exact new JSONL and images.
- Consumes: prompt/knowledge hashes and execution contamination from Tasks 9–10.

- [ ] **Step 1: Write checkpoint prefix/delta tests**

Assert exact prefix yields only appended messages/images; content change in prefix forces rehydrate; repeated image SHA is not resubmitted.

- [ ] **Step 2: Write registry lifecycle tests**

Cover prompt change, knowledge change, one-hour lease, corrupt JSON backup, wrong resume thread ID, resume error, contamination, turn threshold and submitted-byte threshold. Assert diagnostic modes exactly match `new/resumed/rehydrated/recovered/rotated/contaminated`.

- [ ] **Step 3: Verify red**

Run: `swift test --filter 'CodexHistoryCheckpointTests|CodexSessionRegistryTests|AutoReplyCodexGeneratorTests'`.

- [ ] **Step 4: Implement canonical history checkpoint**

Hash canonical stable message events, not timestamps that can be backfilled. Persist submitted image SHA set. Return a full payload only when prefix validation fails.

- [ ] **Step 5: Implement corrupt recovery**

On decode/mismatched UID, atomically move the exact binding to `.corrupt-<milliseconds>.json`, return no active binding, and continue only that UID with new session.

- [ ] **Step 6: Implement rotation and contamination**

Centralize turn/byte thresholds in one policy object. Early reply is retained; contaminated binding is not used next turn.

- [ ] **Step 7: Run focused tests**

Expected: incremental resume submits only new JSONL and images; all invalidation reasons create the documented mode.

---

### Task 13: Deploy portable resources and a persistent V2 worker

**Files:**
- Create: `Sources/PDDAXReader/PortableKnowledgeRuntime.swift`
- Create: `Sources/PDDAXReader/PersistentV2Worker.swift`
- Modify: `Sources/PDDAXReader/KnowledgeResourceLocator.swift`
- Modify: `Sources/PDDAXReader/KnowledgeEvidenceService.swift`
- Modify: `Sources/PDDAXReader/V2KnowledgeRetriever.swift`
- Modify: `Sources/PDDAXReader/AutoReplyViewModel.swift`
- Modify: `scripts/build_app.sh`
- Modify: `scripts/verify_task_isolation_candidate.sh`
- Create: `Tests/PDDAXReaderTests/PersistentV2WorkerTests.swift`
- Modify: `Tests/PDDAXReaderTests/KnowledgeResourceLocatorTests.swift`
- Modify: `Tests/PDDAXReaderTests/V2KnowledgeRetrieverTests.swift`

**Interfaces:**
- Produces: `PersistentV2Worker.retrieve(request:) async throws -> RetrievedKnowledge`.
- Produces: hash-aware `PortableKnowledgeRuntime.prepare(bundleRoot:dataRoot:)`.
- Removes: prompt fallback that exposes a full ZIP path to Codex.

- [ ] **Step 1: Write worker protocol tests**

Use a fixture worker that returns request IDs out of order, sleeps beyond soft/hard limits, crashes, and recovers. Assert matching response, 2-second diagnostic, 5-second kill/restart, and next request success.

- [ ] **Step 2: Write portable deployment tests**

Assert bundled Python/runtime assets exist, deployed knowledge updates when source hash changes, unchanged hash reuses files, and stale `current.zip` is replaced atomically.

- [ ] **Step 3: Verify red**

Run: `swift test --filter 'PersistentV2WorkerTests|KnowledgeResourceLocatorTests|V2KnowledgeRetrieverTests'`.

- [ ] **Step 4: Implement newline request/response worker**

Keep one process, write JSON request with UUID, match response ID, serialize or multiplex according to worker capability, restart on protocol corruption/hard timeout, and drain stderr with a bounded buffer.

- [ ] **Step 5: Implement failure degradation**

Return empty or explicitly last-valid bounded evidence; never place ZIP path in prompt. Record V2 mode/error and continue Codex generation.

- [ ] **Step 6: Package portable runtime**

Copy required Python executable/runtime, scripts, site-packages, vector seed cache, and knowledge ZIP into app resources. Verification script checks executable bits, hashes/manifests, and runtime smoke request.

- [ ] **Step 7: Run Swift and Python tests**

Run:

```bash
swift test --filter 'PersistentV2WorkerTests|KnowledgeResourceLocatorTests|V2KnowledgeRetrieverTests|KnowledgeEvidenceServiceTests'
/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 -m unittest Tests/V2KnowledgePythonTests/test_retrieve_top12.py
```

---

### Task 14: Surface new lifecycle, scheduler, and execution diagnostics in UI

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyViewModel.swift`
- Modify: `Sources/PDDAXReader/AutoReplyView.swift`
- Modify: `Sources/PDDAXReader/AutoReplyProgressPresentation.swift`
- Modify: `Sources/PDDAXReader/AutoReplyFloatingProgress.swift`
- Modify: `Sources/PDDAXReader/AutoReplyDiagnostics.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyViewModelTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyProgressPresentationTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyFloatingProgressTests.swift`

**Interfaces:**
- Consumes: persistence health, desired-running, active UI stage, fairness count, pending capture counts, execution trace, V2 worker state.
- Produces: read-only presentation fields; UI must not trigger extra AX/OCR work.

- [ ] **Step 1: Write failing presentation tests**

Assert distinct messages for user-stopped, waiting-for-environment, running, send-paused-for-persistence, UI stage timeout, early reply ready/background cleanup, V2 restart, and contaminated session.

- [ ] **Step 2: Verify red**

Run UI model/presentation tests.

- [ ] **Step 3: Add bounded diagnostics to runtime snapshot**

Expose only metadata. Ensure the floating panel remains draggable, closable, resizable and does not call capture/discovery itself.

- [ ] **Step 4: Preserve aggressive continuation language**

Warnings explicitly state scheduler continues. Only user stop and send persistence pause use blocking language, and the latter says scanning/generation continue.

- [ ] **Step 5: Run UI tests**

Run: `swift test --filter 'AutoReplyViewModelTests|AutoReplyProgressPresentationTests|AutoReplyFloatingProgressTests'`.

---

### Task 15: Migration/fault-injection integration and full regression

**Files:**
- Modify: `Tests/PDDAXReaderTests/AutoReplyFaultInjectionTests.swift`
- Modify: `Tests/FaultInjection/pdd_task_isolation_soak.py`
- Modify: `Tests/PDDAXReaderTests/AutoReplyPackagingTests.swift`
- Modify: `Tests/PackagingTests/auto_reply_resources_test.sh`
- Modify: `docs/PDD全自动客服-代码级架构与调试交接手册.md`
- Create/Update: `docs/superpowers/evidence/2026-09-01-pdd-kernel-parity-verification.md`

**Interfaces:**
- Consumes: all prior task behaviors.
- Produces: reproducible verification record and updated coworker handoff.

- [ ] **Step 1: Add deterministic fault matrix cases**

Inject UI hang, OCR hang, V2 hang, Codex child ignoring TERM, state external modification, fsync failure, full-disk classification, corrupt session, deleted source image, A/B/C supplement, restart during each send commit phase, and multiple healthy UIDs.

- [ ] **Step 2: Run targeted fault tests**

Run:

```bash
swift test --filter 'AutoReplyFaultInjectionTests|AutoReplyContinuousMessageTests|AutoReplyTransactionalStoreTests|BoundedCodexProcessRunnerTests|PersistentV2WorkerTests'
```

Expected: zero failures; no duplicate send invocation; healthy UID progresses.

- [ ] **Step 3: Run full Swift suite**

Run: `swift test`  
Expected: all non-live tests pass; document exact total and any environment-gated skips.

- [ ] **Step 4: Run Python and packaging suites**

```bash
/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 -m unittest Tests/V2KnowledgePythonTests/test_retrieve_top12.py
zsh Tests/PackagingTests/auto_reply_resources_test.sh
```

- [ ] **Step 5: Run extended soak**

Run: `python3 Tests/FaultInjection/pdd_task_isolation_soak.py --duration 600 --seed 9012026`  
Expected: `SOAK PASS`, one valid UI lease maximum, zero revoked actions, zero duplicate sends, healthy/new revisions progress.

- [ ] **Step 6: Build and verify candidate**

```bash
zsh scripts/build_app.sh --task-isolation-candidate
zsh scripts/verify_task_isolation_candidate.sh
```

Expected: signed candidate with prompt, schema, portable Python/V2, WebOCR and knowledge manifests verified.

- [ ] **Step 7: Perform controlled live PDD validation**

With a test customer and explicit observation, validate pure text, A/B/C, image, mixed image/text, red-dot fairness, Codex hard timeout recovery, V2 restart, app restart with desired-running, manual stop/start, and uncertain-send reconciliation. Do not use uncontrolled real customers for injected failures.

- [ ] **Step 8: Update the handoff manual**

Replace schema-3, fixed concurrency, cursor-change-discards-A, one tail capture, 180-second Codex, per-query V2, prompt contradiction, and nonpersistent-intent descriptions. Add exact new paths, state fields, process cleanup, session modes and runbook commands.

- [ ] **Step 9: Run documentation integrity check**

Check balanced fences, no placeholders, every referenced local path exists, and documented commands match scripts. Record line/byte counts and verification output.

- [ ] **Step 10: Final verification gate**

Re-run `swift test` and candidate verification after the final documentation/source edit. Read full exit output before making completion claims.
