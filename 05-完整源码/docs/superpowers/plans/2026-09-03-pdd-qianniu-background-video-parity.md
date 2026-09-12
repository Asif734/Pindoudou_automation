# PDD Qianniu-Parity Background Video Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Replace PDD's synchronous, deadline-bound video capture with Qianniu's arm-click-background-download-complete-evidence-Codex pipeline.

**Architecture:** The UI lane arms a CEF cursor, clicks the customer video, starts an idempotent background transfer, closes the preview, and returns. A durable per-customer pending batch waits for background completion; the validated MP4 is adaptively framed, exported to M4A, transcribed, and admitted as one Codex job through a buffered event relay.

**Tech Stack:** Swift 5.9, macOS 14, AppKit/AX, AVFoundation, Speech, URLSession, CryptoKit, XCTest.

**Spec:** docs/superpowers/specs/2026-09-03-pdd-qianniu-background-video-parity-design.md

## Global Constraints

- PDD gets temporary URLs from CEF Cache_Data; every later state transition mirrors Qianniu.
- Address waiting and network download have no elapsed-time or byte-size cutoff.
- Background video work never holds a UI lease or performs AX/mouse/keyboard actions.
- uid plus messageID is the identity boundary; no cross-customer candidate reuse.
- Signed URLs, cookies, and raw CEF content never enter persisted state or prompts.
- Frames go to one Codex invocation through --image; MP4 and M4A never do.
- New Codable fields decode old state with safe defaults.
- Write and observe every failing test before production changes.

---

### Task 1: Correct live capture/preflight routing

**Files**
- Modify: Sources/PDDAXReader/PDDLiveAutoReplyDriver.swift
- Test: Tests/PDDAXReaderTests/PDDLiveAutoReplyDriverTests.swift

**Interfaces**
- Consume the two PDDAXConversationDriver lease overloads.
- Produce matching live capture and preflight calls.

- [ ] Write a spy-based test that calls both lease overloads and expects call order capture, preflight.
- [ ] Run: swift test --filter PDDLiveAutoReplyDriverTests
- [ ] Verify RED: current implementation reports preflight, capture.
- [ ] Change live capture to conversationDriver.capture and live preflight to conversationDriver.preflight inside withLease.
- [ ] Run the filtered test plus PDDAXConversationDriverTests and verify GREEN.
- [ ] If Git is available, commit with message: fix: route live capture and preflight correctly

### Task 2: Add durable video identities and pending batches

**Files**
- Create: Sources/PDDAXReader/PDDBackgroundVideoModels.swift
- Modify: Sources/PDDAXReader/AutoReplyModels.swift
- Modify: Sources/PDDAXReader/AutoReplyStore.swift
- Test: Tests/PDDAXReaderTests/PDDBackgroundVideoModelsTests.swift
- Test: Tests/PDDAXReaderTests/AutoReplyStoreTests.swift

**Interfaces**
- Produce PDDVideoTransferKey, PDDVideoTransferPhase, PDDPendingVideoBatch, and PDDVideoTransferEvent.
- Add AutoReplyCapture.pendingVideoMessageIDs.
- Add optional AutoReplyVideoAttachment.audioLocalURL and manifestLocalURL.

- [ ] Write a test proving the same messageID under two UIDs produces different transfer keys.
- [ ] Write legacy JSON decode tests proving missing pendingVideoMessageIDs, audioLocalURL, manifestLocalURL, and pendingVideoBatches default to empty or nil.
- [ ] Run: swift test --filter 'PDDBackgroundVideoModelsTests|AutoReplyStoreTests'
- [ ] Verify RED on missing types and fields.
- [ ] Implement PDDVideoTransferKey with customerHash=SHA256(uid) and messageHash=SHA256(messageID).
- [ ] Implement phases armed, waitingForAddress, downloading, downloaded, preparingEvidence, readyForGeneration, admitted, completed, failed.
- [ ] Implement PDDPendingVideoBatch with uid, frozen capture, expected message IDs, completed attachments keyed by message ID, and failed message IDs.
- [ ] Extend persistent state and custom Codable decoding with backward-compatible defaults.
- [ ] Run the filtered tests and verify GREEN.
- [ ] If Git is available, commit with message: feat: persist pending PDD video batches

### Task 3: Add indefinite CEF watching and unlimited downloading

**Files**
- Modify: Sources/PDDAXReader/PDDVideoCacheProbe.swift
- Create: Sources/PDDAXReader/PDDBackgroundVideoDownloader.swift
- Test: Tests/PDDAXReaderTests/PDDVideoCacheProbeTests.swift
- Test: Tests/PDDAXReaderTests/PDDBackgroundVideoDownloaderTests.swift

**Interfaces**
- Produce an armed candidate cursor with wait() async throws -> URL.
- Produce PDDUnlimitedVideoDownloadClient.download(from:to:).

- [ ] Write a test that starts wait(), writes incomplete metadata, waits past several 0.2-second polls, completes the same metadata, and receives its PDD video URL.
- [ ] Write a session-policy test asserting request/resource timeouts equal greatestFiniteMagnitude, waitsForConnectivity is true, and URL cache/cookie storage are nil.
- [ ] Write a test proving an injected file size above 200 MiB is not rejected without allocating that data.
- [ ] Run: swift test --filter 'PDDVideoCacheProbeTests|PDDBackgroundVideoDownloaderTests'
- [ ] Verify RED because wait() and the unlimited policy do not exist.
- [ ] Implement wait() as a cancellation-aware infinite 0.2-second poll using the existing metadata recheck set.
- [ ] Implement an ephemeral URLSession, allowed-PDD-HTTPS redirect guard, HTTP 200/206 validation, no byte cap, and CancellationError preservation.
- [ ] Download to the supplied partial path and delete it only on real failure.
- [ ] Assert encoded records and sanitized errors contain no signed URL.
- [ ] Run the filtered tests and verify GREEN.
- [ ] If Git is available, commit with message: feat: wait and download PDD videos without deadlines

### Task 4: Split foreground opening from background transfer

**Files**
- Replace: Sources/PDDAXReader/PDDAXVideoPreview.swift
- Create: Sources/PDDAXReader/PDDVideoTransferArmer.swift
- Modify: Sources/PDDAXReader/PDDCustomerVideoModels.swift
- Modify: Sources/PDDAXReader/PDDAXConversationDriver.swift
- Test: Tests/PDDAXReaderTests/PDDVideoTransferArmerTests.swift
- Test: Tests/PDDAXReaderTests/PDDAXConversationDriverTests.swift

**Interfaces**
- PDDVideoTransferArming.arm(uid:messageID:candidate:) returns an optional ArmedPDDVideoTransfer.
- ArmedPDDVideoTransfer.start() is single-use and returns immediately.
- PDD video preview opener performs only foreground activation, click, and close.

- [ ] Write an order test expecting arm, click, start, close.
- [ ] Write a blocked-candidate test proving capture returns while the background watcher is still waiting.
- [ ] Write an idempotency test proving calling start twice creates one transfer.
- [ ] Run: swift test --filter 'PDDVideoTransferArmerTests|PDDAXConversationDriverTests'
- [ ] Verify RED because the current resolver waits and downloads synchronously.
- [ ] Arm all CEF profile baselines before clicking.
- [ ] After a successful click, start one utility-priority background task and close the preview in defer.
- [ ] Return the message ID in pendingVideoMessageIDs and no immediate video attachment.
- [ ] Remove videoOperationTimeout, PDDVideoOperationBudget, synchronous resolve/download retry loops, and the 12/25/60-second video competition.
- [ ] Keep preflight attachment enrichment disabled.
- [ ] Run the filtered tests and verify GREEN.
- [ ] If Git is available, commit with message: refactor: move PDD video transfer off the UI lane

### Task 5: Port Qianniu frame/audio/transcript evidence exactly

**Files**
- Replace: Sources/PDDAXReader/PDDVideoFrameExtractor.swift
- Create: Sources/PDDAXReader/PDDCustomerVideoEvidence.swift
- Create: Sources/PDDAXReader/PDDAppleVideoSpeechTranscriber.swift
- Modify: Sources/PDDAXReader/PDDCustomerVideoDownloader.swift
- Test: Tests/PDDAXReaderTests/PDDVideoFrameExtractorTests.swift
- Test: Tests/PDDAXReaderTests/PDDCustomerVideoEvidenceTests.swift

**Interfaces**
- Produce PDDCustomerVideoEvidencePreparer.prepare(download:) returning AutoReplyVideoAttachment.
- Store a stable MP4, ordered JPEGs, optional audio.m4a, manifest.json, and timestamped transcript.

- [ ] Write exact bucket tests: 1 second gives 3 frames, 8 seconds gives 8, 20 seconds gives 11, and 31 seconds gives 20.
- [ ] Write an inset test: an 8-second video starts at 0.2 and ends at 7.8.
- [ ] Write tests that repeated-looking frames remain, audio creates audio.m4a, no-audio still succeeds, and manifest order equals timestamp order.
- [ ] Run: swift test --filter 'PDDVideoFrameExtractorTests|PDDCustomerVideoEvidenceTests'
- [ ] Verify RED against the current maximum-six schedule.
- [ ] Port Qianniu sampleTimes exactly: under 2 seconds min(3,limit); through 10 seconds min(limit,max(4,ceil(duration))); through 30 seconds min(limit,max(4,ceil(duration/2)+1)); otherwise limit.
- [ ] Use start=min(0.20,duration*0.1), end=duration-min(0.20,duration*0.1), uniform interpolation, and only collapse timestamps closer than 0.04 seconds.
- [ ] Extract asynchronous AVFoundation frames at JPEG quality 0.82 and calculate per-frame SHA-256; perform no pixel similarity filtering.
- [ ] Export audio with AVAssetExportPresetAppleM4A.
- [ ] Implement zh-CN SFSpeechRecognizer, prefer on-device recognition, keep Qianniu's 45-second speech-result bound, and return an empty transcript when unavailable.
- [ ] Prepare in a dot-prefixed staging directory and atomically move to messageHash only after manifest completion.
- [ ] Keep Qianniu's 90-second post-download evidence bound; it cannot delete or cancel the completed MP4.
- [ ] Run the filtered tests and the conditional PDD_LIVE_VIDEO_FILE test; verify GREEN.
- [ ] If Git is available, commit with message: feat: prepare PDD video frames audio and transcript

### Task 6: Hold mixed batches until all video evidence is terminal

**Files**
- Modify: Sources/PDDAXReader/AutoReplyScheduler.swift
- Modify: Sources/PDDAXReader/AutoReplyModels.swift
- Modify: Sources/PDDAXReader/AutoReplyStore.swift
- Test: Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift

**Interfaces**
- Consume AutoReplyCapture.pendingVideoMessageIDs and PDDVideoTransferEvent.
- Produce AutoReplyScheduler.receiveVideoTransferEvent(_:) and durable batch promotion.

- [ ] Write a test proving a text-plus-video capture creates no Codex job before video completion.
- [ ] Write a two-video test: v2 completion alone creates no job; v1 completion promotes one job with attachments ordered v1,v2.
- [ ] Write duplicate-completion and two-UID isolation tests.
- [ ] Write a store reload test for a pending batch.
- [ ] Run: swift test --filter AutoReplySchedulerTests
- [ ] Verify RED because capture currently queues immediately.
- [ ] When pendingVideoMessageIDs is nonempty, persist PDDPendingVideoBatch, advance the ordinary chat cursor, and return without creating AutoReplyJob.
- [ ] receiveVideoTransferEvent must match exact uid and messageID, persist each transition, and ignore duplicate events.
- [ ] Promote exactly one job after all expected IDs are completed or have a terminal real failure.
- [ ] Preserve expected message order when assembling attachments.
- [ ] Use customer revision video-analysis plus the combined message hashes.
- [ ] Add the existing concise unavailable-video diagnostic only for terminal evidence failures.
- [ ] Run scheduler/store tests and verify GREEN.
- [ ] If Git is available, commit with message: feat: admit PDD video evidence as one durable reply

### Task 7: Wire buffered events and cancellation lifecycle

**Files**
- Create: Sources/PDDAXReader/PDDVideoTransferRelay.swift
- Create: Sources/PDDAXReader/PDDVideoTransferRegistry.swift
- Modify: Sources/PDDAXReader/AutoReplyViewModel.swift
- Modify: Sources/PDDAXReader/AutoReplyScheduler.swift
- Test: Tests/PDDAXReaderTests/PDDVideoTransferRelayTests.swift
- Test: Tests/PDDAXReaderTests/AutoReplyViewModelTests.swift

**Interfaces**
- Buffer events produced before scheduler construction finishes.
- Own one Task per transfer key and cancel all on explicit app stop.

- [ ] Write a test proving an event sent before handler installation is delivered once after installation.
- [ ] Write a test proving the registry rejects duplicate keys and removes terminal tasks.
- [ ] Write a stop test proving waiting/downloading tasks observe cancellation.
- [ ] Run: swift test --filter 'PDDVideoTransferRelayTests|AutoReplyViewModelTests'
- [ ] Verify RED on missing relay/registry.
- [ ] Implement the relay actor with FIFO buffering and one installed async handler.
- [ ] Implement the registry actor with insert, finish, contains, and cancelAll.
- [ ] In makeLiveRuntime, create relay and registry first, construct armer/conversation/scheduler, then install a weak scheduler handler through one startup Task.
- [ ] Extend AutoReplyRunning with a cancellation hook and call it after scheduler stop when the user explicitly stops the app.
- [ ] Ensure a normal UI lease timeout never cancels registered background transfers.
- [ ] Run the filtered tests plus scheduler/driver tests and verify GREEN.
- [ ] If Git is available, commit with message: feat: wire durable PDD background video events

### Task 8: Submit evidence to Codex and display durable progress

**Files**
- Modify: Sources/PDDAXReader/AutoReplyCodexGenerator.swift
- Modify: Sources/PDDAXReader/AutoReplyPromptBuilder.swift
- Modify: Sources/PDDAXReader/AutoReplyProgressPresentation.swift
- Modify: Sources/PDDAXReader/AutoReplyViewModel.swift
- Modify: Sources/PDDAXReader/AutoReplyFloatingProgress.swift
- Modify: Sources/PDDAXReader/AutoReplyView.swift
- Test: Tests/PDDAXReaderTests/AutoReplyCodexGeneratorTests.swift
- Test: Tests/PDDAXReaderTests/AutoReplyPromptBuilderTests.swift
- Test: Tests/PDDAXReaderTests/AutoReplyProgressPresentationTests.swift

**Interfaces**
- Consume ordered frames, optional audio path, transcript segments, and transfer status.
- Produce one Codex invocation and an independently retained UI status.

- [ ] Write a test with 20 frames and audio; assert exactly 20 image inputs and no MP4/M4A image argument.
- [ ] Write a prompt test proving transcript segments are sorted and formatted start-end seconds plus text.
- [ ] Write a UI test proving scanner-idle refresh cannot overwrite the latest video completion/preparation status.
- [ ] Run: swift test --filter 'AutoReplyCodexGeneratorTests|AutoReplyPromptBuilderTests|AutoReplyProgressPresentationTests'
- [ ] Verify RED.
- [ ] Validate and append all ordered frame URLs to the single CodexInvocation call.
- [ ] Render one video section stating that frames belong to the same video in playback order; include ordered speech timeline or the exact no-reliable-transcript statement.
- [ ] Validate MP4/M4A for local state only; never pass them to --image.
- [ ] Add independent phases recognized, opened/background-started, downloading, downloaded, preparing, prepared, admitted, failed.
- [ ] Retain the latest terminal video message until a newer video event replaces it.
- [ ] Run the filtered tests and visually verify the app window remains draggable, closable, and unclipped.
- [ ] If Git is available, commit with message: feat: show and submit completed PDD video evidence

### Task 9: Recovery, complete verification, and packaging

**Files**
- Modify: Sources/PDDAXReader/PDDVideoTransferRegistry.swift
- Modify: Sources/PDDAXReader/AutoReplyViewModel.swift
- Modify: docs/PDD全自动客服-代码级架构与调试交接手册.md
- Create: docs/superpowers/evidence/2026-09-03-pdd-background-video-parity-verification.md
- Test: Tests/PDDAXReaderTests/PDDBackgroundVideoRecoveryTests.swift

**Interfaces**
- Resume stable downloaded videos at evidence preparation.
- Reopen only the exact saved UID when a signed address was never captured.

- [ ] Write tests: restart resumes downloaded MP4; partial is never success; missing address requests exact UID reopen; archived video-analysis revision cannot duplicate.
- [ ] Run: swift test --filter PDDBackgroundVideoRecoveryTests
- [ ] Verify RED.
- [ ] On startup, delete orphan partials and validate stable MP4s before resuming evidence.
- [ ] For armed/waiting/downloading records without stable MP4, enqueue exact-UID recovery open using the saved PDD locator and a fresh CEF baseline.
- [ ] Deduplicate recovery against live registry keys, pending scheduler batches, active jobs, and archived video-analysis revisions.
- [ ] Run: swift test
- [ ] Require zero failures; conditional live tests may skip only when their named environment variables are absent.
- [ ] Build: ./scripts/build_app.sh --task-isolation-candidate
- [ ] Verify: codesign --verify --deep --strict --verbose=2 outputs/拼多多全自动客服-任务隔离候选版.app
- [ ] Calculate SHA-256 of Contents/MacOS/PDDTaskIsolationCandidate.
- [ ] Launch stopped and run dry-run live acceptance with a newly sent PDD video.
- [ ] Verify timestamp order: armed, opened, background started, preview closed, scanner resumed, address captured, downloading, stable MP4, evidence, one Codex draft.
- [ ] Verify no signed URL exists anywhere under the runtime root.
- [ ] Perform real-send acceptance only after explicit user confirmation; confirm exactly one reply to the correct UID.
- [ ] Record automated counts, codesign result, SHA, live timings, MP4 metadata, frame count, audio/transcript status, and URL-leak scan in the evidence document.
- [ ] Update the handoff manual with new files, state recovery, and debug commands.
- [ ] If Git is available, commit with message: test: verify PDD background video parity end to end

