import Darwin
import Foundation

@_silgen_name("flock")
private func nativeTmuxFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

struct NativeTmuxSessionIdentity: Equatable, Sendable {
    let sessionID: UInt32
    let socketPath: String
    let serverPID: UInt32

    init(descriptor: NativeTmuxSessionDescriptor) {
        sessionID = descriptor.sessionID
        socketPath = descriptor.socketPath
        serverPID = descriptor.serverPID
    }

    init(snapshot: TmuxSnapshot) {
        sessionID = snapshot.session_id
        socketPath = snapshot.socket_path
        serverPID = snapshot.server_pid
    }

    private var canonicalSocketPath: String {
        URL(fileURLWithPath: socketPath).standardizedFileURL.path
    }

    fileprivate var lockFileName: String {
        let value = "\(serverPID)\u{0}\(sessionID)\u{0}\(canonicalSocketPath)"
        var first: UInt64 = 0xcbf2_9ce4_8422_2325
        var second: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in value.utf8 {
            first ^= UInt64(byte)
            first &*= 0x0000_0100_0000_01b3
            second ^= UInt64(byte)
            second &*= 0x0000_0100_0000_01b3
            second = (second << 7) | (second >> 57)
        }
        return String(format: "%016llx%016llx.lock", first, second)
    }
}

enum NativeTmuxSessionLeaseResult {
    case acquired(NativeTmuxSessionLease)
    case busy
    case unavailable(String)
}

final class NativeTmuxSessionLease: @unchecked Sendable {
    let identity: NativeTmuxSessionIdentity
    private let fileDescriptor: Int32

    private init(identity: NativeTmuxSessionIdentity, fileDescriptor: Int32) {
        self.identity = identity
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = nativeTmuxFlock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
    }

    static func acquire(
        identity: NativeTmuxSessionIdentity,
        directory requestedDirectory: URL? = nil
    ) -> NativeTmuxSessionLeaseResult {
        guard identity.sessionID > 0 || identity.serverPID > 0,
            !identity.socketPath.isEmpty
        else {
            return .unavailable("tmux returned an invalid session identity.")
        }
        guard let directory = requestedDirectory ?? defaultDirectory() else {
            return .unavailable("Satin could not locate its cache directory.")
        }
        if let message = prepare(directory: directory) {
            return .unavailable(message)
        }
        let lockURL = directory.appendingPathComponent(identity.lockFileName)
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            return .unavailable("Satin could not open the tmux session lease.")
        }
        guard nativeTmuxFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return .busy
            }
            return .unavailable("Satin could not acquire the tmux session lease.")
        }
        writeDiagnosticMetadata(descriptor: descriptor, identity: identity)
        return .acquired(
            NativeTmuxSessionLease(identity: identity, fileDescriptor: descriptor)
        )
    }

    static func runSelfTests() -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "satin-tmux-lease-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let identity = NativeTmuxSessionIdentity(
            descriptor: NativeTmuxSessionDescriptor(
                sessionID: 7,
                name: "lease-test",
                windowCount: 1,
                socketPath: "/tmp/satin-lease-test.sock",
                serverPID: 4242
            )
        )
        guard
            let competingResult = competingAcquireResult(
                identity: identity,
                directory: directory
            )
        else {
            return selfTestFailure("initial-acquire")
        }
        guard case .busy = competingResult else {
            return selfTestFailure("competing-acquire")
        }
        guard
            case .acquired(let reacquired) = acquire(
                identity: identity,
                directory: directory
            )
        else {
            return selfTestFailure("reacquire-after-release")
        }
        return withExtendedLifetime(reacquired) { true }
    }

    private static func competingAcquireResult(
        identity: NativeTmuxSessionIdentity,
        directory: URL
    ) -> NativeTmuxSessionLeaseResult? {
        guard
            case .acquired(let heldLease) = acquire(
                identity: identity,
                directory: directory
            )
        else {
            return nil
        }
        return withExtendedLifetime(heldLease) {
            acquire(identity: identity, directory: directory)
        }
    }

    private static func selfTestFailure(_ stage: String) -> Bool {
        fputs("tmux session lease self-test stage failed: \(stage)\n", stderr)
        return false
    }

    private static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dev.soyukke.satin.shared", isDirectory: true)
            .appendingPathComponent("tmux-session-leases", isDirectory: true)
    }

    private static func prepare(directory: URL) -> String? {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            return "Satin could not create the tmux session lease directory."
        }
        var status = stat()
        guard Darwin.lstat(directory.path, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == geteuid()
        else {
            return "The tmux session lease directory is not owner-controlled."
        }
        guard Darwin.chmod(directory.path, mode_t(S_IRWXU)) == 0 else {
            return "Satin could not secure the tmux session lease directory."
        }
        return nil
    }

    private static func writeDiagnosticMetadata(
        descriptor: Int32,
        identity: NativeTmuxSessionIdentity
    ) {
        let bundle = Bundle.main.bundleIdentifier ?? "unknown"
        let value =
            "pid=\(getpid()) bundle=\(bundle) server=\(identity.serverPID) "
            + "session=\(identity.sessionID)\n"
        let bytes = Array(value.utf8)
        _ = Darwin.ftruncate(descriptor, 0)
        _ = Darwin.lseek(descriptor, 0, SEEK_SET)
        bytes.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else {
                return
            }
            _ = Darwin.write(descriptor, address, buffer.count)
        }
    }
}
