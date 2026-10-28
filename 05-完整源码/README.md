# Customer service automation / 客服自动化

The active reply path sends the customer message batch, conversation history, image attachments, video frames and transcripts to Codex. Codex directly reads the local knowledge folder and generates one reply.

当前回复流程把客户批次、聊天历史、图片、视频帧和转写交给 Codex，由 Codex 直接只读阅读本地知识目录并生成一次回复。

Selected database: `/Users/m1air/vscode/Pindoudou_automation/格志京东客服知识库-2026-10-04`.
Set `PDD_KNOWLEDGE_FOLDER` before launching to select a replacement folder. The folder must include `jd_customer_service_rules.md` and `handover/capabilities.json`.

There is no keyword retrieval, embedding, semantic model startup, query planner, or second knowledge inspection in the active reply path. Legacy retrieval code remains unused. Codex may list filenames and read relevant documents directly. Web search is disabled and local tools run in a read-only sandbox. Missing knowledge produces an uncertainty reply, not another retrieval attempt. Transport/session failure recovery remains available.

Codex reads the JD global rules and capabilities first, then relevant technical documents and confirmed revisions. Customer media describes the customer's situation; database documents supply product and policy facts. Reply language follows the customer. The current database is the JD version by user choice; the capture and delivery adapter remains the existing Pinduoduo adapter.

Knowledge file changes invalidate saved automatic-reply sessions. Image/video capture and processing, delivery, and transfer behavior are preserved. Optional SenseVoice uses its independent Python runtime; knowledge answering does not require Python or an embedding model.

Run `swift test` from `05-完整源码` and rebuild with `zsh scripts/build_app.sh --task-isolation-candidate`. Rebuilding is required for source changes to affect an installed application. This change does not launch automatic replies.

Transfer policy: Codex classifies the current customer batch semantically; there is no keyword intent detector. Human-agent requests use a separate per-customer 10-minute counter: first request asks what assistance is needed, second transfers. Refund/return requests first clarify the issue, then transfer on a repeat within 10 minutes or a confirmed issue without a database solution. Technical issues without a database solution transfer; unclear issues first ask for the missing detail. Counters persist and retries of the same batch do not count twice. Successful handoff clears that customer’s counters, closes observed customer messages, cancels pending replies/media work, and invalidates their Codex session so a returned conversation cannot revive the previous handoff. New customers have independent counters. Identity replies consistently describe the Grozziie store customer service role, without technical implementation labels or claims of being human.
