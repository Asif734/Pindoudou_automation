# PDD Cross-Machine Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. This project is intentionally executed inline; do not dispatch subagents.

**Goal:** Make the existing PDD auto-reply candidate self-contained and diagnosable on Apple Silicon Macs running macOS 14 or later without changing its customer-service scheduling behavior.

**Architecture:** Add a compatibility boundary around the existing runtime: resolve bundled tools, expose structured capability checks, read the complete AX semantic attributes, and make OCR/media discovery depend on live geometry and actual file formats. Existing red-dot authorization, UID queues, Codex sessions, response schema, and send flow remain the consumers of these adapted inputs.

**Tech Stack:** Swift 5.9, Swift Package Manager, AppKit/ApplicationServices, ScreenCaptureKit, Speech, ImageIO, AVFoundation, zsh app bundling, arm64 CPython 3.12.

**Spec:** `docs/superpowers/specs/2026-09-03-pdd-cross-machine-compatibility-design.md`

## Global Constraints

- Support Apple Silicon only and require macOS 14 or later.
- Do not inject into PDD, capture private protocols, or add runtime dependency downloads.
- Preserve red-dot-only capture authorization and all existing queue, UID, prompt, response-schema, and send semantics.
- A failed optional media capability must not stop text auto-reply.
- Do not log signed media URLs, authentication data, or customer chat content in compatibility reports.
- The project root has no `.git`; use the existing App backup flow and record test output instead of creating commits.

---

### Task 1: Speech Permission and Video Degradation

**Files:**
- Modify: `Resources/TaskIsolationCandidateInfo.plist`
- Modify: `Resources/AutoReplyInfo.plist`
- Modify: `Sources/PDDAXReader/PDDAppleVideoSpeechTranscriber.swift`
- Modify: `Sources/PDDAXReader/PDDCustomerVideoEvidence.swift`
- Modify: `Sources/PDDAXReader/PDDVideoTransferArmer.swift`
- Modify: `Sources/PDDAXReader/PDDBackgroundVideoRecovery.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyPackagingTests.swift`
- Test: create `Tests/PDDAXReaderTests/PDDVideoSpeechPolicyTests.swift`

**Interfaces:**
- Produces: `PDDVideoSpeechAuthorizationPolicy.action(for:) -> PDDVideoSpeechAuthorizationAction`
- Consumes: `SFSpeechRecognizerAuthorizationStatus`
- Behavior: denied/restricted/unavailable speech yields a frame-only video result, not a scheduler-wide error.

- [ ] **Step 1: Add a failing plist test**

```swift
func testCandidateDeclaresSpeechRecognitionUsage() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let data = try Data(contentsOf: root.appendingPathComponent("Resources/TaskIsolationCandidateInfo.plist"))
    let plist = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    XCTAssertFalse((plist["NSSpeechRecognitionUsageDescription"] as? String ?? "").isEmpty)
}
```

- [ ] **Step 2: Run the test and verify it fails because the key is absent**

Run: `swift test --filter AutoReplyPackagingTests/testCandidateDeclaresSpeechRecognitionUsage`

Expected: FAIL with an empty speech usage description.

- [ ] **Step 3: Add a failing authorization-policy test**

```swift
func testDeniedSpeechAuthorizationSkipsTranscriptWithoutFailingVideo() {
    XCTAssertEqual(PDDVideoSpeechAuthorizationPolicy.action(for: .denied), .skipTranscript)
    XCTAssertEqual(PDDVideoSpeechAuthorizationPolicy.action(for: .restricted), .skipTranscript)
}
```

- [ ] **Step 4: Run the policy test and verify the missing policy failure**

Run: `swift test --filter PDDVideoSpeechPolicyTests`

Expected: compile failure because the policy type does not exist.

- [ ] **Step 5: Add the plist descriptions and minimal policy**

Add a Chinese usage description to every auto-reply plist. Extract the authorization decision from the live transcriber so `.authorized` transcribes, `.notDetermined` requests once, and `.denied`/`.restricted` returns an empty transcript plus a visible degradation reason. Do not throw a fatal runtime error for refusal.

- [ ] **Step 6: Run focused and video pipeline tests**

Run: `swift test --filter PDDVideoSpeechPolicyTests && swift test --filter AutoReplyPackagingTests && swift test --filter PDDVideo`

Expected: all selected tests pass.

### Task 2: Portable Python 3.12 Resolution and Packaging

**Files:**
- Modify: `Sources/PDDAXReader/KnowledgeResourceLocator.swift`
- Create: `Sources/PDDAXReader/PythonRuntimeResolver.swift`
- Modify: `scripts/build_app.sh`
- Create: `Resources/ThirdParty/PythonRuntime/cpython-3.12.14+20260825-aarch64-apple-darwin-install_only_stripped.tar.gz.sha256`
- Create: `Resources/ThirdParty/PythonRuntime/NOTICE.md`
- Test: `Tests/PDDAXReaderTests/KnowledgeResourceLocatorTests.swift`
- Create: `Tests/PDDAXReaderTests/PythonRuntimeResolverTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyPackagingTests.swift`

**Interfaces:**
- Produces: `PythonRuntimeResolver.resolve(resourceRootURL:environment:fileManager:probe:) -> PythonRuntimeResolution`
- `PythonRuntimeResolution` contains `executableURL`, `source`, and `version`.
- `KnowledgeResourceLocator.resolve` returns `nil` when no validated Python 3.12 interpreter exists.

- [ ] **Step 1: Write candidate-order tests**

```swift
func testBundledPythonWinsOverSystemCandidates() throws {
    let layout = try PythonRuntimeFixture.make(bundled: true, pythonOrg: true, homebrew: true)
    let result = try PythonRuntimeResolver.resolve(
        resourceRootURL: layout.resources,
        environment: [:],
        fileManager: layout.fileManager,
        probe: { _ in .init(version: "3.12.10", architectures: [.arm64]) }
    )
    XCTAssertEqual(result.source, .bundled)
}

func testExplicitEnvironmentPythonWinsOverBundled() throws {
    // Arrange an executable PDD_PYTHON_PATH and assert source == .environment.
}
```

- [ ] **Step 2: Verify the resolver tests fail because the type is missing**

Run: `swift test --filter PythonRuntimeResolverTests`

Expected: compile failure for `PythonRuntimeResolver`.

- [ ] **Step 3: Implement pure candidate selection and injectable probing**

Candidate order must be environment, bundled `PythonRuntime/bin/python3.12`, Python.org, Homebrew, then executable `python3.12` entries from PATH. Reject non-executable files, Python versions other than 3.12, and probes without arm64 support.

- [ ] **Step 4: Connect the locator and verify missing Python is detected before worker creation**

Add a failing locator test in which V2 assets and knowledge ZIP exist but no Python candidate validates; expect `resolve(...) == nil`. Then pass the resolved executable into `KnowledgeResources.pythonURL`.

- [ ] **Step 5: Prepare and pin the relocatable runtime**

Download exactly:

`https://github.com/astral-sh/python-build-standalone/releases/download/20260825/cpython-3.12.14%2B20260825-aarch64-apple-darwin-install_only_stripped.tar.gz`

Expected SHA-256:

`8b0f1fa71eab7ca644e482c631807a1116fa848491051cd1c8d9429491de63a6`

Store the archive under `Resources/ThirdParty/PythonRuntime/`, record the digest in the adjacent `.sha256` file, and add a notice linking the Astral `python-build-standalone` project and MPL-2.0 license. This is an explicit dependency-preparation action; normal builds and the shipped App must not download it.

- [ ] **Step 6: Add deterministic runtime packaging**

The build script must require a project-local runtime archive plus expected SHA-256, verify it, expand it under `Contents/Resources/PythonRuntime`, remove `__pycache__`, and verify `file` reports arm64. It must never download during an app build.

- [ ] **Step 7: Build and smoke-test the bundled interpreter with the system Python path temporarily hidden from the resolver**

Run the packaged interpreter with `-c 'import sys; print(sys.version_info[:2])'`, then start `serve_top12.py` until it emits its ready record. Expected version: `(3, 12)` and worker version `v2-top12` or `v2-lexical-only`.

### Task 3: Complete Live AX Semantic Attributes

**Files:**
- Modify: `Sources/PDDAXReader/PDDAXBackend.swift`
- Modify if needed: `Sources/PDDAXReader/PDDAXSemanticNode.swift`
- Test: `Tests/PDDAXReaderTests/PDDAXBackendPolicyTests.swift`
- Test: `Tests/PDDAXReaderTests/PDDAXControlSelectionTests.swift`
- Test: `Tests/PDDAXReaderTests/PDDChatParserTests.swift`

**Interfaces:**
- Produces each live semantic node with `AXValue`, `AXTitle`, `AXDescription`, `AXURL`, `AXDOMClassList`, and `AXDOMIdentifier` when available.
- `PDDAXSemanticNode.title` equals the successfully read `AXTitle`.

- [ ] **Step 1: Add a failing attribute-policy test**

```swift
func testSemanticWalkRequestsAllTextAndMediaAttributes() {
    XCTAssertEqual(
        Set(PDDAXBackendPolicy.semanticAttributeNames),
        Set(["AXValue", "AXTitle", "AXDescription", "AXURL", "AXDOMClassList", "AXDOMIdentifier"])
    )
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --filter PDDAXBackendPolicyTests/testSemanticWalkRequestsAllTextAndMediaAttributes`

Expected: failure because the policy is missing or incomplete.

- [ ] **Step 3: Implement the shared policy and populate the live node**

Read each attribute independently. Preserve successful attributes when another query returns an AX error. Set `title` from `AXTitle`, not a constant `nil`. Continue limiting expensive action/settable queries to the existing roles.

- [ ] **Step 4: Add selector/parser tests for title-only exposure**

Create conversation-row, send-button, customer text, and image URL fixtures where the visible value exists only in `AXTitle`, `AXDescription`, or `AXURL`. Assert the existing selectors and parser recognize them.

- [ ] **Step 5: Run all AX tests**

Run: `swift test --filter PDDAX && swift test --filter PDDChatParserTests`

Expected: all tests pass without increasing traversal scope beyond the PDD process.

### Task 4: Adaptive OCR Crop and Red-Dot Mapping

**Files:**
- Modify: `Sources/PDDAXReader/PDDOCRCapture.swift`
- Modify: `Sources/PDDAXReader/PDDOCRChatParser.swift`
- Modify: `Sources/PDDAXReader/PDDRedDotDetector.swift`
- Modify the conversation driver only to pass the known chat-panel frame
- Test: `Tests/PDDAXReaderTests/PDDOCRCaptureTests.swift`
- Test: `Tests/PDDAXReaderTests/PDDOCRChatParserTests.swift`
- Test: `Tests/PDDAXReaderTests/PDDRedDotDetectorTests.swift`

**Interfaces:**
- Produces: `PDDChatCropResolver.resolve(windowFrame:pixelSize:chatPanelFrame:) -> CGRect`
- Existing proportional crop remains the fallback when `chatPanelFrame` is nil or invalid.
- Red-dot detector maps AX points to image pixels using independent X/Y scales.

- [ ] **Step 1: Write a failing panel-frame crop test**

```swift
func testUsesAXChatPanelFrameInsteadOfWholeWindowRatio() throws {
    let crop = try PDDChatCropResolver.resolve(
        windowFrame: CGRect(x: 100, y: 100, width: 1200, height: 800),
        pixelSize: CGSize(width: 2400, height: 1600),
        chatPanelFrame: CGRect(x: 430, y: 220, width: 700, height: 560)
    )
    XCTAssertEqual(crop, CGRect(x: 660, y: 240, width: 1400, height: 1120))
}
```

- [ ] **Step 2: Verify RED and implement panel-relative crop with fallback**

Run the single test, confirm failure, then implement clipping and coordinate conversion. Invalid or off-window panel frames must exercise the unchanged legacy fallback test.

- [ ] **Step 3: Write a failing non-uniform scale red-dot test**

Construct an image with scaleX `2.0` and scaleY `1.98`, draw the same valid dot in an AX row, and assert that row is selected.

- [ ] **Step 4: Verify RED and replace the global 3% rejection with bounded independent mapping**

Keep connected-component size, location, shape, and color checks. Reject only impossible/non-finite scales or mapped rows outside the captured window.

- [ ] **Step 5: Add panel-relative sender tests**

Test the same left/right bubbles in two different whole-window widths with the same chat-panel-relative positions. Assert customer/service classification is identical.

- [ ] **Step 6: Run OCR, red-dot, source-selector, and scheduler authorization tests**

Run: `swift test --filter PDDOCR && swift test --filter PDDRedDotDetectorTests && swift test --filter PDDMessageSourceSelectorTests && swift test --filter AutoReplySchedulerTests/testUnreadRedDotIsTheOnlyCaptureAuthorization`

Expected: all pass; no-red-dot behavior remains unchanged.

### Task 5: Image Format Normalization and Flexible PDD Cache Profiles

**Files:**
- Modify: `Sources/PDDAXReader/PDDCustomerImageDownloader.swift`
- Create: `Sources/PDDAXReader/PDDImageNormalizer.swift`
- Modify: `Sources/PDDAXReader/PDDAXImagePreview.swift`
- Modify: `Sources/PDDAXReader/PDDVideoCacheProbe.swift`
- Test: `Tests/PDDAXReaderTests/PDDCustomerImageDownloaderTests.swift`
- Test: `Tests/PDDAXReaderTests/PDDAXImagePreviewTests.swift`
- Test: `Tests/PDDAXReaderTests/PDDVideoCacheProbeTests.swift`

**Interfaces:**
- Produces: `PDDImageNormalizer.normalize(data:mimeType:) -> NormalizedPDDImage`
- `NormalizedPDDImage` contains validated bytes, extension, MIME type, width, and height.
- `PDDVideoCacheLocator` returns every real `Cache/Cache_Data` directory beneath the PDD CEF root, regardless of profile name.

- [ ] **Step 1: Add a failing GIF normalization test**

Create a 2x2 image with ImageIO, encode it as GIF in memory, send it through the downloader, and assert the stored attachment is non-empty JPEG with positive dimensions. Add an invalid HTML-body assertion that continues to fail closed.

- [ ] **Step 2: Verify RED and implement ImageIO normalization**

JPEG and PNG may remain in their original validated representation. Other ImageIO-decodable formats use frame zero and `CGImageDestination` to produce JPEG at quality `0.9`. Apply the byte limit before decoding and after conversion.

- [ ] **Step 3: Add a failing arbitrary-profile cache test**

```swift
func testFindsCacheDataInsideNamedCEFProfile() throws {
    let cache = root.appendingPathComponent("account-main/Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    XCTAssertEqual(try PDDVideoCacheLocator.findCacheDataDirectories(inCEFRoot: root), [cache])
}
```

- [ ] **Step 4: Verify RED and implement bounded recursive discovery**

Enumerate directories no deeper than four levels beneath the supplied PDD CEF root, accept only paths ending in `Cache/Cache_Data`, canonicalize them, and reject symlinks that escape the CEF root.

- [ ] **Step 5: Make preview polling configurable without changing queue ownership**

Add a clock-driven unit test showing a preview appearing after three seconds is found before the configured upper bound. Preserve `defer`-based preview closing and ensure the wait remains inside only the current UID task.

- [ ] **Step 6: Run image and video tests**

Run: `swift test --filter PDDCustomerImageDownloaderTests && swift test --filter PDDAXImagePreviewTests && swift test --filter PDDVideoCacheProbeTests && swift test --filter PDDVideo`

Expected: all pass; signed URLs never appear in assertions or logs.

### Task 6: Codex Discovery and Preflight

**Files:**
- Modify: `Sources/PDDAXReader/CodexInstallation.swift`
- Create: `Sources/PDDAXReader/CodexCompatibilityProbe.swift`
- Modify: `Sources/PDDAXReader/AutoReplyViewModel.swift`
- Modify: `Sources/PDDAXReader/AutoReplyProgressPresentation.swift`
- Test: `Tests/PDDAXReaderTests/CodexInstallationTests.swift`
- Create: `Tests/PDDAXReaderTests/CodexCompatibilityProbeTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyViewModelTests.swift`

**Interfaces:**
- Produces: `CodexCompatibilityProbe.check(executableURL:isolatedHomeURL:) async -> CodexCompatibilityResult`
- Result distinguishes missing executable, unsupported CLI invocation, missing ChatGPT authentication, and ready.
- Failure prevents new generation work but releases scheduler ownership and leaves other environment checks visible.

- [ ] **Step 1: Add discovery tests for user Applications and PATH**

Arrange executable candidates under `~/Applications/Codex.app`, `~/Applications/ChatGPT.app`, and a synthetic PATH. Assert explicit `PDD_CODEX_PATH` still wins.

- [ ] **Step 2: Verify RED and extend candidate generation**

Do not execute candidates during path selection. Preserve the existing executable-bit validation.

- [ ] **Step 3: Add failing preflight result tests with an injected process runner**

```swift
func testMissingAuthenticationProducesActionableFailure() async {
    let result = await probe.check(executableURL: codex, isolatedHomeURL: emptyHome)
    XCTAssertEqual(result, .missingAuthentication)
}

func testUnsupportedInvocationIsNotReportedAsGeneratingForever() async {
    runner.result = .failure(exitCode: 2, stderr: "unknown option --ignore-user-config")
    XCTAssertEqual(await probe.check(executableURL: codex, isolatedHomeURL: home), .unsupportedCLI)
}
```

- [ ] **Step 4: Verify RED and implement the light probe**

Use a bounded `--version`/help-compatible invocation and inspect the isolated authentication file without printing it. Do not submit a customer prompt or consume a model request during compatibility checking.

- [ ] **Step 5: Integrate preflight into startup and progress text**

The start path reports the exact problem before scheduler work begins. A per-job CLI incompatibility transitions that job out of generating and releases the UID; it must not stop unrelated jobs.

- [ ] **Step 6: Run Codex and ViewModel tests**

Run: `swift test --filter Codex && swift test --filter AutoReplyViewModelTests && swift test --filter AutoReplyProgressPresentationTests`

Expected: all pass with the model remaining `gpt-5.6-sol` and reasoning `medium`.

### Task 7: Unified Compatibility Report and Safe Signing Selection

**Files:**
- Create: `Sources/PDDAXReader/PDDCompatibilityReport.swift`
- Create: `Sources/PDDAXReader/PDDCompatibilityChecker.swift`
- Modify: `Sources/PDDAXReader/AutoReplyViewModel.swift`
- Modify: `Sources/PDDAXReader/AutoReplyView.swift`
- Modify: `scripts/build_app.sh`
- Test: create `Tests/PDDAXReaderTests/PDDCompatibilityCheckerTests.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyPackagingTests.swift`

**Interfaces:**
- Produces: `PDDCompatibilityReport` containing redacted `PDDCompatibilityItem` values with status `pass`, `degraded`, or `fail`.
- Produces: deterministic signing selection from explicit identity, Developer ID, Apple Development, or ad-hoc.

- [ ] **Step 1: Add failing report classification and redaction tests**

```swift
func testSpeechFailureDegradesButMissingAXFails() {
    XCTAssertEqual(report.status(for: .speech), .degraded)
    XCTAssertEqual(report.status(for: .accessibility), .fail)
}

func testExportNeverContainsSecretsOrChatText() throws {
    let exported = try report.redactedJSON()
    XCTAssertFalse(exported.contains("token"))
    XCTAssertFalse(exported.contains("https://video"))
    XCTAssertFalse(exported.contains("客户消息"))
}
```

- [ ] **Step 2: Verify RED and implement the data model/checker**

Checks must be read-only except for the already-required permission status APIs and the knowledge worker prewarm. No compatibility check may send PDD input or open media.

- [ ] **Step 3: Add UI tests for visible pass/degraded/fail state**

Expose a “兼容性检查” action, summary, and save panel for the redacted JSON report. Required failures disable Start; optional degradation leaves Start enabled with warning text.

- [ ] **Step 4: Add a failing build-script signing-policy test**

Assert the script no longer contains the personal certificate literal and contains explicit, Developer ID, Apple Development, and ad-hoc branches.

- [ ] **Step 5: Implement signing selection and post-build validation**

After signing, run `codesign --verify --deep --strict`. Inspect every Mach-O beneath the app with `lipo -archs` and fail if arm64 is absent. Keep the existing timestamped App backup.

- [ ] **Step 6: Run compatibility and packaging tests**

Run: `swift test --filter PDDCompatibility && swift test --filter AutoReplyPackagingTests`

Expected: all pass and no private data appears in the generated fixture report.

### Task 8: Full Regression, Build, and Real-Machine Validation

**Files:**
- No new production interface unless a failing integration test identifies a defect.
- Record outputs under `outputs/compatibility-validation/` without customer content or signed URLs.

**Interfaces:**
- Delivers the candidate App, a redacted local compatibility report, and reproducible test logs.

- [ ] **Step 1: Run the complete automated suite**

Run: `swift test`

Expected: zero failures. Record the pass and skip counts; do not describe skipped live tests as passed.

- [ ] **Step 2: Build the candidate App**

Run: `scripts/build_app.sh --task-isolation-candidate`

Expected: old App is backed up, Python runtime is included, arm64 validation passes, and `codesign --verify --deep --strict` succeeds.

- [ ] **Step 3: Verify the package independently**

Run `plutil -lint`, `codesign -dvv`, `file`/`lipo` for nested executables, launch the bundled Python, and prewarm the knowledge worker. Confirm no dependency resolves to the developer's home directory or fixed `/Library/Frameworks/Python.framework` path.

- [ ] **Step 4: Open the candidate while preserving explicit run intent**

Terminate only the previous candidate process after confirming its exact executable path, open the rebuilt candidate, and verify the persisted `desiredRunning` value is not silently changed.

- [ ] **Step 5: Run the read-only compatibility check against the currently open PDD**

Confirm AX conversation list, chat panel, composer, send control, PDD version, permissions, CEF cache, Python, knowledge, and Codex are reported. Do not send a message during this step.

- [ ] **Step 6: Execute user-authorized end-to-end checks**

Use a controlled test customer to verify one text, one image, and one video message. Measure discovery, queue, generation, download, frame extraction, and delivery times. Confirm no-red-dot conversations never enter capture.

- [ ] **Step 7: Produce the colleague ZIP and checksum only after local acceptance**

Use `ditto -c -k --sequesterRsrc --keepParent` and `shasum -a 256`. Include first-open instructions and the compatibility-report procedure; exclude raw logs, auth, state files, customer data, and signed media URLs.
