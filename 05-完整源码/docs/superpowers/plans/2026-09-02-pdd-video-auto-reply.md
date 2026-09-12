# PDD Video Auto Reply Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically acquire a newly received PDD customer video, convert it into Codex-readable evidence, and continue through the existing reply queue without blocking on media failures.

**Architecture:** Extend the existing AX-first message and attachment pipeline with a video kind and a lease-bound video acquisition service. Reuse the proven CEF cache-delta downloader, use AVFoundation to validate the MP4 and generate timestamped JPEG frames, then pass those frames through the existing Codex image arguments plus a structured video prompt section.

**Tech Stack:** Swift 5.9, macOS 14, ApplicationServices AX API, Foundation URLSession, AVFoundation, CryptoKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-02-pdd-video-auto-reply-design.md`

## Global Constraints

- Video media acquisition must hold and validate the same `UIOperationLease` used for conversation capture.
- A media failure must never prevent the frozen customer batch from entering Codex generation.
- Never persist or log a signed source URL.
- Codex CLI receives JPEG keyframes through `-i`; never submit MP4 through the image flag.
- Message and attachment identity use the PDD `messageID` and SHA-256, never GZC identifiers.
- Existing text and image behavior must remain backward compatible.

---

### Task 1: Video message classification and AX candidate selection

**Files:**
- Modify: `Sources/PDDAXReader/PDDChatMessage.swift`
- Modify: `Sources/PDDAXReader/PDDChatParser.swift`
- Create: `Sources/PDDAXReader/PDDAXVideoSelection.swift`
- Modify: `Tests/PDDAXReaderTests/PDDChatParserTests.swift`
- Create: `Tests/PDDAXReaderTests/PDDAXVideoSelectionTests.swift`

**Interfaces:**
- Produces: `ChatContentKind.video` and `PDDAXVideoSelection.customerVideos(in:messageIDs:) -> [PDDAXVideoCandidate]`.

- [ ] Write parser tests proving explicit video classes and duration-over-thumbnail customer nodes become `[视频]`, while ordinary images remain `[图片]`.
- [ ] Run `swift test --filter 'PDDChatParserTests|PDDAXVideoSelectionTests'` and verify the new assertions fail because video support is absent.
- [ ] Add `.video`, classification precedence, and a selector scoped to requested customer message IDs and visible message bounds.
- [ ] Run the focused tests and verify they pass.

### Task 2: Cache-delta acquisition and MP4 validation

**Files:**
- Create: `Sources/PDDAXReader/PDDCustomerVideoModels.swift`
- Create: `Sources/PDDAXReader/PDDVideoCacheProbe.swift`
- Create: `Sources/PDDAXReader/PDDCustomerVideoDownloader.swift`
- Create: `Tests/PDDAXReaderTests/PDDVideoCacheProbeTests.swift`
- Create: `Tests/PDDAXReaderTests/PDDCustomerVideoDownloaderTests.swift`

**Interfaces:**
- Produces: `AutoReplyVideoAttachment`, `PDDVideoCacheBaseline.capture`, `PDDVideoCacheWatcher.wait`, and `PDDCustomerVideoDownloading.download`.

- [ ] Write fixture-driven tests for multi-profile cache deltas, PDD HTTPS URL filtering, 200/206 acceptance, invalid media rejection, SHA-256, duration and video-track validation.
- [ ] Run the two focused suites and verify failure from missing production types.
- [ ] Port the tested probe algorithms into focused formal-app files without persisting signed URLs.
- [ ] Run the focused tests and verify they pass.

### Task 3: Lease-bound automatic opening

**Files:**
- Create: `Sources/PDDAXReader/PDDAXVideoPreview.swift`
- Modify: `Sources/PDDAXReader/PDDAXConversationDriver.swift`
- Create: `Tests/PDDAXReaderTests/PDDAXVideoPreviewTests.swift`
- Modify: `Tests/PDDAXReaderTests/PDDAXConversationDriverTests.swift`

**Interfaces:**
- Consumes: `PDDAXVideoCandidate`, `PDDVideoCacheBaseline`, `UIOperationLease`.
- Produces: `PDDCustomerVideoResolving.resolve(candidate:lease:) async throws -> URL` and capture-level video attachments/diagnostics.

- [ ] Write tests proving the resolver snapshots before click, validates the lease around UI actions, and capture continues with `[视频]` when resolution/download fails.
- [ ] Run focused tests and verify expected failures.
- [ ] Implement preview opening and inject resolver/downloader dependencies into the conversation driver alongside the existing image path.
- [ ] Run focused tests and verify success.

### Task 4: Keyframe extraction and durable attachment propagation

**Files:**
- Create: `Sources/PDDAXReader/PDDVideoFrameExtractor.swift`
- Modify: `Sources/PDDAXReader/AutoReplyModels.swift`
- Modify: `Sources/PDDAXReader/CodexHistoryCheckpoint.swift`
- Modify: `Sources/PDDAXReader/AutoReplyRevision.swift`
- Create: `Tests/PDDAXReaderTests/PDDVideoFrameExtractorTests.swift`
- Modify: `Tests/PDDAXReaderTests/HistoryContinuationTests.swift`

**Interfaces:**
- Produces: `PDDVideoFrameExtracting.extractFrames(from:destinationDirectory:) async throws -> [AutoReplyVideoFrame]` and video attachments in captures/jobs/submissions.

- [ ] Create a deterministic tiny MP4 fixture and tests for timestamped JPEG output, Codable backward compatibility, revision identity and continuation deduplication by video digest.
- [ ] Run focused tests and verify the new behavior fails.
- [ ] Implement AVFoundation frame extraction and propagate video attachments through all durable models.
- [ ] Run focused tests and verify success.

### Task 5: Codex prompt and invocation integration

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyPromptBuilder.swift`
- Modify: `Sources/PDDAXReader/AutoReplyCodexGenerator.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyPromptBuilderTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyCodexGeneratorTests.swift`

**Interfaces:**
- Consumes: timestamped keyframes and video metadata from `HistorySubmission.videoAttachments`.
- Produces: `<chat_video_attachments>` prompt evidence and ordered keyframe `-i` arguments.

- [ ] Write tests proving keyframes are passed in message/timestamp order, MP4 is never passed with `-i`, and unavailable video produces a concise fallback instruction.
- [ ] Run focused tests and verify failure.
- [ ] Extend prompt construction and merge image/keyframe URLs for the CLI invocation.
- [ ] Run focused tests and verify success.

### Task 6: Scheduler/UI compatibility and complete verification

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Modify: `Sources/PDDAXReader/AutoReplyProgressPresentation.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyProgressPresentationTests.swift`

**Interfaces:**
- Consumes: capture video attachments and diagnostics.
- Produces: non-blocking task behavior and video-stage progress text.

- [ ] Write tests proving a video processing failure still queues/generates, another UID continues, and video stage text is visible.
- [ ] Run focused tests and verify failure.
- [ ] Preserve video attachments during scheduler normalization/supplement promotion and expose concise progress labels.
- [ ] Run focused tests, then `swift test`, `swift build -c release`, and the live no-send acquisition/Codex-draft chain.
- [ ] Record exact verification evidence in `docs/superpowers/evidence/2026-09-02-pdd-video-auto-reply-verification.md`.
