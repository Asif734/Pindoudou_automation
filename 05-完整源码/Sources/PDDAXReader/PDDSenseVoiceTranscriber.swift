import Foundation

protocol PDDSenseVoiceWorking: Sendable {
    func start() async throws -> Data
    func request(_ data: Data) async throws -> Data
}

extension PersistentJSONLWorker: PDDSenseVoiceWorking {}

private struct PDDSenseVoiceReady: Decodable {
    let type: String
    let version: String
}

private struct PDDSenseVoiceResponse: Decodable {
    let ok: Bool
    let text: String?
}

actor PDDSenseVoiceTranscriber: PDDVideoSpeechTranscribing {
    typealias WaveConverter = @Sendable (URL) async throws -> URL

    private let worker: any PDDSenseVoiceWorking
    private let waveConverter: WaveConverter
    private var prepared = false

    init(worker: any PDDSenseVoiceWorking, waveConverter: @escaping WaveConverter) {
        self.worker = worker
        self.waveConverter = waveConverter
    }

    func prepare() async throws {
        guard !prepared else { return }
        let ready = try JSONDecoder().decode(PDDSenseVoiceReady.self, from: await worker.start())
        guard ready.type == "ready", ready.version == "sensevoice-small-int8" else {
            throw PDDOCRError.engine("SenseVoice 常驻进程未返回 ready")
        }
        prepared = true
    }

    func transcribe(_ mediaURL: URL) async -> [PDDVideoTranscriptSegment] {
        do {
            try await prepare()
            let waveURL = try await waveConverter(mediaURL)
            defer {
                if waveURL != mediaURL { try? FileManager.default.removeItem(at: waveURL) }
            }
            let request = try JSONSerialization.data(withJSONObject: ["path": waveURL.path])
            let response = try JSONDecoder().decode(
                PDDSenseVoiceResponse.self,
                from: await worker.request(request)
            )
            guard response.ok,
                  let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return [] }
            return [.init(startSeconds: 0, durationSeconds: 0, text: text)]
        } catch {
            return []
        }
    }
}

enum PDDSenseVoiceFactory {
    static func make(
        resources: PDDSenseVoiceResources,
        pythonURL: URL,
        knowledgeSitePackagesURL: URL
    ) -> PDDSenseVoiceTranscriber {
        let pythonPath = [resources.sitePackagesURL.path, knowledgeSitePackagesURL.path]
            .joined(separator: ":")
        let worker = PersistentJSONLWorker(
            executable: pythonURL,
            arguments: [
                resources.workerScriptURL.path,
                "--model", resources.modelURL.path,
                "--tokens", resources.tokensURL.path,
            ],
            environment: ProcessInfo.processInfo.environment.merging([
                "PYTHONPATH": pythonPath,
                "PYTHONDONTWRITEBYTECODE": "1",
            ]) { _, new in new },
            startupDeadline: .seconds(30),
            queryDeadline: .seconds(30)
        )
        return PDDSenseVoiceTranscriber(
            worker: worker,
            waveConverter: { try await PDDAudioWaveConverter.convert($0) }
        )
    }
}

enum PDDAudioWaveConverter {
    static func convert(_ source: URL) async throws -> URL {
        if source.pathExtension.lowercased() == "wav" { return source }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-sensevoice-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw PDDOCRError.engine("音轨无法转换为 SenseVoice 输入")
        }
        return destination
    }
}
