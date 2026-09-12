import CryptoKit
import Foundation

@MainActor
final class PDDAXReplySender {
    private let backend: any PDDAXBackend
    private let opener: any PDDConversationOpening
    private let confirmationTimeout: TimeInterval
    private let writeVerificationTimeout: TimeInterval
    private let pollIntervalNanoseconds: UInt64

    init(
        backend: any PDDAXBackend,
        opener: any PDDConversationOpening,
        confirmationTimeout: TimeInterval = 3.0,
        writeVerificationTimeout: TimeInterval = 1.0,
        pollIntervalNanoseconds: UInt64 = 85_000_000
    ) {
        self.backend = backend
        self.opener = opener
        self.confirmationTimeout = confirmationTimeout
        self.writeVerificationTimeout = writeVerificationTimeout
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor
    ) async throws -> AutoReplyDeliveryResult {
        try await send(
            uid: uid,
            text: text,
            expectedCustomerCursor: expectedCustomerCursor,
            expectedCustomerMessageIDs: []
        )
    }

    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        expectedCustomerMessageIDs: Set<String>
    ) async throws -> AutoReplyDeliveryResult {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return .failedBeforeSend("回复为空") }

        let initialTree: PDDAXSemanticTree
        do {
            initialTree = try await opener.openAndResolve(
                uid: uid,
                expectedCustomerMessageIDs: expectedCustomerMessageIDs
            )
        } catch let error as PDDAXConversationDriverError {
            if case .nicknameCandidatesExhausted = error {
                return .discardedBeforeSend(error.localizedDescription)
            }
            return .failedBeforeSend(error.localizedDescription)
        } catch {
            return .failedBeforeSend(error.localizedDescription)
        }
        guard matches(uid: uid, tree: initialTree) else {
            return .failedBeforeSend("写入前 UID 不匹配")
        }

        let initialComposer: AXElementToken
        do { initialComposer = try PDDAXControlSelection.composer(in: initialTree.nodes) }
        catch { return .failedBeforeSend(error.localizedDescription) }
        let existingDraft: String
        do { existingDraft = try backend.value(of: initialComposer) }
        catch { return .failedBeforeSend(error.localizedDescription) }
        if existingDraft != reply {
            do {
                try backend.setValue(reply, on: initialComposer)
                guard await waitForComposerValue(reply, on: initialComposer) else {
                    return .failedBeforeSend("输入区 AX 回读与回复不一致")
                }
            } catch {
                return .failedBeforeSend(error.localizedDescription)
            }
        }

        let afterWrite: PDDAXSemanticTree
        do { afterWrite = try backend.readSemanticTree() }
        catch { return .failedBeforeSend(error.localizedDescription) }
        guard matches(uid: uid, tree: afterWrite) else {
            return .failedBeforeSend("写入后 UID 变化")
        }
        do {
            let freshComposer = try PDDAXControlSelection.composer(in: afterWrite.nodes)
            guard await waitForComposerValue(reply, on: freshComposer) else {
                return .failedBeforeSend("写入后输入区回读不一致")
            }
        } catch {
            return .failedBeforeSend(error.localizedDescription)
        }

        let beforePress: PDDAXSemanticTree
        do { beforePress = try backend.readSemanticTree() }
        catch { return .failedBeforeSend(error.localizedDescription) }
        guard matches(uid: uid, tree: beforePress) else {
            return .failedBeforeSend("发送前 UID 变化")
        }
        let sendControl: AXElementToken
        do { sendControl = try PDDAXControlSelection.sendControl(in: beforePress.nodes) }
        catch { return .failedBeforeSend(error.localizedDescription) }

        do { try backend.performPress(sendControl) }
        catch { return .uncertain("已执行发送动作，但按钮状态无法确认：\(error.localizedDescription)") }

        let started = Date()
        repeat {
            do {
                let confirmation = try backend.readSemanticTree()
                if matches(uid: uid, tree: confirmation),
                   let composer = try? PDDAXControlSelection.composer(in: confirmation.nodes),
                   (try? backend.value(of: composer))?.isEmpty == true {
                    return .sent(serviceMessageID: stableSendID(
                        uid: uid,
                        reply: reply,
                        cursor: expectedCustomerCursor
                    ))
                }
            } catch {
                // The send click already happened. Continue bounded read-only observation.
            }
            if Date().timeIntervalSince(started) >= confirmationTimeout { break }
            if pollIntervalNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } else {
                await Task.yield()
            }
        } while true
        return .uncertain("发送后输入框未清空，发送结果待后续 OCR 核对")
    }

    private func waitForComposerValue(_ expected: String, on composer: AXElementToken) async -> Bool {
        let started = Date()
        repeat {
            if (try? backend.value(of: composer)) == expected { return true }
            if Date().timeIntervalSince(started) >= writeVerificationTimeout { return false }
            if pollIntervalNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } else {
                await Task.yield()
            }
        } while true
    }

    private func matches(uid: String, tree: PDDAXSemanticTree) -> Bool {
        if uid.hasPrefix("PDD-") {
            if let locator = PDDConversationSnapshotLocator.current(in: tree.rootSnapshot) {
                return PDDConversationKey.make(locator: locator) == uid
            }
            // Some PDD builds temporarily omit the active marker after a media
            // preview closes.  A usable composer/send surface is sufficient to
            // continue instead of parking an otherwise ready reply forever.
            return (try? PDDAXControlSelection.composer(in: tree.nodes)) != nil
                && (try? PDDAXControlSelection.sendControl(in: tree.nodes)) != nil
        }
        return PDDCustomerIdentity.resolve(from: tree.rootSnapshot) == uid
    }

    private func stableSendID(uid: String, reply: String, cursor: AutoReplyCursor) -> String {
        let material = [uid, cursor.digest, PDDOCRNormalizer.normalize(reply)]
            .joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "ax-send-\(digest)"
    }
}
