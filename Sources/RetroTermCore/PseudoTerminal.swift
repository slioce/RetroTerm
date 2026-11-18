import Foundation
import CPTY

public enum PseudoTerminalError: Error {
    case spawnFailed(Int32)
}

/// A child process attached to a pseudo-terminal.
public final class PseudoTerminal {
    public let masterFD: Int32
    public let pid: pid_t
    public private(set) var exitStatus: Int32? = nil

    private var readSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?
    private let writeQueue = DispatchQueue(label: "RetroTerm.pty.write")
    private var closed = false

    public init(executable: String, arguments: [String], environment: [String: String],
                workingDirectory: String?, cols: Int, rows: Int) throws {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var master: Int32 = -1
        let pid = cpty_spawn(executable, argv, envp, workingDirectory, UInt16(cols), UInt16(rows), &master)
        if pid < 0 { throw PseudoTerminalError.spawnFailed(errno) }
        self.pid = pid
        self.masterFD = master
    }

    deinit {
        terminate()
    }

    /// Starts delivering output on `queue`. `onData` receives raw bytes; `onExit` fires once at EOF.
    public func startReading(queue: DispatchQueue, onData: @escaping (UnsafeBufferPointer<UInt8>) -> Void,
                             onExit: @escaping (Int32?) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        let bufferSize = 128 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let n = read(self.masterFD, buffer, bufferSize)
            if n > 0 {
                onData(UnsafeBufferPointer(start: buffer, count: n))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            buffer.deallocate()
            guard let self = self else { onExit(nil); return }
            self.reap()
            onExit(self.exitStatus)
        }
        readSource = source
        source.resume()

        let proc = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        proc.setEventHandler { [weak self] in
            self?.reap()
        }
        processSource = proc
        proc.resume()
    }

    private func reap() {
        guard exitStatus == nil else { return }
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid { exitStatus = status }
    }

    public func write(_ bytes: [UInt8]) {
        guard !closed, !bytes.isEmpty else { return }
        let fd = masterFD
        writeQueue.async {
            bytes.withUnsafeBufferPointer { buf in
                var offset = 0
                while offset < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                    if n > 0 { offset += n }
                    else if errno == EINTR || errno == EAGAIN { usleep(1000) }
                    else { break }
                }
            }
        }
    }

    public func write(_ string: String) {
        write(Array(string.utf8))
    }

    public func resize(cols: Int, rows: Int) {
        guard !closed else { return }
        _ = cpty_set_size(masterFD, UInt16(max(1, cols)), UInt16(max(1, rows)))
    }

    public func terminate() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        processSource?.cancel()
        if exitStatus == nil {
            kill(pid, SIGHUP)
        }
        close(masterFD)
    }

    // MARK: - Shell discovery

    /// The user's login shell from the directory service, falling back to /bin/zsh.
    public static func defaultShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let s = String(cString: shell)
            if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        if let env = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        return "/bin/zsh"
    }

    /// Environment for a new shell: the app's environment plus terminal identification.
    public static func shellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "RetroTerm"
        env["TERM_PROGRAM_VERSION"] = "1.0"
        if env["LANG"] == nil || env["LANG"]?.isEmpty == true {
            env["LANG"] = "en_US.UTF-8"
        }
        env.removeValue(forKey: "XPC_SERVICE_NAME")
        env.removeValue(forKey: "XPC_FLAGS")
        return env
    }
}
