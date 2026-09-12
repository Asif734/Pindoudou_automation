# 拼多多 AX 读取器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个可双击运行的 macOS 应用，一键递归读取拼多多商家版的完整 AX 树并支持复制和保存。

**Architecture:** 使用 Swift Package 管理可测试的核心逻辑，以 `AXTreeReader` 封装 macOS ApplicationServices API，以 SwiftUI 提供单窗口界面。构建脚本把 release 可执行文件和 Info.plist 组装为独立 `.app`。

**Tech Stack:** Swift 5.9、SwiftUI、AppKit、ApplicationServices、XCTest、macOS 13+

**Spec:** `docs/superpowers/specs/2026-08-27-pdd-ax-reader-design.md`

## Global Constraints

- 仅使用 macOS Accessibility（AX）API；不使用 OCR 或截图识别。
- 目标应用 Bundle ID 固定为 `com.pinduoduo.merchantMac`。
- 读取过程不得点击、输入或修改拼多多页面，也不得联网。
- 输出必须可在应用内查看、复制并保存为 UTF-8 文本。
- 递归读取必须有深度、节点数量和循环保护。

---

### Task 1: 可测试的 AX 快照格式

**Files:**
- Create: `Package.swift`
- Create: `Sources/PDDAXReader/AXNodeSnapshot.swift`
- Create: `Sources/PDDAXReader/AXDumpFormatter.swift`
- Create: `Tests/PDDAXReaderTests/AXDumpFormatterTests.swift`

**Interfaces:**
- Produces: `AXNodeSnapshot`, `AXDumpFormatter.format(root:) -> String`

- [ ] **Step 1: 写失败测试**

测试构造一个窗口、一个聊天容器和一条文本消息，断言缩进、属性、动作及子节点顺序；另测深层中文文本保持原样。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test`
Expected: FAIL，因为核心类型尚不存在。

- [ ] **Step 3: 实现最小格式化模型**

`AXNodeSnapshot` 保存 `role: String`、`attributes: [(String, String)]`、`actions: [String]`、`children: [AXNodeSnapshot]`。格式器按深度输出 `role`，随后逐行输出属性和动作，再递归输出子节点。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test`
Expected: PASS。

### Task 2: 真实 AX 递归读取器

**Files:**
- Create: `Sources/PDDAXReader/AXTreeReader.swift`
- Create: `Tests/PDDAXReaderTests/AXTreeReaderPolicyTests.swift`

**Interfaces:**
- Consumes: `AXNodeSnapshot`
- Produces: `AXTreeReader(targetBundleIdentifier:maxDepth:maxNodes:)`、`read() throws -> AXReadResult`

- [ ] **Step 1: 写失败测试**

测试独立的 `AXTraversalPolicy`：超过最大深度返回停止标记、达到节点上限返回停止标记、重复节点标识返回循环标记。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter AXTreeReaderPolicyTests`
Expected: FAIL，因为策略类型尚不存在。

- [ ] **Step 3: 实现读取器**

读取器通过 `NSRunningApplication.runningApplications(withBundleIdentifier:)` 定位 PID，以 `AXUIElementCreateApplication` 建立根节点；为每个节点枚举 `AXUIElementCopyAttributeNames` 和 `AXUIElementCopyActionNames`，将非子节点属性转换为稳定文本，并通过 `kAXChildrenAttribute` 递归。默认最大深度 80、最大节点数 20,000，使用 AX 元素哈希集合做循环保护。

- [ ] **Step 4: 运行全部测试**

Run: `swift test`
Expected: PASS。

### Task 3: 一键读取界面与本地导出

**Files:**
- Create: `Sources/PDDAXReader/PDDAXReaderApp.swift`
- Create: `Sources/PDDAXReader/ContentView.swift`

**Interfaces:**
- Consumes: `AXTreeReader.read()`、`AXDumpFormatter.format(root:)`
- Produces: macOS 主窗口、“读取拼多多 AX”“复制全部”“保存…”三个操作。

- [ ] **Step 1: 实现权限与状态模型**

使用 `AXIsProcessTrustedWithOptions` 触发辅助功能授权提示；未授权、目标未运行、读取中、成功和失败均显示明确中文状态。

- [ ] **Step 2: 实现后台扫描**

点击读取后在后台队列创建读取器并生成文本，主线程只更新状态和只读文本区；读取期间禁用重复扫描。

- [ ] **Step 3: 实现复制与保存**

复制写入 `NSPasteboard.general`；保存通过 `NSSavePanel`，默认文件名包含本地时间，并以 UTF-8 原子写入。

- [ ] **Step 4: 构建验证**

Run: `swift build -c release`
Expected: Build complete。

### Task 4: `.app` 打包与真实页面验收

**Files:**
- Create: `scripts/build_app.sh`
- Create: `Resources/Info.plist`
- Create: `README.md`
- Create: `outputs/拼多多AX读取器.app`

**Interfaces:**
- Consumes: release 可执行文件
- Produces: 可双击运行的 `outputs/拼多多AX读取器.app`

- [ ] **Step 1: 创建确定性打包脚本**

脚本运行 release 构建，清理并重建明确的 `outputs/拼多多AX读取器.app/Contents/{MacOS,Resources}`，复制可执行文件和 Info.plist，并使用本机 ad-hoc 签名。

- [ ] **Step 2: 验证包结构和签名**

Run: `plutil -lint Resources/Info.plist && codesign --verify --deep --strict outputs/拼多多AX读取器.app`
Expected: plist 为 OK，签名验证退出码 0。

- [ ] **Step 3: 运行自动化测试**

Run: `swift test && scripts/build_app.sh`
Expected: 所有测试通过并生成 `.app`。

- [ ] **Step 4: 真实读取验收**

启动 `.app` 并授予辅助功能权限后，点击“读取拼多多 AX”；确认输出包含 `AXTextArea`、`1`、`未读` 以及当前聊天区的其他消息。若权限需用户在系统设置中手动勾选，程序保持可重试状态并给出明确提示。
