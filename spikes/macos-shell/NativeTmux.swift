import AppKit
import Darwin
import Foundation

let nativeTmuxSessionListFormat =
    "#{q:session_id}|#{q:session_name}|#{session_windows}|#{q:socket_path}|#{pid}"
let nativeTmuxSessionListCommand =
    "list-sessions -F '\(nativeTmuxSessionListFormat)'"

enum NativeTmuxExecutableSource: String, Equatable {
    case configured
    case loginShell
    case applicationEnvironment
    case fallback

    var label: String {
        switch self {
        case .configured: "Settings"
        case .loginShell: "Login shell"
        case .applicationEnvironment: "Application environment"
        case .fallback: "Fallback search"
        }
    }
}

struct NativeTmuxExecutable: Equatable {
    let path: String
    let version: String
    let source: NativeTmuxExecutableSource
}

enum NativeTmuxResolution: Equatable {
    case available(NativeTmuxExecutable)
    case unavailable(String)
}

private struct NativeProcessOutput {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
    let timedOut: Bool
}

private final class NativeProcessTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func markTimedOut() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private enum NativeTmuxProcessRunner {
    private static let maximumCapturedBytes = 16 * 1_024 * 1_024

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        timeout: TimeInterval
    ) -> NativeProcessOutput? {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let identifier = UUID().uuidString
        let outputURL = temporaryDirectory.appendingPathComponent(
            "satin-tmux-\(identifier).stdout"
        )
        let errorURL = temporaryDirectory.appendingPathComponent(
            "satin-tmux-\(identifier).stderr"
        )
        guard createCaptureFile(at: outputURL), createCaptureFile(at: errorURL),
            let output = try? FileHandle(forWritingTo: outputURL),
            let error = try? FileHandle(forWritingTo: errorURL)
        else {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
            return nil
        }
        defer {
            try? output.close()
            try? error.close()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        process.environment = environment
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        let timeoutState = NativeProcessTimeoutState()
        let timeoutWork = DispatchWorkItem {
            guard process.isRunning else {
                return
            }
            timeoutState.markTimedOut()
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWork
        )
        process.waitUntilExit()
        timeoutWork.cancel()
        return NativeProcessOutput(
            status: process.terminationStatus,
            standardOutput: capturedData(at: outputURL),
            standardError: capturedData(at: errorURL),
            timedOut: timeoutState.timedOut
        )
    }

    private static func createCaptureFile(at url: URL) -> Bool {
        FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        )
    }

    private static func capturedData(at url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Data()
        }
        defer {
            try? handle.close()
        }
        return (try? handle.read(upToCount: maximumCapturedBytes + 1)) ?? Data()
    }
}

final class NativeTmuxExecutableResolver {
    static let shared = NativeTmuxExecutableResolver()
    static let minimumVersion = "3.2"

    private let queue = DispatchQueue(
        label: "dev.soyukke.satin.tmux-resolver",
        qos: .userInitiated
    )
    private var cachedKey: String?
    private var cachedResolution: NativeTmuxResolution?

    func resolve(
        configuredPath: String,
        shellPath: String,
        force: Bool = false,
        completion: @escaping (NativeTmuxResolution) -> Void
    ) {
        let key = "\(configuredPath)\u{0}\(shellPath)"
        queue.async { [self] in
            let resolution: NativeTmuxResolution
            if !force, cachedKey == key, let cachedResolution {
                resolution = cachedResolution
            } else {
                resolution = Self.resolveNow(
                    configuredPath: configuredPath,
                    shellPath: shellPath
                )
                cachedKey = key
                self.cachedResolution = resolution
            }
            DispatchQueue.main.async {
                completion(resolution)
            }
        }
    }

    static func executablePath(forProcessID processID: UInt32) -> String? {
        guard processID > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: 4 * 1_024)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(
                pid_t(processID),
                bytes.baseAddress,
                UInt32(bytes.count)
            )
        }
        guard length > 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    static func runSelfTests() -> Bool {
        supportedVersion("3.2")
            && supportedVersion("3.6a")
            && supportedVersion("next-4.0")
            && !supportedVersion("3.1c")
            && !supportedVersion("unknown")
            && NativeTmuxSessionDiscovery.parse(
                "$0|alpha|2|/tmp/tmux.sock|4242\n$1|beta|1|/tmp/tmux.sock|4242\n"
            )?.map(\.name) == ["alpha", "beta"]
            && NativeTmuxSessionDiscovery.parse(
                "$7|name\\|with\\ space|1|/tmp/tmux\\ socket|4242"
            )?.first
                == NativeTmuxSessionDescriptor(
                    sessionID: 7,
                    name: "name|with space",
                    windowCount: 1,
                    socketPath: "/tmp/tmux socket",
                    serverPID: 4242
                )
            && NativeTmuxSessionDiscovery.parse("broken\n") == nil
            && NativeTmuxSessionTermination.arguments(
                for: NativeTmuxSessionDescriptor(
                    sessionID: 7,
                    name: "name with spaces",
                    windowCount: 2,
                    socketPath: "/tmp/tmux socket",
                    serverPID: 4242
                )
            ) == [
                "-u", "-S", "/tmp/tmux socket", "kill-session", "-t", "=name with spaces",
            ]
            && NativeTmuxSessionTermination.confirmed(.alertFirstButtonReturn)
            && !NativeTmuxSessionTermination.confirmed(.alertSecondButtonReturn)
    }

    private static func resolveNow(
        configuredPath: String,
        shellPath: String
    ) -> NativeTmuxResolution {
        if !configuredPath.isEmpty {
            return validate(path: configuredPath, source: .configured)
        }
        if let executable = findTmux(
            in: ProcessInfo.processInfo.environment["PATH"] ?? ""
        ) {
            return validate(path: executable, source: .applicationEnvironment)
        }
        for directory in fallbackDirectories() {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("tmux").path
            if isExecutableFile(candidate) {
                return validate(path: candidate, source: .fallback)
            }
        }
        // Starting another interactive login shell while the terminal's own shell is
        // initializing can block on shared shell startup state. Keep that expensive
        // lookup as the last fallback so opening the session picker and automatic
        // reattach stay responsive when tmux is already in a known process path.
        let loginShell = selectedLoginShell(configured: shellPath)
        if let path = loginShellPath(shell: loginShell),
            let executable = findTmux(in: path)
        {
            return validate(path: executable, source: .loginShell)
        }
        return .unavailable(
            "tmux was not found in the configured login shell. Choose its executable in Settings."
        )
    }

    private static func validate(
        path: String,
        source: NativeTmuxExecutableSource
    ) -> NativeTmuxResolution {
        guard isExecutableFile(path) else {
            return .unavailable("The configured tmux executable is unavailable: \(path)")
        }
        guard
            let output = NativeTmuxProcessRunner.run(
                executable: path,
                arguments: ["-V"],
                timeout: 2
            )
        else {
            return .unavailable("Satin could not launch the tmux executable: \(path)")
        }
        if output.timedOut {
            return .unavailable("tmux version detection timed out: \(path)")
        }
        let versionData =
            output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        let value = String(decoding: versionData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = value.hasPrefix("tmux ") ? String(value.dropFirst(5)) : value
        guard output.status == 0, supportedVersion(version) else {
            return .unavailable(
                "Satin requires tmux \(minimumVersion) or newer; found \(version.isEmpty ? "an unknown version" : version)."
            )
        }
        return .available(
            NativeTmuxExecutable(path: path, version: version, source: source)
        )
    }

    private static func supportedVersion(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard let start = scalars.firstIndex(where: CharacterSet.decimalDigits.contains) else {
            return false
        }
        var majorEnd = start
        while majorEnd < scalars.endIndex,
            CharacterSet.decimalDigits.contains(scalars[majorEnd])
        {
            majorEnd += 1
        }
        guard majorEnd < scalars.endIndex, scalars[majorEnd] == "." else {
            return false
        }
        let minorStart = majorEnd + 1
        var minorEnd = minorStart
        while minorEnd < scalars.endIndex,
            CharacterSet.decimalDigits.contains(scalars[minorEnd])
        {
            minorEnd += 1
        }
        guard minorEnd > minorStart,
            let major = Int(String(String.UnicodeScalarView(scalars[start..<majorEnd]))),
            let minor = Int(String(String.UnicodeScalarView(scalars[minorStart..<minorEnd])))
        else {
            return false
        }
        return major > 3 || (major == 3 && minor >= 2)
    }

    private static func selectedLoginShell(configured: String) -> String {
        if !configured.isEmpty {
            return configured
        }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let value = String(cString: shell)
            if isExecutableFile(value) {
                return value
            }
        }
        let environmentShell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return isExecutableFile(environmentShell) ? environmentShell : "/bin/zsh"
    }

    private static func loginShellPath(shell: String) -> String? {
        let marker =
            "__SATIN_TMUX_PATH_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let command = "/usr/bin/printf '\(marker)%s\(marker)' \"$PATH\""
        var environment = ProcessInfo.processInfo.environment
        environment["SATIN_RESOLVING_SHELL_ENVIRONMENT"] = "1"
        environment["TERM"] = "dumb"
        guard
            let output = NativeTmuxProcessRunner.run(
                executable: shell,
                arguments: ["-l", "-i", "-c", command],
                environment: environment,
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                timeout: 5
            ),
            !output.timedOut
        else {
            return nil
        }
        let components = String(decoding: output.standardOutput, as: UTF8.self)
            .components(separatedBy: marker)
        guard components.count >= 3 else {
            return nil
        }
        let path = components[components.count - 2]
        return path.isEmpty ? nil : path
    }

    private static func findTmux(in path: String) -> String? {
        for component in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = String(component)
            guard (directory as NSString).isAbsolutePath else {
                continue
            }
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("tmux").path
            if isExecutableFile(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func fallbackDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = NSUserName()
        return [
            "\(home)/.nix-profile/bin",
            "/etc/profiles/per-user/\(user)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/run/current-system/sw/bin",
            "/nix/var/nix/profiles/default/bin",
            "/usr/bin",
        ]
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        guard !path.isEmpty else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

enum NativeTmuxSessionDiscoveryResult {
    case sessions([NativeTmuxSessionDescriptor])
    case unavailable(String)
}

enum NativeTmuxProjectionAdmissionResult {
    case admitted(NativeTmuxSessionLease)
    case busy
    case unavailable(String)
}

enum NativeTmuxProjectionAdmission {
    static func request(
        executable: NativeTmuxExecutable,
        descriptor: NativeTmuxSessionDescriptor,
        completion: @escaping (NativeTmuxProjectionAdmissionResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = inspect(executable: executable, descriptor: descriptor)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    static func clientArguments(for descriptor: NativeTmuxSessionDescriptor) -> [String] {
        [
            "-u", "-S", descriptor.socketPath,
            "list-clients", "-t", "=\(descriptor.name)",
            "-F", "#{client_control_mode}",
        ]
    }

    private static func inspect(
        executable: NativeTmuxExecutable,
        descriptor: NativeTmuxSessionDescriptor
    ) -> NativeTmuxProjectionAdmissionResult {
        let identity = NativeTmuxSessionIdentity(descriptor: descriptor)
        let lease: NativeTmuxSessionLease
        switch NativeTmuxSessionLease.acquire(identity: identity) {
        case .acquired(let acquired):
            lease = acquired
        case .busy:
            return .busy
        case .unavailable(let message):
            return .unavailable(message)
        }
        guard
            let output = NativeTmuxProcessRunner.run(
                executable: executable.path,
                arguments: clientArguments(for: descriptor),
                timeout: 3
            )
        else {
            return .unavailable("Satin could not inspect the tmux session clients.")
        }
        if output.timedOut {
            return .unavailable("tmux session client inspection timed out.")
        }
        if output.status != 0 {
            let errorData =
                output.standardError.isEmpty
                ? output.standardOutput
                : output.standardError
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(
                detail.isEmpty ? "tmux session client inspection failed." : detail
            )
        }
        let hasControlClient = String(decoding: output.standardOutput, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "1" }
        return hasControlClient ? .busy : .admitted(lease)
    }
}

enum NativeTmuxSessionDiscovery {
    static func discover(
        executable: NativeTmuxExecutable,
        socketPath: String?,
        completion: @escaping (NativeTmuxSessionDiscoveryResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = sessions(executable: executable, socketPath: socketPath)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    static func parse(_ value: String) -> [NativeTmuxSessionDescriptor]? {
        var sessions: [NativeTmuxSessionDescriptor] = []
        for line in value.split(whereSeparator: \.isNewline) {
            guard let fields = parseFields(line) else {
                return nil
            }
            guard fields.count == 5,
                let sessionID = parseTmuxID(fields[0], prefix: "$"),
                let windowCount = Int(fields[2]),
                let serverPID = UInt32(fields[4]),
                !fields[1].isEmpty,
                !fields[3].isEmpty
            else {
                return nil
            }
            sessions.append(
                NativeTmuxSessionDescriptor(
                    sessionID: sessionID,
                    name: String(fields[1]),
                    windowCount: windowCount,
                    socketPath: String(fields[3]),
                    serverPID: serverPID
                )
            )
        }
        return sessions.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func parseTmuxID(_ value: String, prefix: Character) -> UInt32? {
        guard value.first == prefix else {
            return nil
        }
        return UInt32(value.dropFirst())
    }

    private static func parseFields(_ line: Substring) -> [String]? {
        var fields: [[UInt8]] = []
        var field: [UInt8] = []
        var escaped = false
        for byte in line.utf8 {
            if escaped {
                field.append(byte)
                escaped = false
            } else if byte == Character("\\").asciiValue {
                escaped = true
            } else if byte == Character("|").asciiValue {
                fields.append(field)
                field.removeAll(keepingCapacity: true)
            } else {
                field.append(byte)
            }
        }
        guard !escaped else {
            return nil
        }
        fields.append(field)
        return fields.map { String(decoding: $0, as: UTF8.self) }
    }

    static func sessions(
        executable: NativeTmuxExecutable,
        socketPath: String?
    ) -> NativeTmuxSessionDiscoveryResult {
        var arguments = ["-u"]
        if let socketPath, !socketPath.isEmpty {
            arguments += ["-S", socketPath]
        }
        arguments += ["list-sessions", "-F", nativeTmuxSessionListFormat]
        guard
            let output = NativeTmuxProcessRunner.run(
                executable: executable.path,
                arguments: arguments,
                timeout: 3
            )
        else {
            return .unavailable("Satin could not launch tmux session discovery.")
        }
        if output.timedOut {
            return .unavailable("tmux session discovery timed out.")
        }
        let value = String(decoding: output.standardOutput, as: UTF8.self)
        if output.status != 0 {
            let errorValue = String(decoding: output.standardError, as: UTF8.self)
            let messageValue = errorValue.isEmpty ? value : errorValue
            let lowercased = messageValue.lowercased()
            if lowercased.contains("no server running")
                || lowercased.contains("no sessions")
                || lowercased.contains("no such file or directory")
            {
                return .sessions([])
            }
            let message = messageValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(message.isEmpty ? "tmux session discovery failed." : message)
        }
        guard output.standardOutput.count <= 16 * 1_024 * 1_024, let parsed = parse(value) else {
            let preview = String(value.prefix(512)).debugDescription
            return .unavailable("tmux returned an invalid session list: \(preview)")
        }
        return .sessions(parsed)
    }
}

enum NativeTmuxSessionTerminationResult {
    case ended
    case unavailable(String)
}

enum NativeTmuxSessionTermination {
    static func confirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    static func arguments(for descriptor: NativeTmuxSessionDescriptor) -> [String] {
        ["-u", "-S", descriptor.socketPath, "kill-session", "-t", "=\(descriptor.name)"]
    }

    static func end(
        executablePath: String,
        descriptor: NativeTmuxSessionDescriptor,
        completion: @escaping (NativeTmuxSessionTerminationResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = endNow(executablePath: executablePath, descriptor: descriptor)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func endNow(
        executablePath: String,
        descriptor: NativeTmuxSessionDescriptor
    ) -> NativeTmuxSessionTerminationResult {
        guard
            let output = NativeTmuxProcessRunner.run(
                executable: executablePath,
                arguments: arguments(for: descriptor),
                timeout: 3
            )
        else {
            return .unavailable("Satin could not launch tmux to end the session.")
        }
        if output.timedOut {
            return .unavailable("Ending the tmux session timed out.")
        }
        guard output.status == 0 else {
            let data = output.standardError.isEmpty ? output.standardOutput : output.standardError
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(message.isEmpty ? "tmux could not end the session." : message)
        }
        return .ended
    }
}

final class TmuxSessionPopoverController: NSViewController, NSSearchFieldDelegate {
    var onSelectLocal: (() -> Void)?
    var onSelectSession: ((NativeTmuxSessionDescriptor) -> Void)?
    var onCreateSession: ((String) -> Void)?
    var onRequestEndSession: ((NativeTmuxSessionDescriptor) -> Void)?

    private var sessions: [NativeTmuxSessionDescriptor] = []
    private let currentSessionName: String?
    private let searchField = NSSearchField(frame: .zero)
    private let rows = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Finding tmux…")
    private let newSessionButton = NSButton(frame: .zero)
    private let nameField = NSTextField(frame: .zero)
    private let createButton = NSButton(frame: .zero)
    private let creationRow = NSStackView()
    private let validationLabel = NSTextField(labelWithString: "")

    init(currentSessionName: String?) {
        self.currentSessionName = currentSessionName
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 320, height: Self.preferredHeight(rowCount: 0))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSView()
        let heading = NSTextField(labelWithString: "Sessions")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        searchField.placeholderString = "Search Sessions"
        searchField.delegate = self
        searchField.isHidden = true
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        refreshSessionRows()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        configureRowButton(
            newSessionButton,
            title: "New tmux Session…",
            symbol: "plus",
            action: #selector(beginCreatingSession(_:))
        )
        newSessionButton.isEnabled = false
        nameField.placeholderString = "Session name"
        nameField.target = self
        nameField.action = #selector(createSession(_:))
        createButton.title = "Create"
        createButton.bezelStyle = .rounded
        createButton.target = self
        createButton.action = #selector(createSession(_:))
        creationRow.orientation = .horizontal
        creationRow.alignment = .centerY
        creationRow.spacing = 8
        creationRow.addArrangedSubview(nameField)
        creationRow.addArrangedSubview(createButton)
        creationRow.isHidden = true
        validationLabel.textColor = .systemRed
        validationLabel.font = .systemFont(ofSize: 11)
        validationLabel.maximumNumberOfLines = 2
        validationLabel.isHidden = true
        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [
            heading, searchField, rows, statusLabel, separator, newSessionButton,
            creationRow, validationLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 320),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            newSessionButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            creationRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            validationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
    }

    func update(
        sessions: [NativeTmuxSessionDescriptor],
        status: String?,
        canCreate: Bool,
        isError: Bool = false
    ) {
        loadViewIfNeeded()
        self.sessions = sessions
        searchField.isHidden = sessions.count <= 5
        statusLabel.stringValue = status ?? ""
        statusLabel.isHidden = status == nil
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        newSessionButton.isEnabled = canCreate
        preferredContentSize.height = Self.preferredHeight(rowCount: sessions.count)
        refreshSessionRows()
    }

    func controlTextDidChange(_ notification: Notification) {
        refreshSessionRows()
    }

    private func refreshSessionRows() {
        for child in rows.arrangedSubviews {
            rows.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered =
            query.isEmpty
            ? sessions
            : sessions.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let local = NSButton(frame: .zero)
        configureRowButton(
            local,
            title: "Local Terminal",
            symbol: currentSessionName == nil ? "checkmark.circle.fill" : "terminal",
            action: #selector(selectLocal(_:))
        )
        rows.addArrangedSubview(local)
        local.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        for descriptor in filtered {
            let button = NSButton(frame: .zero)
            let suffix =
                descriptor.windowCount == 1
                ? "1 window" : "\(descriptor.windowCount) windows"
            let symbol =
                descriptor.name == currentSessionName
                ? "checkmark.circle.fill" : "rectangle.stack"
            configureRowButton(
                button,
                title: "\(descriptor.name)  ·  \(suffix)",
                symbol: symbol,
                action: #selector(selectSession(_:))
            )
            let index = sessions.firstIndex(of: descriptor) ?? -1
            button.tag = index
            button.identifier = NSUserInterfaceItemIdentifier(
                "dev.soyukke.satin.tmux-session-select.\(index)"
            )
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let endButton = NSButton(frame: .zero)
            endButton.bezelStyle = .inline
            endButton.image = NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: "End tmux session \(descriptor.name)"
            )
            endButton.imagePosition = .imageOnly
            endButton.contentTintColor = .secondaryLabelColor
            endButton.target = self
            endButton.action = #selector(requestEndSession(_:))
            endButton.tag = index
            endButton.toolTip = "End tmux session \(descriptor.name)"
            endButton.setAccessibilityLabel("End tmux session \(descriptor.name)")
            endButton.identifier = NSUserInterfaceItemIdentifier(
                "dev.soyukke.satin.tmux-session-end.\(index)"
            )
            endButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
            endButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

            let row = NSStackView(views: [button, endButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 4
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        if filtered.isEmpty, !query.isEmpty {
            let empty = NSTextField(labelWithString: "No matching tmux sessions")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 12)
            rows.addArrangedSubview(empty)
        }
    }

    private func configureRowButton(
        _ button: NSButton,
        title: String,
        symbol: String,
        action: Selector
    ) {
        button.title = title
        button.bezelStyle = .inline
        button.alignment = .left
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @objc private func selectLocal(_ sender: Any?) {
        onSelectLocal?()
    }

    @objc private func selectSession(_ sender: NSButton) {
        guard sessions.indices.contains(sender.tag) else {
            return
        }
        onSelectSession?(sessions[sender.tag])
    }

    @objc private func requestEndSession(_ sender: NSButton) {
        guard sessions.indices.contains(sender.tag) else {
            return
        }
        onRequestEndSession?(sessions[sender.tag])
    }

    @objc private func beginCreatingSession(_ sender: Any?) {
        newSessionButton.isHidden = true
        creationRow.isHidden = false
        validationLabel.isHidden = true
        preferredContentSize.height += 38
        view.window?.makeFirstResponder(nameField)
    }

    @objc private func createSession(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = validationError(for: name) {
            validationLabel.stringValue = error
            validationLabel.isHidden = false
            return
        }
        onCreateSession?(name)
    }

    private func validationError(for name: String) -> String? {
        if name.isEmpty {
            return "Enter a session name."
        }
        if name.contains(":") || name.contains(".") {
            return "tmux session names cannot contain a colon or period."
        }
        if sessions.contains(where: { $0.name == name }) {
            return "A tmux session with that name already exists."
        }
        return nil
    }

    private static func preferredHeight(rowCount: Int) -> CGFloat {
        let visibleRows = min(max(rowCount + 1, 2), 10)
        return CGFloat(visibleRows * 30 + (rowCount > 5 ? 132 : 92))
    }

    #if SATIN_SMOKE_SCENARIOS
        func sessionRowTitlesForSmoke() -> [String] {
            loadViewIfNeeded()
            return rows.arrangedSubviews.compactMap { row in
                if let button = row as? NSButton {
                    return button.title
                }
                return (row as? NSStackView)?.arrangedSubviews
                    .compactMap { $0 as? NSButton }
                    .first(where: {
                        $0.identifier?.rawValue.hasPrefix(
                            "dev.soyukke.satin.tmux-session-select."
                        ) == true
                    })?.title
            }
        }

        func selectLocalForSmoke() -> Bool {
            loadViewIfNeeded()
            guard let button = rows.arrangedSubviews.first as? NSButton,
                button.title == "Local Terminal"
            else {
                return false
            }
            button.performClick(nil)
            return true
        }

        func selectSessionForSmoke(_ descriptor: NativeTmuxSessionDescriptor) -> Bool {
            loadViewIfNeeded()
            guard let index = sessions.firstIndex(of: descriptor) else {
                return false
            }
            let identifier = NSUserInterfaceItemIdentifier(
                "dev.soyukke.satin.tmux-session-select.\(index)"
            )
            guard
                let button = rows.arrangedSubviews
                    .compactMap({ $0 as? NSStackView })
                    .flatMap(\.arrangedSubviews)
                    .first(where: { $0.identifier == identifier }) as? NSButton
            else {
                return false
            }
            button.performClick(nil)
            return true
        }

        func requestEndSessionForSmoke(_ descriptor: NativeTmuxSessionDescriptor) -> Bool {
            loadViewIfNeeded()
            guard let index = sessions.firstIndex(of: descriptor) else {
                return false
            }
            let identifier = NSUserInterfaceItemIdentifier(
                "dev.soyukke.satin.tmux-session-end.\(index)"
            )
            guard
                rows.arrangedSubviews
                    .compactMap({ $0 as? NSStackView })
                    .flatMap(\.arrangedSubviews)
                    .contains(where: { $0.identifier == identifier })
            else {
                return false
            }
            onRequestEndSession?(descriptor)
            return true
        }
    #endif
}
