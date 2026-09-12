# PDD AX + OCR Hybrid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local PaddleOCR fallback that supplements stale or missing PDD AX chat messages without changing AX-based identity, navigation, or sending.

**Architecture:** A focused OCR subsystem captures the verified PDD window chat region, recognizes positioned text, parses left/right message bubbles, and reconciles OCR messages with AX history. `PDDHybridConversationDriver` prefers AX and invokes OCR only on defined degradation signals, while the existing scheduler remains the single generation and delivery coordinator.

**Tech Stack:** Swift 5.9, macOS 13+, AppKit, ApplicationServices, ScreenCaptureKit, WebKit, Network, PP-OCRv5 ONNX/WASM, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-29-pdd-ax-ocr-hybrid-design.md`

## Global Constraints

- AX remains authoritative for UID, navigation, composer, and send actions.
- OCR handles text only; images are out of scope.
- OCR failures must not stop later scheduler ticks.
- The OCR engine is local and its initialized instance is reused.
- No production implementation is written before its focused test fails for the missing behavior.
- This workspace is not a Git repository, so commit steps are inapplicable.

---

### Task 1: Positioned OCR models, normalization, and stable identity

**Files:**
- Create: `Sources/PDDAXReader/PDDOCRModels.swift`
- Create: `Tests/PDDAXReaderTests/PDDOCRModelsTests.swift`

**Interfaces:**
- Produces: `PDDOCRLine`, `PDDOCRMessage`, `PDDOCRNormalizer.normalize(_:)`, and `PDDOCRMessageID.make(uid:sender:timestamp:text:occurrence:)`.

- [ ] Write focused tests with literal expected normalization and IDs, including repeated equal text with different occurrence indices.
- [ ] Run `swift test --filter PDDOCRModelsTests` and verify failure because the types do not exist.
- [ ] Implement the minimal model, normalization, and CryptoKit SHA-256 ID code.
- [ ] Re-run the focused tests and verify they pass.

### Task 2: PDD spatial OCR parser

**Files:**
- Create: `Sources/PDDAXReader/PDDOCRChatParser.swift`
- Create: `Tests/PDDAXReaderTests/PDDOCRChatParserTests.swift`

**Interfaces:**
- Consumes: `[PDDOCRLine]`, image size, and UID.
- Produces: `PDDOCRChatParser.parse(uid:lines:imageSize:) -> [PDDOCRMessage]`.

- [ ] Write fixture tests proving left text becomes customer, right text becomes service, centered time attaches to the next bubble, toolbar/system text is excluded, and ambiguous center text is not customer input.
- [ ] Run `swift test --filter PDDOCRChatParserTests` and verify the missing parser failure.
- [ ] Implement row grouping, chat-area filtering, time recognition, side classification, and stable occurrence numbering.
- [ ] Re-run focused tests and verify they pass.

### Task 3: AX/OCR history reconciliation

**Files:**
- Create: `Sources/PDDAXReader/PDDHybridHistoryReconciler.swift`
- Create: `Tests/PDDAXReaderTests/PDDHybridHistoryReconcilerTests.swift`

**Interfaces:**
- Consumes: AX `[PDDChatMessage]` and OCR `[PDDOCRMessage]`.
- Produces: `PDDHybridHistoryReconciler.merge(ax:ocr:) -> [PDDChatMessage]`.

- [ ] Write tests proving matching AX wins, OCR-only customer text is appended once, repeated equal messages retain order, and later AX recovery does not duplicate OCR history.
- [ ] Run the focused test and verify failure for the absent reconciler.
- [ ] Implement the minimal ordered reconciliation and source-stable IDs.
- [ ] Re-run focused tests and verify they pass.

### Task 4: Local PaddleOCR engine and resource packaging

**Files:**
- Create: `Sources/PDDAXReader/PDDLocalResourceServer.swift`
- Create: `Sources/PDDAXReader/PDDPaddleOCREngine.swift`
- Create: `Resources/WebOCR/**`
- Modify: `Package.swift`
- Modify: `scripts/build_app.sh`
- Create: `Tests/PDDAXReaderTests/PDDOCRResourceTests.swift`

**Interfaces:**
- Produces: `PDDOCRRecognizing.recognize(_:) async throws -> [PDDOCRLine]` and a reusable `PDDPaddleOCREngine`.

- [ ] Write tests for safe resource resolution, MIME types, installed resource selection, and required packaged asset presence.
- [ ] Run the focused test and verify failure because the OCR resource boundary is missing.
- [ ] Implement the local resource server and WKWebView bridge, and vendor the exact PP-OCRv5 WebOCR assets from the verified Qianniu component.
- [ ] Update build packaging to copy `Resources/WebOCR` into each relevant App bundle.
- [ ] Re-run focused tests and verify they pass.

### Task 5: PDD window capture and chat crop

**Files:**
- Create: `Sources/PDDAXReader/PDDOCRCapture.swift`
- Create: `Tests/PDDAXReaderTests/PDDOCRCaptureTests.swift`

**Interfaces:**
- Produces: `PDDOCRCapturing.capture() async throws -> PDDOCRFrame` and pure `PDDOCRCropGeometry` calculations.

- [ ] Write tests for 1x/2x crop scaling, translated windows, invalid intersections, and conservative fallback chat bounds.
- [ ] Run the focused test and verify the geometry API is absent.
- [ ] Implement ScreenCaptureKit single-window capture, AX window bounds lookup, and chat-region crop.
- [ ] Re-run focused tests and verify they pass.

### Task 6: Read-only live OCR probe

**Files:**
- Create: `Sources/PDDAXReader/PDDOCRProbe.swift`
- Modify: `Sources/PDDAXReader/PDDAXReaderApp.swift`
- Modify: `Resources/Info.plist`
- Modify: `Resources/AutoReplyInfo.plist`

**Interfaces:**
- Produces: a probe mode that writes screenshot, raw positioned OCR JSON, parsed JSON, and elapsed timing below `~/Desktop/拼多多AX记录/OCR实验/`.

- [ ] Add a command-level test for probe output structure using a fixture recognizer and capture.
- [ ] Run the focused test and verify the probe does not exist.
- [ ] Implement the read-only probe and screen-recording usage description.
- [ ] Build and run the probe against the currently open PDD window; compare parsed output with AX ground truth and adjust parser only through new failing fixtures.

### Task 7: Hybrid capture fallback

**Files:**
- Create: `Sources/PDDAXReader/PDDHybridConversationDriver.swift`
- Modify: `Sources/PDDAXReader/PDDLiveAutoReplyDriver.swift`
- Modify: `Sources/PDDAXReader/PDDAXReaderApp.swift`
- Modify: `Sources/PDDAXReader/AutoReplyProgressPresentation.swift`
- Create: `Tests/PDDAXReaderTests/PDDHybridConversationDriverTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyProgressPresentationTests.swift`

**Interfaces:**
- Produces: AX-first `capture(uid:after:)` with one OCR fallback on AX recovery errors, empty chat, or stale post-notification tail; OCR failures return the AX result when available or propagate a non-blocking diagnostic.

- [ ] Write tests for AX healthy/no OCR, AX missing/OCR used, stale AX/OCR supplement, OCR failure/next tick remains eligible, and source-specific progress text.
- [ ] Run focused tests and verify the hybrid driver is absent.
- [ ] Implement the minimal hybrid adapter and wire it into live app construction without changing the scheduler delivery state machine.
- [ ] Re-run focused tests and verify they pass.

### Task 8: End-to-end verification and packaging

**Files:**
- Modify only files proven necessary by failing verification.

**Interfaces:**
- Consumes all preceding components and produces the signed `outputs/拼多多全自动客服.app`.

- [ ] Run `swift test` and record test count, skipped count, and failures.
- [ ] Run `./scripts/build_app.sh` and verify the Release build exits 0.
- [ ] Verify WebOCR models exist in the packaged automatic-reply App and `codesign --verify --deep --strict` exits 0.
- [ ] Run the App with delivery disabled, force an AX fallback condition, and confirm OCR content appears in the UI without any send.
- [ ] Re-enable the user's existing real-send mode only after the read-only evidence matches the visible PDD chat.
