# PDD 全自动客服跨机器兼容层设计

日期：2026-09-03

## 目标

让现有 PDD 全自动客服在 Apple Silicon、macOS 14 及以上的同事电脑上运行，不再依赖开发机的 Python 安装路径或单一 AX 暴露方式，并在权限、Codex、OCR、图片和视频能力不可用时给出明确诊断。

本次改造不改变现有业务流程：红点发现、会话入队、同 UID 串行、不同 UID 并行、回复生成、`reply`/`reply_then_transfer` 输出约束和发送规则保持不变。

## 已确认范围

- 仅支持 Apple Silicon，不支持 Intel。
- 最低系统保持 macOS 14。
- 首次安装允许用户右键“打开”或在系统设置中选择“仍要打开”，本阶段不要求 Developer ID 公证。
- 不向拼多多进程注入代码，不读取或修改拼多多网络协议。
- 不使用运行时在线安装 Python 或第三方库。
- 构建时产生候选 App 前先保留旧 App 备份。

## 方案概览

兼容改造分成六个独立边界：运行时资源、权限和启动自检、AX 语义树、截图/OCR 与红点、媒体处理、Codex 探测。每个边界返回结构化能力结果，UI 展示准确原因；单项辅助能力失败时只降级对应功能，不让整个自动客服无原因停止。

## 1. 内置 Python 运行时

### 当前问题

`KnowledgeResourceLocator` 固定返回 `/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12`。同事电脑没有这一安装时，资源检查仍可能通过，但知识库 worker 启动失败。

### 设计

- App 在 `Contents/Resources/PythonRuntime` 内携带 arm64 CPython 3.12 运行时。
- 使用 Astral `python-build-standalone` 的 `cpython-3.12.14+20260825-aarch64-apple-darwin-install_only_stripped.tar.gz`，固定 SHA-256 为 `8b0f1fa71eab7ca644e482c631807a1116fa848491051cd1c8d9429491de63a6`。归档在准备依赖步骤显式下载并校验，随后作为项目本地构建输入；常规构建和 App 运行阶段不联网安装依赖。
- App 的第三方声明中保留该运行时及其 MPL-2.0 许可证信息。
- `KnowledgeResourceLocator` 按以下顺序选择解释器：
  1. `PDD_PYTHON_PATH`，仅用于开发和诊断；
  2. App 内置运行时；
  3. Python.org 3.12 固定路径；
  4. `/opt/homebrew/bin/python3.12`；
  5. PATH 中的 `python3.12`。
- 候选解释器必须存在、可执行、为 arm64 或 universal，并通过一个无副作用的 Python 3.12 版本探测。
- 内置 `site-packages` 继续由 `PYTHONPATH` 指向 App 资源目录，知识库缓存继续写入用户 Application Support。
- 启动自检在调度器启动前验证 worker 能返回 `ready`，失败时 UI 显示所选解释器和失败原因。

## 2. 权限与启动自检

### 语音识别

- 所有候选 App plist 增加 `NSSpeechRecognitionUsageDescription`。
- 视频下载和抽帧不依赖语音权限。
- 只有准备转写音轨时才请求语音权限。
- 用户拒绝或系统不支持时，视频仍以关键帧进入 Codex，UI 标记“音轨转写已跳过”，不得停止自动客服。

### 统一能力检查

新增只读的兼容性报告，包含：

- CPU 架构和 macOS 版本；
- 辅助功能、录屏和语音权限；
- PDD 是否安装、版本、目标窗口和 CEF 缓存根；
- Python 解释器、知识库资源、worker 预热；
- Codex 可执行文件、版本、登录凭据是否存在；
- AX 会话列表、聊天面板、输入框和发送按钮是否能定位。

报告状态分为 `pass`、`degraded`、`fail`。只有自动回复必需能力失败时禁止启动；语音、图片或视频等辅助能力失败时进入 `degraded`，文字客服继续运行。

## 3. AX 语义树适配

### 当前问题

真实 `LivePDDAXBackend` 只读取 `AXValue`、DOM class/identifier、位置、尺寸和 children，未填充 `AXTitle`、`AXDescription`、`AXURL`。上层选择器虽然支持这些字段，但在真实路径中永远取不到。

### 设计

- 真实树统一读取 `AXValue`、`AXTitle`、`AXDescription`、`AXURL`、`AXDOMClassList`、`AXDOMIdentifier`。
- 单个属性返回 AX 错误时只忽略该属性，不丢弃整个节点。
- `title` 字段由真实 `AXTitle` 填充；同一属性同时保留在 snapshot attributes，保证解析器和选择器行为一致。
- 窗口仍通过拼多多 bundle identifier 锁定；中文窗口标题只作排序提示，不作为唯一准入条件。
- 会话、消息、输入框和发送器维持现有 DOM identifier 优先策略，同时允许 `AXValue`、`AXTitle`、`AXDescription` 等价提供可见文本。
- 未取得 DOM identifier 时继续按照用户已接受的规则退回昵称；兼容报告明确显示该会话处于“昵称身份，存在同名风险”。

## 4. 截图、OCR 与红点

### 截图区域

- 优先使用 AX 中聊天面板的实际 frame 作为 OCR 裁剪区域。
- AX 面板 frame 缺失或越界时，才使用当前全窗口比例作为兜底。
- 每次截图记录窗口 frame、面板 frame、像素尺寸和缩放比例，便于跨电脑诊断。

### 客服/客户方向判断

- 在面板坐标系内按消息气泡中心和左右边距判断方向，不再直接依赖整个窗口的固定百分比。
- 如果 AX 已给出 `buyer-item` 或 `cs-item`，以 AX 方向为准；OCR 只补文字。
- 无 AX 方向且布局无法可靠判断时，不伪造身份；保留原始 OCR 结果并在该轮重新扫描。

### 红点

- 仍只在 AX 会话行 frame 内找红点，保持“有红点才入队”。
- 接受 Retina 1x/2x 和非整数缩放，分别计算 X/Y 映射，不因轻微比例差直接返回空。
- 红色判断保留饱和度和连通域要求，同时允许小范围亮度变化。
- 无法建立窗口到截图的有效映射时返回结构化诊断，不把全部会话误判为未读。

## 5. 图片与视频

### 图片

- 使用 ImageIO 判断实际格式和尺寸，不再只检查 JPEG/PNG 文件头。
- JPEG、PNG 可直接保存；WebP、GIF、HEIC 等格式解码首个有效图像后转成 JPEG，交给现有 Codex 图片通道。
- 原始临时 URL 不写入日志和 manifest。
- 图片预览等待改为短轮询，总等待时间可配置；等待发生在对应 UID 的任务中，不阻塞其他 UID。

### 视频

- 保留既有链路：视频特征 → 自动打开 → CEF 缓存取得临时地址 → 发起后台下载 → 关闭预览 → 下载完成后抽帧/音轨 → 加入原 UID 队列。
- CEF 根仍限制在拼多多容器内部，但自动枚举包含 `Cache/Cache_Data` 的 profile，不再只接受数字和 `cef_default` 名称。
- 候选 URL 可由 MP4 扩展名或 `video/mp4` MIME 证明；域名仍限制为拼多多受信 CDN 后缀。
- 缓存 metadata 写入一半时继续以 200ms 间隔重读，直到得到完整候选或任务被取消。
- 下载保留后台持久状态，不设置会主动切断慢速有效传输的短硬超时；停滞、失败和稍后恢复必须产生 UI 状态。
- HLS/m3u8 不在本阶段支持范围；兼容报告将其标为不支持的视频传输类型，而不是误报普通图片。

## 6. Codex 探测和失败边界

- 搜索 `/Applications`、`~/Applications` 下的 Codex/ChatGPT App 内置 CLI，以及 Homebrew、`/usr/local/bin`、PATH 和 `PDD_CODEX_PATH`。
- 启动前运行轻量版本探测，确认当前 CLI 接受现有调用参数。
- 检查隔离 Codex home 是否已经获得可用认证来源；缺少认证时 UI 明确提示用户先登录。
- 默认继续使用 `gpt-5.6-sol`、`medium`，不自动换模型生成不同质量的回复。
- 若 CLI 不支持该模型或参数，任务进入可见失败状态并释放 UID 调度位；不得无限停留在“正在生成”。
- 保留每个 UID 独立 session，以及仅允许 `reply`、`reply_then_transfer` 的输出协议。

## 7. 构建与分发

- 删除构建脚本内写死的个人证书名称。
- 签名选择顺序：显式 `PDD_AX_SIGNING_IDENTITY` → 可用 Developer ID Application → 可用 Apple Development → ad-hoc。
- 构建结束后验证主二进制与所有内置原生依赖均包含 arm64，并执行 `codesign --verify --deep --strict`。
- 生成 ZIP 时保留扩展属性和签名；同事首次启动按已批准流程右键“打开”。
- UI 显示构建版本、签名类型和兼容性报告导出按钮，报告不包含登录 token、视频签名 URL 或聊天内容。

## 8. 错误处理原则

- 单个用户、单张图片、单条视频或一次 Codex 调用失败，不得停止全局自动客服。
- 状态文件无法读取或被外部替换时继续使用现有保护规则，避免写坏队列。
- 环境不兼容必须在启动前明确说明具体缺项，不能只显示“自动客服已停止”。
- 降级必须局部化：语音失败不影响视频画面，视频失败不影响文字，OCR失败不影响有效 AX，某 UID 失败不影响其他 UID。

## 9. 测试与验收

所有行为变化遵循测试先行。

### 自动测试

- Python 候选顺序、缺失、版本错误和内置路径测试；
- plist 权限键和语音拒绝降级测试；
- 真实语义构造中仅有 AXTitle/AXDescription/AXURL 的定位测试；
- 不同窗口尺寸、1x/2x/非整数缩放下的 OCR crop 和红点映射测试；
- WebP/GIF/HEIC 解码转 JPEG 测试；
- 非标准 CEF profile、分段 metadata 和下载恢复测试；
- Codex 多路径、旧 CLI、未登录和不支持模型测试；
- 全量调度、判重、视频队列和发送测试不得回归。

### 本机真实验收

- 新候选 App 能通过签名验证并启动；
- 兼容性报告准确显示本机状态；
- AX 能同时输出 value/title/description/url；
- PDD 无红点时不建立回复任务；
- 普通文字、图片和视频各完成一次端到端流程；
- 权限拒绝场景只降级对应能力；
- App 重新启动后队列和后台媒体状态可以恢复。

### 同事电脑验收

同一 ZIP 在每台电脑执行兼容性检查并导出脱敏报告。至少验证：启动、权限、Python worker、Codex、PDD 版本、AX 四个关键控件、红点、文字回复，以及一条图片和一条视频。只有这些项目完成后，才能称为同事通用版。

## 非目标

- Intel Mac；
- macOS 13 或更早系统；
- 自动绕过 Gatekeeper；
- PDD 注入、抓包或私有协议调用；
- HLS/m3u8 视频；
- 改变客服 prompt、队列优先级或发送门禁；
- 用昵称冲突之外的新身份猜测规则替换现有 PDD identifier 策略。
