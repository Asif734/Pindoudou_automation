import CryptoKit
import XCTest
@testable import PDDAXReader

@MainActor
final class PDDAXConversationDriverTests: XCTestCase {
    func testDiscoverReturnsCurrentAllowedConversationWithoutUnreadEvidence() async throws {
        let backend = FakePDDAXBackend(trees: [openedChatTree(uid: "GZC-000001")])
        let driver = makeDriver(backend: backend)

        let discoveries = try await driver.discover()

        XCTAssertEqual(discoveries, [])
        XCTAssertTrue(backend.pressedIDs.isEmpty)
    }

    func testAXUnreadClassAloneDoesNotCreateUnreadEvidence() async throws {
        let current = openedChatTree(uid: "GZC-000001", nodes: conversationListTree.nodes)
        let backend = FakePDDAXBackend(trees: [current])
        let driver = makeDriver(backend: backend, unread: FakePDDUnreadEvidence(rows: []))

        let discoveries = try await driver.discover()

        XCTAssertEqual(discoveries, [])
        XCTAssertTrue(backend.pressedIDs.isEmpty)
    }

    func testDiscoverPrioritizesOneUnreadConversationOverCurrentConversation() async throws {
        let current = openedChatTree(
            uid: "GZC-000001",
            nodes: conversationListTree.nodes
        )
        let backend = FakePDDAXBackend(trees: [current, openedChatTree(uid: "GZC-000002")])
        let driver = makeDriver(backend: backend, allowedUIDs: ["GZC-000001", "GZC-000002"])

        let discoveries = try await driver.discover()

        XCTAssertEqual(discoveries, [
            .init(uid: "PDD-NAME-058c1710f23a398e4fbeec1a", hasUnreadEvidence: true)
        ])
        XCTAssertEqual(backend.readCount, 2)
        XCTAssertEqual(backend.pressedIDs, [.init(rawValue: 2)])
    }

    func testDiscoverPressesUnreadRowThenReturnsResolvedUID() async throws {
        let backend = FakePDDAXBackend(trees: [conversationListTree, openedChatTree(uid: "GZC-000001")])
        let driver = makeDriver(backend: backend)

        let discoveries = try await driver.discover()

        XCTAssertEqual(discoveries, [
            .init(uid: "PDD-NAME-058c1710f23a398e4fbeec1a", hasUnreadEvidence: true)
        ])
        XCTAssertEqual(backend.pressedIDs, [.init(rawValue: 2)])
    }

    func testDiscoverUsesConversationKeyEvenWhenOpenedProfileContainsLegacyUID() async throws {
        let locator = PDDConversationLocator(domIdentifier: nil, nickname: "测试用户")
        let backend = FakePDDAXBackend(trees: [
            conversationListTree,
            openedChatTree(uid: "GZC-000001")
        ])
        let driver = makeDriver(backend: backend, allowedUIDs: nil)

        let discoveries = try await driver.discover()

        let uid = PDDConversationKey.make(locator: locator)
        XCTAssertEqual(discoveries, [.init(uid: uid, hasUnreadEvidence: true)])
        XCTAssertEqual(driver.conversationLocatorsSnapshot()?[uid], locator)
    }

    func testDiscoverWithoutLegacyUIDCreatesIdentifierKeyAndKeepsLocator() async throws {
        let locator = PDDConversationLocator(domIdentifier: "buyer-123", nickname: "S***")
        let list = PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: [
            semantic(1, role: "AXGroup", classes: ["chat-list-box"]),
            semantic(2, parent: 1, role: "AXGroup", identifier: "buyer-123", classes: ["conversation-item"], actions: ["AXPress"]),
            semantic(3, parent: 2, role: "AXStaticText", value: "S***", classes: ["nickname"]),
            semantic(4, parent: 2, role: "AXGroup", classes: ["red-dot"])
        ])
        let backend = FakePDDAXBackend(trees: [list, usableChatTree()])
        let driver = makeDriver(backend: backend, allowedUIDs: nil)

        let discoveries = try await driver.discover()

        let uid = PDDConversationKey.make(locator: locator)
        XCTAssertEqual(discoveries, [.init(uid: uid, hasUnreadEvidence: true)])
        XCTAssertEqual(driver.conversationLocatorsSnapshot()?[uid], locator)
    }

    func testDiscoverCurrentMaskedConversationWithoutUnreadCreatesNicknameLocator() async throws {
        let locator = PDDConversationLocator(domIdentifier: nil, nickname: "山**川")
        let current = PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: [
            semantic(1, role: "AXGroup", classes: ["chat-list-box"]),
            semantic(2, parent: 1, role: "AXGroup", classes: ["chat-item-box", "active"], actions: ["AXPress"]),
            semantic(3, parent: 2, role: "AXGroup", classes: ["chat-nickname"]),
            semantic(4, parent: 3, role: "AXStaticText", value: "山**川"),
            semantic(10, role: "AXGroup", classes: ["middle-panel"]),
            semantic(11, parent: 10, role: "AXTextArea", settable: true)
        ])
        let backend = FakePDDAXBackend(trees: [current])
        let driver = makeDriver(backend: backend, allowedUIDs: nil)

        let discoveries = try await driver.discover()

        let uid = PDDConversationKey.make(locator: locator)
        XCTAssertEqual(discoveries, [.init(uid: uid, hasUnreadEvidence: false)])
        XCTAssertEqual(driver.conversationLocatorsSnapshot()?[uid], locator)
    }

    func testRestoredBaselineDoesNotDiscardFirstCaptureAfterAppRestart() async throws {
        let locator = PDDConversationLocator(domIdentifier: nil, nickname: "S***")
        let uid = PDDConversationKey.make(locator: locator)
        let backend = FakePDDAXBackend(trees: [openedChatTree(
            uid: uid,
            messages: [customer("新消息")],
            nodes: usableChatTree().nodes
        )])
        let driver = makeDriver(
            backend: backend,
            allowedUIDs: nil,
            ocr: FakePDDOCRSupplement(responses: [[ocr("new", .customer, "新消息")]])
        )
        driver.restoreConversationLocators([uid: locator])
        driver.restoreConversationCaptureState(
            baselinedUIDs: [uid],
            knownServiceMessageIDsByUID: [:]
        )

        let capture = try await driver.capture(uid: uid, after: .empty)

        XCTAssertEqual(capture.batch?.events.map(\.content), ["新消息"])
    }

    func testUIDMismatchAfterRowPressProducesNoDiscovery() async throws {
        let backend = FakePDDAXBackend(trees: [conversationListTree, openedChatTree(uid: "GZC-999999")])
        let driver = makeDriver(backend: backend, allowedUIDs: ["GZC-000001"])

        let discoveries = try await driver.discover()
        XCTAssertTrue(discoveries.isEmpty)
    }

    func testAllUserScopeAcceptsCanonicalUIDResolvedAfterRedDotPress() async throws {
        let backend = FakePDDAXBackend(trees: [conversationListTree, openedChatTree(uid: "GZC-000777")])
        let driver = makeDriver(backend: backend, allowedUIDs: nil)

        let discoveries = try await driver.discover()

        XCTAssertEqual(discoveries, [
            .init(uid: "PDD-NAME-058c1710f23a398e4fbeec1a", hasUnreadEvidence: true)
        ])
    }

    func testDiscoverPressesOnlyOneUnreadConversationPerCall() async throws {
        let root = AXNodeSnapshot(role: "AXWindow")
        let list = PDDAXSemanticTree(rootSnapshot: root, nodes: [
            semantic(1, role: "AXGroup", classes: ["chat-list-box"]),
            semantic(2, parent: 1, role: "AXGroup", actions: ["AXPress"]),
            semantic(3, parent: 2, role: "AXStaticText", value: "客户甲"),
            semantic(4, parent: 2, role: "AXGroup", classes: ["red-dot"]),
            semantic(5, parent: 1, role: "AXGroup", actions: ["AXPress"]),
            semantic(6, parent: 5, role: "AXStaticText", value: "客户乙"),
            semantic(7, parent: 5, role: "AXStaticText", value: "3", classes: ["unread-count"])
        ])
        let backend = FakePDDAXBackend(trees: [list, openedChatTree(uid: "GZC-000002")])
        let driver = makeDriver(backend: backend, allowedUIDs: ["GZC-000001", "GZC-000002"])

        let discoveries = try await driver.discover()

        XCTAssertEqual(discoveries, [
            .init(uid: "PDD-NAME-6ad75cf1be40352868838fb2", hasUnreadEvidence: true)
        ])
        XCTAssertEqual(backend.pressedIDs, [.init(rawValue: 2)])
        XCTAssertEqual(backend.readCount, 2)
    }

    func testOpenAndResolveReturnsToPreviouslyVerifiedNonUnreadRow() async throws {
        let unreadList = PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: [
            semantic(1, role: "AXGroup", classes: ["chat-list-box"]),
            semantic(2, parent: 1, role: "AXGroup", actions: ["AXPress"]),
            semantic(3, parent: 2, role: "AXStaticText", value: "客户甲"),
            semantic(4, parent: 2, role: "AXGroup", classes: ["red-dot"])
        ])
        let ordinaryList = PDDAXSemanticTree(
            rootSnapshot: AXNodeSnapshot(role: "AXWindow", attributes: [("AXValue", "GZC-000001")]),
            nodes: [
                semantic(10, role: "AXGroup", classes: ["chat-list-box"]),
                semantic(11, parent: 10, role: "AXGroup", actions: ["AXPress"]),
                semantic(12, parent: 11, role: "AXStaticText", value: "客户甲")
            ]
        )
        let backend = FakePDDAXBackend(trees: [
            unreadList, openedChatTree(uid: "GZC-000002"),
            ordinaryList, openedChatTree(uid: "GZC-000002")
        ])
        let driver = makeDriver(backend: backend, allowedUIDs: ["GZC-000001", "GZC-000002"])
        _ = try await driver.discover()

        let reopened = try await driver.openAndResolve(uid: "GZC-000002")

        XCTAssertEqual(PDDCustomerIdentity.resolve(from: reopened.rootSnapshot), "GZC-000002")
        XCTAssertEqual(backend.pressedIDs, [.init(rawValue: 2), .init(rawValue: 11)])
    }

    func testOpenAndResolveTriesSecondSameNameRowUntilUIDMatches() async throws {
        let unreadList = PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: [
            semantic(1, role: "AXGroup", classes: ["chat-list-box"]),
            semantic(2, parent: 1, role: "AXGroup", actions: ["AXPress"]),
            semantic(3, parent: 2, role: "AXStaticText", value: "同名客户"),
            semantic(4, parent: 2, role: "AXGroup", classes: ["red-dot"])
        ])
        let duplicateRows: [PDDAXSemanticNode<AXElementToken>] = [
            semantic(10, role: "AXGroup", classes: ["chat-list-box"]),
            semantic(11, parent: 10, role: "AXGroup", actions: ["AXPress"]),
            semantic(12, parent: 11, role: "AXStaticText", value: "同名客户"),
            semantic(21, parent: 10, role: "AXGroup", actions: ["AXPress"]),
            semantic(22, parent: 21, role: "AXStaticText", value: "同名客户")
        ]
        let wrongRowOpen = openedChatTree(uid: "GZC-000003", nodes: duplicateRows)
        let listBeforeOpen = openedChatTree(uid: "GZC-000001", nodes: duplicateRows)
        let backend = FakePDDAXBackend(trees: [
            unreadList, openedChatTree(uid: "GZC-000002"),
            listBeforeOpen, wrongRowOpen, openedChatTree(uid: "GZC-000002")
        ])
        let driver = makeDriver(backend: backend, allowedUIDs: nil)
        _ = try await driver.discover()

        let reopened = try await driver.openAndResolve(uid: "GZC-000002")

        XCTAssertEqual(PDDCustomerIdentity.resolve(from: reopened.rootSnapshot), "GZC-000002")
        XCTAssertEqual(backend.pressedIDs, [
            .init(rawValue: 2), .init(rawValue: 11), .init(rawValue: 21)
        ])
    }

    func testOpenAndResolvePrefersExactDOMIdentifierForSameMaskedNickname() async throws {
        let locator = PDDConversationLocator(domIdentifier: "buyer-b", nickname: "S***")
        let uid = PDDConversationKey.make(locator: locator)
        let list = PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: [
            semantic(1, role: "AXGroup", classes: ["chat-list-box"]),
            semantic(2, parent: 1, role: "AXGroup", identifier: "buyer-a", classes: ["conversation-item"], actions: ["AXPress"]),
            semantic(3, parent: 2, role: "AXStaticText", value: "S***", classes: ["nickname"]),
            semantic(4, parent: 1, role: "AXGroup", identifier: "buyer-b", classes: ["conversation-item"], actions: ["AXPress"]),
            semantic(5, parent: 4, role: "AXStaticText", value: "S***", classes: ["nickname"])
        ])
        let backend = FakePDDAXBackend(trees: [list, usableChatTree()])
        let driver = makeDriver(backend: backend, allowedUIDs: nil)
        driver.restoreConversationLocators([uid: locator])

        _ = try await driver.openAndResolve(uid: uid)

        XCTAssertEqual(backend.pressedIDs, [.init(rawValue: 4)])
    }

    func testExpiredIdentifierFallsBackToNicknameAndRefreshesLocator() async throws {
        let old = PDDConversationLocator(domIdentifier: "expired", nickname: "S***")
        let uid = PDDConversationKey.make(locator: old)
        let list = PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: [
            semantic(1, role: "AXGroup", classes: ["chat-list-box"]),
            semantic(2, parent: 1, role: "AXGroup", identifier: "fresh", classes: ["conversation-item"], actions: ["AXPress"]),
            semantic(3, parent: 2, role: "AXStaticText", value: "S***", classes: ["nickname"])
        ])
        let backend = FakePDDAXBackend(trees: [list, usableChatTree()])
        let driver = makeDriver(backend: backend, allowedUIDs: nil)
        driver.restoreConversationLocators([uid: old])

        _ = try await driver.openAndResolve(uid: uid)

        XCTAssertEqual(driver.conversationLocatorsSnapshot()?[uid]?.domIdentifier, "fresh")
        XCTAssertEqual(driver.takeConversationDiagnostics().map(\.kind), ["conversation-identifier-refreshed"])
    }

    func testNicknameFallbackChecksSecondVisibleCandidateByTargetMessageID() async throws {
        let locator = PDDConversationLocator(domIdentifier: nil, nickname: "c***")
        let uid = PDDConversationKey.make(locator: locator)
        let rows: [PDDAXSemanticNode<AXElementToken>] = [
            semantic(1, role: "AXGroup", classes: ["chat-list-box"]),
            semantic(2, parent: 1, role: "AXGroup", actions: ["AXPress"]),
            semantic(3, parent: 2, role: "AXStaticText", value: "c***"),
            semantic(4, parent: 1, role: "AXGroup", actions: ["AXPress"]),
            semantic(5, parent: 4, role: "AXStaticText", value: "c***")
        ]
        let firstWrong = PDDAXSemanticTree(
            rootSnapshot: AXNodeSnapshot(role: "AXWindow", children: [customer("wrong")]),
            nodes: rows + usableChatTree().nodes
        )
        let secondCorrect = PDDAXSemanticTree(
            rootSnapshot: AXNodeSnapshot(role: "AXWindow", children: [customer("target")]),
            nodes: rows + usableChatTree().nodes
        )
        let backend = FakePDDAXBackend(trees: [
            PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: rows),
            firstWrong,
            secondCorrect
        ])
        let driver = makeDriver(backend: backend, allowedUIDs: nil)
        driver.restoreConversationLocators([uid: locator])

        _ = try await driver.openAndResolve(
            uid: uid,
            expectedCustomerMessageIDs: ["middlePanel_list_target"]
        )

        XCTAssertEqual(backend.pressedIDs, [.init(rawValue: 2), .init(rawValue: 4)])
    }

    func testNicknameFallbackNeverChecksMoreThanTwoVisibleCandidates() async throws {
        let locator = PDDConversationLocator(domIdentifier: nil, nickname: "c***")
        let uid = PDDConversationKey.make(locator: locator)
        let rows: [PDDAXSemanticNode<AXElementToken>] = [
            semantic(1, role: "AXGroup", classes: ["chat-list-box"]),
            semantic(2, parent: 1, role: "AXGroup", actions: ["AXPress"]),
            semantic(3, parent: 2, role: "AXStaticText", value: "c***"),
            semantic(4, parent: 1, role: "AXGroup", actions: ["AXPress"]),
            semantic(5, parent: 4, role: "AXStaticText", value: "c***"),
            semantic(6, parent: 1, role: "AXGroup", actions: ["AXPress"]),
            semantic(7, parent: 6, role: "AXStaticText", value: "c***")
        ]
        let wrong = PDDAXSemanticTree(
            rootSnapshot: AXNodeSnapshot(role: "AXWindow", children: [customer("wrong")]),
            nodes: rows + usableChatTree().nodes
        )
        let backend = FakePDDAXBackend(trees: [
            PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: rows),
            wrong,
            wrong
        ])
        let driver = makeDriver(backend: backend, allowedUIDs: nil)
        driver.restoreConversationLocators([uid: locator])

        do {
            _ = try await driver.openAndResolve(
                uid: uid,
                expectedCustomerMessageIDs: ["middlePanel_list_target"]
            )
            XCTFail("expected nickname fallback exhaustion")
        } catch let error as PDDAXConversationDriverError {
            guard case .nicknameCandidatesExhausted = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(backend.pressedIDs, [.init(rawValue: 2), .init(rawValue: 4)])
    }

    func testMissingRowUsesCurrentUsableChatSurfaceInsteadOfBlocking() async throws {
        let locator = PDDConversationLocator(domIdentifier: "gone", nickname: "S***")
        let uid = PDDConversationKey.make(locator: locator)
        let backend = FakePDDAXBackend(trees: [usableChatTree()])
        let driver = makeDriver(backend: backend, allowedUIDs: nil)
        driver.restoreConversationLocators([uid: locator])

        _ = try await driver.openAndResolve(uid: uid)

        XCTAssertTrue(backend.pressedIDs.isEmpty)
        XCTAssertEqual(driver.takeConversationDiagnostics().map(\.kind), ["conversation-current-fallback"])
    }

    func testNoUnreadConversationCreatesBaselineWithoutJob() async throws {
        let backend = FakePDDAXBackend(trees: [openedChatTree(
            uid: "GZC-000001",
            messages: [customer("A"), customer("B"), customer("C")]
        )])
        let driver = makeDriver(backend: backend, ocr: FakePDDOCRSupplement(responses: [[
            ocr("ocr-a", .customer, "A"),
            ocr("ocr-b", .customer, "B"),
            ocr("ocr-c", .customer, "C")
        ]]))

        let capture = try await driver.capture(uid: "GZC-000001", after: .empty)

        XCTAssertNil(capture.batch)
        XCTAssertEqual(capture.customerCursor.count, 3)
    }

    func testUnreadFirstRunFreezesOnlyCustomerTailAfterLastService() async throws {
        let backend = FakePDDAXBackend(trees: [
            conversationListTree,
            openedChatTree(uid: "GZC-000001"),
            openedChatTree(
                uid: "GZC-000001",
                messages: [customer("A"), service("S"), customer("B"), customer("C")]
            )
        ])
        let driver = makeDriver(backend: backend, ocr: FakePDDOCRSupplement(responses: [[
            ocr("ocr-a", .customer, "A"),
            ocr("ocr-s", .service, "S"),
            ocr("ocr-b", .customer, "B"),
            ocr("ocr-c", .customer, "C")
        ]]))
        _ = try await driver.discover()

        let capture = try await driver.capture(uid: "GZC-000001", after: .empty)

        XCTAssertEqual(capture.batch?.events.map(\.messageID), ["middlePanel_list_B", "middlePanel_list_C"])
        XCTAssertEqual(capture.batch?.startCursor.count, 1)
    }

    func testInvalidPersistedCursorRebasesToLastServiceAndKeepsUnansweredTail() async throws {
        let backend = FakePDDAXBackend(trees: [openedChatTree(
            uid: "GZC-000001",
            messages: [customer("A"), service("S"), customer("B")]
        )])
        let driver = makeDriver(backend: backend, ocr: FakePDDOCRSupplement(responses: [[
            ocr("ocr-a", .customer, "A"),
            ocr("ocr-s", .service, "S"),
            ocr("ocr-b", .customer, "B")
        ]]))
        let staleCursor = AutoReplyCursor(count: 1, digest: String(repeating: "f", count: 64))

        let capture = try await driver.capture(uid: "GZC-000001", after: staleCursor)

        XCTAssertEqual(capture.batch?.events.map(\.messageID), ["middlePanel_list_B"])
        XCTAssertEqual(capture.batch?.startCursor.count, 1)
    }

    func testInvalidCursorRecoveryNeverAdvancesPastPersistedAnsweredCount() async throws {
        let backend = FakePDDAXBackend(trees: [openedChatTree(
            uid: "GZC-000001",
            messages: [customer("older-late"), customer("A"), customer("B"), service("reply-for-A")]
        )])
        let driver = makeDriver(backend: backend, ocr: FakePDDOCRSupplement(responses: [[
            ocr("ocr-older-late", .customer, "older-late"),
            ocr("ocr-a", .customer, "A"),
            ocr("ocr-b", .customer, "B"),
            ocr("ocr-reply-a", .service, "reply-for-A")
        ]]))
        let staleCursor = AutoReplyCursor(count: 1, digest: String(repeating: "f", count: 64))

        let capture = try await driver.capture(uid: "GZC-000001", after: staleCursor)

        XCTAssertEqual(capture.batch?.startCursor.count, 1)
        XCTAssertTrue(capture.batch?.events.contains(where: { $0.messageID == "middlePanel_list_B" }) == true)
    }

    func testAXIsSoleMessageSourceWhileItsStructuredTreeIsValid() async throws {
        let backend = FakePDDAXBackend(trees: [
            openedChatTree(uid: "GZC-000001", messages: [customer("A")]),
            openedChatTree(uid: "GZC-000001", messages: [customer("A")])
        ])
        let ocr = FakePDDOCRSupplement(responses: [[
            ocr("ocr-a", .customer, "A")
        ], [
            ocr("ocr-a", .customer, "A"),
            ocr("ocr-new", .customer, "OCR读到的新问题")
        ]])
        let driver = makeDriver(backend: backend, ocr: ocr)
        let baseline = try await driver.capture(uid: "GZC-000001", after: .empty)

        let capture = try await driver.capture(uid: "GZC-000001", after: baseline.customerCursor)

        XCTAssertEqual(capture.fullHistory.map(\.id), ["middlePanel_list_A"])
        XCTAssertNil(capture.batch)
        XCTAssertEqual(ocr.requestedUIDs, [])
        XCTAssertEqual(capture.ocrDiagnostic, "AX 权威读取：1 条可见消息")
    }

    func testMissingAXStructureWithUnreadUsesOnlyOneOCRProvisionalTail() async throws {
        let uid = "GZC-000001"
        let missing = openedChatTree(uid: uid)
        let backend = FakePDDAXBackend(trees: [conversationListTree, missing, missing])
        let ocr = FakePDDOCRSupplement(responses: [[
            PDDOCRMessage(
                id: "ocr-old", sender: .customer, text: "旧消息", timestamp: nil,
                box: CGRect(x: 10, y: 10, width: 80, height: 20)
            ),
            PDDOCRMessage(
                id: "ocr-new", sender: .customer, text: "最末新问题", timestamp: nil,
                box: CGRect(x: 10, y: 100, width: 100, height: 20)
            )
        ]])
        let driver = makeDriver(backend: backend, ocr: ocr)
        _ = try await driver.discover()

        let capture = try await driver.capture(uid: uid, after: .empty)

        XCTAssertEqual(capture.fullHistory.map(\.content), ["最末新问题"])
        XCTAssertEqual(capture.batch?.events.map(\.content), ["最末新问题"])
        XCTAssertTrue(capture.fullHistory[0].id.hasPrefix("ocr-provisional-"))
        XCTAssertEqual(ocr.requestedUIDs, [uid])
        XCTAssertTrue(capture.ocrDiagnostic?.contains("missingStructure") == true)
    }

    func testPreflightWithoutUnreadNeverInvokesOCRWhenAXStructureIsMissing() async throws {
        let uid = "GZC-000001"
        let backend = FakePDDAXBackend(trees: [openedChatTree(uid: uid)])
        let ocr = FakePDDOCRSupplement(responses: [[
            PDDOCRMessage(
                id: "ocr-false-customer", sender: .customer, text: "客服旧回复误识别",
                timestamp: nil, box: CGRect(x: 10, y: 100, width: 120, height: 20)
            )
        ]])
        let driver = makeDriver(backend: backend, ocr: ocr)

        let capture = try await driver.preflight(uid: uid, after: .empty)

        XCTAssertNil(capture.batch)
        XCTAssertEqual(ocr.requestedUIDs, [])
        XCTAssertTrue(capture.ocrDiagnostic?.contains("无红点，跳过 OCR") == true)
    }

    func testMessageNodesWithoutComposerAreNotAcceptedAsAuthoritativeChatSurface() async throws {
        let uid = "GZC-000001"
        let invalidSurface = openedChatTree(
            uid: uid,
            messages: [customer("stale-ax")],
            nodes: [semantic(99, role: "AXWindow", value: uid)]
        )
        let backend = FakePDDAXBackend(trees: [conversationListTree, invalidSurface, invalidSurface])
        let ocr = FakePDDOCRSupplement(responses: [[
            PDDOCRMessage(
                id: "ocr-real", sender: .customer, text: "真实末尾", timestamp: nil,
                box: CGRect(x: 10, y: 100, width: 100, height: 20)
            )
        ]])
        let driver = makeDriver(backend: backend, ocr: ocr)
        _ = try await driver.discover()

        let capture = try await driver.capture(uid: uid, after: .empty)

        XCTAssertEqual(capture.fullHistory.map(\.content), ["真实末尾"])
        XCTAssertTrue(capture.ocrDiagnostic?.contains("regressedStructure") == true)
    }

    func testUnreadStaleAXUsesOCRAfterThreeSamplesThenAbsorbsRecoveredAXWithoutSecondBatch() async throws {
        let uid = "GZC-000001"
        let axA = openedChatTree(uid: uid, messages: [customer("A")])
        let axAB = openedChatTree(uid: uid, messages: [customer("A"), customer("B")])
        let backend = FakePDDAXBackend(trees: [
            axA,
            conversationListTree, axA,
            axA, axA, axA,
            axAB
        ])
        let ocr = FakePDDOCRSupplement(responses: [[
            PDDOCRMessage(
                id: "ocr-a", sender: .customer, text: "A", timestamp: nil,
                box: CGRect(x: 10, y: 10, width: 20, height: 20)
            ),
            PDDOCRMessage(
                id: "ocr-b", sender: .customer, text: "B", timestamp: nil,
                box: CGRect(x: 10, y: 100, width: 20, height: 20)
            )
        ]])
        let driver = makeDriver(backend: backend, ocr: ocr)
        let baseline = try await driver.capture(uid: uid, after: .empty)
        _ = try await driver.discover()

        let provisional = try await driver.capture(uid: uid, after: baseline.customerCursor)

        XCTAssertEqual(provisional.batch?.events.map(\.content), ["B"])
        XCTAssertTrue(provisional.batch?.events[0].messageID.hasPrefix("ocr-provisional-") == true)
        XCTAssertTrue(provisional.ocrDiagnostic?.contains("AX 未前进（3/3）") == true)
        XCTAssertEqual(ocr.requestedUIDs, [uid])

        let recovered = try await driver.capture(uid: uid, after: provisional.customerCursor)

        XCTAssertNil(recovered.batch)
        XCTAssertEqual(recovered.fullHistory.map(\.content), ["A", "B"])
        XCTAssertTrue(recovered.ocrDiagnostic?.contains("AX 已恢复并吸收 OCR 临时消息") == true)
        XCTAssertNotNil(driver.provisionalReceiptsSnapshot()[uid]?.first?.absorbedAXMessageID)
        XCTAssertEqual(ocr.requestedUIDs, [uid])
    }

    func testOCRFailureIsIrrelevantWhenAXMessagesAreValid() async throws {
        let backend = FakePDDAXBackend(trees: [openedChatTree(
            uid: "GZC-000001", messages: [customer("A")]
        )])
        let ocr = FakePDDOCRSupplement(error: PDDOCRError.capture("fixture"))
        var diagnostic: String?
        let driver = makeDriver(backend: backend, ocr: ocr)
        driver.onOCRDiagnostic = { diagnostic = $0 }

        let capture = try await driver.capture(uid: "GZC-000001", after: .empty)

        XCTAssertEqual(capture.fullHistory.map(\.id), ["middlePanel_list_A"])
        XCTAssertEqual(diagnostic, "AX 权威读取：1 条可见消息")
        XCTAssertTrue(ocr.requestedUIDs.isEmpty)
    }

    func testUnreadCaptureAddsOnlyAXCustomerImageAfterLastAXServiceMessage() async throws {
        let backend = FakePDDAXBackend(trees: [
            conversationListTree,
            openedChatTree(uid: "GZC-000001"),
            openedChatTree(uid: "GZC-000001", messages: [
                imageMessage("old-customer-image", customer: true),
                service("S"),
                imageMessage("service-image", customer: false),
                imageMessage("new-customer-image", customer: true),
                customer("AX正文不能进入OCR历史")
            ])
        ])
        let ocr = FakePDDOCRSupplement(responses: [[ocr("ocr-s", .service, "S")]])
        let driver = makeDriver(backend: backend, ocr: ocr)
        _ = try await driver.discover()

        let capture = try await driver.capture(uid: "GZC-000001", after: .empty)

        XCTAssertEqual(capture.fullHistory.map(\.id), [
            "middlePanel_list_old-customer-image", "middlePanel_list_S",
            "middlePanel_list_service-image", "middlePanel_list_new-customer-image",
            "middlePanel_list_AX正文不能进入OCR历史"
        ])
        XCTAssertEqual(capture.fullHistory.last?.sender, .customer)
        XCTAssertEqual(capture.fullHistory.last?.kind, .text)
        XCTAssertEqual(capture.fullHistory.last?.content, "AX正文不能进入OCR历史")
        XCTAssertEqual(capture.batch?.events.map(\.messageID), [
            "middlePanel_list_new-customer-image", "middlePanel_list_AX正文不能进入OCR历史"
        ])
        XCTAssertEqual(capture.ocrDiagnostic, "AX 权威读取：5 条可见消息")
        XCTAssertTrue(capture.fullHistory.contains { $0.content == "AX正文不能进入OCR历史" })
        XCTAssertTrue(capture.fullHistory.contains { $0.id == "middlePanel_list_service-image" })
    }

    func testUnparseableAXServiceNodeStillCutsOffEarlierCustomerImages() async throws {
        let backend = FakePDDAXBackend(trees: [
            conversationListTree,
            openedChatTree(uid: "GZC-000001"),
            openedChatTree(uid: "GZC-000001", messages: [
                imageMessage("old-image", customer: true),
                emptyMessage("service-boundary", customer: false),
                imageMessage("new-image", customer: true)
            ])
        ])
        let driver = makeDriver(
            backend: backend,
            ocr: FakePDDOCRSupplement(responses: [[ocr("ocr-s", .service, "客服回复")]])
        )
        _ = try await driver.discover()

        let capture = try await driver.capture(uid: "GZC-000001", after: .empty)

        XCTAssertEqual(capture.fullHistory.map(\.id), [
            "middlePanel_list_old-image", "middlePanel_list_new-image"
        ])
        XCTAssertEqual(capture.batch?.events.map(\.messageID), [
            "middlePanel_list_old-image", "middlePanel_list_new-image"
        ])
    }

    func testAXImagesUseMatchingAXTextAsOCROrderingAnchors() async throws {
        let backend = FakePDDAXBackend(trees: [
            conversationListTree,
            openedChatTree(uid: "GZC-000001"),
            openedChatTree(uid: "GZC-000001", messages: [
                service("S"),
                imageMessage("image-before-text", customer: true),
                customer("T"),
                imageMessage("image-after-text", customer: true)
            ])
        ])
        let driver = makeDriver(
            backend: backend,
            ocr: FakePDDOCRSupplement(responses: [[
                ocr("ocr-s", .service, "S"),
                ocr("ocr-t", .customer, "T")
            ]])
        )
        _ = try await driver.discover()

        let capture = try await driver.capture(uid: "GZC-000001", after: .empty)

        XCTAssertEqual(capture.fullHistory.map(\.id), [
            "middlePanel_list_S", "middlePanel_list_image-before-text", "middlePanel_list_T",
            "middlePanel_list_image-after-text"
        ])
        XCTAssertEqual(capture.batch?.events.map(\.messageID), [
            "middlePanel_list_image-before-text", "middlePanel_list_T", "middlePanel_list_image-after-text"
        ])
    }

    func testMultipleAXImagesWithoutDOMIDsRemainDistinctEvents() async throws {
        let backend = FakePDDAXBackend(trees: [
            conversationListTree,
            openedChatTree(uid: "GZC-000001"),
            openedChatTree(uid: "GZC-000001", messages: [
                service("S"),
                imageMessageWithoutID(customer: true, chromeNodeID: "101"),
                imageMessageWithoutID(customer: true, chromeNodeID: "102")
            ])
        ])
        let driver = makeDriver(
            backend: backend,
            ocr: FakePDDOCRSupplement(responses: [[ocr("ocr-s", .service, "S")]])
        )
        _ = try await driver.discover()

        let capture = try await driver.capture(uid: "GZC-000001", after: .empty)
        let imageIDs = capture.fullHistory.filter { $0.kind == .image }.map(\.id)

        XCTAssertEqual(imageIDs.count, 2)
        XCTAssertEqual(Set(imageIDs).count, 2)
        XCTAssertEqual(capture.batch?.events.count, 2)
    }

    func testFallbackAXImageWithoutStableImageNodeIdentityIsNotEmitted() {
        let root = AXNodeSnapshot(role: "AXWindow", children: [
            service("S"),
            imageMessageWithoutID(customer: true)
        ])

        let evidence = PDDAXTailEvidence.extract(root: root, capturedAt: .distantPast)

        XCTAssertEqual(evidence.allImageCount, 1)
        XCTAssertTrue(evidence.customerImages.isEmpty)
    }

    func testFallbackAXImageIdentitySurvivesScrollingWhenChromeNodeIDIsStable() {
        let first = AXNodeSnapshot(role: "AXWindow", children: [
            service("S"),
            imageMessageWithoutID(customer: true, chromeNodeID: "101"),
            imageMessageWithoutID(customer: true, chromeNodeID: "102")
        ])
        let scrolled = AXNodeSnapshot(role: "AXWindow", children: [
            service("S"),
            imageMessageWithoutID(customer: true, chromeNodeID: "102"),
            imageMessageWithoutID(customer: true, chromeNodeID: "103")
        ])

        let firstIDs = PDDAXTailEvidence.extract(root: first, capturedAt: .distantPast)
            .customerImages.map(\.id)
        let scrolledIDs = PDDAXTailEvidence.extract(root: scrolled, capturedAt: .distantFuture)
            .customerImages.map(\.id)

        XCTAssertEqual(firstIDs.count, 2)
        XCTAssertEqual(scrolledIDs.count, 2)
        XCTAssertEqual(firstIDs[1], scrolledIDs[0])
        XCTAssertNotEqual(scrolledIDs[0], scrolledIDs[1])
    }

    func testCapturePersistsOnlyAXFirstHistoryAndLeavesLegacyHistoryUntouched() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-driver-transient-ocr-\(UUID().uuidString)")
        let store = PerUserChatStore(rootDirectory: root)
        _ = try store.merge(uid: "GZC-000001", messages: [
            PDDChatMessage(
                id: "middlePanel_list_legacy", sender: .customer, content: "旧AX正文",
                displayTime: nil, kind: .text, capturedAt: .distantPast
            ),
            PDDChatMessage(
                id: "ocr-policy-noise", sender: .customer,
                content: "2.结论告知:基于调查结果,商家应主动向消费者提供明确、负责任的答复。",
                displayTime: nil, kind: .text, capturedAt: .distantPast
            )
        ])
        let backend = FakePDDAXBackend(trees: [openedChatTree(
            uid: "GZC-000001", messages: [customer("A")]
        )])
        let ocr = FakePDDOCRSupplement(responses: [[ocr("ocr-b", .customer, "B")]])
        let driver = PDDAXConversationDriver(
            backend: backend, chatStore: store,
            allowedUIDs: ["GZC-000001"], ocrSupplement: ocr
        )

        let capture = try await driver.capture(uid: "GZC-000001", after: .empty)

        XCTAssertEqual(capture.fullHistory.map(\.id), ["middlePanel_list_A"])
        XCTAssertEqual(
            try store.load(uid: "GZC-000001").map(\.id),
            ["middlePanel_list_legacy", "ocr-policy-noise"]
        )
        XCTAssertEqual(try store.loadAXFirst(uid: "GZC-000001").map(\.id), ["middlePanel_list_A"])
    }

    func testCaptureDownloadsAXAuthoritativeCustomerImageIntoCaptureAttachments() async throws {
        let uid = "GZC-000001"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-driver-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = openedChatTree(uid: uid)
        let imageID = "middlePanel_list_100"
        let imageTree = openedChatTree(
            uid: uid,
            messages: [imageMessage("100", customer: true)],
            nodes: [
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 0), parentID: nil, role: "AXGroup",
                    value: nil, title: nil, domIdentifier: nil,
                    domClasses: ["history-box", "custom-scroll"], actionNames: [],
                    isSettable: false, frame: CGRect(x: 0, y: 0, width: 500, height: 500)
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 1), parentID: AXElementToken(rawValue: 0), role: "AXGroup",
                    value: nil, title: nil, domIdentifier: imageID,
                    domClasses: ["onemsg", "buyer-item"], actionNames: [], isSettable: false
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 2), parentID: AXElementToken(rawValue: 1),
                    role: "AXGroup", value: nil, title: nil, domIdentifier: nil,
                    domClasses: ["image-msg"], actionNames: [], isSettable: false,
                    frame: CGRect(x: 10, y: 20, width: 30, height: 40)
                ),
                semantic(10, role: "AXGroup", classes: ["middle-panel"]),
                semantic(11, parent: 10, role: "AXTextArea", settable: true)
            ]
        )
        let refreshedImageTree = openedChatTree(
            uid: uid,
            messages: [imageMessage("100", customer: true)],
            nodes: [
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 20), parentID: nil, role: "AXGroup",
                    value: nil, title: nil, domIdentifier: nil,
                    domClasses: ["history-box", "custom-scroll"], actionNames: [],
                    isSettable: false, frame: CGRect(x: 0, y: 0, width: 500, height: 500)
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 21), parentID: AXElementToken(rawValue: 20), role: "AXGroup",
                    value: nil, title: nil, domIdentifier: imageID,
                    domClasses: ["onemsg", "buyer-item"], actionNames: [], isSettable: false
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 22), parentID: AXElementToken(rawValue: 21),
                    role: "AXGroup", value: nil, title: nil, domIdentifier: nil,
                    domClasses: ["image-msg"], actionNames: [], isSettable: false,
                    frame: CGRect(x: 70, y: 80, width: 90, height: 100)
                ),
                semantic(30, role: "AXGroup", classes: ["middle-panel"]),
                semantic(31, parent: 30, role: "AXTextArea", settable: true)
            ]
        )
        let backend = FakePDDAXBackend(trees: [empty, imageTree, refreshedImageTree])
        let resolver = CustomerImageResolverStub(
            url: URL(string: "https://chat-img.pddugc.com/a.jpeg")!
        )
        let imageBytes = Data([0xff, 0xd8, 0xff, 1, 2, 3])
        let downloadedURL = root.appendingPathComponent("a.jpeg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try imageBytes.write(to: downloadedURL)
        let digest = SHA256.hash(data: imageBytes).map { String(format: "%02x", $0) }.joined()
        let attachment = AutoReplyImageAttachment(
            messageID: imageID,
            sourceURL: URL(string: "https://chat-img.pddugc.com/a.jpeg")!,
            localURL: downloadedURL, mimeType: "image/jpeg",
            byteCount: imageBytes.count, sha256: digest
        )
        let driver = PDDAXConversationDriver(
            backend: backend,
            chatStore: PerUserChatStore(rootDirectory: root),
            allowedUIDs: [uid],
            ocrSupplement: FakePDDOCRSupplement(responses: [[], []]),
            imageResolver: resolver,
            imageDownloader: CustomerImageDownloaderStub(attachment: attachment),
            imageRootDirectory: root.appendingPathComponent("images")
        )
        _ = try await driver.capture(uid: uid, after: .empty)
        let lease = UIOperationLeaseRegistry().acquire(uid: uid)

        let capture = try await driver.capture(uid: uid, after: .empty, lease: lease)

        XCTAssertEqual(capture.imageAttachments.count, 1)
        XCTAssertEqual(capture.imageAttachments.first?.sha256, digest)
        XCTAssertEqual(capture.imageAttachments.first?.localURL.lastPathComponent, "\(digest).jpg")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(capture.imageAttachments.first?.localURL)), imageBytes)
        XCTAssertEqual(resolver.candidates.map(\.messageID), [imageID])
        XCTAssertEqual(
            resolver.candidates.first?.frame,
            CGRect(x: 70, y: 80, width: 90, height: 100)
        )
    }

    func testCaptureStartsCustomerVideoInBackgroundAndPreflightDoesNotReopenIt() async throws {
        let uid = "GZC-000001"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-driver-video-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let videoID = "middlePanel_list_200"
        let empty = openedChatTree(uid: uid)
        let videoTree = openedChatTree(
            uid: uid,
            messages: [videoMessage("200", customer: true)],
            nodes: [
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 1), parentID: nil, role: "AXGroup",
                    value: nil, title: nil, domIdentifier: "msgListContainer",
                    domClasses: ["msg-list"], actionNames: [], isSettable: false,
                    frame: CGRect(x: 0, y: 0, width: 500, height: 500)
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 2), parentID: AXElementToken(rawValue: 1), role: "AXGroup",
                    value: nil, title: nil, domIdentifier: videoID,
                    domClasses: ["onemsg", "buyer-item"], actionNames: [], isSettable: false
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 3), parentID: AXElementToken(rawValue: 2), role: "AXGroup",
                    value: nil, title: nil, domIdentifier: nil, domClasses: ["video-msg"],
                    actionNames: [], isSettable: false,
                    frame: CGRect(x: 20, y: 30, width: 120, height: 90)
                ),
                semantic(10, role: "AXGroup", classes: ["middle-panel"]),
                semantic(11, parent: 10, role: "AXTextArea", settable: true)
            ]
        )
        let armer = ConversationVideoArmerStub()
        let opener = ConversationVideoPreviewOpenerStub()
        let driver = PDDAXConversationDriver(
            backend: FakePDDAXBackend(trees: [empty, videoTree, videoTree]),
            chatStore: PerUserChatStore(rootDirectory: root), allowedUIDs: [uid],
            ocrSupplement: FakePDDOCRSupplement(responses: [[], []]),
            videoArmer: armer,
            videoPreviewOpener: opener
        )
        _ = try await driver.capture(uid: uid, after: .empty)
        let capture = try await driver.capture(
            uid: uid, after: .empty, lease: UIOperationLeaseRegistry().acquire(uid: uid)
        )

        XCTAssertEqual(capture.batch?.events.map(\.kind), [.video])
        XCTAssertTrue(capture.videoAttachments.isEmpty)
        XCTAssertEqual(capture.pendingVideoMessageIDs, [videoID])
        XCTAssertEqual(armer.candidates.map(\.messageID), [videoID])
        XCTAssertEqual(opener.opened.map(\.messageID), [videoID])

        let preflight = try await driver.preflight(
            uid: uid, after: .empty, lease: UIOperationLeaseRegistry().acquire(uid: uid)
        )
        XCTAssertEqual(preflight.batch?.events.map(\.kind), [.video])
        XCTAssertTrue(preflight.videoAttachments.isEmpty)
        XCTAssertEqual(capture.pendingVideoMessageIDs, [videoID])
        XCTAssertEqual(armer.candidates.map(\.messageID), [videoID], "preflight must not re-arm video")
        XCTAssertEqual(opener.opened.map(\.messageID), [videoID], "preflight must not reopen video")
    }

    func testCaptureArmsAndOpensEachVideoOnlyOnce() async throws {
        let uid = "GZC-000001"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-driver-video-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let videoID = "middlePanel_list_300"
        let empty = openedChatTree(uid: uid)
        let videoTree = openedChatTree(
            uid: uid,
            messages: [videoMessage("300", customer: true)],
            nodes: [
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 1), parentID: nil, role: "AXGroup",
                    value: nil, title: nil, domIdentifier: "msgListContainer",
                    domClasses: ["msg-list"], actionNames: [], isSettable: false,
                    frame: CGRect(x: 0, y: 0, width: 500, height: 500)
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 2), parentID: AXElementToken(rawValue: 1),
                    role: "AXGroup", value: nil, title: nil, domIdentifier: videoID,
                    domClasses: ["onemsg", "buyer-item"], actionNames: [], isSettable: false
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 3), parentID: AXElementToken(rawValue: 2),
                    role: "AXGroup", value: nil, title: nil, domIdentifier: nil,
                    domClasses: ["video-msg"], actionNames: [], isSettable: false,
                    frame: CGRect(x: 20, y: 30, width: 120, height: 90)
                ),
                semantic(10, role: "AXGroup", classes: ["middle-panel"]),
                semantic(11, parent: 10, role: "AXTextArea", settable: true)
            ]
        )
        let armer = ConversationVideoArmerStub()
        let opener = ConversationVideoPreviewOpenerStub()
        let driver = PDDAXConversationDriver(
            backend: FakePDDAXBackend(trees: [empty, videoTree]),
            chatStore: PerUserChatStore(rootDirectory: root), allowedUIDs: [uid],
            ocrSupplement: FakePDDOCRSupplement(responses: [[], []]),
            videoArmer: armer, videoPreviewOpener: opener
        )
        _ = try await driver.capture(uid: uid, after: .empty)

        let capture = try await driver.capture(
            uid: uid, after: .empty, lease: UIOperationLeaseRegistry().acquire(uid: uid)
        )

        XCTAssertEqual(capture.pendingVideoMessageIDs, [videoID])
        XCTAssertEqual(armer.candidates.map(\.messageID), [videoID])
        XCTAssertEqual(opener.opened.map(\.messageID), [videoID])
    }

    func testTargetedVideoRecoveryDoesNotOpenOtherVideosInCapturedBatch() async throws {
        let uid = "GZC-000001"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-driver-targeted-video-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = "middlePanel_list_300"
        let targetID = "middlePanel_list_301"
        let empty = openedChatTree(uid: uid)
        let videoTree = openedChatTree(
            uid: uid,
            messages: [videoMessage("300", customer: true), videoMessage("301", customer: true)],
            nodes: [
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 1), parentID: nil, role: "AXGroup",
                    value: nil, title: nil, domIdentifier: "msgListContainer",
                    domClasses: ["msg-list"], actionNames: [], isSettable: false,
                    frame: CGRect(x: 0, y: 0, width: 500, height: 500)
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 2), parentID: AXElementToken(rawValue: 1),
                    role: "AXGroup", value: nil, title: nil, domIdentifier: firstID,
                    domClasses: ["onemsg", "buyer-item"], actionNames: [], isSettable: false
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 3), parentID: AXElementToken(rawValue: 2),
                    role: "AXGroup", value: nil, title: nil, domIdentifier: nil,
                    domClasses: ["video-msg"], actionNames: [], isSettable: false,
                    frame: CGRect(x: 20, y: 30, width: 120, height: 90)
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 4), parentID: AXElementToken(rawValue: 1),
                    role: "AXGroup", value: nil, title: nil, domIdentifier: targetID,
                    domClasses: ["onemsg", "buyer-item"], actionNames: [], isSettable: false
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 5), parentID: AXElementToken(rawValue: 4),
                    role: "AXGroup", value: nil, title: nil, domIdentifier: nil,
                    domClasses: ["video-msg"], actionNames: [], isSettable: false,
                    frame: CGRect(x: 20, y: 140, width: 120, height: 90)
                ),
                semantic(10, role: "AXGroup", classes: ["middle-panel"]),
                semantic(11, parent: 10, role: "AXTextArea", settable: true)
            ]
        )
        let armer = ConversationVideoArmerStub()
        let opener = ConversationVideoPreviewOpenerStub()
        let driver = PDDAXConversationDriver(
            backend: FakePDDAXBackend(trees: [empty, videoTree]),
            chatStore: PerUserChatStore(rootDirectory: root), allowedUIDs: [uid],
            ocrSupplement: FakePDDOCRSupplement(responses: [[], []]),
            videoArmer: armer, videoPreviewOpener: opener
        )
        _ = try await driver.capture(uid: uid, after: .empty)

        let capture = try await driver.capture(
            uid: uid, after: .empty, includeImages: false,
            onlyVideoMessageID: targetID,
            lease: UIOperationLeaseRegistry().acquire(uid: uid)
        )

        XCTAssertEqual(capture.pendingVideoMessageIDs, [targetID])
        XCTAssertEqual(armer.candidates.map(\.messageID), [targetID])
        XCTAssertEqual(opener.opened.map(\.messageID), [targetID])
    }

    func testVideoDownloadWaitSuspendsWithoutBlockingMainActor() async throws {
        let uid = "GZC-000001"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-driver-video-timeout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let videoID = "middlePanel_list_400"
        let empty = openedChatTree(uid: uid)
        let videoTree = openedChatTree(
            uid: uid,
            messages: [videoMessage("400", customer: true)],
            nodes: [
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 1), parentID: nil, role: "AXGroup",
                    value: nil, title: nil, domIdentifier: "msgListContainer",
                    domClasses: ["msg-list"], actionNames: [], isSettable: false,
                    frame: CGRect(x: 0, y: 0, width: 500, height: 500)
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 2), parentID: AXElementToken(rawValue: 1),
                    role: "AXGroup", value: nil, title: nil, domIdentifier: videoID,
                    domClasses: ["onemsg", "buyer-item"], actionNames: [], isSettable: false
                ),
                PDDAXSemanticNode(
                    id: AXElementToken(rawValue: 3), parentID: AXElementToken(rawValue: 2),
                    role: "AXGroup", value: nil, title: nil, domIdentifier: nil,
                    domClasses: ["video-msg"], actionNames: [], isSettable: false,
                    frame: CGRect(x: 20, y: 30, width: 120, height: 90)
                ),
                semantic(10, role: "AXGroup", classes: ["middle-panel"]),
                semantic(11, parent: 10, role: "AXTextArea", settable: true)
            ]
        )
        let armer = ConversationVideoArmerStub(operation: {
            try? await Task.sleep(for: .milliseconds(100))
        })
        let opener = ConversationVideoPreviewOpenerStub()
        let driver = PDDAXConversationDriver(
            backend: FakePDDAXBackend(trees: [empty, videoTree]),
            chatStore: PerUserChatStore(rootDirectory: root), allowedUIDs: [uid],
            ocrSupplement: FakePDDOCRSupplement(responses: [[], []]),
            videoArmer: armer,
            videoPreviewOpener: opener
        )
        _ = try await driver.capture(uid: uid, after: .empty)

        let captureTask = Task { @MainActor in
            try await driver.capture(
                uid: uid, after: .empty,
                lease: UIOperationLeaseRegistry().acquire(uid: uid)
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        let responsivenessStart = ContinuousClock.now
        await Task.yield()
        let mainActorResponseTime = responsivenessStart.duration(to: .now)
        let capture = try await withOperationDeadline(.milliseconds(500), stage: "test") {
            try await captureTask.value
        }

        XCTAssertLessThan(mainActorResponseTime, .milliseconds(50))
        XCTAssertEqual(capture.batch?.events.map(\.kind), [.video])
        XCTAssertTrue(capture.videoAttachments.isEmpty)
        XCTAssertEqual(capture.pendingVideoMessageIDs, [videoID])
        XCTAssertFalse(capture.ocrDiagnostic?.contains("操作超时：video") == true)
    }

    private func makeDriver(
        backend: FakePDDAXBackend,
        allowedUIDs: Set<String>? = ["GZC-000001"],
        ocr: (any PDDOCRSupplementing)? = nil,
        unread: (any PDDUnreadEvidenceDetecting)? = nil
    ) -> PDDAXConversationDriver {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-driver-tests-\(UUID().uuidString)")
        return PDDAXConversationDriver(
            backend: backend,
            chatStore: PerUserChatStore(rootDirectory: root),
            allowedUIDs: allowedUIDs,
            ocrSupplement: ocr,
            unreadEvidence: unread ?? FakePDDUnreadEvidence()
        )
    }

    private var conversationListTree: PDDAXSemanticTree {
        let root = AXNodeSnapshot(role: "AXWindow")
        return PDDAXSemanticTree(rootSnapshot: root, nodes: [
            semantic(1, role: "AXList", classes: ["conversation-list"]),
            semantic(2, parent: 1, role: "AXRow", value: "测试用户"),
            semantic(3, parent: 2, role: "AXStaticText", value: "1", classes: ["unread"])
        ])
    }

    private func openedChatTree(
        uid: String,
        messages: [AXNodeSnapshot] = [],
        nodes: [PDDAXSemanticNode<AXElementToken>]? = nil
    ) -> PDDAXSemanticTree {
        let root = AXNodeSnapshot(
            role: "AXWindow",
            attributes: [("AXValue", uid)],
            children: messages
        )
        return PDDAXSemanticTree(
            rootSnapshot: root,
            nodes: nodes ?? [
                semantic(10, role: "AXGroup", value: uid, classes: ["middle-panel"]),
                semantic(11, parent: 10, role: "AXTextArea", settable: true)
            ]
        )
    }

    private func customer(_ id: String) -> AXNodeSnapshot { chatMessage(id: id, customer: true) }
    private func service(_ id: String) -> AXNodeSnapshot { chatMessage(id: id, customer: false) }

    private func imageMessage(_ id: String, customer: Bool) -> AXNodeSnapshot {
        return AXNodeSnapshot(
            role: "AXGroup",
            attributes: [("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "middlePanel_list_\(id)")],
            children: [
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXDOMClassList", customer ? "[buyer-item]" : "[cs-item]")],
                    children: [
                        AXNodeSnapshot(
                            role: "AXGroup",
                            attributes: [("AXDOMClassList", "[msg-content-box,image-msg]")]
                        )
                    ]
                )
            ]
        )
    }

    private func videoMessage(_ id: String, customer: Bool) -> AXNodeSnapshot {
        AXNodeSnapshot(
            role: "AXGroup",
            attributes: [("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "middlePanel_list_\(id)")],
            children: [AXNodeSnapshot(
                role: "AXGroup",
                attributes: [("AXDOMClassList", customer ? "[buyer-item]" : "[cs-item]")],
                children: [AXNodeSnapshot(
                    role: "AXGroup", attributes: [("AXDOMClassList", "[msg-content-box,video-msg]")]
                )]
            )]
        )
    }

    private func emptyMessage(_ id: String, customer: Bool) -> AXNodeSnapshot {
        AXNodeSnapshot(
            role: "AXGroup",
            attributes: [("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "middlePanel_list_\(id)")],
            children: [
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXDOMClassList", customer ? "[buyer-item]" : "[cs-item]")]
                )
            ]
        )
    }

    private func imageMessageWithoutID(
        customer: Bool,
        chromeNodeID: String? = nil
    ) -> AXNodeSnapshot {
        return AXNodeSnapshot(
            role: "AXGroup",
            attributes: [("AXDOMClassList", "[onemsg]")],
            children: [
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXDOMClassList", customer ? "[buyer-item]" : "[cs-item]")],
                    children: [
                        AXNodeSnapshot(
                            role: "AXGroup",
                            attributes: [
                                ("AXDOMClassList", "[msg-content-box,image-msg]")
                            ] + (chromeNodeID.map { [("ChromeAXNodeId", $0)] } ?? [])
                        )
                    ]
                )
            ]
        )
    }

    private func ocr(
        _ id: String,
        _ sender: ChatSender,
        _ text: String,
        timestamp: String? = nil
    ) -> PDDOCRMessage {
        PDDOCRMessage(id: id, sender: sender, text: text, timestamp: timestamp, box: .zero)
    }

    private func chatMessage(id: String, customer: Bool) -> AXNodeSnapshot {
        AXNodeSnapshot(
            role: "AXGroup",
            attributes: [("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "middlePanel_list_\(id)")],
            children: [
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXDOMClassList", customer ? "[buyer-item]" : "[cs-item]")],
                    children: [
                        AXNodeSnapshot(
                            role: "AXGroup",
                            attributes: [("AXDOMClassList", "[msg-content-box]"), ("AXValue", id)]
                        )
                    ]
                )
            ]
        )
    }

    private func semantic(
        _ id: Int,
        parent: Int? = nil,
        role: String,
        value: String? = nil,
        identifier: String? = nil,
        classes: Set<String> = [],
        actions: Set<String> = [],
        settable: Bool = false
    ) -> PDDAXSemanticNode<AXElementToken> {
        .init(
            id: .init(rawValue: id), parentID: parent.map { .init(rawValue: $0) }, role: role,
            value: value, title: nil, domIdentifier: identifier, domClasses: classes,
            actionNames: actions, isSettable: settable
        )
    }

    private func usableChatTree() -> PDDAXSemanticTree {
        PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: [
            semantic(100, role: "AXGroup", classes: ["middle-panel"]),
            semantic(101, parent: 100, role: "AXTextArea", settable: true)
        ])
    }
}

@MainActor
private final class CustomerImageResolverStub: PDDCustomerImageResolving {
    let url: URL
    var candidates: [PDDCustomerImageCandidate] = []
    init(url: URL) { self.url = url }
    func resolve(candidate: PDDCustomerImageCandidate, lease: UIOperationLease) async throws -> URL {
        candidates.append(candidate)
        return url
    }
}

private struct CustomerImageDownloaderStub: PDDCustomerImageDownloading {
    let attachment: AutoReplyImageAttachment
    func download(
        sourceURL: URL, destinationDirectory: URL, messageID: String
    ) async throws -> AutoReplyImageAttachment { attachment }
}

@MainActor
private final class ConversationVideoArmerStub: PDDVideoTransferArming {
    var candidates: [PDDCustomerVideoCandidate] = []
    let operation: @Sendable () async -> Void

    init(operation: @escaping @Sendable () async -> Void = {}) {
        self.operation = operation
    }

    func arm(
        uid: String, messageID: String, candidate: PDDCustomerVideoCandidate
    ) async throws -> ArmedPDDVideoTransfer? {
        candidates.append(candidate)
        return ArmedPDDVideoTransfer(operation: operation)
    }
}

@MainActor
private final class ConversationVideoPreviewOpenerStub: PDDVideoPreviewOpening {
    var opened: [PDDCustomerVideoCandidate] = []
    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws {
        opened.append(candidate)
    }
    func close() async {}
}

@MainActor
private final class CustomerVideoResolverStub: PDDCustomerVideoResolving {
    let url: URL
    var candidates: [PDDCustomerVideoCandidate] = []
    init(url: URL) { self.url = url }
    func resolve(candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws -> URL {
        candidates.append(candidate)
        return url
    }
}

@MainActor
private final class HangingCustomerVideoResolverStub: PDDCustomerVideoResolving {
    static let shared = HangingCustomerVideoResolverStub()
    private(set) var callCount = 0

    func reset() { callCount = 0 }

    func resolve(candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws -> URL {
        callCount += 1
        try await Task.sleep(for: .seconds(60))
        throw PDDCustomerVideoError.downloadFailed
    }
}

@MainActor
private final class CancellingCustomerVideoResolverStub: PDDCustomerVideoResolving {
    func resolve(candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws -> URL {
        throw CancellationError()
    }
}

private struct CustomerVideoDownloaderStub: PDDCustomerVideoDownloading {
    let attachment: AutoReplyVideoAttachment
    func download(
        sourceURL: URL, destinationDirectory: URL, messageID: String
    ) async throws -> AutoReplyVideoAttachment { attachment }
}

private actor CustomerVideoDownloaderSequenceStub: PDDCustomerVideoDownloading {
    var results: [Result<AutoReplyVideoAttachment, Error>]
    private var attempts = 0

    init(results: [Result<AutoReplyVideoAttachment, Error>]) { self.results = results }

    func download(
        sourceURL: URL, destinationDirectory: URL, messageID: String
    ) async throws -> AutoReplyVideoAttachment {
        attempts += 1
        guard !results.isEmpty else { throw PDDCustomerVideoError.downloadFailed }
        return try results.removeFirst().get()
    }

    func attemptCount() -> Int { attempts }
}

@MainActor
private final class FakePDDUnreadEvidence: PDDUnreadEvidenceDetecting {
    let rows: [PDDConversationRow<AXElementToken>]?

    init(rows: [PDDConversationRow<AXElementToken>]? = nil) { self.rows = rows }

    func unreadRows(in tree: PDDAXSemanticTree) async throws -> [PDDConversationRow<AXElementToken>] {
        if let rows { return rows }
        let candidates = try PDDAXControlSelection.conversationCandidates(in: tree.nodes)
        let candidateIDs = Set(candidates.map(\.rowID))
        return try PDDAXControlSelection.conversationRows(in: tree.nodes).filter {
            candidateIDs.contains($0.rowID)
        }
    }
}

@MainActor
private final class FakePDDOCRSupplement: PDDOCRSupplementing {
    var responses: [[PDDOCRMessage]]
    let error: Error?
    var requestedUIDs: [String] = []

    init(responses: [[PDDOCRMessage]] = [], error: Error? = nil) {
        self.responses = responses
        self.error = error
    }

    func messages(uid: String) async throws -> [PDDOCRMessage] {
        requestedUIDs.append(uid)
        if let error { throw error }
        return responses.isEmpty ? [] : responses.removeFirst()
    }
}

@MainActor
private final class FakePDDAXBackend: PDDAXBackend {
    var trees: [PDDAXSemanticTree]
    private(set) var pressedIDs: [AXElementToken] = []
    private(set) var readCount = 0

    init(trees: [PDDAXSemanticTree]) { self.trees = trees }

    func readSemanticTree() throws -> PDDAXSemanticTree {
        readCount += 1
        guard !trees.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return trees.removeFirst()
    }

    func performPress(_ id: AXElementToken) throws { pressedIDs.append(id) }
    func setValue(_ text: String, on id: AXElementToken) throws {}
    func value(of id: AXElementToken) throws -> String { "" }
}
