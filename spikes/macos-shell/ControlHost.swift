import Foundation

@_silgen_name("satin_control_create")
private func satin_control_create(
    _ path: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_control_destroy")
private func satin_control_destroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_control_wakeup_fd")
private func satin_control_wakeup_fd(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("satin_control_take_request_json")
private func satin_control_take_request_json(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_control_respond")
private func satin_control_respond(
    _ handle: UnsafeMutableRawPointer?,
    _ id: UInt64,
    _ response: UnsafePointer<CChar>?
) -> UInt8

struct NativeControlRequest: Decodable {
    let id: UInt64
    let version: UInt32
    let command: String
    let pane: Int?
    let tab: Int?
    let index: Int?
    let background: Bool?
    let text: String?
    let key: String?
    let status: String?
    let summary: String?
    let timeout_ms: UInt64?
    let cwd: String?
    let axis: String?
    let title: String?
    let theme: String?
    let executable: String?
    let arguments: [String]?
    let environment: [String: String]?
}

private struct NativeControlEnvelope: Decodable {
    let id: UInt64
}

struct NativeControlFailure: Error {
    let code: String
    let message: String
}

typealias NativeControlReply = (Result<Any, NativeControlFailure>) -> Void

final class NativeControlServer {
    var onRequest: ((NativeControlRequest, @escaping NativeControlReply) -> Void)?

    let socketPath: String
    private let handle: UnsafeMutableRawPointer
    private var wakeupSource: DispatchSourceRead?

    init?(socketPath: String) {
        let handle = socketPath.withCString { path in
            satin_control_create(path)
        }
        guard let handle else {
            return nil
        }
        let descriptor = satin_control_wakeup_fd(handle)
        guard descriptor >= 0 else {
            satin_control_destroy(handle)
            return nil
        }
        self.socketPath = socketPath
        self.handle = handle
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: .main
        )
        self.wakeupSource = source
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        source.resume()
    }

    deinit {
        wakeupSource?.cancel()
        satin_control_destroy(handle)
    }

    private func drain() {
        while let pointer = satin_control_take_request_json(handle) {
            let json = String(cString: pointer)
            satin_string_free(pointer)
            guard let data = json.data(using: .utf8) else {
                continue
            }
            guard let request = try? JSONDecoder().decode(
                NativeControlRequest.self,
                from: data
            ) else {
                if let envelope = try? JSONDecoder().decode(
                    NativeControlEnvelope.self,
                    from: data
                ) {
                    respond(
                        id: envelope.id,
                        result: .failure(
                            NativeControlFailure(
                                code: "invalid_request",
                                message: "The control request contains invalid values."
                            )
                        )
                    )
                }
                continue
            }
            guard request.version == 1 else {
                respond(
                    id: request.id,
                    result: .failure(
                        NativeControlFailure(
                            code: "unsupported_version",
                            message: "Unsupported control protocol version."
                        )
                    )
                )
                continue
            }
            guard let onRequest else {
                respond(
                    id: request.id,
                    result: .failure(
                        NativeControlFailure(
                            code: "host_unavailable",
                            message: "The application command router is unavailable."
                        )
                    )
                )
                continue
            }
            onRequest(request) { [weak self] result in
                self?.respond(id: request.id, result: result)
            }
        }
    }

    private func respond(
        id: UInt64,
        result: Result<Any, NativeControlFailure>
    ) {
        let object: [String: Any]
        switch result {
        case let .success(value):
            object = ["ok": true, "result": value]
        case let .failure(error):
            object = [
                "ok": false,
                "error": ["code": error.code, "message": error.message],
            ]
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        json.withCString { value in
            _ = satin_control_respond(handle, id, value)
        }
    }
}

enum NativeControlEnvironment {
    static func socketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["SATIN_CONTROL_SOCKET"]
            ?? ProcessInfo.processInfo.environment["NVTERM_CONTROL_SOCKET"],
           !override.isEmpty {
            return override
        }
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_SCENARIO"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "satin-smoke-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
                .appendingPathComponent("control.sock")
                .path
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Satin", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("control.sock")
            .path
    }

    static func cliPath() -> String {
        let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("satin")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent("target/debug/satin")
        .path
    }

    static func nvimLauncherPath() -> String {
        let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("satin-nvim")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent("target/debug/satin-nvim")
        .path
    }

    static func zshIntegrationPath() -> String {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("ShellIntegration", isDirectory: true)
            .appendingPathComponent("zsh", isDirectory: true)
        if let bundled,
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent(".zshrc").path) {
            return bundled.path
        }
        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent("scripts/shell-integration/zsh", isDirectory: true)
        .path
    }
}
