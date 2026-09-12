import Darwin
import Foundation

enum BoundedProcessTermination: Equatable, Sendable {
    case exited(Int32)
    case hardDeadline
    case launchFailed(Int32, String)
}

struct BoundedProcessResult: Sendable {
    let termination: BoundedProcessTermination
    let stdout: Data
    let stderr: Data
    let softDeadlineExceeded: Bool
    let processGroupStillAlive: Bool
    let elapsed: Duration
}

enum BoundedProcess {
    struct Configuration: Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let standardInput: Data?
        let currentDirectory: URL?
        let onStandardOutput: (@Sendable (Data) -> Void)?
        let onStandardInputClosed: (@Sendable () -> Void)?

        init(
            executable: URL,
            arguments: [String] = [],
            environment: [String: String] = ProcessInfo.processInfo.environment,
            standardInput: Data? = nil,
            currentDirectory: URL? = nil,
            onStandardOutput: (@Sendable (Data) -> Void)? = nil,
            onStandardInputClosed: (@Sendable () -> Void)? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.standardInput = standardInput
            self.currentDirectory = currentDirectory
            self.onStandardOutput = onStandardOutput
            self.onStandardInputClosed = onStandardInputClosed
        }
    }

    static func run(
        _ configuration: Configuration,
        softDeadline: Duration,
        hardDeadline: Duration
    ) async -> BoundedProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSynchronously(
                    configuration,
                    softDeadline: softDeadline,
                    hardDeadline: max(hardDeadline, softDeadline)
                ))
            }
        }
    }

    private static func runSynchronously(
        _ configuration: Configuration,
        softDeadline: Duration,
        hardDeadline: Duration
    ) -> BoundedProcessResult {
        let clock = ContinuousClock()
        let start = clock.now
        let softAt = start.advanced(by: softDeadline)
        let hardAt = start.advanced(by: hardDeadline)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        var stdinPipe = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&stdoutPipe) == 0,
              Darwin.pipe(&stderrPipe) == 0,
              Darwin.pipe(&stdinPipe) == 0 else {
            closePipe(&stdoutPipe); closePipe(&stderrPipe); closePipe(&stdinPipe)
            return launchFailure(errno, "pipe", start: start, clock: clock)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            closePipe(&stdoutPipe); closePipe(&stderrPipe); closePipe(&stdinPipe)
            return launchFailure(errno, "posix_spawn init", start: start, clock: clock)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        for descriptor in [stdinPipe[0], stdinPipe[1], stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        if let currentDirectory = configuration.currentDirectory {
            _ = currentDirectory.path.withCString { path in
                posix_spawn_file_actions_addchdir_np(&actions, path)
            }
        }
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))

        let argumentStrings = [configuration.executable.path] + configuration.arguments
        let environmentStrings = configuration.environment.map { "\($0.key)=\($0.value)" }
        let arguments = argumentStrings.map { strdup($0) } + [nil]
        let environment = environmentStrings.map { strdup($0) } + [nil]
        defer {
            for pointer in arguments { if let pointer { free(UnsafeMutableRawPointer(pointer)) } }
            for pointer in environment { if let pointer { free(UnsafeMutableRawPointer(pointer)) } }
        }

        var pid: pid_t = 0
        let spawnStatus = arguments.withUnsafeBufferPointer { argv in
            environment.withUnsafeBufferPointer { envp in
                configuration.executable.path.withCString { executable in
                    posix_spawn(
                        &pid, executable, &actions, &attributes,
                        UnsafeMutablePointer(mutating: argv.baseAddress!),
                        UnsafeMutablePointer(mutating: envp.baseAddress!)
                    )
                }
            }
        }
        closeDescriptor(stdinPipe[0]); closeDescriptor(stdoutPipe[1]); closeDescriptor(stderrPipe[1])
        guard spawnStatus == 0 else {
            closeDescriptor(stdinPipe[1]); closeDescriptor(stdoutPipe[0]); closeDescriptor(stderrPipe[0])
            return launchFailure(
                spawnStatus, String(cString: strerror(spawnStatus)), start: start, clock: clock
            )
        }

        let ioGroup = DispatchGroup()
        let output = ProcessLockedData()
        let error = ProcessLockedData()
        let processFinished = ProcessLockedFlag()
        setNonBlocking(stdoutPipe[0]); setNonBlocking(stderrPipe[0])
        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            readAll(from: stdoutPipe[0], processFinished: processFinished) { chunk in
                output.append(chunk)
                configuration.onStandardOutput?(chunk)
            }
            ioGroup.leave()
        }
        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            readAll(from: stderrPipe[0], processFinished: processFinished) { error.append($0) }
            ioGroup.leave()
        }
        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            if let input = configuration.standardInput {
                input.withUnsafeBytes { raw in
                    guard var base = raw.baseAddress else { return }
                    var remaining = raw.count
                    while remaining > 0 {
                        let count = Darwin.write(stdinPipe[1], base, remaining)
                        if count > 0 { remaining -= count; base = base.advanced(by: count) }
                        else if errno != EINTR { break }
                    }
                }
            }
            closeDescriptor(stdinPipe[1])
            configuration.onStandardInputClosed?()
            ioGroup.leave()
        }

        var status: Int32 = 0
        var softExceeded = false
        var hitHardDeadline = false
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited == -1 && errno != EINTR { break }
            let now = clock.now
            if now >= softAt { softExceeded = true }
            if now >= hardAt {
                hitHardDeadline = true
                terminateGroup(pid)
                let graceEnd = now.advanced(by: .milliseconds(150))
                while clock.now < graceEnd, waitpid(pid, &status, WNOHANG) == 0 { usleep(5_000) }
                if waitpid(pid, &status, WNOHANG) == 0 {
                    _ = kill(-pid, SIGKILL); _ = kill(pid, SIGKILL)
                }
                while waitpid(pid, &status, 0) == -1 && errno == EINTR { }
                break
            }
            usleep(5_000)
        }
        processFinished.value = true
        if !hitHardDeadline, kill(-pid, 0) == 0 {
            terminateGroup(pid)
            usleep(20_000)
            if kill(-pid, 0) == 0 { _ = kill(-pid, SIGKILL) }
        }
        ioGroup.wait()
        let groupAlive = kill(-pid, 0) == 0
        return BoundedProcessResult(
            termination: hitHardDeadline ? .hardDeadline : .exited(decodedExitStatus(status)),
            stdout: output.value,
            stderr: error.value,
            softDeadlineExceeded: softExceeded,
            processGroupStillAlive: groupAlive,
            elapsed: start.duration(to: clock.now)
        )
    }

    private static func terminateGroup(_ pid: pid_t) {
        _ = kill(-pid, SIGTERM); _ = kill(pid, SIGTERM)
    }

    private static func decodedExitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func readAll(
        from descriptor: Int32,
        processFinished: ProcessLockedFlag,
        consume: (Data) -> Void
    ) {
        defer { closeDescriptor(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { consume(Data(buffer.prefix(count))) }
            else if count == 0 { return }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK {
                if processFinished.value { return }
                var state = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                _ = poll(&state, 1, 50)
            } else { return }
        }
    }

    private static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    private static func launchFailure(
        _ code: Int32,
        _ message: String,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> BoundedProcessResult {
        BoundedProcessResult(
            termination: .launchFailed(code, message), stdout: Data(), stderr: Data(),
            softDeadlineExceeded: false, processGroupStillAlive: false,
            elapsed: start.duration(to: clock.now)
        )
    }

    private static func closeDescriptor(_ descriptor: Int32) {
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }

    private static func closePipe(_ descriptors: inout [Int32]) {
        descriptors.forEach(closeDescriptor)
        descriptors = [-1, -1]
    }
}

private final class ProcessLockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class ProcessLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
