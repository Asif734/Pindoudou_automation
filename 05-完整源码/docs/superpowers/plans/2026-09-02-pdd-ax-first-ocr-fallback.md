# PDD AX-First OCR-Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make structured PDD AX messages authoritative and invoke OCR only for a narrowly selected new customer tail when AX is demonstrably unavailable or stale.

**Architecture:** Extract a complete, validity-scored AX visible-message snapshot; route each capture through a stateful source selector; convert OCR output into at most one provisional customer tail; reconcile that provisional event when AX catches up. Move the runtime to an AX-first history generation and migrate old OCR-authoritative pending state without deleting audit files.

**Tech Stack:** Swift 6, XCTest, macOS Accessibility API, ScreenCaptureKit, local PaddleOCR, JSON persistence, SwiftUI diagnostics.

**Spec:** `docs/superpowers/specs/2026-09-02-pdd-ax-first-ocr-fallback-design.md`

## Global Constraints

- AX is authoritative for message text, sender, type, stable DOM ID, time, and order whenever its structured chat subtree is valid.
- OCR never imports the whole visible page into durable history.
- OCR fallback requires missing/regressed AX structure or an unread-triggered one-second stale probe with at least three samples spaced by at least 200ms.
- OCR fallback emits at most the bottommost customer-side tail after the last AX anchor.
- AX recovery absorbs an identical provisional message observed within 30 seconds and never replies twice.
- Existing OCR-authoritative history remains untouched for audit and is not a prefix of the new timeline.
- A source failure never globally stops scanning other users.
- Do not change the short-reply prompt, Codex configuration, knowledge retrieval, watermark settings, or AX sender.
- This directory has no `.git`; replace commit steps with explicit test/checkpoint records and do not invent commits.

---

## File Structure

- Create `Sources/PDDAXReader/PDDAXVisibleMessageEvidence.swift`: full visible AX message extraction, structural validity, fingerprint, and regression comparison.
- Create `Sources/PDDAXReader/PDDMessageSourceSelector.swift`: per-UID AX freshness state and deterministic fallback decision.
- Create `Sources/PDDAXReader/PDDOCRTailSelector.swift`: anchor-aware selection of at most one provisional OCR customer tail.
- Create `Sources/PDDAXReader/PDDProvisionalMessageLedger.swift`: persisted provisional receipts and AX reconciliation.
- Modify `Sources/PDDAXReader/PDDAXImageEvidence.swift`: keep only image-selection/order responsibilities; reuse shared AX evidence rather than parse independently.
- Modify `Sources/PDDAXReader/PerUserChatStore.swift`: add an independent `history-ax-first.jsonl` store path and AX-authoritative merge.
- Modify `Sources/PDDAXReader/AutoReplyModels.swift`: schema 6 fields for source generation and provisional receipts.
- Modify `Sources/PDDAXReader/AutoReplyStore.swift`: idempotent schema 5 → 6 migration.
- Modify `Sources/PDDAXReader/PDDAXConversationDriver.swift`: AX-first capture orchestration and conditional OCR fallback.
- Modify `Sources/PDDAXReader/AutoReplyScheduler.swift`: restore/persist selector and provisional state and expose source diagnostics.
- Modify `Sources/PDDAXReader/AutoReplyViewModel.swift` and `Sources/PDDAXReader/AutoReplyView.swift`: truthful AX/OCR status copy.
- Create `Tests/PDDAXReaderTests/PDDAXVisibleMessageEvidenceTests.swift`.
- Create `Tests/PDDAXReaderTests/PDDMessageSourceSelectorTests.swift`.
- Create `Tests/PDDAXReaderTests/PDDOCRTailSelectorTests.swift`.
- Create `Tests/PDDAXReaderTests/PDDProvisionalMessageLedgerTests.swift`.
- Modify `Tests/PDDAXReaderTests/PerUserChatStoreTests.swift`.
- Modify `Tests/PDDAXReaderTests/AutoReplyStoreTests.swift`.
- Modify `Tests/PDDAXReaderTests/PDDAXConversationDriverTests.swift`.
- Modify `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`.
- Modify `Tests/PDDAXReaderTests/AutoReplyProgressPresentationTests.swift`.

---

### Task 1: Full AX visible-message evidence

**Files:**
- Create: `Sources/PDDAXReader/PDDAXVisibleMessageEvidence.swift`
- Create: `Tests/PDDAXReaderTests/PDDAXVisibleMessageEvidenceTests.swift`
- Modify: `Sources/PDDAXReader/PDDAXImageEvidence.swift`

**Interfaces:**
- Consumes: `AXNodeSnapshot`, `PDDChatParser.parse(root:capturedAt:)`.
- Produces: `PDDAXVisibleMessageEvidence.extract(root:capturedAt:) -> PDDAXVisibleMessageEvidence` with `messageNodeCount`, `messages`, `diagnostics`, `fingerprint`, and `isStructurallyValid`.

- [ ] **Step 1: Write failing tests for sender authority and validity**

Build literal AX fixtures containing `onemsg/buyer-item`, `onemsg/cs-item`, stable `AXDOMIdentifier`, text, and `image-msg`. Assert exact message order, sender, IDs, image kind, node count, and deterministic fingerprint. Add invalid fixtures for zero `onemsg`, zero parsed messages, and a node containing both sender classes.

```swift
func testExtractsBuyerAndServiceMessagesAsAuthoritativeEvidence() {
    let evidence = PDDAXVisibleMessageEvidence.extract(root: root(
        buyer(id: "middlePanel_list_100", text: "客户问题"),
        service(id: "middlePanel_list_101", text: "客服回复")
    ), capturedAt: fixedDate)
    XCTAssertTrue(evidence.isStructurallyValid)
    XCTAssertEqual(evidence.messages.map(\.sender), [.customer, .service])
    XCTAssertEqual(evidence.messages.map(\.id), ["middlePanel_list_100", "middlePanel_list_101"])
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter PDDAXVisibleMessageEvidenceTests`

Expected: compile failure because `PDDAXVisibleMessageEvidence` does not exist.

- [ ] **Step 3: Implement the minimal extractor**

Collect every `onemsg` once, parse each node with `PDDChatParser`, accumulate diagnostics, and hash canonical lines of `id|sender|kind|normalized-content`. Structural validity is true only when node count and parsed count are both positive and no ambiguous-sender diagnostic exists.

```swift
struct PDDAXVisibleMessageEvidence: Equatable, Sendable {
    let messageNodeCount: Int
    let messages: [PDDChatMessage]
    let diagnostics: [String]
    let fingerprint: String
    let isStructurallyValid: Bool

    static func extract(root: AXNodeSnapshot, capturedAt: Date) -> Self
}
```

- [ ] **Step 4: Make image evidence consume the shared extraction path**

Keep `PDDAXTailEvidence.customerImages` behavior, but remove its duplicate traversal/parser assumptions. Derive its messages from the new evidence and retain the Chrome node ID suffix behavior for fallback image IDs.

- [ ] **Step 5: Run focused tests and record checkpoint**

Run: `swift test --filter 'PDDAXVisibleMessageEvidenceTests|PDDAXImageEvidenceTests|PDDChatParserTests'`

Expected: all selected tests pass with 0 failures.

---

### Task 2: Stateful AX freshness decision

**Files:**
- Create: `Sources/PDDAXReader/PDDMessageSourceSelector.swift`
- Create: `Tests/PDDAXReaderTests/PDDMessageSourceSelectorTests.swift`

**Interfaces:**
- Consumes: UID, unread evidence flag, sample timestamps, and `PDDAXVisibleMessageEvidence`.
- Produces: `PDDMessageSourceDecision` values `.useAX`, `.resampleAX(afterNanoseconds:)`, or `.useOCR(reason:)`.

- [ ] **Step 1: Write failing table-driven decision tests**

Cover: valid changed AX uses AX immediately; missing subtree uses OCR immediately; unread + unchanged first/second samples requests resampling; third unchanged sample inside the one-second deadline uses OCR; no unread + unchanged valid AX uses AX/no-op; regressed AX uses OCR; a changed fingerprint resets stale sampling.

```swift
XCTAssertEqual(selector.observe(uid: uid, unread: true, evidence: same, now: t0),
               .resampleAX(afterNanoseconds: 200_000_000))
XCTAssertEqual(selector.observe(uid: uid, unread: true, evidence: same, now: t400),
               .useOCR(reason: .unreadAXStale))
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter PDDMessageSourceSelectorTests`

Expected: compile failure because the selector types do not exist.

- [ ] **Step 3: Implement selector state without sleeping**

Store per-UID last trusted fingerprint/ordered stable IDs and an optional stale-probe record. The selector returns a resample delay; `PDDAXConversationDriver` performs the wait/read, keeping policy deterministic and independently testable.

```swift
enum PDDAXFallbackReason: String, Codable, Sendable {
    case missingStructure, regressedStructure, unreadAXStale
}

enum PDDMessageSourceDecision: Equatable, Sendable {
    case useAX
    case resampleAX(afterNanoseconds: UInt64)
    case useOCR(reason: PDDAXFallbackReason)
}
```

- [ ] **Step 4: Run focused tests and record checkpoint**

Run: `swift test --filter PDDMessageSourceSelectorTests`

Expected: all selector tests pass with 0 failures.

---

### Task 3: Anchor-aware OCR tail selection

**Files:**
- Create: `Sources/PDDAXReader/PDDOCRTailSelector.swift`
- Create: `Tests/PDDAXReaderTests/PDDOCRTailSelectorTests.swift`
- Modify: `Sources/PDDAXReader/PDDOCRModels.swift` only if an explicit provisional conversion helper is required.

**Interfaces:**
- Consumes: parsed OCR messages with boxes, AX visible messages, unread evidence, UID, and capture time.
- Produces: `PDDChatMessage?` whose ID starts with `ocr-provisional-`.

- [ ] **Step 1: Write failing tests that reject page history**

Use literal OCR fixtures containing old customer text, old service text mislabelled customer, watermark text, the AX anchor, and one bottom new customer bubble. Assert the selector returns only the bottom bubble. Assert nil for no anchor plus no unread, nil when only an AX service duplicate exists, and one bottom customer result for no anchor plus unread.

```swift
let selected = PDDOCRTailSelector.select(
    uid: uid, ocr: [old, fakeService, anchorOCR, newest], ax: [anchorAX],
    hasUnreadEvidence: true, capturedAt: fixedDate
)
XCTAssertEqual(selected?.content, "唯一新问题")
XCTAssertTrue(selected?.id.hasPrefix("ocr-provisional-") == true)
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter PDDOCRTailSelectorTests`

Expected: compile failure because `PDDOCRTailSelector` does not exist.

- [ ] **Step 3: Implement exact anchor and bottom-tail rules**

Match the final AX visible text against OCR by sender and normalized exact content. Drop all OCR entries through that anchor. Remove exact AX service duplicates and known platform noise. Select only the last remaining customer-side text entry. Do not concatenate page-wide candidates or use fuzzy similarity.

- [ ] **Step 4: Run parser and selector tests and record checkpoint**

Run: `swift test --filter 'PDDOCRTailSelectorTests|PDDOCRChatParserTests|PDDOCRModelsTests'`

Expected: all selected tests pass with 0 failures.

---

### Task 4: Provisional receipt reconciliation

**Files:**
- Create: `Sources/PDDAXReader/PDDProvisionalMessageLedger.swift`
- Create: `Tests/PDDAXReaderTests/PDDProvisionalMessageLedgerTests.swift`
- Modify: `Sources/PDDAXReader/AutoReplyModels.swift`

**Interfaces:**
- Produces persisted `PDDProvisionalReceipt` and `PDDProvisionalMessageLedger.reconcile(axMessages:now:)`.
- Later tasks persist `[String: [PDDProvisionalReceipt]]` by UID in `AutoReplyPersistentState`.

- [ ] **Step 1: Write failing tests for the 30-second absorption contract**

Assert exact normalized content within 30 seconds absorbs the AX message; content mismatch does not; 30.001 seconds does not; absorbed/answered receipts do not emit a second actionable event; repeated reconciliation is idempotent.

```swift
struct PDDProvisionalReceipt: Codable, Equatable, Sendable {
    let provisionalMessageID: String
    let normalizedContent: String
    let firstObservedAt: Date
    var answered: Bool
    var absorbedAXMessageID: String?
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter PDDProvisionalMessageLedgerTests`

Expected: compile failure because the receipt and ledger types do not exist.

- [ ] **Step 3: Implement exact-content reconciliation**

Never replace AX content or sender. Return filtered actionable AX messages plus updated receipts; record the AX ID on absorption. Prune only absorbed receipts older than the existing state retention horizon; do not delete active receipts.

- [ ] **Step 4: Run focused tests and record checkpoint**

Run: `swift test --filter PDDProvisionalMessageLedgerTests`

Expected: all ledger tests pass with 0 failures.

---

### Task 5: AX-first history generation and schema-6 migration

**Files:**
- Modify: `Sources/PDDAXReader/PerUserChatStore.swift`
- Modify: `Sources/PDDAXReader/AutoReplyModels.swift`
- Modify: `Sources/PDDAXReader/AutoReplyStore.swift`
- Modify: `Tests/PDDAXReaderTests/PerUserChatStoreTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyStoreTests.swift`

**Interfaces:**
- Produces: `PerUserChatStore.loadAXFirst(uid:)`, `mergeAXFirst(uid:messages:)`, schema version 6, `provisionalReceiptsByUID`, and `axFirstBaselinedUIDs`.

- [ ] **Step 1: Write failing history-isolation tests**

Persist a polluted legacy `history.jsonl`, then call `loadAXFirst`. Assert it returns empty and legacy bytes remain unchanged. Merge AX messages and assert only `history-ax-first.jsonl` changes. Assert repeated AX IDs update metadata without duplicating events.

- [ ] **Step 2: Write failing schema migration tests**

Create schema-5 state containing completed jobs, failed jobs, queued/generating OCR-only jobs, pending capture requests, OCR answered cursors, and locators. After load, assert schema 6; terminal records and locators remain; unsent OCR jobs become failed with migration reason; pending requests and old answered cursors/baselines clear; receipts initialize empty; a backup is written once; loading again is unchanged.

- [ ] **Step 3: Run focused tests and verify RED**

Run: `swift test --filter 'PerUserChatStoreTests|AutoReplyStoreTests'`

Expected: new isolation/migration assertions fail against schema 5 and the legacy history path.

- [ ] **Step 4: Implement separate AX-first storage**

Factor the existing JSONL decode/persist mechanics so legacy and AX-first filenames share validation without sharing contents. `mergeAXFirst` accepts AX messages and provisional events selected by Task 3 only; it must not call `mergeOCRAuthoritative`.

- [ ] **Step 5: Implement idempotent schema 5 → 6 migration**

Back up original `state.json` as `state.schema5-backup-<timestamp>.json`, transform once, append one `ax-first-migration` event per affected UID, cap events at 100, and atomically persist schema 6. Preserve completed/failed/uncertain/quarantined jobs; fail only discovered/capturing/queued/generating/ready/sending jobs whose target IDs are exclusively `ocr-*` and were not confirmed sent.

- [ ] **Step 6: Run focused tests and record checkpoint**

Run: `swift test --filter 'PerUserChatStoreTests|AutoReplyStoreTests|AutoReplyTransactionalStoreTests'`

Expected: all selected tests pass with 0 failures.

---

### Task 6: Integrate AX-first capture in the conversation driver

**Files:**
- Modify: `Sources/PDDAXReader/PDDAXConversationDriver.swift`
- Modify: `Sources/PDDAXReader/PDDAXImageEvidence.swift`
- Modify: `Tests/PDDAXReaderTests/PDDAXConversationDriverTests.swift`

**Interfaces:**
- Consumes Tasks 1–5 APIs.
- Produces unchanged public `capture(uid:after:lease:) -> AutoReplyCapture`, with a truthful `ocrDiagnostic` source description.

- [ ] **Step 1: Write failing driver integration tests**

Cover these end-to-end capture branches with real parsers and controlled backends: valid AX bypasses OCR entirely; AX customer delta creates a batch; valid unchanged AX creates no batch; missing AX invokes OCR once and accepts only one provisional tail; unread stale AX performs three reads before OCR; AX recovery absorbs a provisional; OCR failure throws only for the current capture and the next capture can recover.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter PDDAXConversationDriverTests`

Expected: at least valid-AX-bypasses-OCR fails because the current driver calls OCR unconditionally.

- [ ] **Step 3: Replace OCR-authoritative orchestration**

Read and score AX first. Loop only when the selector returns `.resampleAX`; validate the UI lease before and after each wait/read. Call OCR only on `.useOCR`, pass its output through `PDDOCRTailSelector`, reconcile receipts, then call `mergeAXFirst`. Remove the production call to `mergeOCRAuthoritative`.

- [ ] **Step 4: Preserve baseline and image behavior**

On first AX-first capture without unread evidence, baseline the AX-first timeline. With unread evidence, freeze only customers after the final visible AX service boundary. Continue resolving/downloading images from AX `image-msg`; OCR still cannot create image events.

- [ ] **Step 5: Run focused integration tests and record checkpoint**

Run: `swift test --filter 'PDDAXConversationDriverTests|PDDAXImageEvidenceTests|PDDHybridMessageOrderingTests'`

Expected: all selected tests pass; update/remove only tests that assert the intentionally deleted OCR-authoritative contract.

---

### Task 7: Persist runtime source state and expose truthful diagnostics

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Modify: `Sources/PDDAXReader/AutoReplyProgressPresentation.swift`
- Modify: `Sources/PDDAXReader/AutoReplyViewModel.swift`
- Modify: `Sources/PDDAXReader/AutoReplyView.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyProgressPresentationTests.swift`

**Interfaces:**
- Consumes: schema-6 receipt/baseline state and driver diagnostics.
- Produces: durable restore/save and the exact UI messages listed in the spec.

- [ ] **Step 1: Write failing scheduler persistence tests**

Assert receipts survive restart; an absorbed receipt stays absorbed; source failures do not set `isRunning` false; other UIDs continue; and migration-failed jobs are not requeued.

- [ ] **Step 2: Write failing presentation tests**

Assert exact states for `AX 权威读取：N 条可见消息`, `AX 未前进（3/3），启用尾部 OCR`, `OCR 临时客户消息：<summary>`, `AX 已恢复并吸收 OCR 临时消息`, and `AX/OCR 均无可信新消息，继续轮询`.

- [ ] **Step 3: Run focused tests and verify RED**

Run: `swift test --filter 'AutoReplySchedulerTests|AutoReplyProgressPresentationTests'`

Expected: new persistence and copy assertions fail.

- [ ] **Step 4: Wire state restore/save and UI fields**

Restore selector snapshots, AX-first baselines, and receipts at scheduler initialization; persist after every receipt creation/answer/absorption. Replace the old blanket `OCR 已读取 N 条可见气泡` wording with the source decision and accepted-count wording.

- [ ] **Step 5: Run focused tests and record checkpoint**

Run: `swift test --filter 'AutoReplySchedulerTests|AutoReplyProgressPresentationTests|AutoReplyViewModelTests'`

Expected: all selected tests pass with 0 failures.

---

### Task 8: Full verification, package, and live probe

**Files:**
- Modify only if verification exposes a scoped defect.
- Record evidence in `docs/superpowers/evidence/2026-09-02-pdd-ax-first-live-validation.md`.

**Interfaces:**
- Consumes the completed AX-first runtime.
- Produces a signed candidate app and reproducible live evidence.

- [ ] **Step 1: Run the complete automated suite**

Run: `swift test`

Expected: all tests pass, 0 failures. If the known worker timeout flakes, run the failing test alone to classify it, then rerun the complete suite fresh; do not claim success from the isolated rerun.

- [ ] **Step 2: Build and inspect the candidate app**

Run: `./scripts/build_app.sh --task-isolation-candidate`

Then verify bundle resources, executable identity, and signature:

```bash
test -x 'outputs/拼多多全自动客服-任务隔离候选版.app/Contents/MacOS/PDDTaskIsolationCandidate'
codesign --verify --deep --strict 'outputs/拼多多全自动客服-任务隔离候选版.app'
```

- [ ] **Step 3: Run a read-only AX/OCR comparison**

With the current conversation visible, record AX `onemsg` IDs/classes/text, raw OCR text/boxes, source decision, and elapsed times. Verify prior service replies and diagonal shop watermarks do not appear in the actionable customer batch.

- [ ] **Step 4: Run one controlled unique-message test**

After the user provides a unique test message, record: first visible time, each AX sample time/fingerprint, fallback decision, task target JSONL, Codex duration, send result, and AX recovery. Verify exactly one reply and no feedback-loop job.

- [ ] **Step 5: Launch formal mode and verify UI**

Restart the candidate app, use Computer Use to click `开始`, and verify the UI shows `停止`, dry-run value `0`, `运行中`, and `允许 AX 发送`. Confirm queue and CLI counts settle to zero after the controlled test.

- [ ] **Step 6: Write the evidence record**

Include exact command outputs, test counts, app path, process ID, source diagnostics, task sequence, and any limitations. Do not claim AX-first completion without both fresh full-suite evidence and the controlled live result.

