import AppKit
import Foundation
import PDDVideoProbeCore
import SwiftUI

@main
struct PDDVideoProbeApp: App {
    var body: some Scene {
        WindowGroup("拼多多视频直链测试器") { ProbeView() }
            .windowResizability(.contentSize)
    }
}

private struct ProbeView: View {
    @StateObject private var model = ProbeViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("拼多多视频直链测试器").font(.system(size: 28, weight: .bold))
            Text("不使用 OCR、不录屏、不发送消息。通过 AX 自动定位并点开当前聊天中最新的客户视频，再从 CEF 缓存取得地址并下载原始 MP4。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    Label("打开拼多多商家版并进入含客户视频的聊天", systemImage: "1.circle.fill")
                    Label("点击下方“开始自动测试”", systemImage: "2.circle.fill")
                    Label("测试器用 AX 自动定位并点开最新客户视频", systemImage: "3.circle.fill")
                    Label("等待自动下载、验证并导出结果 ZIP", systemImage: "4.circle.fill")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            HStack(spacing: 10) {
                ProgressView().opacity(model.isRunning ? 1 : 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.status).font(.headline)
                    Text(model.detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 48, alignment: .leading)
            HStack {
                Button(model.isRunning ? "正在测试…" : "开始自动测试") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning)
                Button("打开结果") { model.revealResult() }.disabled(model.resultURL == nil)
                Spacer()
                Text("不会保存视频地址或登录信息").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(26)
        .frame(width: 680)
    }
}

@MainActor
private final class ProbeViewModel: ObservableObject {
    @Published var status = "准备就绪"
    @Published var detail = "进入含客户视频的会话后，测试器会自动定位并点击。"
    @Published var isRunning = false
    @Published var resultURL: URL?

    private var task: Task<Void, Never>?
    private var outputFolder: URL?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        resultURL = nil
        status = "正在检查拼多多缓存"
        detail = "尚未读取旧视频地址，也尚未点击拼多多。"
        task = Task { await runProbe() }
    }

    func revealResult() {
        guard let resultURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resultURL])
    }

    private func runProbe() async {
        let discoveryStarted = Date()
        var discoveryMilliseconds = 0
        var downloadMilliseconds = 0
        var httpStatus: Int?
        var fileSummary: SanitizedPDDVideoProbeReport.FileSummary?
        var didDiscoverCandidate = false
        let machine = machineSummary()
        do {
            let cefRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.pinduoduo.merchantMac/PMDataRelease/Caches/cef")
            let cacheDirectories = try PDDVideoCacheLocator.findCacheDataDirectories(inCEFRoot: cefRoot)
            let baselines = try PDDVideoCacheBaseline.capture(directories: cacheDirectories)
            let folder = try makeOutputFolder()
            outputFolder = folder
            status = "正在用 AX 定位客户视频"
            detail = "只选择当前聊天中最新、可见、客户侧的视频消息。"

            let opener = PDDVideoAXAutoOpener()
            let candidate = try await PDDVideoAXCandidateWaiter().wait(timeout: .seconds(60)) {
                try await opener.latestCustomerVideo()
            }
            try opener.click(candidate)
            status = "已自动点开视频，正在捕获链接"
            detail = "已定位最新客户视频；视频地址只保留在内存。"

            let mediaURL = try await PDDVideoCacheWatcher()
                .waitForNewCandidate(in: baselines, timeout: .seconds(60))
            discoveryMilliseconds = max(0, Int(Date().timeIntervalSince(discoveryStarted) * 1_000))
            didDiscoverCandidate = true
            status = "已发现视频，正在下载"
            detail = "视频地址只保留在内存，不会写入报告。"
            let destination = folder.appendingPathComponent("下载的视频.mp4")
            let receipt = try await PDDVideoDownloadClient().download(from: mediaURL, to: destination)
            downloadMilliseconds = receipt.elapsedMilliseconds
            httpStatus = receipt.statusCode
            status = "正在验证视频"
            detail = "检查容器、时长、轨道、分辨率、编码和文件哈希。"
            fileSummary = try await PDDVideoFileInspector.inspect(receipt.fileURL)

            let report = SanitizedPDDVideoProbeReport(
                machine: machine, result: .passed,
                discoveryMilliseconds: discoveryMilliseconds,
                downloadMilliseconds: downloadMilliseconds,
                httpStatus: httpStatus, file: fileSummary, failure: nil
            )
            try write(report: report, to: folder)
            let zip = try zipFolder(folder)
            resultURL = zip
            status = "测试通过"
            detail = "视频已下载并验证，脱敏结果 ZIP 已生成在桌面。"
            NSWorkspace.shared.activateFileViewerSelecting([zip])
        } catch {
            if !didDiscoverCandidate {
                discoveryMilliseconds = max(0, Int(Date().timeIntervalSince(discoveryStarted) * 1_000))
            }
            let message = publicMessage(for: error)
            if outputFolder == nil { outputFolder = try? makeOutputFolder() }
            if let folder = outputFolder {
                let report = SanitizedPDDVideoProbeReport(
                    machine: machine, result: .failed,
                    discoveryMilliseconds: discoveryMilliseconds,
                    downloadMilliseconds: downloadMilliseconds,
                    httpStatus: httpStatus, file: fileSummary, failure: message
                )
                try? write(report: report, to: folder)
                if let zip = try? zipFolder(folder) { resultURL = zip }
            }
            status = "测试未通过"
            detail = message
        }
        isRunning = false
    }

    private func makeOutputFolder() throws -> URL {
        let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = desktop.appendingPathComponent(
            "拼多多视频直链测试结果-\(Host.current().localizedName ?? "Mac")-\(formatter.string(from: Date()))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func write(report: SanitizedPDDVideoProbeReport, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: folder.appendingPathComponent("result.json"), options: .atomic)
        try Data(PDDVideoProbeReportMarkdown.render(report).utf8)
            .write(to: folder.appendingPathComponent("测试报告.md"), options: .atomic)
    }

    private func zipFolder(_ folder: URL) throws -> URL {
        let zip = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zip.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PDDVideoProbeError.outputFailed }
        return zip
    }

    private func machineSummary() -> SanitizedPDDVideoProbeReport.Machine {
        let bundle = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.pinduoduo.merchantMac" })?
            .bundleURL.flatMap(Bundle.init(url:)) ?? Bundle(path: "/Applications/拼多多商家版.app")
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return .init(macOS: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture, pddVersion: version)
    }

    private func publicMessage(for error: Error) -> String {
        if let error = error as? PDDVideoProbeError { return error.localizedDescription }
        return "测试发生未知错误；结果中未记录内部地址或原始错误文本。"
    }
}
