import Foundation

struct PDDSenseVoiceResources: Equatable, Sendable {
    let workerScriptURL: URL
    let modelURL: URL
    let tokensURL: URL
    let sitePackagesURL: URL
}

enum PDDSenseVoiceResourceLocator {
    static func resolve(
        resourceRootURL: URL,
        fileManager: FileManager = .default
    ) -> PDDSenseVoiceResources? {
        let root = resourceRootURL.appendingPathComponent("SenseVoice", isDirectory: true)
        let worker = root.appendingPathComponent("serve_sensevoice.py")
        let model = root.appendingPathComponent("model/model.int8.onnx")
        let tokens = root.appendingPathComponent("model/tokens.txt")
        let packages = root.appendingPathComponent("site-packages", isDirectory: true)
        let sherpa = packages.appendingPathComponent("sherpa_onnx", isDirectory: true)
        guard [worker, model, tokens, packages, sherpa].allSatisfy({
            fileManager.fileExists(atPath: $0.path)
        }) else { return nil }
        return .init(
            workerScriptURL: worker,
            modelURL: model,
            tokensURL: tokens,
            sitePackagesURL: packages
        )
    }

    static func resolve(bundle: Bundle = .main) -> PDDSenseVoiceResources? {
        guard let root = bundle.resourceURL else { return nil }
        return resolve(resourceRootURL: root)
    }
}
