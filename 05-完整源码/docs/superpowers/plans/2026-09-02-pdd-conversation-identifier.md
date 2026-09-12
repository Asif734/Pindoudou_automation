# PDD Conversation Identifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hard-coded `GZC-[0-9]+` identity gate with a persisted conversation locator that prefers a unique AX DOM identifier and falls back to the visible nickname without blocking the scheduler.

**Architecture:** Keep scheduler-facing `uid: String` as the safe local isolation key, but derive it from a new `PDDConversationLocator`. Discovery extracts only true outer conversation rows, persists `uid -> locator`, and reopening tries DOM identifier first, nickname second, then the current usable chat surface. Schema migration removes unlocatable legacy pending captures while retaining legacy terminal history.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, macOS Accessibility API, CryptoKit SHA-256, XCTest, JSON Codable state.

**Spec:** `docs/superpowers/specs/2026-09-02-pdd-conversation-identifier-design.md`

## Global Constraints

- `AXDOMIdentifier` is a page element identifier, not a claimed real buyer UID.
- Identifier lookup has priority; missing, duplicate, changed, or absent identifiers fall back to the normalized visible nickname.
- Multiple nickname matches choose the first valid outer conversation row and emit a warning; they must not block global processing.
- Preserve macOS 14 as the deployment floor and add no third-party dependency.
- Keep legacy `GZC-[0-9]+` paths readable, but create new work only under safe `PDD-ID-*` or `PDD-NAME-*` keys.
- Do not change OCR, image download, Codex reply content, knowledge retrieval, or video handling.
- This workspace has no `.git` directory; replace commit steps with explicit test checkpoints and do not initialize a repository.

---

### Task 1: Conversation Locator and Safe Local Key

**Files:**
- Create: `Sources/PDDAXReader/PDDConversationLocator.swift`
- Modify: `Sources/PDDAXReader/PerUserAXStore.swift`
- Test: `Tests/PDDAXReaderTests/PDDConversationLocatorTests.swift`
- Test: `Tests/PDDAXReaderTests/PerUserAXStoreTests.swift`

**Interfaces:**
- Produces: `PDDConversationLocator(domIdentifier:nickname:)`
- Produces: `PDDConversationKey.make(locator:) -> String`
- Produces: `PDDConversationLocator.normalizedNickname: String`
- Extends: `PerUserAXStore.validUID(_:)` for new key formats.

- [ ] **Step 1: Write failing locator/key tests**

```swift
func testUniqueIdentifierProducesIdentifierKey() {
    let locator = PDDConversationLocator(domIdentifier: "buyer-row-123", nickname: "S***")
    XCTAssertTrue(PDDConversationKey.make(locator: locator).hasPrefix("PDD-ID-"))
}

func testMissingIdentifierProducesNicknameKey() {
    let locator = PDDConversationLocator(domIdentifier: nil, nickname: "  S***  ")
    XCTAssertTrue(PDDConversationKey.make(locator: locator).hasPrefix("PDD-NAME-"))
    XCTAssertEqual(locator.normalizedNickname, "S***")
}

func testSameNicknameWithDifferentIdentifiersProducesDifferentKeys() {
    XCTAssertNotEqual(
        PDDConversationKey.make(locator: .init(domIdentifier: "row-a", nickname: "S***")),
        PDDConversationKey.make(locator: .init(domIdentifier: "row-b", nickname: "S***"))
    )
}
```

- [ ] **Step 2: Run the focused tests and verify compilation fails**

Run: `swift test --filter PDDConversationLocatorTests`

Expected: FAIL because `PDDConversationLocator` and `PDDConversationKey` do not exist.

- [ ] **Step 3: Implement the focused locator and key type**

```swift
import CryptoKit
import Foundation

struct PDDConversationLocator: Codable, Equatable, Sendable {
    var domIdentifier: String?
    var nickname: String

    var normalizedNickname: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PDDConversationKey {
    static func make(locator: PDDConversationLocator) -> String {
        let identifier = locator.domIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = identifier.flatMap { $0.isEmpty ? nil : $0 } ?? locator.normalizedNickname
        let prefix = identifier?.isEmpty == false ? "PDD-ID-" : "PDD-NAME-"
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return prefix + digest.prefix(24)
    }
}
```

- [ ] **Step 4: Extend safe path validation with exact regexes**

Accept `^GZC-[0-9]+$`, `^PDD-ID-[0-9a-f]{24}$`, and `^PDD-NAME-[0-9a-f]{24}$`; retain the existing length, ellipsis, and control-character checks.

- [ ] **Step 5: Run focused tests**

Run: `swift test --filter PDDConversationLocatorTests && swift test --filter PerUserAXStoreTests`

Expected: PASS.

### Task 2: Extract Only Real Conversation Rows

**Files:**
- Modify: `Sources/PDDAXReader/PDDAXSemanticNode.swift`
- Modify: `Sources/PDDAXReader/PDDAXControlSelection.swift`
- Test: `Tests/PDDAXReaderTests/PDDAXControlSelectionTests.swift`

**Interfaces:**
- Changes: `PDDConversationRow` adds `domIdentifier: String?` and retains `visibleLabel` as the nickname compatibility accessor.
- Produces: `PDDAXControlSelection.conversationRows(in:)` with only outer rows and valid nicknames.

- [ ] **Step 1: Add failing fixtures for nested actions and footer noise**

Create a conversation-list fixture with three outer rows named `S***`, `c*y`, and `山**川`; put a timestamp and nested `转移会话` pressable under each row; add a `已经没有更多了哦~` footer. Assert exactly three rows and assert their DOM identifiers and nicknames.

```swift
XCTAssertEqual(rows.map(\.visibleLabel), ["S***", "c*y", "山**川"])
XCTAssertEqual(rows.map(\.domIdentifier), ["row-a", "row-b", "row-c"])
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `swift test --filter PDDAXControlSelectionTests`

Expected: FAIL because the existing first-descendant label selection returns timestamps/actions and nested rows.

- [ ] **Step 3: Extend the row value object**

```swift
struct PDDConversationRow<ID: Hashable>: Equatable {
    let rowID: ID
    let visibleLabel: String
    let domIdentifier: String?
    let frame: CGRect
}
```

- [ ] **Step 4: Implement outer-row and nickname selection**

Use the nearest ancestor in the conversation list to reject nested pressable controls. Reject candidate text matching `^\d{1,2}:\d{2}$`, pure digits, `转移会话`, `加载更多会话`, `已经没有更多了哦~`, and known footer phrases. Prefer a descendant whose DOM classes contain nickname/name/user; otherwise select the first non-noise text that is not an action, timestamp, unread count, or preview-only descendant.

- [ ] **Step 5: Validate DOM identifier uniqueness in the returned list**

After constructing rows, count nonempty identifiers. Set `domIdentifier` to `nil` for identifiers that occur more than once so downstream key creation automatically uses nickname fallback.

- [ ] **Step 6: Run selection and existing driver tests**

Run: `swift test --filter PDDAXControlSelectionTests && swift test --filter PDDAXConversationDriverTests`

Expected: PASS after fixture initializers are updated for the new field.

### Task 3: Persist Locators and Migrate Legacy Pending Work

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyModels.swift`
- Modify: `Sources/PDDAXReader/AutoReplyStore.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyStoreTests.swift`

**Interfaces:**
- Adds: `AutoReplyPersistentState.conversationLocatorsByUID: [String: PDDConversationLocator]`
- Raises: persistent schema version from 4 to 5.
- Migration: schema 4 drops active legacy `GZC-*` pending captures without locators and appends `legacy-locator-dropped` events.

- [ ] **Step 1: Write a failing schema-4 migration test**

Persist schema 4 with one completed legacy job and one pending `GZC-000001` capture. Load it and assert the completed job remains, the pending request is gone, schema is 5, and the migration event exists.

- [ ] **Step 2: Run the test and verify unsupported/new-field failure**

Run: `swift test --filter AutoReplyStoreTests`

Expected: FAIL because schema 5 and locator storage do not exist.

- [ ] **Step 3: Add the state field and Codable default**

```swift
var schemaVersion = 5
var conversationLocatorsByUID: [String: PDDConversationLocator] = [:]
```

Decode the dictionary with `decodeIfPresent(...) ?? [:]` for legacy files.

- [ ] **Step 4: Implement schema-4 migration**

Create the normal timestamped schema backup, remove pending requests whose UID begins `GZC-` and lacks a locator, append one bounded migration event per dropped UID, set schema 5, and atomically save. Do not delete jobs, archives, cursor dictionaries, history folders, or Codex sessions.

- [ ] **Step 5: Run store tests**

Run: `swift test --filter AutoReplyStoreTests && swift test --filter AutoReplyTransactionalStoreTests`

Expected: PASS.

### Task 4: Identifier-First Conversation Discovery and Reopening

**Files:**
- Modify: `Sources/PDDAXReader/PDDAXConversationDriver.swift`
- Modify: `Sources/PDDAXReader/PDDLiveAutoReplyDriver.swift`
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Test: `Tests/PDDAXReaderTests/PDDAXConversationDriverTests.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`

**Interfaces:**
- Driver receives a locator persistence closure or store shared with scheduler.
- Discovery returns the safe internal key derived from the locator.
- Reopening takes the internal key, resolves its persisted locator, and matches identifier then nickname.
- Driver exposes warnings through the existing diagnostic/event path rather than throwing for ambiguity/current-page fallback.

- [ ] **Step 1: Write failing identifier-first and nickname-fallback tests**

Cover:

```swift
// Exact identifier wins even if two rows display S***.
// Missing old identifier falls back to nickname and refreshes locator.
// Two nickname matches choose the first row and emit an ambiguity warning.
// No matching row plus a usable current chat surface returns the current tree.
```

- [ ] **Step 2: Run focused driver tests and verify failure**

Run: `swift test --filter PDDAXConversationDriverTests`

Expected: FAIL because current logic calls `PDDCustomerIdentity.resolve` and requires `GZC-*`.

- [ ] **Step 3: Replace GZC resolution in discovery**

When unread evidence returns a row, construct the locator from that row, derive the safe UID, persist the locator, press the row, wait 80ms, and accept a semantic tree containing the chat surface. Remove the post-click `PDDCustomerIdentity.resolve` gate.

- [ ] **Step 4: Replace reopening logic**

Load the locator for the UID. Match a true row by exact nonempty identifier first. If absent, match normalized nickname. For multiple nickname candidates, choose the first in the already ordered result and send a diagnostic warning. After pressing, accept a usable chat surface; if no row matches but the current tree already has a composer/chat panel, return it with a current-page warning.

- [ ] **Step 5: Persist refreshed identifiers through scheduler state**

The driver callback supplies `(uid, locator, diagnostic)`. Scheduler mutates `state.conversationLocatorsByUID[uid]`, commits it through the existing persistence path, and maps the diagnostic enum exactly: `.identifierRefreshed` to `conversation-identifier-refreshed`, `.nicknameAmbiguous` to `conversation-nickname-ambiguous`, and `.currentFallback` to `conversation-current-fallback`.

- [ ] **Step 6: Bound an unmatched locator retry**

When an unmatched locator throws, leave the capture request in the queue with a `notBefore` timestamp exactly one second after the failed attempt. `dequeueCaptureRequest` must skip requests whose `notBefore` is in the future. Add a scheduler test proving two ticks inside one second produce only one open attempt and a tick at or after one second makes the second attempt.

- [ ] **Step 7: Run driver and scheduler tests**

Run: `swift test --filter PDDAXConversationDriverTests && swift test --filter AutoReplySchedulerTests`

Expected: PASS.

### Task 5: Reader Compatibility, Live Probe, Full Verification, and Deployment

**Files:**
- Modify: `Sources/PDDAXReader/ReaderWorkflow.swift`
- Modify: `Sources/PDDAXReader/SingleAXParseWorkflow.swift`
- Modify: `Tests/PDDAXReaderTests/LivePDDOCRSmokeTests.swift`
- Test: `Tests/PDDAXReaderTests/ReaderWorkflowTests.swift`
- Test: `Tests/PDDAXReaderTests/SingleAXParseWorkflowTests.swift`
- Build: `scripts/build_app.sh`

**Interfaces:**
- Reader mode reports the selected conversation locator/key instead of requiring `PDDCustomerIdentity`.
- Live smoke output prints `nickname`, `domIdentifier`, and `frame` for true rows.

- [ ] **Step 1: Add failing reader tests with masked nickname and DOM identifier**

Assert reader and single-parse workflows succeed without any `GZC-*` string when a valid conversation locator is available.

- [ ] **Step 2: Implement reader locator resolution**

Reuse the same selection/key path as the automatic driver; do not maintain a second identity algorithm.

- [ ] **Step 3: Extend the authorized live smoke diagnostic**

Print exactly one line per true row:

```text
PDD conversation nickname=<value> domIdentifier=<value-or-nil> frame=<rect>
```

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
swift test --filter ReaderWorkflowTests
swift test --filter SingleAXParseWorkflowTests
swift test
```

Expected: all non-live tests pass; environment-gated live tests may skip unless explicitly enabled.

- [ ] **Step 5: Run the authorized live probe**

Run: `PDD_LIVE_OCR=1 swift test --filter LivePDDOCRSmokeTests/testCurrentPDDWindowMapsPixelRedDotsOntoAXConversationRows`

Expected: only true user rows, with distinct DOM identifiers when PDD exposes them; missing identifiers are printed as nil and exercise nickname fallback.

- [ ] **Step 6: Back up and build the candidate app**

Run: `./scripts/build_app.sh --task-isolation-candidate`

Expected: release build succeeds, previous app is moved under `outputs/backups/<timestamp>/`, resources compare successfully, and codesign succeeds.

- [ ] **Step 7: Launch and perform live acceptance**

Open the rebuilt candidate, press Start, and verify:

- current `S***` can be captured without `GZC-*`;
- the old pending hot loop does not return;
- two same-nickname fixtures remain separate when identifiers differ;
- identifier absence/expiry produces a warning and nickname fallback rather than stopping;
- the scheduler continues scanning after warnings.

- [ ] **Step 8: Record verification evidence**

Report exact test counts, live row diagnostics, built app path, whether the running process points to the rebuilt executable, and any remaining ambiguity risk from duplicate masked nicknames.
