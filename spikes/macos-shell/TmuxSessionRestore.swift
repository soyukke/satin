import AppKit
import Foundation

/// What it takes to build a tmux session again once its server is gone: its
/// windows, their splits and the folder each shell was in. Satin keeps the
/// newest one while it shows a local session, so a server that crashes, or
/// one lost to a restart, can be built again. Programs and their output are
/// gone with the server and are not part of it.
struct NativeTmuxRestorePlan: Codable, Equatable {
    indirect enum Node: Codable, Equatable {
        case pane(cwd: String, active: Bool)
        /// Side by side when `sideBySide`, else one above the other; `ratio`
        /// is the first one's share.
        case split(sideBySide: Bool, ratio: Double, first: Node, second: Node)
    }

    struct Window: Codable, Equatable {
        let name: String
        let active: Bool
        let layout: Node
    }

    let sessionName: String
    let socketPath: String
    let executablePath: String
    let windows: [Window]

    init(sessionName: String, socketPath: String, executablePath: String, windows: [Window]) {
        self.sessionName = sessionName
        self.socketPath = socketPath
        self.executablePath = executablePath
        self.windows = windows
    }

    /// Nil when the snapshot has no window to build again.
    init?(_ snapshot: TmuxSnapshot, executablePath: String) {
        let windows = snapshot.windows.sorted { $0.index < $1.index }.compactMap {
            window -> Window? in
            let panes = Dictionary(
                window.panes.map { ($0.pane_id, $0) }, uniquingKeysWith: { first, _ in first })
            guard let layout = Self.node(window.layout, panes: panes, active: window.active_pane_id)
            else {
                return nil
            }
            return Window(
                name: window.name, active: window.window_id == snapshot.active_window_id,
                layout: layout)
        }
        guard !windows.isEmpty, !snapshot.session_name.isEmpty, !snapshot.socket_path.isEmpty
        else {
            return nil
        }
        self.init(
            sessionName: snapshot.session_name, socketPath: snapshot.socket_path,
            executablePath: executablePath, windows: windows)
    }

    var paneCount: Int {
        windows.reduce(0) { $0 + Self.count($1.layout) }
    }

    private static func node(
        _ layout: TmuxLayoutSnapshot, panes: [UInt32: TmuxPaneSnapshot], active: UInt32
    ) -> Node? {
        if layout.kind == "leaf", let paneId = layout.pane_id {
            return .pane(cwd: panes[paneId]?.current_path ?? "", active: paneId == active)
        }
        guard layout.kind == "split", let first = layout.first, let second = layout.second,
            let first = node(first, panes: panes, active: active),
            let second = node(second, panes: panes, active: active)
        else {
            return nil
        }
        return .split(
            sideBySide: layout.axis == "vertical", ratio: min(max(layout.ratio ?? 0.5, 0.05), 0.95),
            first: first, second: second)
    }

    private static func count(_ node: Node) -> Int {
        switch node {
        case .pane: 1
        case .split(_, _, let first, let second): count(first) + count(second)
        }
    }
}

enum NativeTmuxRestore {
    /// tmux tells a control client this when its server died rather than
    /// ended, as when it crashes. A server that is told to end says nothing.
    static func serverCrashed(reason: String?) -> Bool {
        guard let reason else {
            return false
        }
        return reason.contains("server exited unexpectedly") || reason.contains("lost server")
    }

    static func load() -> NativeTmuxRestorePlan? {
        guard let data = UserDefaults.standard.data(forKey: NativePreferenceKey.tmuxRestorePlan)
        else {
            return nil
        }
        return try? JSONDecoder().decode(NativeTmuxRestorePlan.self, from: data)
    }

    static func save(_ plan: NativeTmuxRestorePlan) {
        guard plan != load(), let data = try? JSONEncoder().encode(plan) else {
            return
        }
        UserDefaults.standard.set(data, forKey: NativePreferenceKey.tmuxRestorePlan)
    }

    /// Builds the plan's session on its socket, starting a server there when
    /// none runs. A session of that name that is already there is left as it
    /// is. Nil when it was built or found, else what went wrong.
    static func build(_ plan: NativeTmuxRestorePlan, executable: String) -> String? {
        let server = ["-u", "-S", plan.socketPath]
        func tmux(_ arguments: [String]) -> (ok: Bool, output: String) {
            guard
                let output = NativeTmuxProcessRunner.run(
                    executable: executable, arguments: server + arguments, timeout: 5)
            else {
                return (false, "Satin could not launch tmux.")
            }
            let text = String(
                decoding: output.status == 0 ? output.standardOutput : output.standardError,
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return (output.status == 0 && !output.timedOut, text)
        }
        if tmux(["has-session", "-t", "=\(plan.sessionName)"]).ok {
            return nil
        }
        let printPane = ["-P", "-F", "#{pane_id}"]
        var activeWindow: String?
        var activePanes: [String] = []
        for (index, window) in plan.windows.enumerated() {
            let cwd = folder(firstCwd(window.layout))
            let created =
                index == 0
                ? tmux(
                    ["new-session", "-d", "-s", plan.sessionName, "-x", "240", "-y", "70"]
                        + ["-n", window.name, "-c", cwd] + printPane)
                : tmux(
                    ["new-window", "-d", "-t", "=\(plan.sessionName):", "-n", window.name]
                        + ["-c", cwd] + printPane)
            guard created.ok, !created.output.isEmpty else {
                if index == 0 {
                    return created.output.isEmpty
                        ? "tmux could not start the session." : created.output
                }
                continue
            }
            // A split's first part keeps the pane it splits; the second part
            // is a new pane beside or below it, sized by the second's share.
            func fill(_ node: NativeTmuxRestorePlan.Node, pane: String) {
                switch node {
                case .pane(_, let active):
                    if active {
                        activePanes.append(pane)
                    }
                case .split(let sideBySide, let ratio, let first, let second):
                    let share = max(5, min(95, Int(((1 - ratio) * 100).rounded())))
                    let split = tmux(
                        ["split-window", "-d", "-t", pane, sideBySide ? "-h" : "-v"]
                            + ["-l", "\(share)%", "-c", folder(firstCwd(second))] + printPane)
                    fill(first, pane: pane)
                    if split.ok, !split.output.isEmpty {
                        fill(second, pane: split.output)
                    }
                }
            }
            fill(window.layout, pane: created.output)
            if window.active {
                activeWindow = created.output
            }
        }
        for pane in activePanes {
            _ = tmux(["select-pane", "-t", pane])
        }
        if let activeWindow {
            _ = tmux(["select-window", "-t", activeWindow])
        }
        return nil
    }

    private static func firstCwd(_ node: NativeTmuxRestorePlan.Node) -> String {
        switch node {
        case .pane(let cwd, _): cwd
        case .split(_, _, let first, _): firstCwd(first)
        }
    }

    /// A folder that is still there, or home.
    private static func folder(_ path: String) -> String {
        var isDirectory: ObjCBool = false
        if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return path
        }
        return NSHomeDirectory()
    }
}

extension TerminalShellViewController {
    /// Keeps the newest plan for a session whose server runs on this Mac.
    func recordTmuxRestorePlan(_ snapshot: TmuxSnapshot, session: NativeTmuxSession) {
        guard !session.executablePath.isEmpty,
            isLocalTmuxEndpoint(socketPath: snapshot.socket_path, serverPid: snapshot.server_pid),
            let plan = NativeTmuxRestorePlan(snapshot, executablePath: session.executablePath)
        else {
            return
        }
        NativeTmuxRestore.save(plan)
    }

    /// Offers to build again a session whose server is gone. False when
    /// there is no plan for it.
    @discardableResult
    func offerTmuxRestore(
        sessionName: String? = nil, socketPath: String? = nil, crashed: Bool
    ) -> Bool {
        guard let plan = NativeTmuxRestore.load(),
            sessionName.map({ $0 == plan.sessionName }) ?? true,
            socketPath.map({ $0 == plan.socketPath }) ?? true
        else {
            return false
        }
        NativeLog.lifecycleInfo(
            "tmux_restore_offered windows=\(plan.windows.count) crashed=\(crashed)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            crashed
            ? "tmux quit unexpectedly" : "tmux session “\(plan.sessionName)” is gone"
        let windows = plan.windows.count == 1 ? "1 window" : "\(plan.windows.count) windows"
        let panes = plan.paneCount == 1 ? "1 pane" : "\(plan.paneCount) panes"
        alert.informativeText =
            "Satin can open “\(plan.sessionName)” again with its \(windows) and \(panes), "
            + "split as they were and in the same folders. "
            + "Programs that were running and their output can't be brought back."
        alert.addButton(withTitle: "Restore Session")
        alert.addButton(withTitle: "Not Now")
        let answer: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.restoreTmuxSession(plan)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
        return true
    }

    func restoreTmuxSession(_ plan: NativeTmuxRestorePlan) {
        let executable =
            FileManager.default.isExecutableFile(atPath: plan.executablePath)
            ? plan.executablePath : resolvedTmuxExecutable?.path
        guard let executable else {
            presentTmuxSessionError("Satin could not resolve the tmux executable.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure = NativeTmuxRestore.build(plan, executable: executable)
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if let failure {
                    NativeLog.runtimeError("tmux_restore_failed message=\(failure)")
                    self.presentTmuxSessionError(failure)
                    return
                }
                NativeLog.lifecycleInfo("tmux_restore_built windows=\(plan.windows.count)")
                self.attachRestoredTmuxSession(plan, executable: executable)
            }
        }
    }

    private func attachRestoredTmuxSession(_ plan: NativeTmuxRestorePlan, executable: String) {
        let resolve: (NativeTmuxExecutable) -> Void = { [weak self] resolved in
            NativeTmuxSessionDiscovery.discover(
                executable: resolved, socketPath: plan.socketPath
            ) { [weak self] result in
                guard let self else {
                    return
                }
                guard case .sessions(let sessions) = result,
                    let descriptor = sessions.first(where: { $0.name == plan.sessionName })
                else {
                    self.presentTmuxSessionError(
                        "Satin built “\(plan.sessionName)” again but could not find it.")
                    return
                }
                self.resolvedTmuxExecutable = resolved
                self.attachTmuxSession(descriptor)
            }
        }
        if let resolved = resolvedTmuxExecutable, resolved.path == executable {
            resolve(resolved)
            return
        }
        NativeTmuxExecutableResolver.shared.resolve(
            configuredPath: executable, shellPath: settings.shellPath
        ) { [weak self] resolution in
            switch resolution {
            case .available(let resolved):
                resolve(resolved)
            case .unavailable(let message):
                self?.presentTmuxSessionError(message)
            }
        }
    }
}

func runNativeTmuxRestoreSelfTests() -> Bool {
    let plan = NativeTmuxRestorePlan(
        sessionName: "work", socketPath: "/tmp/s", executablePath: "/bin/tmux",
        windows: [
            .init(
                name: "edit", active: true,
                layout: .split(
                    sideBySide: true, ratio: 0.6, first: .pane(cwd: "/a", active: false),
                    second: .split(
                        sideBySide: false, ratio: 0.5, first: .pane(cwd: "/b", active: true),
                        second: .pane(cwd: "/c", active: false)))),
            .init(name: "logs", active: false, layout: .pane(cwd: "/d", active: true)),
        ])
    guard let data = try? JSONEncoder().encode(plan),
        let decoded = try? JSONDecoder().decode(NativeTmuxRestorePlan.self, from: data)
    else {
        return false
    }
    return decoded == plan && plan.paneCount == 4
        && NativeTmuxRestore.serverCrashed(reason: "server exited unexpectedly")
        && !NativeTmuxRestore.serverCrashed(reason: nil)
        && !NativeTmuxRestore.serverCrashed(reason: "detached")
}
