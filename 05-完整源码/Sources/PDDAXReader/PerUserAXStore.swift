import Foundation

enum PerUserAXStoreError: LocalizedError {
    case invalidUID
    case unsafeDestination

    var errorDescription: String? {
        switch self {
        case .invalidUID:
            return "AX 中没有读到安全、完整的拼多多用户 ID。"
        case .unsafeDestination:
            return "用户文件路径超出本地隔离目录，已拒绝写入。"
        }
    }
}

struct PerUserAXStore {
    let rootDirectory: URL

    init(
        rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/拼多多AX记录", isDirectory: true)
    ) {
        self.rootDirectory = rootDirectory
    }

    func save(uid: String, contents: String) throws -> URL {
        guard Self.validUID(uid) else { throw PerUserAXStoreError.invalidUID }

        let fileManager = FileManager.default
        let usersDirectory = rootDirectory.appendingPathComponent("用户", isDirectory: true)
        try fileManager.createDirectory(at: usersDirectory, withIntermediateDirectories: true)

        let canonicalUsersDirectory = usersDirectory.resolvingSymlinksInPath().standardizedFileURL
        let userDirectory = usersDirectory.appendingPathComponent(uid, isDirectory: true)
        try fileManager.createDirectory(at: userDirectory, withIntermediateDirectories: true)

        let canonicalUserDirectory = userDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalUserDirectory.path.hasPrefix(canonicalUsersDirectory.path + "/") else {
            throw PerUserAXStoreError.unsafeDestination
        }

        let destination = canonicalUserDirectory.appendingPathComponent("ax.txt")
        try Data(contents.utf8).write(to: destination, options: .atomic)
        return destination
    }

    static func validUID(_ uid: String) -> Bool {
        let validShape = uid.range(
            of: #"^(GZC-[0-9]+|PDD-(ID|NAME)-[0-9a-f]{24})$"#,
            options: .regularExpression
        ) != nil
        return validShape
            && uid.count <= 256
            && !uid.contains("...")
            && !uid.contains("…")
            && !uid.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}
