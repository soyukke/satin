import AppKit
import CoreGraphics
import Darwin
import Foundation
import MetalKit
import OSLog

let nativeApplicationName = Bundle.main.object(
    forInfoDictionaryKey: "CFBundleDisplayName"
) as? String ?? "Satin"
let nativeApplicationDataDirectoryName = Bundle.main.object(
    forInfoDictionaryKey: "SatinDataDirectoryName"
) as? String ?? "Satin"
let nativeIsDevelopmentBuild = Bundle.main.object(
    forInfoDictionaryKey: "SatinDevelopmentBuild"
) as? Bool ?? false

enum NativeLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dev.soyukke.satin"
    private static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    private static let runtime = Logger(subsystem: subsystem, category: "runtime")
    private static let session = Logger(subsystem: subsystem, category: "session")

    static func started() {
        lifecycle.info("application_started")
    }

    static func lifecycleError(_ message: String) {
        lifecycle.error("\(message, privacy: .public)")
    }

    static func lifecycleInfo(_ message: String) {
        lifecycle.info("\(message, privacy: .public)")
    }

    static func runtimeError(_ message: String) {
        runtime.error("\(message, privacy: .public)")
    }

    static func sessionWarning(_ message: String) {
        session.warning("\(message, privacy: .public)")
    }
}

struct AppSemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ rawValue: String) {
        var value = rawValue
        if value.first == "v" {
            value.removeFirst()
        }

        let buildParts = value.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !buildParts[0].isEmpty,
              buildParts.count == 1
                  || Self.validIdentifiers(buildParts[1], rejectNumericLeadingZeroes: false)
        else {
            return nil
        }

        let versionParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let core = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.numericComponent(core[0]),
              let minor = Self.numericComponent(core[1]),
              let patch = Self.numericComponent(core[2])
        else {
            return nil
        }

        let prerelease: [String]
        if versionParts.count == 2 {
            guard Self.validIdentifiers(
                versionParts[1],
                rejectNumericLeadingZeroes: true
            ) else {
                return nil
            }
            prerelease = versionParts[1].split(separator: ".").map(String.init)
        } else {
            prerelease = []
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    static func < (lhs: AppSemanticVersion, rhs: AppSemanticVersion) -> Bool {
        let lhsCore = [lhs.major, lhs.minor, lhs.patch]
        let rhsCore = [rhs.major, rhs.minor, rhs.patch]
        if lhsCore != rhsCore {
            return lhsCore.lexicographicallyPrecedes(rhsCore)
        }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }

        for (lhsIdentifier, rhsIdentifier) in zip(lhs.prerelease, rhs.prerelease) {
            if lhsIdentifier == rhsIdentifier {
                continue
            }
            let lhsNumber = Int(lhsIdentifier)
            let rhsNumber = Int(rhsIdentifier)
            switch (lhsNumber, rhsNumber) {
            case let (.some(lhsValue), .some(rhsValue)):
                return lhsValue < rhsValue
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhsIdentifier < rhsIdentifier
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func numericComponent(_ value: Substring) -> Int? {
        guard !value.isEmpty,
              value.allSatisfy(\.isNumber),
              value.count == 1 || value.first != "0"
        else {
            return nil
        }
        return Int(value)
    }

    private static func validIdentifiers(
        _ value: Substring,
        rejectNumericLeadingZeroes: Bool
    ) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !identifiers.isEmpty else {
            return false
        }
        return identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty else {
                return false
            }
            let validCharacters = identifier.utf8.allSatisfy { character in
                (48...57).contains(character)
                    || (65...90).contains(character)
                    || (97...122).contains(character)
                    || character == 45
            }
            let numericLeadingZero = rejectNumericLeadingZeroes
                && identifier.count > 1
                && identifier.first == "0"
                && identifier.allSatisfy(\.isNumber)
            return validCharacters && !numericLeadingZero
        }
    }
}

struct AvailableAppUpdate {
    let version: String
    let archiveName: String
    let archiveSize: Int64
    let downloadURL: URL
    let manifestURL: URL
    let releaseNotesURL: URL
}

enum AppUpdateResult {
    case current
    case available(AvailableAppUpdate)
}

enum AppUpdateError: LocalizedError {
    case invalidCurrentVersion
    case invalidEndpoint
    case invalidResponse
    case invalidRelease
    case responseTooLarge
    case serverStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion:
            return "The installed application version is unavailable."
        case .invalidEndpoint:
            return "The update service URL is invalid."
        case .invalidResponse:
            return "GitHub returned invalid signed update metadata."
        case .invalidRelease:
            return "The latest update manifest has invalid release metadata."
        case .responseTooLarge:
            return "The update response exceeded the allowed size."
        case let .serverStatus(status):
            return "GitHub returned HTTP status \(status)."
        }
    }
}

final class AppUpdateChecker {
    private static let repositoryPath = "/soyukke/satin"
    private static let maximumResponseBytes = 65_536
    private let endpoint: URL
    private let session: URLSession

    init(
        endpoint: URL? = URL(
            string: "https://github.com/soyukke/satin/releases/latest/download/latest.json"
        ),
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint ?? URL(fileURLWithPath: "/invalid-update-endpoint")
        self.session = session
    }

    @discardableResult
    func check(
        currentVersion: String,
        completion: @escaping (Result<AppUpdateResult, Error>) -> Void
    ) -> URLSessionDataTask? {
        guard endpoint.scheme == "https",
              endpoint.host == "github.com",
              endpoint.path == Self.repositoryPath + "/releases/latest/download/latest.json",
              endpoint.query == nil,
              endpoint.fragment == nil
        else {
            completion(.failure(AppUpdateError.invalidEndpoint))
            return nil
        }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: 15
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Satin/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                completion(.failure(AppUpdateError.invalidResponse))
                return
            }
            guard response.url?.scheme == "https",
                  let responseHost = response.url?.host,
                  responseHost == "github.com"
                    || responseHost == "release-assets.githubusercontent.com"
            else {
                completion(.failure(AppUpdateError.invalidResponse))
                return
            }
            guard response.statusCode == 200 else {
                completion(.failure(AppUpdateError.serverStatus(response.statusCode)))
                return
            }
            guard let data else {
                completion(.failure(AppUpdateError.invalidResponse))
                return
            }
            guard data.count <= Self.maximumResponseBytes else {
                completion(.failure(AppUpdateError.responseTooLarge))
                return
            }

            do {
                completion(.success(try Self.evaluate(data: data, currentVersion: currentVersion)))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
        return task
    }

    static func evaluate(data: Data, currentVersion: String) throws -> AppUpdateResult {
        guard let current = AppSemanticVersion(currentVersion) else {
            throw AppUpdateError.invalidCurrentVersion
        }
        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            throw AppUpdateError.invalidResponse
        }
        guard let latest = AppSemanticVersion(manifest.version)
        else {
            throw AppUpdateError.invalidRelease
        }
        let version = manifest.version
        let tagName = "v\(version)"
        let expectedAssetName = "Satin-\(version)-macOS-arm64.zip"
        let expectedAssetPath = Self.repositoryPath
            + "/releases/download/\(tagName)/\(expectedAssetName)"
        guard let expectedDownloadURL = URL(
            string: "https://github.com\(expectedAssetPath)"
        ),
            let manifestURL = URL(
                string: "https://github.com\(Self.repositoryPath)"
                    + "/releases/download/\(tagName)/latest.json"
            ),
            let releaseNotesURL = URL(
                string: "https://github.com\(Self.repositoryPath)"
                    + "/releases/tag/\(tagName)"
            )
        else {
            throw AppUpdateError.invalidRelease
        }
        guard manifest.schemaVersion == 2,
              !manifest.build.isEmpty,
              manifest.channel == "development" || manifest.channel == "production",
              manifest.architecture == "arm64",
              manifest.archive == expectedAssetName,
              manifest.archiveSize > 0,
              manifest.archiveSize <= 536_870_912,
              manifest.downloadURL == expectedDownloadURL,
              manifest.sha256.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil,
              manifest.signature.algorithm == "ed25519",
              !manifest.signature.keyID.isEmpty,
              Data(base64Encoded: manifest.signature.value)?.count == 64
        else {
            throw AppUpdateError.invalidRelease
        }
        guard current < latest else {
            return .current
        }
        return .available(
            AvailableAppUpdate(
                version: version,
                archiveName: expectedAssetName,
                archiveSize: manifest.archiveSize,
                downloadURL: expectedDownloadURL,
                manifestURL: manifestURL,
                releaseNotesURL: releaseNotesURL
            )
        )
    }

    static func runSelfTests() -> Bool {
        guard let prerelease = AppSemanticVersion("1.2.3-beta.2"),
              let laterPrerelease = AppSemanticVersion("1.2.3-beta.11"),
              let release = AppSemanticVersion("v1.2.3"),
              let nextPatch = AppSemanticVersion("1.2.4"),
              prerelease < laterPrerelease,
              laterPrerelease < release,
              release < nextPatch,
              AppSemanticVersion("01.2.3") == nil,
              AppSemanticVersion("1.2.3-beta.01") == nil
        else {
            return false
        }

        let response = """
        {
          "schemaVersion": 2,
          "version": "1.2.4",
          "build": "1",
          "channel": "development",
          "minimumMacOS": "14.0",
          "architecture": "arm64",
          "archive": "Satin-1.2.4-macOS-arm64.zip",
          "archiveSize": 1024,
          "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
          "downloadURL": "https://github.com/soyukke/satin/releases/download/v1.2.4/Satin-1.2.4-macOS-arm64.zip",
          "notarized": false,
          "signature": {
            "algorithm": "ed25519",
            "keyID": "self-test",
            "value": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
          }
        }
        """
        let invalidResponse = response.replacingOccurrences(
            of: "https://github.com/soyukke/satin/releases/download/",
            with: "https://example.com/soyukke/satin/releases/download/"
        )
        guard let data = response.data(using: .utf8),
              let invalidData = invalidResponse.data(using: .utf8),
              case let .available(update) = try? evaluate(
                  data: data,
                  currentVersion: "1.2.3"
              ),
              update.version == "1.2.4",
              update.archiveSize == 1024,
              update.manifestURL.path
                == "/soyukke/satin/releases/download/v1.2.4/latest.json",
              case .current = try? evaluate(data: data, currentVersion: "1.2.4"),
              case nil = try? evaluate(data: invalidData, currentVersion: "1.2.3")
        else {
            return false
        }
        return true
    }

    static func runLiveSmoke(currentVersion: String, expected: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var observed = ""
        let task = AppUpdateChecker().check(currentVersion: currentVersion) { result in
            let value: String
            switch result {
            case .success(.current):
                value = "current"
            case let .success(.available(update)):
                value = "available:\(update.version)"
            case let .failure(error):
                value = "error:\(error.localizedDescription)"
            }
            lock.lock()
            observed = value
            lock.unlock()
            semaphore.signal()
        }
        guard task != nil,
              semaphore.wait(timeout: .now() + 30) == .success
        else {
            task?.cancel()
            fputs("update live smoke timed out\n", stderr)
            return false
        }
        lock.lock()
        let result = observed
        lock.unlock()
        guard result == expected else {
            fputs(
                "update live smoke expected \(expected), observed \(result)\n",
                stderr
            )
            return false
        }
        print("update live smoke passed: \(result)")
        return true
    }
}

@_silgen_name("satin_core_create")
func satin_core_create() -> UnsafeMutableRawPointer?

@_silgen_name("satin_core_create_with_theme")
func satin_core_create_with_theme(_ theme: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

@_silgen_name("satin_core_destroy")
func satin_core_destroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_core_new_tab")
func satin_core_new_tab(_ handle: UnsafeMutableRawPointer?) -> Int

@_silgen_name("satin_core_split_active")
func satin_core_split_active(_ handle: UnsafeMutableRawPointer?, _ axis: UInt32) -> Int

@_silgen_name("satin_core_close_pane")
func satin_core_close_pane(_ handle: UnsafeMutableRawPointer?, _ paneId: Int) -> UInt8

@_silgen_name("satin_core_select_tab")
func satin_core_select_tab(_ handle: UnsafeMutableRawPointer?, _ index: Int) -> UInt8

@_silgen_name("satin_core_move_tab")
func satin_core_move_tab(_ handle: UnsafeMutableRawPointer?, _ tabId: Int, _ index: Int) -> UInt8

@_silgen_name("satin_core_select_pane")
func satin_core_select_pane(_ handle: UnsafeMutableRawPointer?, _ paneId: Int) -> UInt8

@_silgen_name("satin_core_rename_tab")
func satin_core_rename_tab(
    _ handle: UnsafeMutableRawPointer?,
    _ index: Int,
    _ title: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_core_set_tab_theme")
func satin_core_set_tab_theme(
    _ handle: UnsafeMutableRawPointer?,
    _ index: Int,
    _ theme: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_core_set_default_theme")
func satin_core_set_default_theme(
    _ handle: UnsafeMutableRawPointer?,
    _ theme: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_core_snapshot_json")
func satin_core_snapshot_json(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_core_apply_workspace_json")
func satin_core_apply_workspace_json(
    _ handle: UnsafeMutableRawPointer?,
    _ workspace: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_runtime_create")
func satin_runtime_create(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_runtime_create_in_cwd")
func satin_runtime_create_in_cwd(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16,
    _ cwd: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_runtime_create_config")
func satin_runtime_create_config(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16,
    _ config: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_runtime_create_external")
func satin_runtime_create_external(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_runtime_destroy")
func satin_runtime_destroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_runtime_resize")
func satin_runtime_resize(
    _ handle: UnsafeMutableRawPointer?,
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UInt8

@_silgen_name("satin_runtime_write")
func satin_runtime_write(
    _ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ len: Int
) -> UInt8

@_silgen_name("satin_runtime_key")
func satin_runtime_key(
    _ handle: UnsafeMutableRawPointer?,
    _ keyCode: UInt16,
    _ modifiers: UInt32,
    _ text: UnsafePointer<UInt8>?,
    _ textLength: Int,
    _ unshifted: UnsafePointer<UInt8>?,
    _ unshiftedLength: Int,
    _ repeated: UInt8,
    _ released: UInt8
) -> UInt8

@_silgen_name("satin_runtime_text")
func satin_runtime_text(
    _ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_paste")
func satin_runtime_paste(
    _ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_take_tmux_event_json")
func satin_runtime_take_tmux_event_json(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_tmux_command")
func satin_runtime_tmux_command(
    _ handle: UnsafeMutableRawPointer?,
    _ command: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_runtime_tmux_feed_pane")
func satin_runtime_tmux_feed_pane(
    _ pane: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_tmux_shell_prompt_state")
func satin_runtime_tmux_shell_prompt_state(
    _ pane: UnsafeMutableRawPointer?
) -> UInt8

@_silgen_name("satin_runtime_tmux_semantic_prompt_seen")
func satin_runtime_tmux_semantic_prompt_seen(
    _ pane: UnsafeMutableRawPointer?
) -> UInt8

@_silgen_name("satin_runtime_tmux_prompt_generation")
func satin_runtime_tmux_prompt_generation(
    _ pane: UnsafeMutableRawPointer?
) -> UInt64

@_silgen_name("satin_runtime_tmux_reset_prompt_tracking")
func satin_runtime_tmux_reset_prompt_tracking(
    _ pane: UnsafeMutableRawPointer?
) -> UInt8

@_silgen_name("satin_runtime_tmux_key")
func satin_runtime_tmux_key(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ keyCode: UInt16,
    _ modifiers: UInt32,
    _ text: UnsafePointer<UInt8>?,
    _ textLength: Int,
    _ unshifted: UnsafePointer<UInt8>?,
    _ unshiftedLength: Int,
    _ repeated: UInt8,
    _ released: UInt8
) -> UInt8

@_silgen_name("satin_runtime_tmux_write")
func satin_runtime_tmux_write(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_tmux_paste")
func satin_runtime_tmux_paste(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_tmux_mouse")
func satin_runtime_tmux_mouse(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ action: UInt32,
    _ button: Int32,
    _ modifiers: UInt32,
    _ x: Float,
    _ y: Float,
    _ cellWidth: UInt32,
    _ cellHeight: UInt32
) -> UInt8

@_silgen_name("satin_runtime_tmux_focus")
func satin_runtime_tmux_focus(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ focused: UInt8
) -> UInt8

@_silgen_name("satin_runtime_mouse")
func satin_runtime_mouse(
    _ handle: UnsafeMutableRawPointer?,
    _ action: UInt32,
    _ button: Int32,
    _ modifiers: UInt32,
    _ x: Float,
    _ y: Float,
    _ cellWidth: UInt32,
    _ cellHeight: UInt32
) -> UInt8

@_silgen_name("satin_runtime_focus")
func satin_runtime_focus(
    _ handle: UnsafeMutableRawPointer?,
    _ focused: UInt8
) -> UInt8

@_silgen_name("satin_runtime_select")
func satin_runtime_select(
    _ handle: UnsafeMutableRawPointer?,
    _ startRow: UInt32,
    _ startCol: UInt16,
    _ endRow: UInt32,
    _ endCol: UInt16,
    _ rectangular: UInt8
) -> UInt8

@_silgen_name("satin_runtime_select_all")
func satin_runtime_select_all(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_clear_selection")
func satin_runtime_clear_selection(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_selected_text")
func satin_runtime_selected_text(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_hyperlink")
func satin_runtime_hyperlink(
    _ handle: UnsafeMutableRawPointer?,
    _ row: UInt32,
    _ col: UInt16
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_title")
func satin_runtime_title(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_take_bell_count")
func satin_runtime_take_bell_count(_ handle: UnsafeMutableRawPointer?) -> UInt64

@_silgen_name("satin_runtime_find")
func satin_runtime_find(
    _ handle: UnsafeMutableRawPointer?,
    _ query: UnsafePointer<CChar>?,
    _ backwards: UInt8
) -> UInt8

@_silgen_name("satin_runtime_set_option_as_alt")
func satin_runtime_set_option_as_alt(
    _ handle: UnsafeMutableRawPointer?,
    _ enabled: UInt8
) -> UInt8

@_silgen_name("satin_runtime_drain")
func satin_runtime_drain(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_exited")
func satin_runtime_exited(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_wakeup_fd")
func satin_runtime_wakeup_fd(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("satin_runtime_scroll")
func satin_runtime_scroll(_ handle: UnsafeMutableRawPointer?, _ requestedRows: Int) -> Int

@_silgen_name("satin_runtime_renderer_scroll_position")
func satin_runtime_renderer_scroll_position(_ handle: UnsafeMutableRawPointer?) -> Float

@_silgen_name("satin_runtime_cursor_position")
func satin_runtime_cursor_position(_ handle: UnsafeMutableRawPointer?) -> UInt32

@_silgen_name("satin_runtime_cwd")
func satin_runtime_cwd(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_screen_text")
func satin_runtime_screen_text(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_kitty_placement_count")
func satin_runtime_kitty_placement_count(_ handle: UnsafeMutableRawPointer?) -> Int

@_silgen_name("satin_nvim_create")
func satin_nvim_create(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_nvim_create_in_cwd")
func satin_nvim_create_in_cwd(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16,
    _ cwd: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_nvim_create_with_config")
func satin_nvim_create_with_config(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16,
    _ configuration: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_nvim_destroy")
func satin_nvim_destroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_nvim_resize")
func satin_nvim_resize(
    _ handle: UnsafeMutableRawPointer?,
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UInt8

@_silgen_name("satin_nvim_input")
func satin_nvim_input(
    _ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ len: Int
) -> UInt8

@_silgen_name("satin_nvim_mouse")
func satin_nvim_mouse(
    _ handle: UnsafeMutableRawPointer?,
    _ button: UnsafePointer<CChar>?,
    _ action: UnsafePointer<CChar>?,
    _ modifier: UnsafePointer<CChar>?,
    _ grid: Int64,
    _ row: Int64,
    _ col: Int64
) -> UInt8

@_silgen_name("satin_nvim_take_message_selection_text")
func satin_nvim_take_message_selection_text(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_nvim_command")
func satin_nvim_command(
    _ handle: UnsafeMutableRawPointer?,
    _ command: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_nvim_drain")
func satin_nvim_drain(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_nvim_exited")
func satin_nvim_exited(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_nvim_exit_code")
func satin_nvim_exit_code(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("satin_nvim_wakeup_fd")
func satin_nvim_wakeup_fd(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("satin_nvim_kitty_placement_count")
func satin_nvim_kitty_placement_count(_ handle: UnsafeMutableRawPointer?) -> Int

@_silgen_name("satin_nvim_renderer_model_json")
func satin_nvim_renderer_model_json(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_string_free")
func satin_string_free(_ value: UnsafeMutablePointer<CChar>?)

@_silgen_name("satin_skia_metal_create")
func satin_skia_metal_create(
    _ device: UnsafeMutableRawPointer?,
    _ commandQueue: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_skia_metal_destroy")
func satin_skia_metal_destroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_skia_metal_render_nvim")
func satin_skia_metal_render_nvim(
    _ renderer: UnsafeMutableRawPointer?,
    _ nvim: UnsafeMutableRawPointer?,
    _ texture: UnsafeMutableRawPointer?,
    _ width: Int32,
    _ height: Int32,
    _ originX: Float,
    _ originY: Float,
    _ contentWidth: Float,
    _ contentHeight: Float,
    _ cellWidth: Float,
    _ cellHeight: Float,
    _ clear: UInt8
) -> UInt8

@_silgen_name("satin_skia_metal_render_terminal")
func satin_skia_metal_render_terminal(
    _ renderer: UnsafeMutableRawPointer?,
    _ runtime: UnsafeMutableRawPointer?,
    _ texture: UnsafeMutableRawPointer?,
    _ width: Int32,
    _ height: Int32,
    _ originX: Float,
    _ originY: Float,
    _ contentWidth: Float,
    _ contentHeight: Float,
    _ cellWidth: Float,
    _ cellHeight: Float,
    _ clear: UInt8
) -> UInt8

@_silgen_name("satin_skia_metal_needs_animation_frame")
func satin_skia_metal_needs_animation_frame(_ renderer: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_skia_metal_forget_runtime")
func satin_skia_metal_forget_runtime(
    _ renderer: UnsafeMutableRawPointer?,
    _ runtime: UnsafeMutableRawPointer?
)

@_silgen_name("satin_skia_metal_set_font_family")
func satin_skia_metal_set_font_family(
    _ renderer: UnsafeMutableRawPointer?,
    _ family: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_skia_metal_next_frame_delay_ms")
func satin_skia_metal_next_frame_delay_ms(_ renderer: UnsafeMutableRawPointer?) -> UInt64

private let ffiSplitVertical: UInt32 = 0
private let ffiSplitHorizontal: UInt32 = 1
private let terminalHorizontalInset: CGFloat = 12
private let terminalTextTop: CGFloat = 12
private let terminalTextBottomInset: CGFloat = 10
private let defaultTerminalFontSize = CGFloat(nativeDefaultFontSize)
private let minTerminalFontSize = CGFloat(nativeMinimumFontSize)
private let maxTerminalFontSize = CGFloat(nativeMaximumFontSize)
private let maxOutputScrollAnimationRows = 12
private let maxTerminalBottomInputSmokePosition = 0.1
private let maxNvimCursorMoveSmokeGrowth = 0.001
private let nvimStartupCommandDelay: TimeInterval = 0.4
private let nvimStartupCwdCorrectionDelay: TimeInterval = 1.0
private let nvimSmokeReadyMarker = "NVSMOKE_READY"
private let nvimJumpBaselineDelay: TimeInterval = 0.5
private let themeAccentColors: [String: NSColor] = [
    "Graphite": NSColor(calibratedRed: 0.54, green: 0.56, blue: 0.62, alpha: 1.0),
    "Juniper": NSColor(calibratedRed: 0.18, green: 0.62, blue: 0.43, alpha: 1.0),
    "Harbor": NSColor(deviceRed: 0.10, green: 0.50, blue: 0.82, alpha: 1.0),
    "Rose": NSColor(calibratedRed: 0.78, green: 0.32, blue: 0.48, alpha: 1.0),
    "Paper": NSColor(calibratedRed: 0.78, green: 0.57, blue: 0.26, alpha: 1.0),
]
private let currentSessionSchemaVersion = 3

struct NativeSessionState: Codable {
    let schemaVersion: Int
    let activeTab: Int
    let tabs: [NativeSessionTab]
    let tmuxAttachment: NativeTmuxAttachment?

    init(
        schemaVersion: Int,
        activeTab: Int,
        tabs: [NativeSessionTab],
        tmuxAttachment: NativeTmuxAttachment? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.activeTab = activeTab
        self.tabs = tabs
        self.tmuxAttachment = tmuxAttachment
    }
}

struct NativeTmuxAttachment: Codable, Equatable {
    let sessionName: String
    let socketPath: String
}

struct NativeTmuxSessionDescriptor: Equatable {
    let name: String
    let windowCount: Int
    let socketPath: String
}

enum NativeTmuxSessionDiscovery {
    static func sessions(socketPath: String?) -> [NativeTmuxSessionDescriptor] {
        guard let executable = executableURL() else {
            return []
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var arguments: [String] = []
        if let socketPath, !socketPath.isEmpty {
            arguments += ["-S", socketPath]
        }
        arguments += [
            "list-sessions",
            "-F",
            "#{session_name}\t#{session_windows}\t#{socket_path}",
        ]
        process.arguments = arguments

        do {
            try process.run()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return []
        }
        guard let value = String(data: data, encoding: .utf8) else {
            return []
        }
        return value.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let windowCount = Int(fields[1]),
                  !fields[0].isEmpty,
                  !fields[2].isEmpty
            else {
                return nil
            }
            return NativeTmuxSessionDescriptor(
                name: String(fields[0]),
                windowCount: windowCount,
                socketPath: String(fields[2])
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func executableURL() -> URL? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirectories = environmentPath.split(separator: ":").map(String.init)
        let fallbackDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/run/current-system/sw/bin",
            "/nix/var/nix/profiles/default/bin",
            "/usr/bin",
        ]
        for directory in pathDirectories + fallbackDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("tmux")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

final class TmuxSessionPopoverController: NSViewController, NSSearchFieldDelegate {
    var onSelectLocal: (() -> Void)?
    var onSelectSession: ((NativeTmuxSessionDescriptor) -> Void)?
    var onCreateSession: ((String) -> Void)?

    private let sessions: [NativeTmuxSessionDescriptor]
    private let currentSessionName: String?
    private let searchField = NSSearchField(frame: .zero)
    private let rows = NSStackView()
    private let newSessionButton = NSButton(frame: .zero)
    private let nameField = NSTextField(frame: .zero)
    private let createButton = NSButton(frame: .zero)
    private let creationRow = NSStackView()
    private let validationLabel = NSTextField(labelWithString: "")

    init(sessions: [NativeTmuxSessionDescriptor], currentSessionName: String?) {
        self.sessions = sessions
        self.currentSessionName = currentSessionName
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(
            width: 320,
            height: Self.preferredHeight(rowCount: sessions.count)
        )
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
        searchField.isHidden = sessions.count <= 5

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        refreshSessionRows()

        configureRowButton(
            newSessionButton,
            title: "New tmux Session…",
            symbol: "plus",
            action: #selector(beginCreatingSession(_:))
        )

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
            heading,
            searchField,
            rows,
            separator,
            newSessionButton,
            creationRow,
            validationLabel,
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
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            newSessionButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            creationRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            validationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
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
        let filtered = query.isEmpty
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
        for descriptor in filtered {
            let button = NSButton(frame: .zero)
            let suffix = descriptor.windowCount == 1 ? "1 window" : "\(descriptor.windowCount) windows"
            let symbol = descriptor.name == currentSessionName ? "checkmark.circle.fill" : "rectangle.stack"
            configureRowButton(
                button,
                title: "\(descriptor.name)  ·  \(suffix)",
                symbol: symbol,
                action: #selector(selectSession(_:))
            )
            button.tag = sessions.firstIndex(of: descriptor) ?? -1
            rows.addArrangedSubview(button)
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
        return CGFloat(visibleRows * 30 + (rowCount > 5 ? 114 : 74))
    }
}

struct NativeSessionTab: Codable {
    let title: String
    let theme: String
    let layout: NativeSessionPane
}

final class NativeSessionPane: Codable {
    let kind: String
    let axis: String?
    let paneMode: String?
    let cwd: String
    let active: Bool
    let first: NativeSessionPane?
    let second: NativeSessionPane?

    init(
        kind: String,
        axis: String? = nil,
        paneMode: String? = nil,
        cwd: String = "",
        active: Bool = false,
        first: NativeSessionPane? = nil,
        second: NativeSessionPane? = nil
    ) {
        self.kind = kind
        self.axis = axis
        self.paneMode = paneMode
        self.cwd = cwd
        self.active = active
        self.first = first
        self.second = second
    }
}

struct LegacyNativeSessionState: Codable {
    let activeTab: Int
    let tabs: [LegacyNativeSessionTab]
}

struct LegacyNativeSessionTab: Codable {
    let title: String
    let theme: String
    let cwd: String
}

struct TerminalCoreSnapshot: Codable {
    let active_tab: Int
    let tabs: [TerminalCoreTabSnapshot]
}

struct TerminalCoreTabSnapshot: Codable {
    let id: Int
    let index: Int
    let title: String
    let active_pane: Int
    let theme: String
    let panes: [Int]
    let layout: PaneLayoutSnapshot
}

final class PaneLayoutSnapshot: Codable {
    let kind: String
    let pane_id: Int?
    let axis: String?
    let ratio: Double?
    let first: PaneLayoutSnapshot?
    let second: PaneLayoutSnapshot?

    init(
        kind: String,
        paneId: Int? = nil,
        axis: String? = nil,
        ratio: Double? = nil,
        first: PaneLayoutSnapshot? = nil,
        second: PaneLayoutSnapshot? = nil
    ) {
        self.kind = kind
        self.pane_id = paneId
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

struct TmuxControlEvent: Decodable {
    let kind: String
    let pane_id: UInt32?
    let data: [UInt8]?
    let snapshot: TmuxSnapshot?
    let reason: String?
    let message: String?
}

struct TmuxSnapshot: Decodable {
    let session_id: UInt32
    let session_name: String
    let socket_path: String
    let server_pid: UInt32
    let active_window_id: UInt32
    let windows: [TmuxWindowSnapshot]
}

struct TmuxWindowSnapshot: Decodable {
    let window_id: UInt32
    let index: UInt32
    let name: String
    let active_pane_id: UInt32
    let zoomed: Bool
    let layout: TmuxLayoutSnapshot
    let panes: [TmuxPaneSnapshot]
}

struct TmuxPaneSnapshot: Decodable {
    let pane_id: UInt32
    let index: UInt32
    let active: Bool
    let current_path: String
    let cols: UInt16
    let rows: UInt16
    let cursor_x: UInt16
    let cursor_y: UInt16
    let cursor_visible: Bool
    let origin_mode: Bool
    let scroll_region_upper: UInt16
    let current_command: String
}

final class TmuxLayoutSnapshot: Decodable {
    let kind: String
    let pane_id: UInt32?
    let axis: String?
    let ratio: Double?
    let first: TmuxLayoutSnapshot?
    let second: TmuxLayoutSnapshot?
}

struct NeovideRendererModelSnapshot: Decodable {
    let background: TerminalColorSnapshot
    let cursor: TerminalCursorSnapshot?
    let cursor_parent_grid_id: Int?
    let message_selection: NeovideMessageSelectionSnapshot?
    let scrollbar: ScrollbarSnapshot?
    let scroll_hint: FrameScrollHint?
    let windows: [NeovideRenderedWindowSnapshot]
}

struct NeovideMessageSelectionSnapshot: Decodable {
    let grid_id: Int
    let start: NeovideGridPositionSnapshot
    let end: NeovideGridPositionSnapshot
}

struct NeovideGridPositionSnapshot: Decodable {
    let row: Int
    let col: Int
}

struct ScrollbarSnapshot: Decodable {
    let top: UInt64
    let visible: UInt64
    let total: UInt64
}

struct NeovideRenderedWindowSnapshot: Decodable {
    let grid_id: Int
    let top: Int
    let left: Int
    let width: Int
    let height: Int
    let window_kind: String
    let zindex: Int
    let compindex: Int
    let hidden: Bool
    let scroll_position: Double
    let lines: [NeovideLineSnapshot?]
}

struct NeovideLineSnapshot: Decodable {
    let text: String
    let cells: [TerminalCellSnapshot]
}

struct TerminalCellSnapshot: Decodable {
    let text: String
    let bg: TerminalColorSnapshot?
    let blend: UInt8
}

struct TerminalColorSnapshot: Decodable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

struct TerminalCursorSnapshot: Decodable {
    let x: UInt16
    let y: UInt16
    let style: String
    let cell_percentage: UInt8
    let blinkwait_ms: UInt64
    let blinkon_ms: UInt64
    let blinkoff_ms: UInt64
}

struct FrameScrollHint: Decodable {
    let start_row: Int
    let end_row: Int
    let start_col: Int?
    let end_col: Int?
    let rows: Int

    var outputShift: OutputScrollShift {
        OutputScrollShift(
            startRow: start_row,
            endRow: end_row,
            rows: rows,
            startCol: start_col,
            endCol: end_col
        )
    }
}

struct OutputScrollShift {
    let startRow: Int
    let endRow: Int
    let startCol: Int?
    let endCol: Int?
    let rows: Int

    init(startRow: Int, endRow: Int, rows: Int, startCol: Int? = nil, endCol: Int? = nil) {
        self.startRow = startRow
        self.endRow = endRow
        self.startCol = startCol
        self.endCol = endCol
        self.rows = rows
    }
}

struct SkiaRenderGeometry {
    let originX: Float
    let originY: Float
    let contentWidth: Float
    let contentHeight: Float
    let cellWidth: Float
    let cellHeight: Float
}

final class RustCore {
    private let handle: UnsafeMutableRawPointer

    init?(defaultTheme: String = nativeThemeNames[0]) {
        let handle = defaultTheme.withCString { value in
            satin_core_create_with_theme(value)
        }
        guard let handle else {
            return nil
        }
        self.handle = handle
    }

    deinit {
        satin_core_destroy(handle)
    }

    func snapshot() -> TerminalCoreSnapshot? {
        decode(satin_core_snapshot_json(handle), as: TerminalCoreSnapshot.self)
    }

    func applyWorkspace(_ snapshot: TerminalCoreSnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot),
              let json = String(data: data, encoding: .utf8)
        else {
            return false
        }
        return json.withCString { value in
            satin_core_apply_workspace_json(handle, value) != 0
        }
    }

    @discardableResult
    func newTab() -> Int {
        satin_core_new_tab(handle)
    }

    func splitActive(axis: UInt32) -> Int? {
        let paneId = satin_core_split_active(handle, axis)
        return paneId >= 0 ? paneId : nil
    }

    func closePane(_ paneId: Int) -> Bool {
        satin_core_close_pane(handle, paneId) != 0
    }

    func selectTab(_ index: Int) -> Bool {
        satin_core_select_tab(handle, index) != 0
    }

    func moveTab(_ tabId: Int, to index: Int) -> Bool {
        satin_core_move_tab(handle, tabId, index) != 0
    }

    func selectPane(_ paneId: Int) -> Bool {
        satin_core_select_pane(handle, paneId) != 0
    }

    func renameTab(_ index: Int, title: String) {
        title.withCString { value in
            _ = satin_core_rename_tab(handle, index, value)
        }
    }

    func setTheme(_ theme: String, tab index: Int) {
        theme.withCString { value in
            _ = satin_core_set_tab_theme(handle, index, value)
        }
    }

    func setDefaultTheme(_ theme: String) {
        theme.withCString { value in
            _ = satin_core_set_default_theme(handle, value)
        }
    }

    private func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, as type: T.Type) -> T? {
        guard let pointer else {
            return nil
        }
        defer {
            satin_string_free(pointer)
        }

        let json = String(cString: pointer)
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            NativeLog.runtimeError("core_snapshot_decode_failed error=\(error)")
            return nil
        }
    }
}

protocol NativePane: AnyObject {
    var kind: NativePaneMode { get }

    func resize(grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int))
    func write(_ data: Data)
    func drain() -> Bool
    func isExited() -> Bool
    func wakeupFD() -> Int32
    func renderHandle() -> UnsafeMutableRawPointer?
    func controlScreenText() -> String
    func controlImageCount() -> Int
}

struct NativeTerminalSpawnConfiguration: Encodable {
    let cwd: String?
    let shell: String?
    let environment: [String: String]
    let startup_command: [String]
}

struct NativeFinderEditorLaunch {
    let paths: [String]
    let workingDirectory: String

    init?(paths: [String]) {
        var seen = Set<String>()
        var normalized: [String] = []
        var totalBytes = 0
        for path in paths {
            guard (path as NSString).isAbsolutePath else {
                continue
            }
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: resolved),
                  resolved.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }),
                  seen.insert(resolved).inserted
            else {
                continue
            }
            guard normalized.count < 254 else {
                return nil
            }
            totalBytes += resolved.utf8.count
            guard totalBytes <= 12 * 1_024 else {
                return nil
            }
            normalized.append(resolved)
        }
        guard let first = normalized.first else {
            return nil
        }
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: first, isDirectory: &isDirectory)
        self.paths = normalized
        self.workingDirectory = isDirectory.boolValue
            ? first
            : URL(fileURLWithPath: first).deletingLastPathComponent().path
    }

    func startupCommand(editor: String) -> [String] {
        [editor, "--"] + paths
    }

    static func runSelfTests() -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("satin-finder-launch-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("file with spaces.txt")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("finder launch".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: root) }
            guard let launch = Self(paths: [file.path, file.path]) else {
                return false
            }
            return launch.paths == [file.path]
                && launch.workingDirectory == root.path
                && launch.startupCommand(editor: "nvim") == ["nvim", "--", file.path]
                && Self(paths: [root.path])?.workingDirectory == root.path
                && Self(paths: ["relative.txt"]) == nil
        } catch {
            return false
        }
    }
}

struct NativeNeovimLaunchConfiguration: Encodable {
    let cwd: String?
    let executable: String?
    let arguments: [String]
    let environment: [String: String]
}

struct NativeMouseInput {
    let button: String
    let action: String
    let modifier: String
    let grid: Int64
    let row: Int64
    let col: Int64
    var surfaceX: Float = 0
    var surfaceY: Float = 0
    var cellWidth: UInt32 = 1
    var cellHeight: UInt32 = 1
}

enum NativeMouseHandling: Equatable {
    case unhandled
    case handled
    case messageSelection
}

enum NativePaneMode: Equatable {
    case terminal
    case neovim

    static func current() -> Self {
        ProcessInfo.processInfo.environment["SATIN_NATIVE_PANE"] == "nvim" ? .neovim : .terminal
    }

    init(sessionValue: String?) {
        self = sessionValue == "neovim" ? .neovim : .terminal
    }

    var sessionValue: String {
        switch self {
        case .terminal:
            "terminal"
        case .neovim:
            "neovim"
        }
    }
}

class RustTerminalPane: NativePane {
    let kind = NativePaneMode.terminal
    fileprivate let handle: UnsafeMutableRawPointer

    init?(
        grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
        cwd: String? = nil,
        shell: String? = nil,
        environment: [String: String] = [:],
        startupCommand: [String] = []
    ) {
        let configuration = NativeTerminalSpawnConfiguration(
            cwd: cwd,
            shell: shell?.isEmpty == false ? shell : nil,
            environment: environment,
            startup_command: startupCommand
        )
        guard let data = try? JSONEncoder().encode(configuration),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let handle = json.withCString { value in
            satin_runtime_create_config(
                clampedUInt16(grid.rows),
                clampedUInt16(grid.cols),
                clampedUInt16(grid.widthPixels),
                clampedUInt16(grid.heightPixels),
                value
            )
        }
        guard let handle else {
            NativeLog.runtimeError("terminal_runtime_create_failed")
            return nil
        }
        self.handle = handle
    }

    fileprivate init(externalHandle: UnsafeMutableRawPointer) {
        self.handle = externalHandle
    }

    deinit {
        satin_runtime_destroy(handle)
    }

    func resize(grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int)) {
        _ = satin_runtime_resize(
            handle,
            clampedUInt16(grid.rows),
            clampedUInt16(grid.cols),
            clampedUInt16(grid.widthPixels),
            clampedUInt16(grid.heightPixels)
        )
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            _ = satin_runtime_write(handle, base, buffer.count)
        }
    }

    func key(_ event: NSEvent, released: Bool) -> Bool {
        let text = terminalKeyText(event)
        let unshifted = event.charactersIgnoringModifiers ?? ""
        let textData = text.map { Data($0.utf8) }
        let unshiftedData = Data(unshifted.utf8)
        return unshiftedData.withUnsafeBytes { unshiftedBuffer in
            let unshiftedBase = unshiftedBuffer.bindMemory(to: UInt8.self).baseAddress
            if let textData {
                return textData.withUnsafeBytes { textBuffer in
                    satin_runtime_key(
                        handle,
                        event.keyCode,
                        terminalModifierMask(event.modifierFlags),
                        textBuffer.bindMemory(to: UInt8.self).baseAddress,
                        textBuffer.count,
                        unshiftedBase,
                        unshiftedBuffer.count,
                        event.isARepeat ? 1 : 0,
                        released ? 1 : 0
                    ) != 0
                }
            }
            return satin_runtime_key(
                handle,
                event.keyCode,
                terminalModifierMask(event.modifierFlags),
                nil,
                0,
                unshiftedBase,
                unshiftedBuffer.count,
                event.isARepeat ? 1 : 0,
                released ? 1 : 0
            ) != 0
        }
    }

    func writeText(_ text: String) {
        withUtf8(text) { bytes, count in
            _ = satin_runtime_text(handle, bytes, count)
        }
    }

    func paste(_ text: String) {
        withUtf8(text) { bytes, count in
            _ = satin_runtime_paste(handle, bytes, count)
        }
    }

    func mouse(_ input: NativeMouseInput) -> Bool {
        satin_runtime_mouse(
            handle,
            terminalMouseAction(input.action),
            terminalMouseButton(input.button, action: input.action),
            terminalModifierMask(input.modifier),
            input.surfaceX,
            input.surfaceY,
            input.cellWidth,
            input.cellHeight
        ) != 0
    }

    func focus(_ focused: Bool) {
        _ = satin_runtime_focus(handle, focused ? 1 : 0)
    }

    func select(start: (row: Int, col: Int), end: (row: Int, col: Int), rectangular: Bool) {
        _ = satin_runtime_select(
            handle,
            UInt32(max(0, start.row)),
            clampedUInt16(start.col + 1) - 1,
            UInt32(max(0, end.row)),
            clampedUInt16(end.col + 1) - 1,
            rectangular ? 1 : 0
        )
    }

    func selectAll() {
        _ = satin_runtime_select_all(handle)
    }

    func clearSelection() {
        _ = satin_runtime_clear_selection(handle)
    }

    func selectedText() -> String? {
        ownedRustString(satin_runtime_selected_text(handle))
    }

    func hyperlink(row: Int, col: Int) -> String? {
        ownedRustString(
            satin_runtime_hyperlink(
                handle,
                UInt32(max(0, row)),
                clampedUInt16(col + 1) - 1
            )
        )
    }

    func title() -> String? {
        ownedRustString(satin_runtime_title(handle))
    }

    func takeBellCount() -> UInt64 {
        satin_runtime_take_bell_count(handle)
    }

    func find(_ query: String, backwards: Bool) -> Bool {
        query.withCString { value in
            satin_runtime_find(handle, value, backwards ? 1 : 0) != 0
        }
    }

    func setOptionAsAlt(_ enabled: Bool) {
        _ = satin_runtime_set_option_as_alt(handle, enabled ? 1 : 0)
    }

    @discardableResult
    func drain() -> Bool {
        satin_runtime_drain(handle) != 0
    }

    func isExited() -> Bool {
        satin_runtime_exited(handle) != 0
    }

    func wakeupFD() -> Int32 {
        satin_runtime_wakeup_fd(handle)
    }

    func currentWorkingDirectory() -> String? {
        guard let pointer = satin_runtime_cwd(handle) else {
            return nil
        }
        defer {
            satin_string_free(pointer)
        }

        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    func scroll(rows: Int) -> Int {
        satin_runtime_scroll(handle, rows)
    }

    func rendererScrollPosition() -> Double {
        Double(satin_runtime_renderer_scroll_position(handle))
    }

    func cursorPosition() -> (x: Int, y: Int)? {
        let packed = satin_runtime_cursor_position(handle)
        guard packed != UInt32.max else {
            return nil
        }
        return (Int(packed & 0xffff), Int(packed >> 16))
    }

    func renderHandle() -> UnsafeMutableRawPointer? {
        handle
    }

    func controlScreenText() -> String {
        ownedRustString(satin_runtime_screen_text(handle)) ?? ""
    }

    func controlImageCount() -> Int {
        satin_runtime_kitty_placement_count(handle)
    }

    func takeTmuxEvent() -> TmuxControlEvent? {
        guard let pointer = satin_runtime_take_tmux_event_json(handle) else {
            return nil
        }
        defer { satin_string_free(pointer) }
        return try? JSONDecoder().decode(TmuxControlEvent.self, from: Data(String(cString: pointer).utf8))
    }

    @discardableResult
    func tmuxCommand(_ command: String) -> Bool {
        command.withCString { value in
            satin_runtime_tmux_command(handle, value) != 0
        }
    }

}

final class RustTmuxPane: RustTerminalPane {
    let tmuxPaneId: UInt32
    private weak var gateway: RustTerminalPane?
    private var currentShellCommand: String?
    private var shellOwnsPane = false
    private var returnAwaitingPrompt = false
    private var returnPromptGeneration: UInt64 = 0
    private var pendingRepeatedReturn: NSEvent?

    init?(
        grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
        paneId: UInt32,
        gateway: RustTerminalPane
    ) {
        guard let handle = satin_runtime_create_external(
            clampedUInt16(grid.rows),
            clampedUInt16(grid.cols),
            clampedUInt16(grid.widthPixels),
            clampedUInt16(grid.heightPixels)
        ) else {
            return nil
        }
        self.tmuxPaneId = paneId
        self.gateway = gateway
        super.init(externalHandle: handle)
    }

    override func write(_ data: Data) {
        _ = writeThroughTmux(data)
    }

    @discardableResult
    func writeThroughTmux(_ data: Data) -> Bool {
        guard let gateway else {
            return false
        }
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return satin_runtime_tmux_write(
                gateway.handle,
                handle,
                tmuxPaneId,
                base,
                buffer.count
            ) != 0
        }
    }

    override func writeText(_ text: String) {
        write(Data(text.utf8))
    }

    func syncCursor(_ snapshot: TmuxPaneSnapshot) {
        let absoluteRow = Int(snapshot.cursor_y)
        let row = snapshot.origin_mode
            ? max(0, absoluteRow - Int(snapshot.scroll_region_upper))
            : absoluteRow
        let visibility = snapshot.cursor_visible ? "h" : "l"
        let column = Int(snapshot.cursor_x)
        _ = feed(Data("\u{1b}[\(row + 1);\(column + 1)H\u{1b}[?25\(visibility)".utf8))
    }

    func setCurrentCommand(_ command: String) {
        let commandIsShell = tmuxCommandIsShell(command)
        if commandIsShell {
            if currentShellCommand != command {
                currentShellCommand = command
                _ = satin_runtime_tmux_reset_prompt_tracking(handle)
                resetRepeatedReturnBackpressure()
            }
            shellOwnsPane = true
            return
        }
        if returnAwaitingPrompt {
            return
        }
        shellOwnsPane = false
        resetRepeatedReturnBackpressure()
    }

    override func key(_ event: NSEvent, released: Bool) -> Bool {
        let isReturn = terminalReturnKeyCodes.contains(event.keyCode)
        if isReturn, released {
            resetRepeatedReturnBackpressure()
            return forwardKey(event, released: true)
        }
        let promptState = satin_runtime_tmux_shell_prompt_state(handle)
        let managesShellRepeat = isReturn && shellOwnsPane && promptState != 0
        if managesShellRepeat {
            if event.isARepeat, returnAwaitingPrompt {
                pendingRepeatedReturn = event
                return true
            }
            returnAwaitingPrompt = true
            returnPromptGeneration = satin_runtime_tmux_prompt_generation(handle)
        }
        let sent = forwardKey(event, released: released)
        if !sent, managesShellRepeat {
            resetRepeatedReturnBackpressure()
        }
        return sent
    }

    private func forwardKey(_ event: NSEvent, released: Bool) -> Bool {
        guard let gateway else {
            return false
        }
        let textData = terminalKeyText(event).map { Data($0.utf8) }
        let unshiftedData = Data((event.charactersIgnoringModifiers ?? "").utf8)
        return unshiftedData.withUnsafeBytes { unshiftedBuffer in
            let unshifted = unshiftedBuffer.bindMemory(to: UInt8.self).baseAddress
            if let textData {
                return textData.withUnsafeBytes { textBuffer in
                    satin_runtime_tmux_key(
                        gateway.handle,
                        handle,
                        tmuxPaneId,
                        event.keyCode,
                        terminalModifierMask(event.modifierFlags),
                        textBuffer.bindMemory(to: UInt8.self).baseAddress,
                        textBuffer.count,
                        unshifted,
                        unshiftedBuffer.count,
                        event.isARepeat ? 1 : 0,
                        released ? 1 : 0
                    ) != 0
                }
            }
            return satin_runtime_tmux_key(
                gateway.handle,
                handle,
                tmuxPaneId,
                event.keyCode,
                terminalModifierMask(event.modifierFlags),
                nil,
                0,
                unshifted,
                unshiftedBuffer.count,
                event.isARepeat ? 1 : 0,
                released ? 1 : 0
            ) != 0
        }
    }

    override func paste(_ text: String) {
        _ = pasteThroughTmux(text)
    }

    @discardableResult
    func pasteThroughTmux(_ text: String) -> Bool {
        guard let gateway else {
            return false
        }
        return withUtf8(text) { bytes, count in
            satin_runtime_tmux_paste(
                gateway.handle,
                handle,
                tmuxPaneId,
                bytes,
                count
            ) != 0
        }
    }

    override func mouse(_ input: NativeMouseInput) -> Bool {
        guard let gateway else {
            return false
        }
        return satin_runtime_tmux_mouse(
            gateway.handle,
            handle,
            tmuxPaneId,
            terminalMouseAction(input.action),
            terminalMouseButton(input.button, action: input.action),
            terminalModifierMask(input.modifier),
            input.surfaceX,
            input.surfaceY,
            input.cellWidth,
            input.cellHeight
        ) != 0
    }

    override func focus(_ focused: Bool) {
        guard let gateway else {
            return
        }
        if !focused {
            resetRepeatedReturnBackpressure()
        }
        _ = satin_runtime_tmux_focus(
            gateway.handle,
            handle,
            tmuxPaneId,
            focused ? 1 : 0
        )
    }

    @discardableResult
    func feed(_ data: Data) -> Bool {
        guard gateway != nil else {
            return false
        }
        let fed = data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return satin_runtime_tmux_feed_pane(
                handle,
                base,
                buffer.count
            ) != 0
        }
        if fed {
            forwardPendingReturnAtReadyPrompt()
        }
        return fed
    }

    private func forwardPendingReturnAtReadyPrompt() {
        guard returnAwaitingPrompt else {
            return
        }
        let promptGeneration = satin_runtime_tmux_prompt_generation(handle)
        let semanticPromptSeen = satin_runtime_tmux_semantic_prompt_seen(handle) != 0
        let semanticPromptAdvanced = promptGeneration != returnPromptGeneration
        let fallbackPromptReady = !semanticPromptSeen
            && satin_runtime_tmux_shell_prompt_state(handle) == 2
        guard semanticPromptAdvanced || fallbackPromptReady else {
            return
        }
        returnAwaitingPrompt = false
        guard let event = pendingRepeatedReturn else {
            return
        }
        pendingRepeatedReturn = nil
        _ = key(event, released: false)
    }

    private func resetRepeatedReturnBackpressure() {
        returnAwaitingPrompt = false
        returnPromptGeneration = satin_runtime_tmux_prompt_generation(handle)
        pendingRepeatedReturn = nil
    }
}

final class RustNeovimPane: NativePane {
    let kind = NativePaneMode.neovim
    private let handle: UnsafeMutableRawPointer

    init?(
        grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
        cwd: String? = nil,
        executable: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        let configuration = NativeNeovimLaunchConfiguration(
            cwd: cwd,
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        guard let data = try? JSONEncoder().encode(configuration),
              let json = String(data: data, encoding: .utf8)
        else {
            NativeLog.runtimeError("neovim_launch_configuration_encode_failed")
            return nil
        }
        let handle = json.withCString { value in
            satin_nvim_create_with_config(
                clampedUInt16(grid.rows),
                clampedUInt16(grid.cols),
                clampedUInt16(grid.widthPixels),
                clampedUInt16(grid.heightPixels),
                value
            )
        }
        guard let handle = handle else {
            NativeLog.runtimeError("neovim_runtime_create_failed")
            return nil
        }
        self.handle = handle
    }

    deinit {
        satin_nvim_destroy(handle)
    }

    func resize(grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int)) {
        _ = satin_nvim_resize(
            handle,
            clampedUInt16(grid.rows),
            clampedUInt16(grid.cols),
            clampedUInt16(grid.widthPixels),
            clampedUInt16(grid.heightPixels)
        )
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            _ = satin_nvim_input(handle, base, buffer.count)
        }
    }

    func mouse(_ input: NativeMouseInput) -> NativeMouseHandling {
        let result = input.button.withCString { button in
            input.action.withCString { action in
                input.modifier.withCString { modifier in
                    satin_nvim_mouse(
                        handle,
                        button,
                        action,
                        modifier,
                        input.grid,
                        input.row,
                        input.col
                    )
                }
            }
        }
        switch result {
        case 2:
            return .messageSelection
        case 1:
            return .handled
        default:
            return .unhandled
        }
    }

    func takeMessageSelectionText() -> String? {
        ownedRustString(satin_nvim_take_message_selection_text(handle))
    }

    func runCommand(_ command: String) -> Bool {
        command.withCString { value in
            satin_nvim_command(handle, value) != 0
        }
    }

    @discardableResult
    func drain() -> Bool {
        satin_nvim_drain(handle) != 0
    }

    func isExited() -> Bool {
        satin_nvim_exited(handle) != 0
    }

    func exitCode() -> Int {
        let code = satin_nvim_exit_code(handle)
        return code == Int32.min ? 1 : Int(code)
    }

    func wakeupFD() -> Int32 {
        satin_nvim_wakeup_fd(handle)
    }

    func rendererModel() -> NeovideRendererModelSnapshot? {
        decode(satin_nvim_renderer_model_json(handle), as: NeovideRendererModelSnapshot.self)
    }

    func renderHandle() -> UnsafeMutableRawPointer? {
        handle
    }

    func controlScreenText() -> String {
        guard let model = rendererModel() else {
            return ""
        }
        return model.windows
            .filter { !$0.hidden }
            .sorted { ($0.zindex, $0.grid_id) < ($1.zindex, $1.grid_id) }
            .flatMap { window in window.lines.compactMap { $0?.text } }
            .joined(separator: "\n")
    }

    func controlImageCount() -> Int {
        satin_nvim_kitty_placement_count(handle)
    }

    private func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, as type: T.Type) -> T? {
        guard let pointer else {
            return nil
        }
        defer {
            satin_string_free(pointer)
        }

        let json = String(cString: pointer)
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            NativeLog.runtimeError("neovim_snapshot_decode_failed error=\(error)")
            return nil
        }
    }
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func tmuxCommandArgument(_ value: String) -> String {
    let octal = value.utf8.map { String(format: "\\%03o", Int($0)) }.joined()
    return "\"\(octal)\""
}

private func isLocalTmuxEndpoint(socketPath: String, serverPid: UInt32) -> Bool {
    guard serverPid > 0 else {
        return false
    }
    var status = stat()
    guard lstat(socketPath, &status) == 0,
          status.st_mode & S_IFMT == S_IFSOCK
    else {
        return false
    }
    if kill(pid_t(serverPid), 0) == 0 {
        return true
    }
    return errno == EPERM
}

private func vimSingleQuote(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
}

final class RenameTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onCommit?()
            return true
        }
        return false
    }
}

final class TerminalTextView: NSView, NSTextInputClient {
    var onInput: ((Data) -> Void)?
    var onKeyEvent: ((NSEvent, Bool) -> Bool)?
    var onTextInput: ((String) -> Void)?
    var onMouseInput: ((NativeMouseInput) -> NativeMouseHandling)?
    var onSelectionChanged: (((row: Int, col: Int), (row: Int, col: Int), Bool) -> Void)?
    var onHyperlinkRequested: (((row: Int, col: Int)) -> Bool)?
    var onCopyRequested: (() -> Bool)?
    var onPasteRequested: (() -> Bool)?
    var onSelectAllRequested: (() -> Bool)?
    var onFindRequested: (() -> Bool)?
    var onScroll: ((CGFloat) -> Void)?
    var onPaneSelected: ((Int) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onContextMenuRequested: ((Int?, NSEvent, NSView) -> Void)?
    var onGeometryChanged: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onResetZoom: (() -> Void)?
    var onFontSizeChanged: ((CGFloat) -> Void)?

    required init?(coder: NSCoder) {
        nil
    }

    private var rendererModelSnapshot: NeovideRendererModelSnapshot?
    private var terminalCursor: (x: Int, y: Int)?
    private var rendererModelFrameCount = 0
    private var activePaneId: Int?
    private var paneFrames: [Int: NSRect] = [:]
    private var terminalFontSize = defaultTerminalFontSize
    private var terminalFont = NSFont.monospacedSystemFont(ofSize: defaultTerminalFontSize, weight: .regular)
    private var terminalFontFamily = ""
    private var markedText = NSMutableAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    private var interpretingKeyEvent: NSEvent?
    private var selectionAnchor: (row: Int, col: Int)?
    private var messageSelectionActive = false
    private var terminalKeysDown = Set<UInt16>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        drawPaneBorders()
        drawScrollbar()
        drawMarkedText()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChanged?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            onFocusChanged?(false)
        }
        return accepted
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityLabel() -> String? {
        "Terminal"
    }

    override func accessibilityHelp() -> String? {
        "Interactive terminal. Command-click links, and use Command-F to search scrollback."
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed {
            invalidateInputCoordinates()
            onGeometryChanged?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if handleCommandKey(event) {
                return
            }
            super.keyDown(with: event)
            return
        }
        interpretingKeyEvent = event
        let handled = inputContext?.handleEvent(event) ?? false
        if !handled, !routeKeyEvent(event, released: false),
           let data = terminalInputData(for: event) {
            onInput?(data)
        }
        interpretingKeyEvent = nil
    }

    override func keyUp(with event: NSEvent) {
        guard terminalKeysDown.remove(event.keyCode) != nil else {
            super.keyUp(with: event)
            return
        }
        _ = routeKeyEvent(event, released: true)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let paneId = paneFrames.first(where: { $0.value.contains(point) })?.key,
           paneId != activePaneId {
            activePaneId = paneId
            onPaneSelected?(paneId)
        }
        if event.modifierFlags.contains(.command),
           let position = mouseGridPosition(point),
           onHyperlinkRequested?(position) == true {
            return
        }

        window?.makeFirstResponder(self)
        guard let input = mouseInput(button: "left", action: "press", event: event, point: point) else {
            return
        }
        if handleMouseInput(input) {
            selectionAnchor = nil
            return
        }
        let position = (row: Int(input.row), col: Int(input.col))
        selectionAnchor = position
        onSelectionChanged?(position, position, event.modifierFlags.contains(.option))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let input = mouseInput(
            button: "left",
            action: "release",
            event: event,
            point: point,
            clampToGrid: messageSelectionActive
        ) else {
            return
        }
        if handleMouseInput(input) {
            selectionAnchor = nil
            return
        }
        if let anchor = selectionAnchor {
            onSelectionChanged?(
                anchor,
                (row: Int(input.row), col: Int(input.col)),
                event.modifierFlags.contains(.option)
            )
        }
        selectionAnchor = nil
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let input = mouseInput(
            button: "left",
            action: "drag",
            event: event,
            point: point,
            clampToGrid: messageSelectionActive
        ) else {
            return
        }
        if handleMouseInput(input) {
            selectionAnchor = nil
            return
        }
        if let anchor = selectionAnchor {
            onSelectionChanged?(
                anchor,
                (row: Int(input.row), col: Int(input.col)),
                event.modifierFlags.contains(.option)
            )
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let input = mouseInput(button: "right", action: "press", event: event, point: point),
           handleMouseInput(input) {
            return
        }
        onContextMenuRequested?(nil, event, self)
    }

    override func rightMouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let input = mouseInput(
            button: "right",
            action: "release",
            event: event,
            point: point
        ) else {
            return
        }
        _ = handleMouseInput(input)
    }

    override func otherMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let input = mouseInput(
            button: "middle",
            action: "press",
            event: event,
            point: point
        ) else {
            return
        }
        _ = handleMouseInput(input)
    }

    override func otherMouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let input = mouseInput(
            button: "middle",
            action: "release",
            event: event,
            point: point
        ) else {
            return
        }
        _ = handleMouseInput(input)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard terminalTextRect().contains(point) else {
            super.scrollWheel(with: event)
            return
        }

        if sendWheelMouseInput(for: event, at: point) {
            return
        }

        let rows = scrollRows(for: event)
        guard rows != 0 else {
            return
        }
        onScroll?(rows)
    }

    @objc func copy(_ sender: Any?) {
        _ = onCopyRequested?()
    }

    @objc func paste(_ sender: Any?) {
        _ = onPasteRequested?()
    }

    @objc override func selectAll(_ sender: Any?) {
        _ = onSelectAllRequested?()
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        _ = onFindRequested?()
    }

    func setRendererModel(_ model: NeovideRendererModelSnapshot?) {
        rendererModelSnapshot = model
        if model != nil {
            rendererModelFrameCount += 1
        }
        needsDisplay = true
    }

    func setTerminalCursor(_ cursor: (x: Int, y: Int)?) {
        terminalCursor = cursor
        invalidateInputCoordinates()
        if hasMarkedText() {
            needsDisplay = true
        }
    }

    func markedTextOriginForSmoke() -> NSPoint {
        compositionOrigin()
    }

    func hasRendererModelFrames() -> Bool {
        rendererModelFrameCount > 0
    }

    func rendererContentRowCount() -> Int {
        guard let rendererModelSnapshot else {
            return 0
        }
        return contentRowCount(rendererModelRows(rendererModelSnapshot))
    }

    func rendererMaxScrollPosition() -> Double {
        rendererModelSnapshot?.windows
            .map { abs($0.scroll_position) }
            .max() ?? 0
    }

    func rendererCursorParentGridID() -> Int? {
        rendererModelSnapshot?.cursor_parent_grid_id
    }

    func rendererHasVisibleWindow(gridID: Int) -> Bool {
        rendererModelSnapshot?.windows.contains {
            $0.grid_id == gridID && !$0.hidden && $0.width > 0 && $0.height > 0
        } ?? false
    }

    func rendererVisibleWindowRightEdge(gridID: Int) -> Int? {
        rendererModelSnapshot?.windows.first {
            $0.grid_id == gridID && !$0.hidden && $0.width > 0 && $0.height > 0
        }.map { $0.left + $0.width }
    }

    func rendererModelOccupiedCellCount(column: Int) -> Int {
        guard let rendererModelSnapshot, column >= 0 else {
            return 0
        }
        return rendererModelRows(rendererModelSnapshot).reduce(0) { count, row in
            guard row.indices.contains(column) else {
                return count
            }
            let cell = row[column]
            let hasText = !cell.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return count + ((hasText || cell.bg != nil) ? 1 : 0)
        }
    }

    func rendererPopulatedLineCount(gridID: Int) -> Int {
        rendererModelSnapshot?.windows
            .first { $0.grid_id == gridID }?
            .lines
            .compactMap { $0 }
            .count ?? 0
    }

    func rendererLineCapacity(gridID: Int) -> Int {
        rendererModelSnapshot?.windows
            .first { $0.grid_id == gridID }?
            .lines
            .count ?? 0
    }

    func rendererCursorParentInLeftSplit() -> Int? {
        guard let model = rendererModelSnapshot,
              let parentGrid = model.cursor_parent_grid_id,
              parentGrid > 1,
              let parent = model.windows.first(where: {
                  $0.grid_id == parentGrid && !$0.hidden && $0.width > 0 && $0.height > 0
              }),
              parent.left == 0,
              model.windows.contains(where: {
                  $0.grid_id > 1
                      && $0.grid_id != parentGrid
                      && !$0.hidden
                      && $0.width > 0
                      && $0.height > 0
                      && $0.left > parent.left
              })
        else {
            return nil
        }
        return parentGrid
    }

    func rendererViewportSummary() -> String {
        guard let rendererModelSnapshot else {
            return "none"
        }
        let windows = rendererModelSnapshot.windows
            .filter { !$0.hidden }
            .map { window in
                "\(window.grid_id):\(window.width)x\(window.height)" +
                    "@\(String(format: "%.3f", window.scroll_position))"
            }
            .joined(separator: ",")
        let cursor = rendererModelSnapshot.cursor
            .map { "\($0.x),\($0.y)" } ?? "none"
        return "windows=\(windows.isEmpty ? "none" : windows) cursor=\(cursor)"
    }

    func rendererTextSummary() -> String {
        guard let rendererModelSnapshot else {
            return "none"
        }
        let rows = rendererModelRows(rendererModelSnapshot)
            .map { row in row.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(4)
        return rows.isEmpty ? "none" : rows.joined(separator: "|")
    }

    func rendererModelContainsTexts(_ needles: [String]) -> Bool {
        rendererModelMissingTexts(needles).isEmpty
    }

    func rendererModelMissingTexts(_ needles: [String]) -> [String] {
        guard let rendererModelSnapshot else {
            return needles
        }
        let rows = rendererModelRows(rendererModelSnapshot)
        let cellTexts = rows.flatMap { row in row.map(\.text) }
        let rowText = rows
            .map { row in row.map(\.text).joined() }
            .joined(separator: "\n")
        return needles.filter { needle in
            !cellTexts.contains(needle) && !rowText.contains(needle)
        }
    }

    func rendererModelCellSummary(_ labels: [(label: String, text: String)]) -> String {
        let cells = labels.compactMap { label, text in
            rendererModelCellPosition(text).map { row, col in
                "\(label):\(row):\(col)"
            }
        }
        return cells.isEmpty ? "none" : cells.joined(separator: ",")
    }

    func rendererModelTextStartSummary(label: String, text: String) -> String {
        guard let position = rendererModelTextStartPosition(text) else {
            return "none"
        }
        return "\(label):\(position.row):\(position.col)"
    }

    func rendererModelRawTextStartSummary(label: String, text: String) -> String {
        guard let rendererModelSnapshot else {
            return "none"
        }
        for window in rendererModelSnapshot.windows {
            for (rowIndex, line) in window.lines.enumerated() {
                guard let line,
                      let range = line.text.range(of: text)
                else {
                    continue
                }
                let col = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
                return "\(label):\(window.grid_id):\(rowIndex):\(col):\(window.hidden ? "hidden" : "visible")"
            }
        }
        return "none"
    }

    func rendererModelWindowTextSummary(limit: Int = 4) -> String {
        guard let rendererModelSnapshot else {
            return "none"
        }
        let summaries = rendererModelSnapshot.windows.prefix(limit).map { window in
            let text = window.lines.compactMap { line in
                line?.text.trimmingCharacters(in: .whitespaces)
            }
            .first { !$0.isEmpty } ?? "-"
            let clipped = text.count > 24 ? String(text.prefix(24)) : text
            return "\(window.grid_id):\(window.width)x\(window.height)" +
                "@\(window.left),\(window.top):\(window.hidden ? "h" : "v"):\(clipped)"
        }
        return summaries.isEmpty ? "none" : summaries.joined(separator: ",")
    }

    func skiaGeometrySummary() -> String {
        let geometry = skiaRenderGeometry()
        return [
            geometry.originX,
            geometry.originY,
            geometry.cellWidth,
            geometry.cellHeight,
        ]
        .map {
            String(
                format: "%.4f",
                locale: Locale(identifier: "en_US_POSIX"),
                Double($0)
            )
        }
        .joined(separator: ":")
    }

    func skiaViewportSummary() -> String {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return [
            Int((bounds.width * scale).rounded()),
            Int((bounds.height * scale).rounded()),
        ]
        .map(String.init)
        .joined(separator: ":")
    }

    private func rendererModelCellPosition(_ needle: String) -> (row: Int, col: Int)? {
        guard let rendererModelSnapshot else {
            return nil
        }
        let rows = rendererModelRows(rendererModelSnapshot)
        for (rowIndex, row) in rows.enumerated() {
            for (colIndex, cell) in row.enumerated()
            where cell.text == needle || cell.text.contains(needle) {
                return (rowIndex, colIndex)
            }
        }
        return nil
    }

    func rendererModelTextStartPosition(_ needle: String) -> (row: Int, col: Int)? {
        guard let rendererModelSnapshot else {
            return nil
        }
        let rows = rendererModelRows(rendererModelSnapshot)
        for (rowIndex, row) in rows.enumerated() {
            let text = rowPlainText(row)
            guard let range = text.range(of: needle) else {
                continue
            }
            return (rowIndex, text.distance(from: text.startIndex, to: range.lowerBound))
        }
        return nil
    }

    func rendererModelTextOccurrences(_ needle: String) -> Int {
        guard let rendererModelSnapshot else {
            return 0
        }
        return rendererModelRows(rendererModelSnapshot).reduce(0) { count, row in
            count + rowPlainText(row).components(separatedBy: needle).count - 1
        }
    }

    func rendererModelBlendCellCount(minBlend: UInt8) -> Int {
        guard let rendererModelSnapshot else {
            return 0
        }
        return rendererModelRows(rendererModelSnapshot).reduce(0) { count, row in
            count + row.filter { $0.bg != nil && $0.blend >= minBlend }.count
        }
    }

    func rendererModelBlendCellSummary(minBlend: UInt8) -> String {
        guard let rendererModelSnapshot else {
            return "none"
        }
        let rows = rendererModelRows(rendererModelSnapshot)
        for (rowIndex, row) in rows.enumerated() {
            for (colIndex, cell) in row.enumerated()
            where cell.bg != nil && cell.blend >= minBlend && cell.text.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let bg = cell.bg else {
                    continue
                }
                return [
                    rowIndex,
                    colIndex,
                    Int(cell.blend),
                    Int(bg.r),
                    Int(bg.g),
                    Int(bg.b),
                    Int(rendererModelSnapshot.background.r),
                    Int(rendererModelSnapshot.background.g),
                    Int(rendererModelSnapshot.background.b),
                ]
                .map(String.init)
                .joined(separator: ":")
            }
        }
        return "none"
    }

    func rendererModelWindowKindCounts() -> [String: Int] {
        guard let rendererModelSnapshot else {
            return [:]
        }
        return rendererModelSnapshot.windows.reduce(into: [:]) { counts, window in
            guard !window.hidden else {
                return
            }
            counts[window.window_kind, default: 0] += 1
        }
    }

    func rendererModelMessageSelectionSummary() -> String {
        guard let selection = rendererModelSnapshot?.message_selection else {
            return "none"
        }
        return [
            selection.grid_id,
            selection.start.row,
            selection.start.col,
            selection.end.row,
            selection.end.col,
        ].map(String.init).joined(separator: ":")
    }

    func rendererModelCursorSummary() -> String {
        guard let cursor = rendererModelSnapshot?.cursor else {
            return "none"
        }
        return "\(cursor.y):\(cursor.x)"
    }

    func rendererModelCursorDetailSummary() -> String {
        guard let cursor = rendererModelSnapshot?.cursor else {
            return "none"
        }
        return [
            String(cursor.y),
            String(cursor.x),
            cursor.style,
            String(cursor.cell_percentage),
            String(cursor.blinkwait_ms),
            String(cursor.blinkon_ms),
            String(cursor.blinkoff_ms),
        ]
        .joined(separator: ":")
    }

    func updatePaneFrames(_ frames: [Int: NSRect], activePaneId: Int?) {
        paneFrames = frames
        self.activePaneId = activePaneId
        invalidateInputCoordinates()
        needsDisplay = true
    }

    @discardableResult
    func setTerminalFontSize(_ size: CGFloat) -> Bool {
        let clampedSize = min(max(size, minTerminalFontSize), maxTerminalFontSize)
        guard abs(clampedSize - terminalFontSize) > 0.01 else {
            return false
        }

        terminalFontSize = clampedSize
        terminalFont = configuredTerminalFont(family: terminalFontFamily, size: clampedSize)
        onFontSizeChanged?(clampedSize)
        needsDisplay = true
        onGeometryChanged?()
        return true
    }

    @discardableResult
    func setTerminalFont(family: String, size: CGFloat) -> Bool {
        let clampedSize = min(max(size, minTerminalFontSize), maxTerminalFontSize)
        let normalizedFamily = family.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = normalizedFamily != terminalFontFamily
            || abs(clampedSize - terminalFontSize) > 0.01
        guard changed else {
            return false
        }
        terminalFontFamily = normalizedFamily
        terminalFontSize = clampedSize
        terminalFont = configuredTerminalFont(family: normalizedFamily, size: clampedSize)
        onFontSizeChanged?(clampedSize)
        needsDisplay = true
        onGeometryChanged?()
        return true
    }

    func zoomIn() -> Bool {
        setTerminalFontSize(terminalFontSize + 1)
    }

    func zoomOut() -> Bool {
        setTerminalFontSize(terminalFontSize - 1)
    }

    func resetZoom() -> Bool {
        setTerminalFontSize(defaultTerminalFontSize)
    }

    func terminalGridSize() -> (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int) {
        terminalGridSize(for: terminalTextRect())
    }

    func terminalGridSize(
        for textRect: NSRect
    ) -> (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int) {
        let cellSize = terminalCellSize()
        let cols = max(1, Int(textRect.width / cellSize.width))
        let rows = max(1, Int(textRect.height / cellSize.height))
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let widthPixels = max(1, Int(textRect.width * scale))
        let heightPixels = max(1, Int(textRect.height * scale))
        return (rows, cols, widthPixels, heightPixels)
    }

    func skiaRenderGeometry() -> SkiaRenderGeometry {
        skiaRenderGeometry(for: terminalTextRect())
    }

    func skiaRenderGeometry(for textRect: NSRect) -> SkiaRenderGeometry {
        let cellSize = terminalCellSize()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return SkiaRenderGeometry(
            originX: Float(textRect.minX * scale),
            originY: Float(textRect.minY * scale),
            contentWidth: Float(textRect.width * scale),
            contentHeight: Float(textRect.height * scale),
            cellWidth: Float(cellSize.width * scale),
            cellHeight: Float(cellSize.height * scale)
        )
    }

    private func drawPaneBorders() {
        guard paneFrames.count > 1 else {
            return
        }
        for (paneId, rect) in paneFrames {
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = paneId == activePaneId ? 2 : 1
            (paneId == activePaneId
                ? NSColor.controlAccentColor
                : NSColor.separatorColor
            ).setStroke()
            path.stroke()
        }
    }

    private func drawScrollbar() {
        guard let scrollbar = rendererModelSnapshot?.scrollbar,
              scrollbar.total > scrollbar.visible,
              scrollbar.total > 0
        else {
            return
        }
        let textRect = terminalTextRect()
        let track = NSRect(x: textRect.maxX - 5, y: textRect.minY, width: 4, height: textRect.height)
        let visibleFraction = CGFloat(scrollbar.visible) / CGFloat(scrollbar.total)
        let thumbHeight = max(18, track.height * visibleFraction)
        let maxTop = scrollbar.total - scrollbar.visible
        let historyOffset = maxTop == 0 ? 0 : CGFloat(scrollbar.top) / CGFloat(maxTop)
        let thumbY = track.minY + (track.height - thumbHeight) * (1 - historyOffset)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.75).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: track.minX, y: thumbY, width: track.width, height: thumbHeight),
            xRadius: 2,
            yRadius: 2
        ).fill()
    }

    private func rendererModelRows(_ model: NeovideRendererModelSnapshot) -> [[TerminalCellSnapshot]] {
        let mainWindow = model.windows.first { $0.grid_id == 1 }
        let grid = terminalGridSize()
        let rowCount = max(1, mainWindow?.height ?? grid.rows)
        let colCount = max(1, mainWindow?.width ?? grid.cols)
        var rows = Array(
            repeating: rendererModelBlankRow(cols: colCount),
            count: rowCount
        )

        for window in sortedRendererWindows(model.windows) where !window.hidden {
            overlayRendererWindow(window, into: &rows)
        }
        return rows
    }

    private func rendererModelBlankRow(cols: Int) -> [TerminalCellSnapshot] {
        Array(
            repeating: TerminalCellSnapshot(
                text: " ",
                bg: nil,
                blend: 0
            ),
            count: cols
        )
    }

    private func sortedRendererWindows(
        _ windows: [NeovideRenderedWindowSnapshot]
    ) -> [NeovideRenderedWindowSnapshot] {
        windows.sorted {
            ($0.zindex, $0.compindex, $0.grid_id) < ($1.zindex, $1.compindex, $1.grid_id)
        }
    }

    private func overlayRendererWindow(
        _ window: NeovideRenderedWindowSnapshot,
        into rows: inout [[TerminalCellSnapshot]]
    ) {
        let maxRow = min(window.height, window.lines.count)
        for sourceRow in 0..<maxRow {
            let targetRow = window.top + sourceRow
            guard rows.indices.contains(targetRow),
                  let line = window.lines[sourceRow]
            else {
                continue
            }
            overlayRendererLine(
                line,
                targetRow: targetRow,
                left: window.left,
                width: window.width,
                rows: &rows
            )
        }
    }

    private func overlayRendererLine(
        _ line: NeovideLineSnapshot,
        targetRow: Int,
        left: Int,
        width: Int,
        rows: inout [[TerminalCellSnapshot]]
    ) {
        let targetWidth = min(width, line.cells.count)
        guard targetWidth > 0 else {
            return
        }

        var row = rows[targetRow]
        if row.count < left + targetWidth {
            row.append(contentsOf: rendererModelBlankRow(cols: left + targetWidth - row.count))
        }
        for sourceCol in 0..<targetWidth {
            row[left + sourceCol] = line.cells[sourceCol]
        }
        rows[targetRow] = row
    }

    private func handleCommandKey(_ event: NSEvent) -> Bool {
        guard let key = event.charactersIgnoringModifiers ?? event.characters else {
            return false
        }

        switch key {
        case "c":
            return onCopyRequested?() ?? false
        case "v":
            return onPasteRequested?() ?? false
        case "a":
            return onSelectAllRequested?() ?? false
        case "f":
            return onFindRequested?() ?? false
        case "=", "+":
            onZoomIn?()
            return true
        case "-":
            onZoomOut?()
            return true
        case "0":
            onResetZoom?()
            return true
        default:
            return false
        }
    }

    private func drawMarkedText() {
        guard markedText.length > 0 else {
            return
        }
        let textRect = terminalTextRect()
        let cell = terminalCellSize()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: terminalFont,
            .foregroundColor: NSColor.textColor,
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let value = NSAttributedString(string: markedText.string, attributes: attributes)
        let origin = compositionOrigin()
        value.draw(
            in: NSRect(
                x: origin.x,
                y: origin.y,
                width: max(cell.width, textRect.maxX - origin.x),
                height: cell.height
            )
        )
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let value = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let wasComposing = hasMarkedText()
        unmarkText()
        guard !value.isEmpty else {
            return
        }
        if !wasComposing, let event = interpretingKeyEvent,
           routeKeyEvent(event, released: false) {
            return
        }
        onTextInput?(value)
    }

    override func doCommand(by selector: Selector) {
        guard let event = interpretingKeyEvent else {
            return
        }
        if !routeKeyEvent(event, released: false), let data = terminalInputData(for: event) {
            onInput?(data)
        }
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else {
            markedText = NSMutableAttributedString(string: string as? String ?? "")
        }
        markedSelection = clampedRange(selectedRange, length: markedText.length)
        needsDisplay = true
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .foregroundColor, .backgroundColor]
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard hasMarkedText() else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        let available = NSRange(location: 0, length: markedText.length)
        let intersection = NSIntersectionRange(range, available)
        guard intersection.location != NSNotFound, intersection.length > 0 else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        actualRange?.pointee = intersection
        return markedText.attributedSubstring(from: intersection)
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard hasMarkedText() else {
            return 0
        }
        let local = convert(point, from: nil)
        let origin = compositionOrigin()
        let index = Int(((local.x - origin.x) / terminalCellSize().width).rounded(.down))
        return min(max(index, 0), markedText.length)
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        let origin = compositionOrigin()
        actualRange?.pointee = clampedRange(range, length: max(markedText.length, 1))
        let local = NSRect(
            x: origin.x,
            y: origin.y,
            width: terminalCellSize().width,
            height: terminalCellSize().height
        )
        return window?.convertToScreen(convert(local, to: nil)) ?? local
    }

    private func compositionOrigin() -> NSPoint {
        let textRect = terminalTextRect()
        let cell = terminalCellSize()
        let cursor: (x: Int, y: Int)? = if let rendererCursor = rendererModelSnapshot?.cursor {
            (Int(rendererCursor.x), Int(rendererCursor.y))
        } else {
            terminalCursor
        }
        guard let cursor else {
            return NSPoint(x: textRect.minX, y: textRect.maxY - cell.height)
        }
        return NSPoint(
            x: min(
                textRect.minX + CGFloat(cursor.x) * cell.width,
                textRect.maxX - cell.width
            ),
            y: min(
                textRect.minY + CGFloat(cursor.y) * cell.height,
                textRect.maxY - cell.height
            )
        )
    }

    private func invalidateInputCoordinates() {
        inputContext?.invalidateCharacterCoordinates()
    }

    private func routeKeyEvent(_ event: NSEvent, released: Bool) -> Bool {
        let handled = onKeyEvent?(event, released) ?? false
        if handled, !released {
            terminalKeysDown.insert(event.keyCode)
        }
        return handled
    }

    private func clampedRange(_ range: NSRange, length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    private func terminalTextRect() -> NSRect {
        if let activePaneId, let frame = paneFrames[activePaneId] {
            return frame
        }
        return terminalContentRect()
    }

    func terminalContentRect() -> NSRect {
        NSRect(
            x: terminalHorizontalInset,
            y: terminalTextTop,
            width: max(1, bounds.width - terminalHorizontalInset * 2),
            height: max(1, bounds.height - terminalTextTop - terminalTextBottomInset)
        )
    }

    private func terminalCellSize() -> NSSize {
        let measured = ("M" as NSString).size(withAttributes: [.font: terminalFont])
        let lineHeight = terminalFont.ascender - terminalFont.descender + terminalFont.leading
        return NSSize(width: max(1, measured.width), height: max(1, lineHeight))
    }

    private func scrollRows(for event: NSEvent) -> CGFloat {
        if event.hasPreciseScrollingDeltas {
            return -event.scrollingDeltaY / terminalCellSize().height
        }
        return -event.scrollingDeltaY * 3.0
    }

    private func mouseInput(
        button: String,
        action: String,
        event: NSEvent,
        point: NSPoint,
        clampToGrid: Bool = false
    ) -> NativeMouseInput? {
        guard let position = mouseGridPosition(point, clampToGrid: clampToGrid) else {
            return nil
        }
        let textRect = terminalTextRect()
        let cellSize = terminalCellSize()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return NativeMouseInput(
            button: button,
            action: action,
            modifier: mouseModifierString(for: event),
            grid: 0,
            row: Int64(position.row),
            col: Int64(position.col),
            surfaceX: Float((point.x - textRect.minX) * scale),
            surfaceY: Float((point.y - textRect.minY) * scale),
            cellWidth: UInt32(max(1, Int((cellSize.width * scale).rounded()))),
            cellHeight: UInt32(max(1, Int((cellSize.height * scale).rounded())))
        )
    }

    private func handleMouseInput(_ input: NativeMouseInput) -> Bool {
        let handling = onMouseInput?(input) ?? .unhandled
        if handling == .messageSelection {
            messageSelectionActive = input.action != "release"
        } else if input.button == "left" &&
            (input.action == "press" || input.action == "release") {
            messageSelectionActive = false
        }
        return handling != .unhandled
    }

    private func sendWheelMouseInput(for event: NSEvent, at point: NSPoint) -> Bool {
        let rows = scrollRows(for: event)
        guard rows != 0 else {
            return false
        }
        let action = rows > 0 ? "down" : "up"
        guard let input = mouseInput(button: "wheel", action: action, event: event, point: point) else {
            return false
        }
        guard handleMouseInput(input) else {
            return false
        }
        let repeats = min(6, max(1, Int(abs(rows).rounded(.up))))
        if repeats > 1 {
            for _ in 1..<repeats {
                _ = handleMouseInput(input)
            }
        }
        return true
    }

    private func mouseGridPosition(
        _ point: NSPoint,
        clampToGrid: Bool = false
    ) -> (row: Int, col: Int)? {
        let textRect = terminalTextRect()
        guard clampToGrid || textRect.contains(point) else {
            return nil
        }
        let cellSize = terminalCellSize()
        let grid = terminalGridSize()
        let col = Int((point.x - textRect.minX) / cellSize.width)
        let row = Int((point.y - textRect.minY) / cellSize.height)
        return (
            row: min(max(row, 0), grid.rows - 1),
            col: min(max(col, 0), grid.cols - 1)
        )
    }

    private func mouseModifierString(for event: NSEvent) -> String {
        var modifier = ""
        if event.modifierFlags.contains(.shift) {
            modifier.append("S")
        }
        if event.modifierFlags.contains(.control) {
            modifier.append("C")
        }
        if event.modifierFlags.contains(.option) {
            modifier.append("A")
        }
        if event.modifierFlags.contains(.command) {
            modifier.append("D")
        }
        return modifier
    }

    private func rowPlainText(_ row: [TerminalCellSnapshot]) -> String {
        row.map(\.text).joined()
    }

    private func contentRowCount(_ rows: [[TerminalCellSnapshot]]) -> Int {
        rows.filter { !rowPlainText($0).trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
}

func terminalInputData(for event: NSEvent) -> Data? {
    switch event.keyCode {
    case 36, 76:
        return Data([13])
    case 48:
        return Data([9])
    case 51:
        return Data([127])
    case 53:
        return Data([27])
    case 123:
        return Data("\u{1B}[D".utf8)
    case 124:
        return Data("\u{1B}[C".utf8)
    case 125:
        return Data("\u{1B}[B".utf8)
    case 126:
        return Data("\u{1B}[A".utf8)
    case 115:
        return Data("\u{1B}[H".utf8)
    case 119:
        return Data("\u{1B}[F".utf8)
    case 116:
        return Data("\u{1B}[5~".utf8)
    case 121:
        return Data("\u{1B}[6~".utf8)
    case 117:
        return Data("\u{1B}[3~".utf8)
    default:
        return textInputData(for: event)
    }
}

private func terminalKeyText(_ event: NSEvent) -> String? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let text = flags.contains(.control) || flags.contains(.option) || flags.contains(.command)
        ? event.charactersIgnoringModifiers
        : event.characters
    guard let text, !text.isEmpty,
          text.unicodeScalars.allSatisfy({ scalar in
              !CharacterSet.controlCharacters.contains(scalar) &&
                  !(0xF700...0xF8FF).contains(Int(scalar.value))
          })
    else {
        return nil
    }
    return text
}

private let terminalReturnKeyCodes: Set<UInt16> = [36, 76]

private let tmuxShellCommandNames: Set<String> = {
    var names = Set<String>()
    if let contents = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) {
        for line in contents.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("#") else {
                continue
            }
            names.insert((value as NSString).lastPathComponent)
        }
    }
    if let loginShell = ProcessInfo.processInfo.environment["SHELL"] {
        names.insert((loginShell as NSString).lastPathComponent)
    }
    return names
}()

private func tmuxCommandIsShell(_ command: String) -> Bool {
    let name = (command as NSString).lastPathComponent
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return tmuxShellCommandNames.contains(name)
}

private func terminalModifierMask(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var mask: UInt32 = 0
    if flags.contains(.shift) {
        mask |= 1 << 0
    }
    if flags.contains(.control) {
        mask |= 1 << 1
    }
    if flags.contains(.option) {
        mask |= 1 << 2
    }
    if flags.contains(.command) {
        mask |= 1 << 3
    }
    if flags.contains(.capsLock) {
        mask |= 1 << 4
    }
    if flags.contains(.numericPad) {
        mask |= 1 << 5
    }
    return mask
}

private func terminalModifierMask(_ value: String) -> UInt32 {
    var mask: UInt32 = 0
    if value.contains("S") {
        mask |= 1 << 0
    }
    if value.contains("C") {
        mask |= 1 << 1
    }
    if value.contains("A") {
        mask |= 1 << 2
    }
    if value.contains("D") {
        mask |= 1 << 3
    }
    return mask
}

private func terminalMouseAction(_ action: String) -> UInt32 {
    switch action {
    case "release":
        return 1
    case "drag":
        return 2
    default:
        return 0
    }
}

private func terminalMouseButton(_ button: String, action: String) -> Int32 {
    switch button {
    case "left":
        return 0
    case "right":
        return 1
    case "middle":
        return 2
    case "wheel":
        return action == "up" ? 3 : 4
    default:
        return -1
    }
}

private func withUtf8<Result>(
    _ text: String,
    _ body: (UnsafePointer<UInt8>?, Int) -> Result
) -> Result {
    let data = Data(text.utf8)
    return data.withUnsafeBytes { buffer in
        body(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
    }
}

private func ownedRustString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else {
        return nil
    }
    defer {
        satin_string_free(pointer)
    }
    return String(cString: pointer)
}

private func preferredBool(_ key: String, defaultValue: Bool) -> Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: key) != nil else {
        return defaultValue
    }
    return defaults.bool(forKey: key)
}

func textInputData(for event: NSEvent) -> Data? {
    if event.modifierFlags.contains(.control),
       let byte = controlByte(for: event) {
        return Data([byte])
    }
    guard let characters = event.characters, !characters.isEmpty else {
        return nil
    }
    return Data(characters.utf8)
}

func controlByte(for event: NSEvent) -> UInt8? {
    guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
        return nil
    }
    let value = scalar.value
    if (65...90).contains(value) {
        return UInt8(value - 64)
    }
    if (97...122).contains(value) {
        return UInt8(value - 96)
    }
    return nil
}

func clampedUInt16(_ value: Int) -> UInt16 {
    UInt16(min(max(value, 1), Int(UInt16.max)))
}

func configuredTerminalFont(family: String, size: CGFloat) -> NSFont {
    let family = family.trimmingCharacters(in: .whitespacesAndNewlines)
    if !family.isEmpty,
       let font = NSFontManager.shared.font(
           withFamily: family,
           traits: [],
           weight: 5,
           size: size
       ) {
        return font
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

func themeAccentColor(_ theme: String?) -> NSColor {
    guard let theme else {
        return themeAccentColors["Graphite"] ?? NSColor.controlAccentColor
    }
    return themeAccentColors[theme] ?? NSColor.controlAccentColor
}

/// Owns the small amount of platform-specific navigation presentation in Satin.
///
/// Keep availability checks here so the rest of the shell can continue to use
/// semantic AppKit controls. When macOS changes its standard navigation
/// appearance again, this is the only compatibility boundary that should need
/// to change.
enum NativePlatformAppearance {
    enum WindowRole {
        case terminal
        case settings
    }

    static var usesLiquidGlass: Bool {
#if SATIN_HAS_LIQUID_GLASS_SDK
        if #available(macOS 26.0, *) {
            return true
        }
#endif
        return false
    }

    static func configureWindow(_ window: NSWindow, role: WindowRole) {
        window.titleVisibility = .hidden
        window.toolbarStyle = role == .terminal ? .unifiedCompact : .unified
        window.titlebarSeparatorStyle = .none
        guard role == .terminal else {
            return
        }
        if #available(macOS 26.0, *) {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
        }
    }

    static func configureTabControl(_ control: NSSegmentedControl) {
        control.segmentStyle = .automatic
    }

    static func makeToolbarControls(
        sessionControl: NSButton,
        actionControl: NSSegmentedControl
    ) -> NSView {
#if SATIN_HAS_LIQUID_GLASS_SDK
        if #available(macOS 26.0, *) {
            sessionControl.isBordered = false
            sessionControl.bezelStyle = .inline
            actionControl.segmentStyle = .automatic
            return NativeLiquidGlassToolbarControls(
                sessionControl: sessionControl,
                actionControl: actionControl
            )
        }
#endif

        sessionControl.bezelStyle = .texturedRounded
        actionControl.segmentStyle = .capsule
        let stack = NSStackView(views: [sessionControl, actionControl])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    static func toolbarControlsUseExpectedPresentation(_ view: NSView) -> Bool {
#if SATIN_HAS_LIQUID_GLASS_SDK
        if #available(macOS 26.0, *) {
            return view is NativeLiquidGlassToolbarControls
        }
#endif
        return view is NSStackView
    }

    static func toolbarControlContentSizeDidChange(_ view: NSView) {
#if SATIN_HAS_LIQUID_GLASS_SDK
        if #available(macOS 26.0, *),
           let controls = view as? NativeLiquidGlassToolbarControls {
            controls.updatePreferredSize()
            return
        }
#endif
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
        view.superview?.needsLayout = true
    }
}

#if SATIN_HAS_LIQUID_GLASS_SDK
@available(macOS 26.0, *)
private final class NativeLiquidGlassToolbarControls: NSView {
    private enum Metrics {
        static let height: CGFloat = 28
        static let spacing: CGFloat = 6
        static let controlVerticalInset: CGFloat = 1
        static let sessionHorizontalInset: CGFloat = 6
        static let actionsHorizontalInset: CGFloat = 2
        static let minimumSessionWidth: CGFloat = 86
        static let minimumActionsWidth: CGFloat = 94
    }

    private let sessionControl: NSButton
    private let actionControl: NSSegmentedControl
    private let container = NSGlassEffectContainerView()
    private let containerContent = NSView()
    private let sessionGlass = NSGlassEffectView()
    private let actionsGlass = NSGlassEffectView()
    private var preferredWidthConstraint: NSLayoutConstraint?
    private var preferredHeightConstraint: NSLayoutConstraint?

    init(sessionControl: NSButton, actionControl: NSSegmentedControl) {
        self.sessionControl = sessionControl
        self.actionControl = actionControl
        super.init(frame: .zero)

        sessionGlass.style = .regular
        sessionGlass.cornerRadius = Metrics.height / 2
        sessionGlass.contentView = sessionControl
        actionsGlass.style = .regular
        actionsGlass.cornerRadius = Metrics.height / 2
        actionsGlass.contentView = actionControl
        container.spacing = Metrics.spacing + 4
        container.contentView = containerContent
        containerContent.addSubview(sessionGlass)
        containerContent.addSubview(actionsGlass)
        addSubview(container)
        updatePreferredSize()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let sessionWidth = max(
            Metrics.minimumSessionWidth,
            sessionContentWidth + Metrics.sessionHorizontalInset * 2
        )
        let actionsWidth = max(
            Metrics.minimumActionsWidth,
            actionControl.fittingSize.width + Metrics.actionsHorizontalInset * 2
        )
        return NSSize(
            width: sessionWidth + Metrics.spacing + actionsWidth,
            height: Metrics.height
        )
    }

    func updatePreferredSize() {
        let size = intrinsicContentSize
        if preferredWidthConstraint == nil {
            preferredWidthConstraint = widthAnchor.constraint(equalToConstant: size.width)
            preferredHeightConstraint = heightAnchor.constraint(equalToConstant: size.height)
            preferredWidthConstraint?.isActive = true
            preferredHeightConstraint?.isActive = true
        } else {
            preferredWidthConstraint?.constant = size.width
            preferredHeightConstraint?.constant = size.height
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    override func layout() {
        super.layout()
        container.frame = bounds
        containerContent.frame = container.bounds

        let sessionWidth = max(
            Metrics.minimumSessionWidth,
            sessionContentWidth + Metrics.sessionHorizontalInset * 2
        )
        let actionsWidth = max(
            Metrics.minimumActionsWidth,
            bounds.width - sessionWidth - Metrics.spacing
        )
        sessionGlass.frame = NSRect(
            x: 0,
            y: 0,
            width: sessionWidth,
            height: bounds.height
        )
        actionsGlass.frame = NSRect(
            x: sessionWidth + Metrics.spacing,
            y: 0,
            width: actionsWidth,
            height: bounds.height
        )
        sessionControl.frame = sessionGlass.bounds.insetBy(
            dx: Metrics.sessionHorizontalInset,
            dy: Metrics.controlVerticalInset
        )
        actionControl.frame = actionsGlass.bounds.insetBy(
            dx: Metrics.actionsHorizontalInset,
            dy: Metrics.controlVerticalInset
        )
    }

    private var sessionContentWidth: CGFloat {
        let font = sessionControl.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let titleWidth = (sessionControl.title as NSString).size(withAttributes: [
            .font: font,
        ]).width
        let imageWidth = sessionControl.image?.size.width ?? 0
        let imageSpacing: CGFloat = sessionControl.image == nil ? 0 : 5
        return ceil(titleWidth + imageWidth + imageSpacing)
    }
}
#endif

private final class NativeTerminalBackdropView: NSView {
    private var accentColor = themeAccentColor(nil)

    override var isOpaque: Bool {
        true
    }

    func updateAccentColor(_ color: NSColor) {
        accentColor = color
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let base = NSColor(calibratedRed: 0.078, green: 0.086, blue: 0.102, alpha: 1)
        base.setFill()
        dirtyRect.fill()
        let resolvedAccent = accentColor.usingColorSpace(.deviceRGB) ?? accentColor
        let top = base.blended(withFraction: 0.42, of: resolvedAccent) ?? base
        NSGradient(starting: base, ending: top)?.draw(in: bounds, angle: 90)
    }
}

func colorSwatchImage(_ color: NSColor) -> NSImage {
    let image = NSImage(size: NSSize(width: 14, height: 14))
    image.lockFocus()
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
    image.unlockFocus()
    return image
}

func metalObjectPointer(_ object: AnyObject) -> UnsafeMutableRawPointer {
    Unmanaged.passUnretained(object).toOpaque()
}

protocol TerminalContextMenuProvider: AnyObject {
    func terminalContextMenu(tabIndex: Int?) -> NSMenu
}

final class TerminalMetalView: MTKView, MTKViewDelegate {
    weak var contextMenuProvider: TerminalContextMenuProvider?
    var renderProvider: ((MTLTexture, UnsafeMutableRawPointer?) -> Bool)?

    private let commandQueue: MTLCommandQueue
    private var skiaRenderer: UnsafeMutableRawPointer?
    private var skiaFrameCount = 0

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    init(frame frameRect: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let skiaRenderer = satin_skia_metal_create(
                  metalObjectPointer(device),
                  metalObjectPointer(commandQueue)
        )
        else {
            fatalError("Metal/Skia initialization failed after capability preflight")
        }

        self.commandQueue = commandQueue
        self.skiaRenderer = skiaRenderer
        super.init(frame: frameRect, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.078, green: 0.086, blue: 0.102, alpha: 1.0)
        enableSetNeedsDisplay = true
        isPaused = true
        preferredFramesPerSecond = 120
        delegate = self
        needsDisplay = true
    }

    static func isAvailable() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let renderer = satin_skia_metal_create(
                  metalObjectPointer(device),
                  metalObjectPointer(commandQueue)
              )
        else {
            return false
        }
        satin_skia_metal_destroy(renderer)
        return true
    }

    deinit {
        satin_skia_metal_destroy(skiaRenderer)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?.terminalContextMenu(tabIndex: nil) else {
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        if renderProvider?(drawable.texture, skiaRenderer) == true {
            skiaFrameCount += 1
            requestNextSkiaFrameIfNeeded(commandBuffer)
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        guard let descriptor = currentRenderPassDescriptor else {
            return
        }
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        encoder?.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func hasSkiaFrames() -> Bool {
        skiaFrameCount > 0
    }

    func skiaFrames() -> Int {
        skiaFrameCount
    }

    func resetSkiaFrameCount() {
        skiaFrameCount = 0
    }

    func hasPendingSkiaFrame() -> Bool {
        satin_skia_metal_needs_animation_frame(skiaRenderer) != 0
    }

    func forgetRuntime(_ runtime: UnsafeMutableRawPointer?) {
        satin_skia_metal_forget_runtime(skiaRenderer, runtime)
    }

    func setFontFamily(_ family: String) {
        family.withCString { value in
            _ = satin_skia_metal_set_font_family(skiaRenderer, value)
        }
        needsDisplay = true
    }

    private func requestNextSkiaFrameIfNeeded(_ commandBuffer: MTLCommandBuffer) {
        let delayMs = satin_skia_metal_next_frame_delay_ms(skiaRenderer)
        guard delayMs != UInt64.max else {
            return
        }
        commandBuffer.addCompletedHandler { [weak self] _ in
            let deadline = DispatchTime.now() + .milliseconds(Int(min(delayMs, UInt64(Int.max))))
            DispatchQueue.main.asyncAfter(deadline: deadline) {
                self?.needsDisplay = true
            }
        }
    }
}

struct NativePaneControlStatus {
    let status: String
    let summary: String
    let revision: UInt64
    let updatedAt: Date

    var json: [String: Any] {
        [
            "status": status,
            "summary": summary,
            "revision": revision,
            "updatedAt": updatedAt.timeIntervalSince1970,
        ]
    }
}

struct NativeStatusWaiter {
    let token: UUID
    let reply: NativeControlReply
    let timeout: DispatchWorkItem
}

final class NativeSuspendedTerminalSession {
    let pane: RustTerminalPane
    let completion: NativeControlReply?

    init(pane: RustTerminalPane, completion: NativeControlReply?) {
        self.pane = pane
        self.completion = completion
    }
}

private let tmuxNativePaneIdBase = 1_000_000_000
private let tmuxNativeTabIdBase = 1_500_000_000

final class NativeTmuxSession {
    let gatewayPaneId: Int
    let gateway: RustTerminalPane
    let savedWorkspace: TerminalCoreSnapshot
    var nativePaneIds: [UInt32: Int] = [:]
    var tmuxPaneIds: [Int: UInt32] = [:]
    var nativeTabIds: [UInt32: Int] = [:]
    var tmuxWindowIds: [Int: UInt32] = [:]
    var bufferedOutput: [UInt32: Data] = [:]
    var latestPanes: [UInt32: TmuxPaneSnapshot] = [:]
    var lastClientGrid: (cols: Int, rows: Int)?
    var sessionName = "tmux"
    var socketPath = ""
    var serverPid: UInt32 = 0
    var activeWindowZoomed = false

    init(gatewayPaneId: Int, gateway: RustTerminalPane, savedWorkspace: TerminalCoreSnapshot) {
        self.gatewayPaneId = gatewayPaneId
        self.gateway = gateway
        self.savedWorkspace = savedWorkspace
    }

    func nativePaneId(_ paneId: UInt32) -> Int {
        tmuxNativePaneIdBase + Int(paneId)
    }

    func nativeTabId(_ windowId: UInt32) -> Int {
        tmuxNativeTabIdBase + Int(windowId)
    }
}

private enum SatinToolbarItemIdentifier {
    static let tabs = NSToolbarItem.Identifier("dev.soyukke.satin.toolbar.tabs")
    static let controls = NSToolbarItem.Identifier("dev.soyukke.satin.toolbar.controls")
}

final class TerminalShellViewController: NSViewController, NSTabViewDelegate,
    TerminalContextMenuProvider, NSToolbarDelegate {
    private let core: RustCore
    private var settings: NativeSettings
    private let tabControl = NSSegmentedControl(frame: .zero)
    private let sessionControlButton = NSButton(frame: .zero)
    private let toolbarActionControl = NSSegmentedControl(frame: .zero)
    private let backdropView = NativeTerminalBackdropView(frame: .zero)
    private let metalView: TerminalMetalView
    private let terminalTextView = TerminalTextView(frame: .zero)
    private let defaultPaneMode = NativePaneMode.current()
    private var terminalPanes: [Int: NativePane] = [:]
    private var scrollRemainders: [Int: CGFloat] = [:]
    private var paneWorkingDirectories: [Int: String] = [:]
    private var paneModes: [Int: NativePaneMode] = [:]
    private var paneTitles: [Int: String] = [:]
    private var tmuxSession: NativeTmuxSession?
    private var pendingTmuxReattach: NativeTmuxAttachment?
    private var sessionPopover: NSPopover?
    private var lastSearchQuery = ""
    private var optionAsAltEnabled: Bool
    private var notificationsEnabled: Bool
    private var pendingPaneWorkingDirectory: String?
    private var pendingPaneStartupCommand: [String]?
    private var pendingPaneMode: NativePaneMode?
    private let initialFinderLaunch: NativeFinderEditorLaunch?
    private var activePaneId: Int?
    private var lastSnapshot: TerminalCoreSnapshot?
    private var lastNvimModelScrollShift: OutputScrollShift?
    private var visiblePaneFrames: [Int: NSRect] = [:]
    private var nvimFileTreeSmokeTarget = "none"
    private var nvimFileTreeCloseSmokeGrid: Int?
    private var nvimFileTreeCloseSmokeBoundary: Int?
    private var nvimFileTreeCloseSmokeBefore = "none"
    private var nvimMessageSelectionSmoke = "overlay=no copied=no"
    private var paneWakeupSources: [Int: DispatchSourceRead] = [:]
    private var suspendedPaneWakeupSources: [Int: DispatchSourceRead] = [:]
    private var syncingTabs = false
    private var controlSocketPath = ""
    private var controlCliPath = ""
    private var nvimLauncherPath = ""
    private var zshIntegrationPath = ""
    private var suspendedTerminalSessions: [Int: NativeSuspendedTerminalSession] = [:]
    private var paneControlStatuses: [Int: NativePaneControlStatus] = [:]
    private var paneStatusWaiters: [Int: [NativeStatusWaiter]] = [:]
    private var nextStatusRevision: UInt64 = 1
    private lazy var toolbarControlsView = NativePlatformAppearance.makeToolbarControls(
        sessionControl: sessionControlButton,
        actionControl: toolbarActionControl
    )
    private lazy var nativeToolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: "dev.soyukke.satin.toolbar.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false
        return toolbar
    }()

    init?(
        core: RustCore,
        settings: NativeSettings,
        initialFinderLaunch: NativeFinderEditorLaunch? = nil
    ) {
        guard TerminalMetalView.isAvailable() else {
            NativeLog.runtimeError("metal_renderer_create_failed")
            return nil
        }
        self.core = core
        self.settings = settings
        self.initialFinderLaunch = initialFinderLaunch
        self.optionAsAltEnabled = settings.optionAsAlt
        self.notificationsEnabled = settings.notifications
        self.metalView = TerminalMetalView(frame: .zero)
        super.init(nibName: nil, bundle: nil)
        configureTabControl()
        configureToolbarControls()
        self.metalView.contextMenuProvider = self
        self.terminalTextView.onPaneSelected = { [weak self] paneId in
            self?.selectPane(paneId)
        }
        self.terminalTextView.onFocusChanged = { [weak self] focused in
            self?.setTerminalFocus(focused)
        }
        self.terminalTextView.onContextMenuRequested = { [weak self] tabIndex, event, view in
            guard let menu = self?.terminalContextMenu(tabIndex: tabIndex) else {
                return
            }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        self.terminalTextView.onGeometryChanged = { [weak self] in
            self?.resizeTerminalPanesToGrid()
        }
        self.terminalTextView.onInput = { [weak self] data in
            self?.writeToActivePane(data)
        }
        self.terminalTextView.onKeyEvent = { [weak self] event, released in
            self?.sendKeyToActivePane(event, released: released) ?? false
        }
        self.terminalTextView.onTextInput = { [weak self] text in
            self?.writeTextToActivePane(text)
        }
        self.terminalTextView.onMouseInput = { [weak self] input in
            self?.sendMouseInputToActivePane(input) ?? .unhandled
        }
        self.terminalTextView.onSelectionChanged = { [weak self] start, end, rectangular in
            self?.selectTerminalText(start: start, end: end, rectangular: rectangular)
        }
        self.terminalTextView.onHyperlinkRequested = { [weak self] position in
            self?.openTerminalHyperlink(position) ?? false
        }
        self.terminalTextView.onCopyRequested = { [weak self] in
            self?.copySelection() ?? false
        }
        self.terminalTextView.onPasteRequested = { [weak self] in
            self?.pasteClipboard() ?? false
        }
        self.terminalTextView.onSelectAllRequested = { [weak self] in
            self?.selectAllTerminalText() ?? false
        }
        self.terminalTextView.onFindRequested = { [weak self] in
            self?.findInScrollback() ?? false
        }
        self.terminalTextView.onScroll = { [weak self] rows in
            self?.scrollActivePane(deltaRows: rows)
        }
        self.terminalTextView.onZoomIn = { [weak self] in
            self?.zoomIn(nil)
        }
        self.terminalTextView.onZoomOut = { [weak self] in
            self?.zoomOut(nil)
        }
        self.terminalTextView.onResetZoom = { [weak self] in
            self?.resetZoom(nil)
        }
        self.terminalTextView.onFontSizeChanged = { size in
            UserDefaults.standard.set(Double(size), forKey: NativePreferenceKey.fontSize)
        }
        self.metalView.renderProvider = { [weak self] texture, renderer in
            self?.renderActiveMetalFrame(texture: texture, renderer: renderer) ?? false
        }
        _ = self.terminalTextView.setTerminalFont(
            family: settings.fontFamily,
            size: CGFloat(settings.fontSize)
        )
        self.metalView.setFontFamily(settings.fontFamily)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        for source in paneWakeupSources.values {
            source.cancel()
        }
        for source in suspendedPaneWakeupSources.values {
            source.cancel()
        }
        for pane in terminalPanes.values {
            metalView.forgetRuntime(pane.renderHandle())
        }
    }

    override func loadView() {
        view = NSView()
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        metalView.translatesAutoresizingMaskIntoConstraints = false
        configureTerminalTextView()
        view.addSubview(backdropView)
        view.addSubview(metalView)
        metalView.addSubview(terminalTextView)

        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            metalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            terminalTextView.topAnchor.constraint(equalTo: metalView.topAnchor),
            terminalTextView.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            terminalTextView.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            terminalTextView.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let initialFinderLaunch {
            prepareFinderEditorLaunch(initialFinderLaunch)
        } else {
            restoreSessionIfNeeded()
        }
        syncFromCore()
        schedulePendingTmuxReattach()
    }

    func openFinderItems(_ launch: NativeFinderEditorLaunch) -> Bool {
        prepareFinderEditorLaunch(launch)
        core.newTab()
        syncFromCore()
        guard let activePaneId, let pane = terminalPanes[activePaneId] else {
            return false
        }
        return pane.kind == .terminal
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(terminalTextView)
    }

    func toolbar() -> NSToolbar {
        nativeToolbar
    }

    func configureControl(
        socketPath: String,
        cliPath: String,
        nvimLauncherPath: String,
        zshIntegrationPath: String
    ) {
        controlSocketPath = socketPath
        controlCliPath = cliPath
        self.nvimLauncherPath = nvimLauncherPath
        self.zshIntegrationPath = zshIntegrationPath
    }

    func applySettings(_ settings: NativeSettings) {
        let previous = self.settings
        self.settings = settings
        optionAsAltEnabled = settings.optionAsAlt
        notificationsEnabled = settings.notifications
        for pane in terminalPanes.values {
            (pane as? RustTerminalPane)?.setOptionAsAlt(settings.optionAsAlt)
        }
        if previous.fontFamily != settings.fontFamily
            || previous.fontSize != settings.fontSize {
            _ = terminalTextView.setTerminalFont(
                family: settings.fontFamily,
                size: CGFloat(settings.fontSize)
            )
            metalView.setFontFamily(settings.fontFamily)
            resizeTerminalPanesToGrid()
        }
        if previous.defaultTheme != settings.defaultTheme {
            core.setDefaultTheme(settings.defaultTheme)
        }
    }

    func handleControlRequest(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if tmuxSession != nil, request.command == "open-neovim" {
            reply(
                controlFailure(
                    "tmux_owned",
                    "Native Neovim replacement is unavailable while tmux owns the pane."
                )
            )
            return
        }
        switch request.command {
        case "list":
            reply(.success(controlListResult()))
        case "read-screen":
            handleControlReadScreen(request, reply: reply)
        case "send":
            handleControlSend(request, reply: reply)
        case "key":
            handleControlKey(request, reply: reply)
        case "status-set":
            handleControlStatusSet(request, reply: reply)
        case "status-wait":
            handleControlStatusWait(request, reply: reply)
        case "new-tab":
            handleControlNewTab(request, reply: reply)
        case "split":
            handleControlSplit(request, reply: reply)
        case "select-tab":
            handleControlSelectTab(request, reply: reply)
        case "move-tab":
            handleControlMoveTab(request, reply: reply)
        case "close-tab":
            handleControlCloseTab(request, reply: reply)
        case "select-pane":
            handleControlSelectPane(request, reply: reply)
        case "close-pane":
            handleControlClosePane(request, reply: reply)
        case "open-neovim":
            handleControlOpenNeovim(request, reply: reply)
        case "rename-tab":
            handleControlRenameTab(request, reply: reply)
        case "set-theme":
            handleControlSetTheme(request, reply: reply)
        default:
            reply(controlFailure("unknown_command", "Unknown control command."))
        }
    }

    private func controlListResult() -> [String: Any] {
        guard let snapshot = core.snapshot() else {
            return ["tabs": [], "panes": []]
        }
        let tabs: [[String: Any]] = snapshot.tabs.map { tab in
            [
                "id": tab.id,
                "index": tab.index,
                "title": tab.title,
                "theme": tab.theme,
                "active": tab.index == snapshot.active_tab,
                "activePane": tab.active_pane,
                "panes": tab.panes,
            ]
        }
        let panes = snapshot.tabs.flatMap { tab in
            tab.panes.map { paneId -> [String: Any] in
                let pane = terminalPanes[paneId]
                return [
                    "id": paneId,
                    "tab": tab.id,
                    "kind": (pane?.kind ?? paneModes[paneId] ?? .terminal).sessionValue,
                    "cwd": paneWorkingDirectories[paneId] ?? "",
                    "title": paneTitles[paneId] ?? "",
                    "kittyImages": pane?.controlImageCount() ?? 0,
                    "status": (paneControlStatuses[paneId]?.json as Any?) ?? NSNull(),
                ]
            }
        }
        return [
            "socket": controlSocketPath,
            "activeTab": (
                snapshot.tabs.first(where: { $0.index == snapshot.active_tab })?.id as Any?
            ) ?? NSNull(),
            "tabs": tabs,
            "panes": panes,
        ]
    }

    private func handleControlReadScreen(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let paneId = request.pane, let pane = controlPane(paneId) else {
            reply(controlFailure("pane_not_found", "The requested pane does not exist."))
            return
        }
        _ = pane.drain()
        reply(.success(["pane": paneId, "text": pane.controlScreenText()]))
    }

    private func handleControlSend(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let paneId = request.pane,
              let text = request.text,
              let pane = controlPane(paneId)
        else {
            reply(controlFailure("invalid_send", "A valid pane and text are required."))
            return
        }
        pane.write(Data(text.utf8))
        reply(.success(["pane": paneId, "bytes": text.utf8.count]))
    }

    private func handleControlOpenNeovim(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let paneId = request.pane,
              controlPaneExists(paneId),
              terminalPanes[paneId] is RustTerminalPane,
              suspendedTerminalSessions[paneId] == nil
        else {
            reply(controlFailure("pane_not_terminal", "The pane is not an active terminal."))
            return
        }
        guard let requestedDirectory = request.cwd,
              let cwd = validatedControlDirectory(requestedDirectory)
        else {
            reply(controlFailure("invalid_cwd", "The working directory is invalid."))
            return
        }
        guard let requestedExecutable = request.executable,
              (requestedExecutable as NSString).isAbsolutePath,
              FileManager.default.isExecutableFile(atPath: requestedExecutable)
        else {
            reply(controlFailure("invalid_nvim", "The Neovim executable is invalid."))
            return
        }
        let executable = URL(fileURLWithPath: requestedExecutable).standardizedFileURL.path
        let arguments = request.arguments ?? []
        guard arguments.count <= 256 else {
            reply(controlFailure("too_many_arguments", "Too many Neovim arguments were supplied."))
            return
        }
        let launched = switchTerminalPaneToNeovim(
            paneId: paneId,
            cwd: cwd,
            executable: executable,
            arguments: arguments,
            environment: request.environment ?? [:],
            completion: reply
        )
        if !launched {
            reply(controlFailure("nvim_launch_failed", "Native Neovim could not be started."))
        }
    }

    private func handleControlKey(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let paneId = request.pane,
              let key = request.key,
              let pane = controlPane(paneId),
              let data = controlKeyData(key)
        else {
            reply(controlFailure("invalid_key", "The pane or key name is invalid."))
            return
        }
        pane.write(data)
        reply(.success(["pane": paneId, "key": key]))
    }

    private func handleControlStatusSet(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        let allowed = ["idle", "running", "waiting", "done", "failed", "blocked"]
        guard let paneId = request.pane,
              controlPaneExists(paneId),
              let status = request.status?.lowercased(),
              allowed.contains(status)
        else {
            reply(controlFailure("invalid_status", "The pane or status value is invalid."))
            return
        }
        let value = NativePaneControlStatus(
            status: status,
            summary: request.summary ?? "",
            revision: nextStatusRevision,
            updatedAt: Date()
        )
        if nextStatusRevision < UInt64.max {
            nextStatusRevision += 1
        }
        paneControlStatuses[paneId] = value
        let waiters = paneStatusWaiters.removeValue(forKey: paneId) ?? []
        for waiter in waiters {
            waiter.timeout.cancel()
            waiter.reply(.success(value.json))
        }
        reply(.success(value.json))
    }

    private func handleControlStatusWait(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let paneId = request.pane, controlPaneExists(paneId) else {
            reply(controlFailure("pane_not_found", "The requested pane does not exist."))
            return
        }
        if let current = paneControlStatuses[paneId],
           ["done", "failed", "blocked"].contains(current.status) {
            reply(.success(current.json))
            return
        }
        let token = UUID()
        let timeout = DispatchWorkItem { [weak self] in
            self?.timeoutStatusWait(paneId: paneId, token: token)
        }
        let waiter = NativeStatusWaiter(token: token, reply: reply, timeout: timeout)
        paneStatusWaiters[paneId, default: []].append(waiter)
        let milliseconds = min(request.timeout_ms ?? 60_000, 3_600_000)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int(milliseconds)),
            execute: timeout
        )
    }

    private func timeoutStatusWait(paneId: Int, token: UUID) {
        guard var waiters = paneStatusWaiters[paneId],
              let index = waiters.firstIndex(where: { $0.token == token })
        else {
            return
        }
        let waiter = waiters.remove(at: index)
        paneStatusWaiters[paneId] = waiters.isEmpty ? nil : waiters
        waiter.reply(controlFailure("wait_timeout", "No pane status update was received."))
    }

    private func removeControlState(_ paneId: Int) {
        paneControlStatuses.removeValue(forKey: paneId)
        let waiters = paneStatusWaiters.removeValue(forKey: paneId) ?? []
        for waiter in waiters {
            waiter.timeout.cancel()
            waiter.reply(controlFailure("pane_closed", "The pane was closed."))
        }
    }

    private func discardPaneState(_ paneId: Int) {
        removeControlState(paneId)
        discardSuspendedTerminalSession(paneId)
        removePaneRuntime(paneId)
        scrollRemainders.removeValue(forKey: paneId)
        paneWorkingDirectories.removeValue(forKey: paneId)
        paneModes.removeValue(forKey: paneId)
        paneTitles.removeValue(forKey: paneId)
    }

    private func restoreControlContext(tabId: Int?, paneId: Int?) {
        guard let tabId,
              let tab = lastSnapshot?.tabs.first(where: { $0.id == tabId })
        else {
            return
        }
        _ = core.selectTab(tab.index)
        if let paneId, tab.panes.contains(paneId) {
            _ = core.selectPane(paneId)
        }
        syncFromCore()
    }

    private func handleControlNewTab(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.title != nil && (title?.isEmpty ?? true) {
            reply(controlFailure("invalid_title", "The tab title cannot be empty."))
            return
        }
        if let session = tmuxSession {
            guard let cwd = validatedControlDirectory(request.cwd) else {
                reply(controlFailure("invalid_cwd", "The working directory is invalid."))
                return
            }
            var command = "new-window"
            if request.background == true {
                command += " -d"
            }
            command += " -c \(tmuxCommandArgument(cwd))"
            if let title {
                command += " -n \(tmuxCommandArgument(title))"
            }
            replyTmuxCommand(session, command: command, result: ["queued": true], reply: reply)
            return
        }
        let previousTabId = lastSnapshot.flatMap { snapshot in
            snapshot.tabs.first(where: { $0.index == snapshot.active_tab })?.id
        }
        let previousPaneId = activePaneId
        guard let cwd = validatedControlDirectory(request.cwd) else {
            reply(controlFailure("invalid_cwd", "The working directory is invalid."))
            return
        }
        pendingPaneWorkingDirectory = cwd
        let index = core.newTab()
        if let title {
            core.renameTab(index, title: title)
        }
        syncFromCore()
        guard let tab = lastSnapshot?.tabs.first(where: { $0.index == index }) else {
            reply(controlFailure("core_error", "The new tab was not created."))
            return
        }
        let result = ["tab": tab.id, "pane": tab.active_pane]
        if request.background == true {
            restoreControlContext(tabId: previousTabId, paneId: previousPaneId)
        }
        reply(.success(result))
    }

    private func handleControlSplit(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if let session = tmuxSession {
            guard let paneId = request.pane,
                  let tmuxPaneId = session.tmuxPaneIds[paneId],
                  let cwd = validatedControlDirectory(request.cwd),
                  let axisName = request.axis,
                  ["horizontal", "vertical"].contains(axisName)
            else {
                reply(controlFailure("invalid_split", "The pane, axis, or directory is invalid."))
                return
            }
            let flag = axisName == "horizontal" ? "-v" : "-h"
            let detached = request.background == true ? " -d" : ""
            let command = "split-window \(flag)\(detached) -c \(tmuxCommandArgument(cwd)) "
                + "-t %\(tmuxPaneId)"
            replyTmuxCommand(
                session,
                command: command,
                result: ["pane": paneId, "queued": true],
                reply: reply
            )
            return
        }
        let previousTabId = lastSnapshot.flatMap { snapshot in
            snapshot.tabs.first(where: { $0.index == snapshot.active_tab })?.id
        }
        let previousPaneId = activePaneId
        guard let paneId = request.pane,
              let tab = lastSnapshot?.tabs.first(where: { $0.panes.contains(paneId) }),
              let cwd = validatedControlDirectory(request.cwd),
              let axisName = request.axis
        else {
            reply(controlFailure("invalid_split", "The pane, axis, or directory is invalid."))
            return
        }
        _ = core.selectTab(tab.index)
        _ = core.selectPane(paneId)
        pendingPaneWorkingDirectory = request.cwd == nil ? activeWorkingDirectory() : cwd
        let axis = axisName == "horizontal" ? ffiSplitHorizontal : ffiSplitVertical
        guard let newPane = core.splitActive(axis: axis) else {
            reply(controlFailure("core_error", "The pane could not be split."))
            return
        }
        syncFromCore()
        let result = ["tab": tab.id, "pane": newPane]
        if request.background == true {
            restoreControlContext(tabId: previousTabId, paneId: previousPaneId)
        }
        reply(.success(result))
    }

    private func handleControlSelectTab(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if let session = tmuxSession {
            guard let tabId = request.tab,
                  let windowId = session.tmuxWindowIds[tabId]
            else {
                reply(controlFailure("tab_not_found", "The requested tab does not exist."))
                return
            }
            replyTmuxCommand(
                session,
                command: "select-window -t @\(windowId)",
                result: ["tab": tabId],
                reply: reply
            )
            return
        }
        guard let tabId = request.tab,
              let tab = lastSnapshot?.tabs.first(where: { $0.id == tabId }),
              core.selectTab(tab.index)
        else {
            reply(controlFailure("tab_not_found", "The requested tab does not exist."))
            return
        }
        syncFromCore()
        focusTerminal()
        reply(.success(["tab": tabId]))
    }

    private func handleControlMoveTab(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if let session = tmuxSession {
            guard let tabId = request.tab,
                  let index = request.index,
                  let snapshot = lastSnapshot,
                  let source = snapshot.tabs.first(where: { $0.id == tabId }),
                  let sourceWindow = session.tmuxWindowIds[source.id],
                  index >= 0,
                  index < snapshot.tabs.count
            else {
                reply(controlFailure("invalid_tab_index", "The tab or destination index is invalid."))
                return
            }
            let remaining = snapshot.tabs.filter { $0.id != tabId }
            if remaining.isEmpty || source.index == index {
                reply(.success(["tab": tabId, "index": index]))
                return
            }
            let positionFlag: String
            let targetTab: TerminalCoreTabSnapshot
            if index == 0 {
                positionFlag = "-b"
                targetTab = remaining[0]
            } else {
                positionFlag = "-a"
                targetTab = remaining[min(index - 1, remaining.count - 1)]
            }
            guard let targetWindow = session.tmuxWindowIds[targetTab.id] else {
                reply(controlFailure("tab_not_found", "The destination tab does not exist."))
                return
            }
            replyTmuxCommand(
                session,
                command: "move-window -s @\(sourceWindow) \(positionFlag) -t @\(targetWindow)",
                result: ["tab": tabId, "index": index],
                reply: reply
            )
            return
        }
        guard let tabId = request.tab,
              let index = request.index,
              let snapshot = lastSnapshot,
              index < snapshot.tabs.count,
              snapshot.tabs.contains(where: { $0.id == tabId }),
              core.moveTab(tabId, to: index)
        else {
            reply(controlFailure("invalid_tab_index", "The tab or destination index is invalid."))
            return
        }
        syncFromCore()
        reply(.success(["tab": tabId, "index": index]))
    }

    private func handleControlCloseTab(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if let session = tmuxSession {
            guard let tabId = request.tab,
                  let snapshot = lastSnapshot,
                  let tab = snapshot.tabs.first(where: { $0.id == tabId }),
                  let windowId = session.tmuxWindowIds[tabId]
            else {
                reply(controlFailure("tab_not_found", "The requested tab does not exist."))
                return
            }
            guard snapshot.tabs.count > 1 else {
                reply(controlFailure("final_tab", "The final tab cannot be closed by automation."))
                return
            }
            replyTmuxCommand(
                session,
                command: "kill-window -t @\(windowId)",
                result: ["tab": tabId, "closedPanes": tab.panes],
                reply: reply
            )
            return
        }
        guard let tabId = request.tab,
              let snapshot = lastSnapshot,
              let tab = snapshot.tabs.first(where: { $0.id == tabId })
        else {
            reply(controlFailure("tab_not_found", "The requested tab does not exist."))
            return
        }
        guard snapshot.tabs.count > 1 else {
            reply(controlFailure("final_tab", "The final tab cannot be closed by automation."))
            return
        }
        for paneId in tab.panes {
            guard core.closePane(paneId) else {
                reply(controlFailure("core_error", "The tab could not be closed."))
                return
            }
            discardPaneState(paneId)
        }
        syncFromCore()
        reply(.success(["tab": tabId, "closedPanes": tab.panes]))
    }

    private func handleControlSelectPane(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if let session = tmuxSession {
            guard let paneId = request.pane,
                  let tmuxPaneId = session.tmuxPaneIds[paneId]
            else {
                reply(controlFailure("pane_not_found", "The requested pane does not exist."))
                return
            }
            replyTmuxCommand(
                session,
                command: "select-pane -t %\(tmuxPaneId)",
                result: ["pane": paneId],
                reply: reply
            )
            return
        }
        guard let paneId = request.pane,
              let tab = lastSnapshot?.tabs.first(where: { $0.panes.contains(paneId) }),
              core.selectTab(tab.index),
              core.selectPane(paneId)
        else {
            reply(controlFailure("pane_not_found", "The requested pane does not exist."))
            return
        }
        syncFromCore()
        focusTerminal()
        reply(.success(["tab": tab.id, "pane": paneId]))
    }

    private func handleControlClosePane(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if let session = tmuxSession {
            guard let paneId = request.pane,
                  let snapshot = lastSnapshot,
                  let tab = snapshot.tabs.first(where: { $0.panes.contains(paneId) }),
                  let tmuxPaneId = session.tmuxPaneIds[paneId]
            else {
                reply(controlFailure("pane_not_found", "The requested pane does not exist."))
                return
            }
            guard snapshot.tabs.count > 1 || tab.panes.count > 1 else {
                reply(controlFailure("final_pane", "The final pane cannot be closed by automation."))
                return
            }
            replyTmuxCommand(
                session,
                command: "kill-pane -t %\(tmuxPaneId)",
                result: ["tab": tab.id, "pane": paneId, "tabClosed": tab.panes.count == 1],
                reply: reply
            )
            return
        }
        guard let paneId = request.pane,
              let snapshot = lastSnapshot,
              let tab = snapshot.tabs.first(where: { $0.panes.contains(paneId) })
        else {
            reply(controlFailure("pane_not_found", "The requested pane does not exist."))
            return
        }
        guard snapshot.tabs.count > 1 || tab.panes.count > 1 else {
            reply(controlFailure("final_pane", "The final pane cannot be closed by automation."))
            return
        }
        guard core.closePane(paneId) else {
            reply(controlFailure("core_error", "The pane could not be closed."))
            return
        }
        discardPaneState(paneId)
        syncFromCore()
        reply(.success([
            "tab": tab.id,
            "pane": paneId,
            "tabClosed": tab.panes.count == 1,
        ]))
    }

    private func handleControlRenameTab(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let tabId = request.tab,
              let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let tab = lastSnapshot?.tabs.first(where: { $0.id == tabId })
        else {
            reply(controlFailure("invalid_tab", "The tab or title is invalid."))
            return
        }
        if let session = tmuxSession,
           let windowId = session.tmuxWindowIds[tabId] {
            replyTmuxCommand(
                session,
                command: "rename-window -t @\(windowId) \(tmuxCommandArgument(title))",
                result: ["tab": tabId, "title": title],
                reply: reply
            )
            return
        }
        core.renameTab(tab.index, title: title)
        syncFromCore()
        reply(.success(["tab": tabId, "title": title]))
    }

    private func handleControlSetTheme(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let tabId = request.tab,
              let theme = request.theme,
              nativeThemeNames.contains(theme),
              let tab = lastSnapshot?.tabs.first(where: { $0.id == tabId })
        else {
            reply(controlFailure("invalid_theme", "The tab or theme is invalid."))
            return
        }
        core.setTheme(theme, tab: tab.index)
        syncFromCore()
        reply(.success(["tab": tabId, "theme": theme]))
    }

    private func controlPane(_ paneId: Int) -> NativePane? {
        guard controlPaneExists(paneId) else {
            return nil
        }
        return terminalPane(for: paneId)
    }

    private func controlPaneExists(_ paneId: Int) -> Bool {
        lastSnapshot?.tabs.contains(where: { $0.panes.contains(paneId) }) == true
    }

    private func validatedControlDirectory(_ requested: String?) -> String? {
        let value = requested ?? newPaneWorkingDirectory()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private func controlFailure(_ code: String, _ message: String) -> Result<Any, NativeControlFailure> {
        .failure(NativeControlFailure(code: code, message: message))
    }

    private func replyTmuxCommand(
        _ session: NativeTmuxSession,
        command: String,
        result: [String: Any],
        reply: @escaping NativeControlReply
    ) {
        guard session.gateway.tmuxCommand(command) else {
            reply(controlFailure("tmux_command_failed", "The tmux command could not be queued."))
            return
        }
        reply(.success(result))
    }

    private func controlKeyData(_ key: String) -> Data? {
        let normalized = key.lowercased()
        let named: [String: [UInt8]] = [
            "enter": [13], "return": [13], "tab": [9], "escape": [27],
            "esc": [27], "backspace": [127], "space": [32],
            "up": [27, 91, 65], "down": [27, 91, 66],
            "right": [27, 91, 67], "left": [27, 91, 68],
            "home": [27, 91, 72], "end": [27, 91, 70],
            "delete": [27, 91, 51, 126], "pageup": [27, 91, 53, 126],
            "pagedown": [27, 91, 54, 126],
        ]
        if let bytes = named[normalized] {
            return Data(bytes)
        }
        if normalized.hasPrefix("ctrl+"),
           let scalar = normalized.dropFirst(5).unicodeScalars.first,
           normalized.dropFirst(5).unicodeScalars.count == 1,
           scalar.value >= 97,
           scalar.value <= 122 {
            return Data([UInt8(scalar.value - 96)])
        }
        return key.count == 1 ? Data(key.utf8) : nil
    }

    @objc func tabControlChanged(_ sender: NSSegmentedControl) {
        guard !syncingTabs, sender.selectedSegment >= 0 else {
            return
        }

        selectTab(sender.selectedSegment)
    }

    @objc func newTab(_ sender: Any?) {
        if let session = tmuxSession {
            _ = session.gateway.tmuxCommand("new-window")
            return
        }
        pendingPaneWorkingDirectory = newPaneWorkingDirectory()
        core.newTab()
        syncFromCore()
    }

    @objc func splitVertical(_ sender: Any?) {
        if routeTmuxSplit(horizontal: true) {
            return
        }
        pendingPaneWorkingDirectory = newPaneWorkingDirectory()
        _ = core.splitActive(axis: ffiSplitVertical)
        syncFromCore()
    }

    @objc func splitHorizontal(_ sender: Any?) {
        if routeTmuxSplit(horizontal: false) {
            return
        }
        pendingPaneWorkingDirectory = newPaneWorkingDirectory()
        _ = core.splitActive(axis: ffiSplitHorizontal)
        syncFromCore()
    }

    @objc func openNativeNeovim(_ sender: Any?) {
        guard let paneId = activePaneId else {
            return
        }
        _ = switchTerminalPaneToNeovim(paneId: paneId)
    }

    @objc func closeActivePane(_ sender: Any?) {
        if let session = tmuxSession,
           let paneId = activePaneId,
           let tmuxPaneId = session.tmuxPaneIds[paneId] {
            _ = session.gateway.tmuxCommand("kill-pane -t %\(tmuxPaneId)")
            return
        }
        guard let paneId = activePaneId, core.closePane(paneId) else {
            return
        }
        discardPaneState(paneId)
        guard let snapshot = core.snapshot(), !snapshot.tabs.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        syncFromCore()
    }

    private func routeTmuxSplit(horizontal: Bool) -> Bool {
        guard let session = tmuxSession,
              let paneId = activePaneId,
              let tmuxPaneId = session.tmuxPaneIds[paneId]
        else {
            return false
        }
        let flag = horizontal ? "-h" : "-v"
        return session.gateway.tmuxCommand("split-window \(flag) -t %\(tmuxPaneId)")
    }

    @objc func toggleOptionAsAlt(_ sender: Any?) {
        optionAsAltEnabled.toggle()
        UserDefaults.standard.set(optionAsAltEnabled, forKey: NativePreferenceKey.optionAsAlt)
        for pane in terminalPanes.values {
            (pane as? RustTerminalPane)?.setOptionAsAlt(optionAsAltEnabled)
        }
    }

    @objc func toggleNotifications(_ sender: Any?) {
        notificationsEnabled.toggle()
        UserDefaults.standard.set(notificationsEnabled, forKey: NativePreferenceKey.notifications)
    }

    @objc func toggleSessionRestore(_ sender: Any?) {
        let enabled = !preferredBool(NativePreferenceKey.sessionRestore, defaultValue: true)
        UserDefaults.standard.set(enabled, forKey: NativePreferenceKey.sessionRestore)
        if !enabled {
            UserDefaults.standard.removeObject(forKey: NativePreferenceKey.sessionState)
        }
    }

    func saveSessionState() {
        guard preferredBool(NativePreferenceKey.sessionRestore, defaultValue: true),
              let state = currentSessionState()
        else {
            return
        }
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: NativePreferenceKey.sessionState)
        } catch {
            NativeLog.sessionWarning("session_encode_failed error=\(error)")
        }
    }

    private func currentSessionState() -> NativeSessionState? {
        guard let snapshot = tmuxSession?.savedWorkspace ?? lastSnapshot else {
            return nil
        }
        let tabs = snapshot.tabs.compactMap { tab in
            savedSessionPane(tab.layout, activePane: tab.active_pane).map { layout in
                NativeSessionTab(title: tab.title, theme: tab.theme, layout: layout)
            }
        }
        return NativeSessionState(
            schemaVersion: currentSessionSchemaVersion,
            activeTab: snapshot.active_tab,
            tabs: tabs,
            tmuxAttachment: tmuxSession.flatMap { session in
                guard isLocalTmuxEndpoint(
                    socketPath: session.socketPath,
                    serverPid: session.serverPid
                ) else {
                    return nil
                }
                return validatedTmuxAttachment(
                    NativeTmuxAttachment(
                        sessionName: session.sessionName,
                        socketPath: session.socketPath
                    )
                )
            }
        )
    }

    private func validatedTmuxAttachment(
        _ attachment: NativeTmuxAttachment
    ) -> NativeTmuxAttachment? {
        let name = attachment.sessionName
        let socket = attachment.socketPath
        guard !name.isEmpty,
              name.utf8.count <= 256,
              socket.utf8.count <= 1_024,
              (socket as NSString).isAbsolutePath,
              name.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              socket.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return attachment
    }

    private func savedSessionPane(
        _ layout: PaneLayoutSnapshot,
        activePane: Int
    ) -> NativeSessionPane? {
        if layout.kind == "leaf", let paneId = layout.pane_id {
            let cwd = (terminalPanes[paneId] as? RustTerminalPane)?
                .currentWorkingDirectory()
                ?? paneWorkingDirectories[paneId]
                ?? nativeWorkingDirectory()
            let mode = terminalPanes[paneId]?.kind ?? paneModes[paneId] ?? defaultPaneMode
            return NativeSessionPane(
                kind: "leaf",
                paneMode: mode.sessionValue,
                cwd: cwd,
                active: paneId == activePane
            )
        }
        guard layout.kind == "split",
              let axis = layout.axis,
              let first = layout.first.flatMap({
                  savedSessionPane($0, activePane: activePane)
              }),
              let second = layout.second.flatMap({
                  savedSessionPane($0, activePane: activePane)
              })
        else {
            return nil
        }
        return NativeSessionPane(kind: "split", axis: axis, first: first, second: second)
    }

    @objc func renameActiveTab(_ sender: Any?) {
        guard let snapshot = lastSnapshot,
              let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab })
        else {
            return
        }

        let input = RenameTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.stringValue = tab.title
        input.isEditable = true
        input.isSelectable = true
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.accessoryView = input
        let renameButton = alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        alert.window.initialFirstResponder = input
        alert.window.makeFirstResponder(input)
        input.selectText(nil)
        input.onCommit = { [weak renameButton] in
            renameButton?.performClick(nil)
        }
        DispatchQueue.main.async { [weak alert, weak input] in
            guard let alert, let input else {
                return
            }
            alert.window.makeFirstResponder(input)
            input.selectText(nil)
        }

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        if let session = tmuxSession,
           let windowId = session.tmuxWindowIds[tab.id] {
            _ = session.gateway.tmuxCommand(
                "rename-window -t @\(windowId) \(tmuxCommandArgument(input.stringValue))"
            )
            return
        }
        core.renameTab(snapshot.active_tab, title: input.stringValue)
        syncFromCore()
    }

    @objc func toggleTmuxPaneZoom(_ sender: Any?) {
        guard let session = tmuxSession,
              let paneId = activePaneId,
              let tmuxPaneId = session.tmuxPaneIds[paneId]
        else {
            return
        }
        _ = session.gateway.tmuxCommand("resize-pane -Z -t %\(tmuxPaneId)")
        focusTerminal()
    }

    @objc func closeTmuxWindow(_ sender: Any?) {
        guard let session = tmuxSession,
              let snapshot = lastSnapshot,
              let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab }),
              let windowId = session.tmuxWindowIds[tab.id]
        else {
            return
        }
        _ = session.gateway.tmuxCommand("kill-window -t @\(windowId)")
    }

    @objc func zoomIn(_ sender: Any?) {
        _ = terminalTextView.zoomIn()
        focusTerminal()
    }

    @objc func zoomOut(_ sender: Any?) {
        _ = terminalTextView.zoomOut()
        focusTerminal()
    }

    @objc func resetZoom(_ sender: Any?) {
        _ = terminalTextView.resetZoom()
        focusTerminal()
    }

    func selectTabFromShortcut(_ shortcutNumber: Int) {
        guard let snapshot = lastSnapshot,
              !snapshot.tabs.isEmpty,
              (1...9).contains(shortcutNumber)
        else {
            return
        }

        let index = shortcutNumber == 9 ? snapshot.tabs.count - 1 : shortcutNumber - 1
        guard index >= 0, index < snapshot.tabs.count else {
            return
        }
        selectTab(index)
    }

    @objc func setThemeFromMenu(_ sender: NSMenuItem) {
        guard let snapshot = lastSnapshot,
              let theme = sender.representedObject as? String
        else {
            return
        }
        core.setTheme(theme, tab: snapshot.active_tab)
        syncFromCore()
    }

    func terminalContextMenu(tabIndex: Int?) -> NSMenu {
        if let tabIndex {
            selectTabForContextMenu(tabIndex)
        }

        let menu = NSMenu()
        menu.addItem(menuItem("Rename Session", #selector(renameActiveTab(_:))))
        if tmuxSession != nil {
            let zoomTitle = tmuxSession?.activeWindowZoomed == true
                ? "Restore tmux Panes"
                : "Zoom tmux Pane"
            menu.addItem(menuItem(zoomTitle, #selector(toggleTmuxPaneZoom(_:))))
            menu.addItem(menuItem("Close tmux Window", #selector(closeTmuxWindow(_:))))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(themeMenuItem())
        return menu
    }

    func applySmokeScenario(resultPath: String?) {
        core.newTab()
        core.renameTab(1, title: "native smoke")
        core.setTheme("Harbor", tab: 1)
        _ = core.splitActive(axis: ffiSplitVertical)
        syncFromCore()
        writeToActivePane(Data("printf 'native pty view ready\\n'\r".utf8))
        guard let resultPath, !resultPath.isEmpty else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.writeNativeSmokeResult(resultPath, retries: 12)
        }
    }

    func applySessionSchemaSmokeScenario(resultPath: String) {
        _ = core.splitActive(axis: ffiSplitVertical)
        _ = core.splitActive(axis: ffiSplitHorizontal)
        syncFromCore()
        guard let state = currentSessionState(),
              let data = try? JSONEncoder().encode(state),
              let decoded = decodeSessionState(data)
        else {
            writeSessionSmokeResult(resultPath, result: "failed session-schema encode\n")
            return
        }
        let legacy = LegacyNativeSessionState(
            activeTab: 0,
            tabs: [LegacyNativeSessionTab(title: "legacy", theme: "Graphite", cwd: "/tmp")]
        )
        let migrated = (try? JSONEncoder().encode(legacy)).flatMap(decodeSessionState)
        let attachment = NativeTmuxAttachment(
            sessionName: "persisted-session",
            socketPath: "/tmp/persisted-tmux.sock"
        )
        let attachedState = NativeSessionState(
            schemaVersion: currentSessionSchemaVersion,
            activeTab: state.activeTab,
            tabs: state.tabs,
            tmuxAttachment: attachment
        )
        let attachedData = try? JSONEncoder().encode(attachedState)
        let attachedRoundTrip = attachedData.flatMap(decodeSessionState)
        let consumed = sessionStateWithoutTmuxAttachment(attachedState)
        var versionTwoObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        versionTwoObject?["schemaVersion"] = 2
        versionTwoObject?.removeValue(forKey: "tmuxAttachment")
        let versionTwoData = versionTwoObject.flatMap {
            try? JSONSerialization.data(withJSONObject: $0)
        }
        let versionTwoMigrated = versionTwoData.flatMap(decodeSessionState)
        let corruptRejected = decodeSessionState(Data("{not-json".utf8)) == nil
        let futureData = Data("{\"schemaVersion\":999}".utf8)
        let futurePreserved = sessionSchemaVersion(in: futureData) == 999
        let counts = sessionPaneCounts(decoded.tabs[decoded.activeTab].layout)
        let ok = decoded.schemaVersion == currentSessionSchemaVersion
            && counts.leaves == 3
            && counts.splits == 2
            && counts.activeLeaves == 1
            && migrated?.schemaVersion == currentSessionSchemaVersion
            && migrated?.tabs.first?.layout.kind == "leaf"
            && attachedRoundTrip?.tmuxAttachment == attachment
            && consumed.tmuxAttachment == nil
            && versionTwoMigrated?.schemaVersion == currentSessionSchemaVersion
            && versionTwoMigrated?.tmuxAttachment == nil
            && validatedTmuxAttachment(attachment) == attachment
            && validatedTmuxAttachment(
                NativeTmuxAttachment(sessionName: "invalid", socketPath: "relative.sock")
            ) == nil
            && corruptRejected
            && futurePreserved
        let status = ok ? "ok" : "failed"
        writeSessionSmokeResult(
            resultPath,
            result: "\(status) session-schema version=\(decoded.schemaVersion) " +
                "leaves=\(counts.leaves) splits=\(counts.splits) active=\(counts.activeLeaves) " +
                "migration=\(migrated == nil ? "failed" : "ok") " +
                "reattach=\(attachedRoundTrip?.tmuxAttachment == attachment ? "ok" : "failed") " +
                "consume-once=\(consumed.tmuxAttachment == nil ? "ok" : "failed") " +
                "corruption=rejected future=preserved\n"
        )
    }

    func applyTmuxNativeSmokeScenario(resultPath: String) {
        waitForTmuxSmokeLayout(resultPath, previousGrid: nil, retries: 10)
    }

    private func waitForTmuxSmokeLayout(
        _ resultPath: String,
        previousGrid: (rows: Int, cols: Int)?,
        retries: Int
    ) {
        view.layoutSubtreeIfNeeded()
        resizeTerminalPanesToGrid()
        let grid = tmuxClientGrid()
        if previousGrid?.rows != grid.rows || previousGrid?.cols != grid.cols {
            guard retries > 0 else {
                writeSessionSmokeResult(resultPath, result: "failed tmux-native layout-unstable\n")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForTmuxSmokeLayout(
                    resultPath,
                    previousGrid: (rows: grid.rows, cols: grid.cols),
                    retries: retries - 1
                )
            }
            return
        }

        let socket = "satin-native-smoke-\(ProcessInfo.processInfo.processIdentifier)"
        let command = "tmux -L \(socket) new-session -d -s satin-native-smoke && "
            + "tmux -L \(socket) send-keys -t satin-native-smoke "
            + "\"printf 'TMUX_HISTORY_MARKER\\n'; seq 1 120\" Enter && sleep 0.2 && "
            + "tmux -L \(socket) -CC attach -t satin-native-smoke"
        writeToActivePane(Data("\(command)\r".utf8))
        waitForTmuxSmokeEntry(resultPath, retries: 40)
    }

    private func waitForTmuxSmokeEntry(_ resultPath: String, retries: Int) {
        guard retries > 0 else {
            let live = activePaneId
                .flatMap { terminalPanes[$0] as? RustTmuxPane }?
                .cursorPosition()
            let projected = tmuxSession?.latestPanes.values.first(where: { $0.active })
            writeSessionSmokeResult(
                resultPath,
                result: "failed tmux-native entry-timeout "
                    + "live-cursor=\(live?.x ?? -1),\(live?.y ?? -1) "
                    + "tmux-cursor=\(projected.map { Int($0.cursor_x) } ?? -1),"
                    + "\(projected.map { Int($0.cursor_y) } ?? -1)\n"
            )
            return
        }
        guard tmuxSession != nil,
              lastSnapshot?.tabs.count == 1,
              lastSnapshot?.tabs.first?.panes.count == 1,
              sessionControlTitle().hasPrefix("tmux · "),
              view.window?.title.contains("tmux · ") == true
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForTmuxSmokeEntry(resultPath, retries: retries - 1)
            }
            return
        }
        guard let tmuxPane = activePaneId.flatMap({ terminalPanes[$0] as? RustTmuxPane }) else {
            writeSessionSmokeResult(resultPath, result: "failed tmux-native missing-pane\n")
            return
        }
        let projectedPane = tmuxSession?.latestPanes.values.first { $0.active }
        let currentGrid = tmuxClientGrid()
        let gridIsSettled = tmuxSession?.lastClientGrid?.cols == currentGrid.cols
            && tmuxSession?.lastClientGrid?.rows == currentGrid.rows
        guard let tmuxCursor = tmuxPane.cursorPosition(),
              tmuxCursor.x > 0,
              let projectedPane,
              tmuxCursor.x == Int(projectedPane.cursor_x),
              tmuxCursor.y == Int(projectedPane.cursor_y),
              gridIsSettled
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForTmuxSmokeEntry(resultPath, retries: retries - 1)
            }
            return
        }
        let cursorProbe = "TMUX_CURSOR_ADVANCE"
        guard tmuxPane.writeThroughTmux(Data(cursorProbe.utf8)) else {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native cursor-input=no\n")
            return
        }
        waitForTmuxSmokeLiveCursor(
            resultPath,
            pane: tmuxPane,
            start: tmuxCursor,
            marker: cursorProbe,
            retries: 20
        )
    }

    private func waitForTmuxSmokeLiveCursor(
        _ resultPath: String,
        pane: RustTmuxPane,
        start: (x: Int, y: Int),
        marker: String,
        retries: Int
    ) {
        let cursor = pane.cursorPosition()
        let cursorAdvanced = cursor?.y == start.y
            && (cursor?.x ?? -1) >= start.x + marker.count
        let inputVisible = pane.controlScreenText().contains(marker)
        guard cursorAdvanced, inputVisible else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxSmokeLiveCursor(
                        resultPath,
                        pane: pane,
                        start: start,
                        marker: marker,
                        retries: retries - 1
                    )
                }
            } else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-native live-cursor=no "
                        + "start=\(start.x),\(start.y) "
                        + "observed=\(cursor?.x ?? -1),\(cursor?.y ?? -1)\n"
                )
            }
            return
        }
        guard pane.writeThroughTmux(Data([3])) else {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native cursor-clear=no\n")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.continueTmuxSmokeIME(resultPath, pane: pane)
        }
    }

    private func continueTmuxSmokeIME(_ resultPath: String, pane tmuxPane: RustTmuxPane) {
        terminalTextView.setMarkedText(
            "TMUX_IME_PREEDIT",
            selectedRange: NSRange(location: 16, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let imeOrigin = terminalTextView.markedTextOriginForSmoke()
        guard let paneId = activePaneId,
              let paneFrame = visiblePaneFrames[paneId],
              paneFrame.contains(imeOrigin),
              imeOrigin.x > paneFrame.minX + 1
        else {
            terminalTextView.unmarkText()
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native ime-anchor=no\n")
            return
        }
        terminalTextView.insertText(
            "printf 'TMUX_IME_%s\\n' COMMITTED\r",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        _ = tmuxPane.scroll(rows: -10_000)
        let historyVisible = tmuxPane.controlScreenText().contains("TMUX_HISTORY_MARKER")
        _ = tmuxPane.scroll(rows: 10_000)
        guard historyVisible else {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native history=no\n")
            return
        }
        let shellCheck = "test \"$SHELL\" = \"$SATIN_SHELL_EXECUTABLE\" "
            + "&& printf 'TMUX_NATIVE_%s SHELL_MATCH=%s\\n' OUTPUT yes "
            + "|| printf 'TMUX_NATIVE_%s SHELL_MATCH=%s SHELL=%s SELECTED=%s\\n' "
            + "OUTPUT no \"$SHELL\" \"$SATIN_SHELL_EXECUTABLE\""
        writeTextToActivePane("\(shellCheck)\r")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.waitForTmuxSmokeOutput(resultPath, retries: 20)
        }
    }

    private func waitForTmuxSmokeOutput(_ resultPath: String, retries: Int) {
        let screenText = activePaneId
            .flatMap { terminalPanes[$0] as? RustTmuxPane }?
            .controlScreenText() ?? ""
        if screenText.contains("TMUX_NATIVE_OUTPUT SHELL_MATCH=no") {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            let detail = screenText
                .split(separator: "\n")
                .last(where: { $0.contains("TMUX_NATIVE_OUTPUT SHELL_MATCH=no") })
                .map(String.init) ?? "missing"
            writeSessionSmokeResult(
                resultPath,
                result: "failed tmux-native shell-env=no detail=\(detail)\n"
            )
            return
        }
        let outputVisible = screenText.contains("TMUX_NATIVE_OUTPUT SHELL_MATCH=yes")
        let imeInputVisible = screenText.contains("TMUX_IME_COMMITTED")
        guard outputVisible, imeInputVisible else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxSmokeOutput(resultPath, retries: retries - 1)
                }
            } else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native output-timeout\n")
            }
            return
        }
        beginTmuxSmokeKitty(resultPath)
    }

    private func beginTmuxSmokeKitty(_ resultPath: String) {
        guard let pane = activePaneId.flatMap({ terminalPanes[$0] as? RustTmuxPane }) else {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native kitty-pane=no\n")
            return
        }
        let command = "printf '\\033Ptmux;\\033\\033_G"
            + "a=T,f=24,s=1,v=1,i=4242,c=8,r=4,q=2;/wAA"
            + "\\033\\033\\\\\\033\\\\'"
        guard pane.pasteThroughTmux(command), pane.writeThroughTmux(Data([13])) else {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native kitty-input=no\n")
            return
        }
        waitForTmuxSmokeKitty(resultPath, pane: pane, retries: 30)
    }

    private func waitForTmuxSmokeKitty(
        _ resultPath: String,
        pane: RustTmuxPane,
        retries: Int
    ) {
        guard pane.controlImageCount() == 1 else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak pane] in
                    guard let pane else {
                        return
                    }
                    self?.waitForTmuxSmokeKitty(
                        resultPath,
                        pane: pane,
                        retries: retries - 1
                    )
                }
            } else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native kitty-image=no\n")
            }
            return
        }
        let clear = "printf '\\033Ptmux;\\033\\033_Ga=d,d=I,i=4242,q=2"
            + "\\033\\033\\\\\\033\\\\'"
        guard pane.pasteThroughTmux(clear), pane.writeThroughTmux(Data([13])) else {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native kitty-clear=no\n")
            return
        }
        beginTmuxSmokeReturnRepeat(resultPath)
    }

    private func beginTmuxSmokeReturnRepeat(_ resultPath: String) {
        guard let pane = activePaneId.flatMap({ terminalPanes[$0] as? RustTmuxPane }),
              pane.writeThroughTmux(Data("PS1='TMUX_REPEAT> '\r".utf8))
        else {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native repeat-setup=no\n")
            return
        }
        waitForTmuxSmokeReturnPrompt(resultPath, pane: pane, retries: 20)
    }

    private func waitForTmuxSmokeReturnPrompt(
        _ resultPath: String,
        pane: RustTmuxPane,
        retries: Int
    ) {
        let marker = "TMUX_REPEAT>"
        let lastLine = pane.controlScreenText()
            .split(separator: "\n")
            .last
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard lastLine == marker else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak pane] in
                    guard let pane else {
                        return
                    }
                    self?.waitForTmuxSmokeReturnPrompt(
                        resultPath,
                        pane: pane,
                        retries: retries - 1
                    )
                }
            } else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native repeat-prompt=no\n")
            }
            return
        }
        sendTmuxSmokeReturnRepeat(resultPath, pane: pane, remaining: 65)
    }

    private func sendTmuxSmokeReturnRepeat(
        _ resultPath: String,
        pane: RustTmuxPane,
        remaining: Int
    ) {
        guard remaining > 0 else {
            if let event = tmuxSmokeReturnEvent(repeated: false, released: true) {
                _ = pane.key(event, released: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak pane] in
                guard let pane else {
                    return
                }
                self?.validateTmuxSmokeReturnRepeat(resultPath, pane: pane, retries: 10)
            }
            return
        }
        guard let event = tmuxSmokeReturnEvent(repeated: true, released: false),
              pane.key(event, released: false)
        else {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native repeat-input=no\n")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak pane] in
            guard let pane else {
                return
            }
            self?.sendTmuxSmokeReturnRepeat(
                resultPath,
                pane: pane,
                remaining: remaining - 1
            )
        }
    }

    private func validateTmuxSmokeReturnRepeat(
        _ resultPath: String,
        pane: RustTmuxPane,
        retries: Int
    ) {
        let marker = "TMUX_REPEAT>"
        let lines = pane.controlScreenText().components(separatedBy: .newlines)
        let markerRows = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces) == marker
        }
        let continuous = markerRows.count >= 10
            && markerRows.first.flatMap { first in
                markerRows.last.map { last in
                    lines[first...last].allSatisfy {
                        $0.trimmingCharacters(in: .whitespaces) == marker
                    }
                }
            } == true
        guard continuous else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak pane] in
                    guard let pane else {
                        return
                    }
                    self?.validateTmuxSmokeReturnRepeat(
                        resultPath,
                        pane: pane,
                        retries: retries - 1
                    )
                }
            } else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-native repeat-gap=yes rows=\(markerRows.count)\n"
                )
            }
            return
        }
        continueTmuxSmokeSplit(resultPath)
    }

    private func tmuxSmokeReturnEvent(repeated: Bool, released: Bool) -> NSEvent? {
        NSEvent.keyEvent(
            with: released ? .keyUp : .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: repeated,
            keyCode: 36
        )
    }

    private func continueTmuxSmokeSplit(_ resultPath: String) {
        guard let paneId = activePaneId,
              runTmuxSmokeControl([
                  "command": "split",
                  "pane": paneId,
                  "axis": "vertical",
              ])
        else {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native cli-split=no\n")
            return
        }
        waitForTmuxSmokeSplit(resultPath, previousPaneId: paneId, retries: 30)
    }

    private func waitForTmuxSmokeSplit(
        _ resultPath: String,
        previousPaneId: Int,
        retries: Int
    ) {
        guard lastSnapshot?.tabs.first?.panes.count == 2,
              activePaneId != previousPaneId
        else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxSmokeSplit(
                        resultPath,
                        previousPaneId: previousPaneId,
                        retries: retries - 1
                    )
                }
            } else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native split-timeout\n")
            }
            return
        }
        let expected = tmuxClientGrid()
        guard tmuxSession?.lastClientGrid?.cols == expected.cols,
              tmuxSession?.lastClientGrid?.rows == expected.rows
        else {
            let observed = tmuxSession?.lastClientGrid
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(
                resultPath,
                result: "failed tmux-native client-grid expected=\(expected.cols)x\(expected.rows) "
                    + "observed=\(observed?.cols ?? -1)x\(observed?.rows ?? -1)\n"
            )
            return
        }
        guard let tab = lastSnapshot?.tabs.first,
              let currentPaneId = activePaneId,
              let targetPaneId = tab.panes.first(where: { $0 != currentPaneId })
        else {
            writeSessionSmokeResult(resultPath, result: "failed tmux-native action-context\n")
            return
        }
        selectPane(targetPaneId)
        terminalTextView.insertText(
            "printf 'TMUX_FOCUS_%s\\n' COMMITTED\r",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        waitForTmuxSmokeFocusInput(resultPath, paneId: targetPaneId, retries: 30)
    }

    private func waitForTmuxSmokeFocusInput(
        _ resultPath: String,
        paneId: Int,
        retries: Int
    ) {
        let focusedInputVisible = (terminalPanes[paneId] as? RustTmuxPane)?
            .controlScreenText()
            .contains("TMUX_FOCUS_COMMITTED") == true
        guard focusedInputVisible, activePaneId == paneId else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxSmokeFocusInput(
                        resultPath,
                        paneId: paneId,
                        retries: retries - 1
                    )
                }
            } else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native focus-input=no\n")
            }
            return
        }
        continueTmuxSmokeActions(resultPath, paneId: paneId)
    }

    private func continueTmuxSmokeActions(_ resultPath: String, paneId: Int) {
        guard let session = tmuxSession,
              let tab = lastSnapshot?.tabs.first,
              let pane = terminalPanes[paneId] as? RustTmuxPane
        else {
            writeSessionSmokeResult(resultPath, result: "failed tmux-native action-context\n")
            return
        }
        guard runTmuxSmokeControl([
            "command": "rename-tab",
            "tab": tab.id,
            "title": "tmux renamed",
        ]) else {
            session.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native cli-rename=no\n")
            return
        }
        let pasteAccepted = pane.pasteThroughTmux("printf 'TMUX_PASTE_OK\\n'")
        let enterAccepted = pane.writeThroughTmux(Data([13]))
        guard pasteAccepted, enterAccepted else {
            session.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(
                resultPath,
                result: "failed tmux-native input-rejected "
                    + "paste=\(pasteAccepted ? "yes" : "no") "
                    + "enter=\(enterAccepted ? "yes" : "no")\n"
            )
            return
        }
        waitForTmuxSmokePaste(resultPath, retries: 30)
    }

    private func waitForTmuxSmokePaste(_ resultPath: String, retries: Int) {
        let pasted = terminalPanes.values.contains { pane in
            (pane as? RustTmuxPane)?.controlScreenText().contains("TMUX_PASTE_OK") == true
        }
        guard pasted else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxSmokePaste(resultPath, retries: retries - 1)
                }
            } else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native paste-timeout\n")
            }
            return
        }
        toggleTmuxPaneZoom(nil)
        waitForTmuxSmokeZoom(resultPath, retries: 30)
    }

    private func waitForTmuxSmokeZoom(_ resultPath: String, retries: Int) {
        guard lastSnapshot?.tabs.first?.panes.count == 1,
              tmuxSession?.activeWindowZoomed == true,
              sessionControlTitle().contains("· Zoom")
        else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxSmokeZoom(resultPath, retries: retries - 1)
                }
            } else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native zoom-timeout\n")
            }
            return
        }
        toggleTmuxPaneZoom(nil)
        waitForTmuxSmokeUnzoom(resultPath, retries: 30)
    }

    private func waitForTmuxSmokeUnzoom(_ resultPath: String, retries: Int) {
        let paneTexts = terminalPanes.values.compactMap { pane in
            (pane as? RustTmuxPane)?.controlScreenText()
        }
        let screenText = paneTexts.joined(separator: "\n")
        let titleCorrect = lastSnapshot?.tabs.first?.title == "tmux renamed"
        guard lastSnapshot?.tabs.first?.panes.count == 2,
              tmuxSession?.activeWindowZoomed == false,
              screenText.contains("TMUX_PASTE_OK"),
              titleCorrect
        else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxSmokeUnzoom(resultPath, retries: retries - 1)
                }
            } else {
                let paneCount = lastSnapshot?.tabs.first?.panes.count ?? -1
                let zoomed = tmuxSession?.activeWindowZoomed == true
                let pasted = screenText.contains("TMUX_PASTE_OK")
                let detail = paneTexts
                    .map { $0.suffix(300).replacingOccurrences(of: "\n", with: "|") }
                    .joined(separator: " <PANE> ")
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-native unzoom-or-paste "
                        + "panes=\(paneCount) zoomed=\(zoomed ? "yes" : "no") "
                        + "paste=\(pasted ? "yes" : "no") "
                        + "title=\(titleCorrect ? "yes" : "no") detail=\(detail)\n"
                )
            }
            return
        }
        guard runTmuxSmokeControl([
            "command": "new-tab",
            "title": "tmux cli tab",
            "background": false,
        ]) else {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native cli-new-tab=no\n")
            return
        }
        waitForTmuxSmokeTab(resultPath, retries: 30)
    }

    private func waitForTmuxSmokeTab(_ resultPath: String, retries: Int) {
        guard lastSnapshot?.tabs.count == 2 else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxSmokeTab(resultPath, retries: retries - 1)
                }
            } else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native tab-timeout\n")
            }
            return
        }
        tmuxSession?.gateway.tmuxCommand("kill-session")
        waitForTmuxSmokeExit(resultPath, retries: 30)
    }

    private func waitForTmuxSmokeExit(_ resultPath: String, retries: Int) {
        guard tmuxSession == nil else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxSmokeExit(resultPath, retries: retries - 1)
                }
            } else {
                writeSessionSmokeResult(resultPath, result: "failed tmux-native exit-timeout\n")
            }
            return
        }
        let restored = lastSnapshot?.tabs.contains { $0.panes.contains(activePaneId ?? -1) } == true
        let attachmentCleared = currentSessionState()?.tmuxAttachment == nil
        let result = restored && attachmentCleared
            ? "ok tmux-native indicator=yes output=yes history=yes paste=yes zoom=yes "
                + "rename=yes split=2 client-grid=full tabs=2 cli=yes live-cursor=yes "
                + "ime=yes focus-input=yes return-repeat=yes kitty=yes "
                + "shell-env=yes "
                + "shell-restored=yes detach-clears=yes\n"
            : "failed tmux-native shell-restored=\(restored ? "yes" : "no") "
                + "detach-clears=\(attachmentCleared ? "yes" : "no")\n"
        writeSessionSmokeResult(resultPath, result: result)
    }

    private func runTmuxSmokeControl(_ payload: [String: Any]) -> Bool {
        var object = payload
        object["id"] = 1
        object["version"] = 1
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let request = try? JSONDecoder().decode(NativeControlRequest.self, from: data)
        else {
            return false
        }
        var succeeded = false
        handleControlRequest(request) { result in
            if case .success = result {
                succeeded = true
            }
        }
        return succeeded
    }

    func applyTmuxReattachSmokeScenario(
        resultPath: String,
        sessionName: String,
        socketPath: String,
        expectedContent: String
    ) {
        let attachment = NativeTmuxAttachment(
            sessionName: sessionName,
            socketPath: socketPath
        )
        guard let validated = validatedTmuxAttachment(attachment) else {
            writeSessionSmokeResult(resultPath, result: "failed tmux-reattach invalid-descriptor\n")
            return
        }
        pendingTmuxReattach = validated
        schedulePendingTmuxReattach()
        waitForTmuxReattachEntry(
            resultPath,
            attachment: validated,
            expectedContent: expectedContent,
            retries: 40
        )
    }

    private func waitForTmuxReattachEntry(
        _ resultPath: String,
        attachment: NativeTmuxAttachment,
        expectedContent: String,
        retries: Int
    ) {
        guard let session = tmuxSession else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxReattachEntry(
                        resultPath,
                        attachment: attachment,
                        expectedContent: expectedContent,
                        retries: retries - 1
                    )
                }
            } else {
                writeSessionSmokeResult(resultPath, result: "failed tmux-reattach entry-timeout\n")
            }
            return
        }
        let descriptorSaved = currentSessionState()?.tmuxAttachment == attachment
        guard session.sessionName == attachment.sessionName,
              session.socketPath == attachment.socketPath,
              descriptorSaved,
              sessionControlTitle().hasPrefix("tmux · ")
        else {
            _ = session.gateway.tmuxCommand("detach-client")
            writeSessionSmokeResult(
                resultPath,
                result: "failed tmux-reattach topology-or-descriptor\n"
            )
            return
        }
        let existingContentVisible = terminalPanes.values.contains { pane in
            guard let tmuxPane = pane as? RustTmuxPane else {
                return false
            }
            return tmuxPane.controlScreenText().contains(expectedContent)
        }
        guard existingContentVisible else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxReattachEntry(
                        resultPath,
                        attachment: attachment,
                        expectedContent: expectedContent,
                        retries: retries - 1
                    )
                }
            } else {
                _ = session.gateway.tmuxCommand("detach-client")
                let detail = terminalPanes.values.compactMap { pane in
                    (pane as? RustTmuxPane)?.controlScreenText()
                }.joined(separator: " | ").prefix(800)
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-reattach existing-content=no detail=\(detail)\n"
                )
            }
            return
        }
        guard let pane = activePaneId.flatMap({ terminalPanes[$0] as? RustTmuxPane }) else {
            _ = session.gateway.tmuxCommand("detach-client")
            writeSessionSmokeResult(resultPath, result: "failed tmux-reattach active-pane=no\n")
            return
        }
        pane.write(Data("\u{1b}:qa!\r".utf8))
        waitForTmuxReattachPrimaryRestore(resultPath, retries: 30)
    }

    private func waitForTmuxReattachPrimaryRestore(_ resultPath: String, retries: Int) {
        let primaryVisible = activePaneId
            .flatMap { terminalPanes[$0] as? RustTmuxPane }?
            .controlScreenText()
            .contains("SATIN_TMUX_REATTACH_PRIMARY_CONTENT") == true
        guard primaryVisible else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxReattachPrimaryRestore(resultPath, retries: retries - 1)
                }
            } else {
                _ = tmuxSession?.gateway.tmuxCommand("detach-client")
                writeSessionSmokeResult(resultPath, result: "failed tmux-reattach primary-restore=no\n")
            }
            return
        }
        _ = tmuxSession?.gateway.tmuxCommand("detach-client")
        waitForTmuxReattachDetach(resultPath, retries: 30)
    }

    private func waitForTmuxReattachDetach(_ resultPath: String, retries: Int) {
        guard tmuxSession == nil else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxReattachDetach(resultPath, retries: retries - 1)
                }
            } else {
                writeSessionSmokeResult(resultPath, result: "failed tmux-reattach detach-timeout\n")
            }
            return
        }
        let attachmentCleared = currentSessionState()?.tmuxAttachment == nil
        let status = attachmentCleared ? "ok" : "failed"
        writeSessionSmokeResult(
            resultPath,
            result: "\(status) tmux-reattach attached=yes descriptor=yes alternate=yes "
                + "primary-restored=yes "
                + "explicit-detach-clears=\(attachmentCleared ? "yes" : "no")\n"
        )
    }

    func applyMissingTmuxReattachSmokeScenario(
        resultPath: String,
        sessionName: String,
        socketPath: String
    ) {
        let attachment = NativeTmuxAttachment(
            sessionName: sessionName,
            socketPath: socketPath
        )
        guard let validated = validatedTmuxAttachment(attachment) else {
            writeSessionSmokeResult(
                resultPath,
                result: "failed tmux-reattach-missing invalid-descriptor\n"
            )
            return
        }
        pendingTmuxReattach = validated
        schedulePendingTmuxReattach()
        waitForMissingTmuxReattach(resultPath, retries: 40)
    }

    private func waitForMissingTmuxReattach(_ resultPath: String, retries: Int) {
        let terminalText = activePaneId
            .flatMap { terminalPanes[$0] as? RustTerminalPane }?
            .controlScreenText() ?? ""
        let errorVisible = terminalText.contains("can't find session")
        let attachmentCleared = currentSessionState()?.tmuxAttachment == nil
        guard tmuxSession == nil, errorVisible, attachmentCleared else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForMissingTmuxReattach(resultPath, retries: retries - 1)
                }
            } else {
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-reattach-missing error-visible="
                        + "\(errorVisible ? "yes" : "no")\n"
                )
            }
            return
        }
        writeSessionSmokeResult(
            resultPath,
            result: "ok tmux-reattach-missing error-visible=yes shell-restored=yes\n"
        )
    }

    func applyTabBarActionsSmokeScenario(resultPath: String) {
        waitForTabBarActionsSmokeScenario(resultPath: resultPath, retries: 20)
    }

    private func waitForTabBarActionsSmokeScenario(resultPath: String, retries: Int) {
        view.layoutSubtreeIfNeeded()
        let controlsReady = sessionControlButton.superview != nil
            && toolbarActionControl.superview != nil
            && (0..<3).allSatisfy { toolbarActionControl.image(forSegment: $0) != nil }
        let shortcutsReady = mainMenuShortcutMatches(
            actionName: "splitVertical:",
            shortcut: settings.shortcut(for: .splitVertical)
        ) && mainMenuShortcutMatches(
            actionName: "splitHorizontal:",
            shortcut: settings.shortcut(for: .splitHorizontal)
        )
        if !shortcutsReady, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.waitForTabBarActionsSmokeScenario(
                    resultPath: resultPath,
                    retries: retries - 1
                )
            }
            return
        }
        let chromeReady = NativePlatformAppearance.toolbarControlsUseExpectedPresentation(
            toolbarControlsView
        )
        let compactChrome = view.window?.toolbarStyle == .unifiedCompact
            && (!NativePlatformAppearance.usesLiquidGlass
                || toolbarControlsView.intrinsicContentSize.height <= 30)
        let contentBelowChrome = metalView.frame.maxY <= view.safeAreaRect.maxY + 0.5
        let backdropSpansWindow = backdropView.frame.maxY >= view.bounds.maxY - 0.5
        if controlsReady {
            newTab(nil)
            splitVertical(nil)
            splitHorizontal(nil)
        }
        guard let snapshot = core.snapshot(),
              let activeTab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab })
        else {
            writeSessionSmokeResult(resultPath, result: "failed tab-bar-actions snapshot=missing\n")
            return
        }
        let metrics = paneLayoutMetrics(activeTab.layout)
        let axes = metrics.axes.sorted()
        let ok = controlsReady
            && shortcutsReady
            && chromeReady
            && compactChrome
            && contentBelowChrome
            && backdropSpansWindow
            && snapshot.tabs.count == 2
            && snapshot.active_tab == 1
            && metrics.leaves == 3
            && metrics.splits == 2
            && axes == ["horizontal", "vertical"]
        let status = ok ? "ok" : "failed"
        writeSessionSmokeResult(
            resultPath,
            result: "\(status) tab-bar-actions controls=\(controlsReady ? "ready" : "invalid") "
                + "shortcuts=\(shortcutsReady ? "ready" : "invalid") "
                + "chrome=\(NativePlatformAppearance.usesLiquidGlass ? "glass" : "standard") "
                + "density=\(compactChrome ? "compact" : "regular") "
                + "content=\(contentBelowChrome ? "safe" : "under-titlebar") "
                + "background=\(backdropSpansWindow ? "edge-to-edge" : "inset") "
                + "tabs=\(snapshot.tabs.count) active=\(snapshot.active_tab) "
                + "leaves=\(metrics.leaves) splits=\(metrics.splits) "
                + "axes=\(axes.joined(separator: ","))\n"
        )
    }

    private func mainMenuShortcutMatches(
        actionName: String,
        shortcut: NativeKeyShortcut
    ) -> Bool {
        guard let item = mainMenuItem(in: NSApp.mainMenu, actionName: actionName) else {
            return false
        }
        let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
        let expected = shortcut.modifiers.intersection(.deviceIndependentFlagsMask)
        return item.keyEquivalent == shortcut.keyEquivalent && modifiers == expected
    }

    private func mainMenuItem(in menu: NSMenu?, actionName: String) -> NSMenuItem? {
        guard let menu else {
            return nil
        }
        for item in menu.items {
            if item.action.map(NSStringFromSelector) == actionName {
                return item
            }
            if let match = mainMenuItem(in: item.submenu, actionName: actionName) {
                return match
            }
        }
        return nil
    }

    func applyHomeWorkingDirectorySmokeScenario(resultPath: String) {
        let expected = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let actual = activeWorkingDirectory()
        let processDirectory = FileManager.default.currentDirectoryPath
        let ok = settings.startupDirectory.isEmpty
            && processDirectory == "/"
            && actual == expected
        let status = ok ? "ok" : "failed"
        writeSessionSmokeResult(
            resultPath,
            result: "\(status) home-cwd startup=default "
                + "process=\(processDirectory == "/" ? "root" : "other") "
                + "pane=\(actual == expected ? "home" : "other")\n"
        )
    }

    func applyTerminalResizeSmokeScenario(resultPath: String) {
        guard let window = view.window else {
            writeSessionSmokeResult(resultPath, result: "failed terminal-resize no-window\n")
            return
        }
        window.setContentSize(NSSize(width: 780, height: 480))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak window] in
            guard let self, let window else {
                return
            }
            let initial = terminalTextView.terminalGridSize()
            window.setContentSize(NSSize(width: 1120, height: 760))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else {
                    return
                }
                resizeTerminalPanesToGrid()
                let resized = terminalTextView.terminalGridSize()
                let ok = resized.rows > initial.rows
                    && resized.cols > initial.cols
                    && terminalPanes[activePaneId ?? -1] != nil
                let status = ok ? "ok" : "failed"
                writeSessionSmokeResult(
                    resultPath,
                    result: "\(status) terminal-resize " +
                        "from=\(initial.cols)x\(initial.rows) to=\(resized.cols)x\(resized.rows)\n"
                )
            }
        }
    }

    private func sessionPaneCounts(
        _ pane: NativeSessionPane
    ) -> (leaves: Int, splits: Int, activeLeaves: Int) {
        if pane.kind == "leaf" {
            return (1, 0, pane.active ? 1 : 0)
        }
        let empty = (leaves: 0, splits: 0, activeLeaves: 0)
        let first = pane.first.map(sessionPaneCounts) ?? empty
        let second = pane.second.map(sessionPaneCounts) ?? empty
        return (
            first.leaves + second.leaves,
            first.splits + second.splits + 1,
            first.activeLeaves + second.activeLeaves
        )
    }

    private func paneLayoutMetrics(
        _ pane: PaneLayoutSnapshot
    ) -> (leaves: Int, splits: Int, axes: Set<String>) {
        if pane.kind == "leaf" {
            return (1, 0, [])
        }
        let empty = (leaves: 0, splits: 0, axes: Set<String>())
        let first = pane.first.map(paneLayoutMetrics) ?? empty
        let second = pane.second.map(paneLayoutMetrics) ?? empty
        var axes = first.axes.union(second.axes)
        if let axis = pane.axis {
            axes.insert(axis)
        }
        return (
            first.leaves + second.leaves,
            first.splits + second.splits + 1,
            axes
        )
    }

    private func writeSessionSmokeResult(_ path: String, result: String) {
        try? result.write(toFile: path, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    func applyTerminalBottomInputSmokeScenario(resultPath: String) {
        let command = [
            "i=0",
            "while [ $i -lt 80 ]; do printf '\\n'; i=$((i + 1)); done",
        ].joined(separator: "; ")
        writeToActivePane(Data("\(command)\r".utf8))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.waitForTerminalBottomInputIdleThenType(resultPath, retries: 24)
        }
    }

    func applyTerminalExitClosesTabSmokeScenario(resultPath: String) {
        core.newTab()
        syncFromCore()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.writeToActivePane(Data("exit\r".utf8))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.writeTerminalExitClosesTabSmokeResult(resultPath, retries: 16)
        }
    }

    func applyTerminalNvimHandoffSmokeScenario(resultPath: String) {
        openNativeNeovim(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.runNvimCommandOrWrite(
                "enew | call setline(1, 'HANDOFFNVIM') | call cursor(1, 1)",
                fallback: Data()
            )
            self?.metalView.resetSkiaFrameCount()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.writeTerminalNvimHandoffSmokeResult(resultPath, retries: 16)
        }
    }

    func applyFinderEditorSmokeScenario(resultPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.writeFinderEditorSmokeResult(resultPath, retries: 48)
        }
    }

    private func writeFinderEditorSmokeResult(_ resultPath: String, retries: Int) {
        let marker = "SATIN_FINDER_EDITOR_MARKER"
        let snapshot = core.snapshot()
        let oneTab = snapshot?.tabs.count == 1
        let onePane = snapshot?.tabs.first?.panes.count == 1
        let actualMode = activePaneMode()
        let expectedMode = ProcessInfo.processInfo.environment[
            "SATIN_NATIVE_SMOKE_FINDER_MODE"
        ] == "terminal" ? NativePaneMode.terminal : .neovim
        let expectedPaneMode = actualMode == expectedMode
        let markerCount: Int
        if actualMode == .terminal,
           let paneId = activePaneId,
           let pane = terminalPanes[paneId] {
            markerCount = pane.controlScreenText().components(separatedBy: marker).count - 1
        } else {
            markerCount = terminalTextView.rendererModelTextOccurrences(marker)
        }
        let ok = oneTab && onePane && expectedPaneMode && markerCount == 1
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.writeFinderEditorSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }
        let summary = [
            "simple=\(oneTab && onePane ? "yes" : "no")",
            "mode=\(actualMode.sessionValue)",
            "marker=\(markerCount)",
        ].joined(separator: " ")
        let result = ok
            ? "ok finder-editor \(summary)\n"
            : "failed finder-editor \(summary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    func applyShellNvimNativeSmokeScenario(resultPath: String) {
        let fixture = "/tmp/satin-shell-nvim-native-smoke.txt"
        let before = "/tmp/satin-shell-nvim-native-before.txt"
        let after = "/tmp/satin-shell-nvim-native-after.txt"
        let forwarded = "/tmp/satin-shell-nvim-native-environment.txt"
        writeSmokeLines(path: fixture)
        try? FileManager.default.removeItem(atPath: before)
        try? FileManager.default.removeItem(atPath: after)
        try? FileManager.default.removeItem(atPath: forwarded)
        let command = [
            "export SATIN_SHELL_CONTINUITY=preserved",
            "export SATIN_LAUNCH_ENVIRONMENT=forwarded",
            "printf '%s' \"$$\" > \(shellQuote(before))",
            "nvim -Nu NONE -n \(shellQuote(fixture))",
            "printf '%s:%s:%s' \"$$\" \"$SATIN_SHELL_CONTINUITY\" \"$?\" " +
                "> \(shellQuote(after))",
        ].joined(separator: "; ")
        writeToActivePane(Data("\(command)\r".utf8))
        waitForShellNvimNativeContent(
            resultPath,
            beforePath: before,
            afterPath: after,
            retries: 48
        )
    }

    private func waitForShellNvimNativeContent(
        _ resultPath: String,
        beforePath: String,
        afterPath: String,
        retries: Int
    ) {
        let ready = activePaneMode() == .neovim
            && terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker])
        guard ready else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.waitForShellNvimNativeContent(
                        resultPath,
                        beforePath: beforePath,
                        afterPath: afterPath,
                        retries: retries - 1
                    )
                }
                return
            }
            writeShellNvimNativeSmokeFailure(resultPath, reason: "native-launch-timeout")
            return
        }
        runNvimCommandOrWrite(
            "call writefile([$SATIN_LAUNCH_ENVIRONMENT], " +
                "'\(vimSingleQuote("/tmp/satin-shell-nvim-native-environment.txt"))')",
            fallback: Data()
        )
        runNvimCommandOrWrite(
            "topleft vertical 24new | terminal",
            fallback: Data()
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else {
                return
            }
            runNvimCommandOrWrite("wincmd l", fallback: Data())
            clearSmokeScrollShift()
            metalView.resetSkiaFrameCount()
            writeToActivePane(Data([0x04]))
            waitForShellNvimNativeScroll(
                resultPath,
                beforePath: beforePath,
                afterPath: afterPath,
                retries: 24
            )
        }
    }

    private func waitForShellNvimNativeScroll(
        _ resultPath: String,
        beforePath: String,
        afterPath: String,
        retries: Int
    ) {
        let shift = peekSmokeScrollShift()
        let skiaFrames = metalView.skiaFrames()
        let ok = shift.map { value in
            abs(value.rows) > maxOutputScrollAnimationRows && (value.startCol ?? 0) > 0
        } ?? false
        guard ok && skiaFrames >= 2 else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForShellNvimNativeScroll(
                        resultPath,
                        beforePath: beforePath,
                        afterPath: afterPath,
                        retries: retries - 1
                    )
                }
                return
            }
            writeShellNvimNativeSmokeFailure(resultPath, reason: "split-scroll-missing")
            return
        }
        let summary = nvimAnimationSmokeSummary(
            shift,
            hasModelFrames: terminalTextView.hasRendererModelFrames(),
            skiaFrames: skiaFrames
        )
        runNvimCommandOrWrite("cquit! 7", fallback: Data())
        waitForShellNvimResume(
            resultPath,
            beforePath: beforePath,
            afterPath: afterPath,
            scrollSummary: summary,
            retries: 48
        )
    }

    private func waitForShellNvimResume(
        _ resultPath: String,
        beforePath: String,
        afterPath: String,
        scrollSummary: String,
        retries: Int
    ) {
        let before = try? String(contentsOfFile: beforePath, encoding: .utf8)
        let after = try? String(contentsOfFile: afterPath, encoding: .utf8)
        let forwarded = try? String(
            contentsOfFile: "/tmp/satin-shell-nvim-native-environment.txt",
            encoding: .utf8
        )
        let resumed = activePaneMode() == .terminal
            && before.map { "\($0):preserved:7" } == after
            && forwarded == "forwarded\n"
        guard resumed else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForShellNvimResume(
                        resultPath,
                        beforePath: beforePath,
                        afterPath: afterPath,
                        scrollSummary: scrollSummary,
                        retries: retries - 1
                    )
                }
                return
            }
            writeShellNvimNativeSmokeFailure(resultPath, reason: "shell-resume-timeout")
            return
        }
        let result = "ok shell-nvim-native terminal-split=yes same-shell=yes " +
            "environment=yes exit-status=yes \(scrollSummary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func writeShellNvimNativeSmokeFailure(_ resultPath: String, reason: String) {
        let result = "failed shell-nvim-native reason=\(reason) mode=\(activePaneMode()) " +
            "\(terminalTextView.rendererViewportSummary())\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    func applyTerminalNvimCwdSmokeScenario(resultPath: String) {
        let cwd = ProcessInfo.processInfo.environment["SATIN_NATIVE_CWD_EXPECTED"]
            ?? "/tmp/satin-terminal-nvim-cwd"
        let cwdFile = ProcessInfo.processInfo.environment["SATIN_NATIVE_CWD_ACTUAL"]
            ?? "/tmp/satin-terminal-nvim-cwd.actual"
        try? FileManager.default.createDirectory(
            atPath: cwd,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(atPath: cwdFile)

        let cwdCommand = [
            "cd \(shellQuote(cwd))",
            "printf '\\u{1b}]7;file://localhost\(cwd)\\u{07}'",
        ].joined(separator: "; ")
        writeToActivePane(Data("\(cwdCommand)\r".utf8))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.openNativeNeovim(nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.runNvimCommandOrWrite(
                "call writefile([getcwd()], '\(vimSingleQuote(cwdFile))')",
                fallback: Data()
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.writeTerminalNvimCwdSmokeResult(
                resultPath,
                expected: cwd,
                actualFile: cwdFile,
                retries: 16
            )
        }
    }

    func applyTerminalNvimQuitSmokeScenario(resultPath: String) {
        openNativeNeovim(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.runNvimCommandOrWrite("qa!", fallback: Data())
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.waitForTerminalAfterNvimQuit(resultPath, retries: 20)
        }
    }

    func applyNvimScrollSmokeScenario(resultPath: String) {
        openNvimSmokeBuffer(
            path: "/tmp/satin-nvim-scroll-smoke.txt",
            terminalCommand: "nvim -Nu NONE -n $tmp"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            guard let self else {
                return
            }
            clearSmokeScrollShift()
            metalView.resetSkiaFrameCount()
            writeToActivePane(Data([0x04]))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.75) { [weak self] in
            self?.writeNvimAnimationSmokeResult(resultPath, retries: 12)
        }
    }

    func applyNvimJumpSmokeScenario(resultPath: String) {
        openNvimSmokeBuffer(
            path: "/tmp/satin-nvim-jump-smoke.txt",
            terminalCommand: "nvim -Nu NONE -n $tmp"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.waitForNvimSmokeContentThenJump(resultPath, retries: 24)
        }
    }

    func applyNvimSidePaneSmokeScenario(resultPath: String) {
        openNvimSmokeBuffer(
            path: "/tmp/satin-nvim-side-pane-smoke.txt",
            terminalCommand: "nvim -Nu NONE -n $tmp"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else {
                return
            }
            runNvimCommandOrWrite(
                "topleft vertical 24new",
                fallback: Data("\u{1b}:topleft vertical 24new\r".utf8)
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self else {
                return
            }
            runNvimCommandOrWrite(
                "wincmd l",
                fallback: Data(":wincmd l\r".utf8)
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) { [weak self] in
            guard let self else {
                return
            }
            clearSmokeScrollShift()
            metalView.resetSkiaFrameCount()
            writeToActivePane(Data([0x04]))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.8) { [weak self] in
            self?.writeNvimSidePaneSmokeResult(resultPath, retries: 8)
        }
    }

    func applyNvimCommandLineSmokeScenario(resultPath: String) {
        openNvimSmokeBuffer(
            path: "/tmp/satin-nvim-commandline-smoke.txt",
            terminalCommand: "nvim -Nu NONE -n $tmp"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self else {
                return
            }
            clearSmokeScrollShift()
            writeToActivePane(Data("\u{1b}:qa".utf8))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            self?.writeNvimNoScrollSmokeResult(resultPath, label: "commandline")
        }
    }

    func applyNvimCursorMoveSmokeScenario(resultPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else {
                return
            }
            let command = "enew! | call setline(1, ['\(nvimSmokeReadyMarker)'] + " +
                "map(range(1, 9), '\"SATIN_STABLE_ROW_\" . " +
                "printf(\"%02d\", v:val) . \"_ABCDEFGHIJKLMNOPQRSTUVWXYZ\"')) | " +
                "setlocal scrolloff=0 nosmoothscroll | normal! gg"
            runNvimCommandOrWrite(command, fallback: Data())
            waitForNvimCursorMoveContent(resultPath, retries: 24)
        }
    }

    func applyNvimShapedTextSmokeScenario(resultPath: String) {
        openNvimShapedTextSmokeBuffer(
            path: "/tmp/satin-nvim-shaped-text-smoke.txt",
            terminalCommand: "nvim -Nu NONE -n $tmp"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            self?.writeNvimShapedTextSmokeResult(resultPath, retries: 16)
        }
    }

    func applyNvimSkiaSmokeScenario(resultPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.configureNvimSkiaSmoke()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            self?.writeNvimSkiaSmokeResult(resultPath, retries: 12)
        }
    }

    func applyNvimImageSmokeScenario(resultPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.configureNvimSkiaSmoke()
            self?.sendNvimImageSmokePlacement()
            self?.metalView.resetSkiaFrameCount()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            self?.writeNvimImageSmokeResult(resultPath, retries: 12)
        }
    }

    func applyNvimUiSurfacesSmokeScenario(resultPath: String) {
        openNvimSmokeBuffer(
            path: "/tmp/satin-nvim-ui-surfaces-smoke.txt",
            terminalCommand: "nvim -Nu NONE -n $tmp"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else {
                return
            }
            runNvimCommandOrWrite("vnew", fallback: Data("\u{1b}:vnew\r".utf8))
            runNvimCommandOrWrite(
                "call setline(1, 'RIGHTSPLIT')",
                fallback: Data(":call setline(1, 'RIGHTSPLIT')\r".utf8)
            )
            runNvimCommandOrWrite(
                nvimSmokeStatuslineCommand(),
                fallback: Data(":set laststatus=2 statusline=STATUSLINE\r".utf8)
            )
            runNvimCommandOrWrite(
                nvimFloatCommand(),
                fallback: Data(":echo 'FLOATBOX'\r".utf8)
            )
            runNvimCommandOrWrite(
                "echo 'MSGBOX'",
                fallback: Data(":echo 'MSGBOX'\r".utf8)
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
            guard let self else {
                return
            }
            runNvimCommandOrWrite(
                nvimSmokeStatuslineCommand(),
                fallback: Data(":set laststatus=2 statusline=STATUSLINE\r".utf8)
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.45) { [weak self] in
            self?.exerciseNvimMessageSelectionSmoke()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.7) { [weak self] in
            self?.writeNvimUiSurfacesSmokeResult(resultPath, retries: 12)
        }
    }

    func applyNvimPopupmenuSmokeScenario(resultPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.configureNvimPopupmenuSmoke()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            self?.writeNvimPopupmenuSmokeResult(resultPath, retries: 12)
        }
    }

    func applyNvimFileTreeSmokeScenario(resultPath: String) {
        let openedPath = "/tmp/satin-nvim-file-tree-opened.txt"
        let treeLinesPath = "/tmp/satin-nvim-file-tree-lines.txt"
        let cwdPath = "/tmp/satin-nvim-file-tree-cwd.txt"
        try? FileManager.default.removeItem(atPath: openedPath)
        try? FileManager.default.removeItem(atPath: treeLinesPath)
        try? FileManager.default.removeItem(atPath: cwdPath)
        nvimFileTreeSmokeTarget = "none"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else {
                return
            }
            runNvimCommandOrWrite(
                "call writefile([getcwd()], '\(vimSingleQuote(cwdPath))')",
                fallback: Data()
            )
            runNvimCommandOrWrite(
                nvimFileTreeOpenCommand(),
                fallback: Data([0x10])
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            self?.runNvimCommandOrWrite(
                "call search('Cargo.toml')",
                fallback: Data("/Cargo.toml\r".utf8)
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.runNvimCommandOrWrite(
                "call writefile(getline(1, '$'), '\(vimSingleQuote(treeLinesPath))')",
                fallback: Data()
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) { [weak self] in
            self?.clickNvimFileTreeSmokeTarget()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.7) { [weak self] in
            self?.writeToActivePane(Data([13]))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.3) { [weak self] in
            self?.runNvimCommandOrWrite(
                "call writefile([expand('%:t')], '\(vimSingleQuote(openedPath))')",
                fallback: Data()
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.7) { [weak self] in
            self?.writeNvimFileTreeSmokeResult(
                resultPath,
                openedPath: openedPath,
                treeLinesPath: treeLinesPath,
                cwdPath: cwdPath,
                retries: 12
            )
        }
    }

    func applyNvimFileTreeCursorMoveSmokeScenario(resultPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else {
                return
            }
            runNvimCommandOrWrite(
                nvimFileTreeOpenCommand(),
                fallback: Data([0x10])
            )
            waitForNvimFileTreeCursorMoveContent(resultPath, retries: 24)
        }
    }

    func applyNvimFileTreeCloseSmokeScenario(resultPath: String) {
        nvimFileTreeCloseSmokeGrid = nil
        nvimFileTreeCloseSmokeBoundary = nil
        nvimFileTreeCloseSmokeBefore = "none"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else {
                return
            }
            runNvimCommandOrWrite(
                "enew! | setlocal nonumber norelativenumber signcolumn=no foldcolumn=0 | " +
                    "set laststatus=0 showtabline=0 | " +
                    "call setline(1, ['CLOSESMOKE']) | " +
                    "lua vim.opt.fillchars:append({eob=' '})",
                fallback: Data()
            )
            runNvimCommandOrWrite(
                nvimFileTreeOpenCommand(),
                fallback: Data([0x10])
            )
            waitForNvimFileTreeCloseOpen(resultPath, retries: 24)
        }
    }

    func applyNvimCursorSwitchSmokeScenario(resultPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.configureNvimCursorSmokeTab(
                marker: "OLDTAB",
                cursorRow: 17,
                cursorCol: 59
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else {
                return
            }
            core.newTab()
            syncFromCore()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            self?.configureNvimCursorSmokeTab(
                marker: "NEWTAB",
                cursorRow: 5,
                cursorCol: 11
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.8) { [weak self] in
            self?.writeNvimCursorSwitchSmokeResult(resultPath, retries: 12)
        }
    }

    func applyNvimCursorShapeSmokeScenario(resultPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.configureNvimCursorShapeSmoke()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.3) { [weak self] in
            self?.clearMarkedTextForVisualSmoke()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.7) { [weak self] in
            self?.writeNvimCursorShapeSmokeResult(resultPath, retries: 12)
        }
    }

    func applyNvimCursorNormalShapeSmokeScenario(resultPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.configureNvimCursorNormalShapeSmoke()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
            self?.writeNvimCursorDetailSmokeResult(
                resultPath,
                label: "cursor-normal-shape",
                expected: "5:11:block:0:0:0:0",
                expectedText: "CURSORNORMAL",
                retries: 12
            )
        }
    }

    func applyNvimCursorReplaceShapeSmokeScenario(resultPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.configureNvimCursorReplaceShapeSmoke()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { [weak self] in
            self?.clearMarkedTextForVisualSmoke()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
            self?.writeNvimCursorDetailSmokeResult(
                resultPath,
                label: "cursor-replace-shape",
                expected: "5:11:underline:20:0:0:0",
                expectedText: "CURSORREPLACE",
                retries: 12
            )
        }
    }

    func applyNvimCursorBlinkSmokeScenario(resultPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.configureNvimCursorBlinkSmoke()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) { [weak self] in
            self?.clearMarkedTextForVisualSmoke()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.7) { [weak self] in
            self?.writeNvimCursorBlinkSmokeResult(resultPath, retries: 8)
        }
    }

    private func moveNvimSmokeToBottomThenJump(_ resultPath: String, attempts: Int) {
        clearSmokeScrollShift()
        metalView.resetSkiaFrameCount()
        runNvimCommandOrWrite("normal! G", fallback: Data("\u{1b}G".utf8))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.finishNvimSmokeBottomMove(resultPath, attempts: attempts)
        }
    }

    private func waitForNvimSmokeContentThenJump(_ resultPath: String, retries: Int) {
        let contentRows = terminalTextView.rendererContentRowCount()
        let hasReadyMarker = terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker])
        let contentReady = hasReadyMarker
        guard contentReady else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.waitForNvimSmokeContentThenJump(resultPath, retries: retries - 1)
                }
                return
            }
            writeNvimJumpContentNotReadyResult(
                resultPath,
                contentRows: contentRows,
                hasReadyMarker: hasReadyMarker
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + nvimJumpBaselineDelay) { [weak self] in
            self?.moveNvimSmokeToBottomThenJump(resultPath, attempts: 4)
        }
    }

    private func writeNvimJumpContentNotReadyResult(
        _ resultPath: String,
        contentRows: Int,
        hasReadyMarker: Bool
    ) {
        let rendererSummary = "model-frames=\(terminalTextView.hasRendererModelFrames() ? "yes" : "no") " +
            "skia-frames=\(metalView.skiaFrames() > 0 ? "yes" : "no") count=\(metalView.skiaFrames())"
        let markerSummary = hasReadyMarker ? "yes" : "no"
        let result = "failed jump-content-not-ready rows=\(contentRows) " +
            "marker=\(markerSummary) \(rendererSummary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func finishNvimSmokeBottomMove(_ resultPath: String, attempts: Int) {
        let moved = consumeSmokeScrollShift()
            .map { abs($0.rows) > maxOutputScrollAnimationRows } ?? false
        if !moved, attempts > 0 {
            moveNvimSmokeToBottomThenJump(resultPath, attempts: attempts - 1)
            return
        }

        clearSmokeScrollShift()
        metalView.resetSkiaFrameCount()
        runNvimCommandOrWrite("normal! gg", fallback: Data("\u{1b}gg".utf8))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.writeNvimAnimationSmokeResult(resultPath, retries: 8)
        }
    }

    private func writeNvimAnimationSmokeResult(_ resultPath: String, retries: Int) {
        let shift = peekSmokeScrollShift()
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        let ok = hasModelFrames && skiaFrames >= 2 &&
            (shift.map { abs($0.rows) > maxOutputScrollAnimationRows } ?? false)
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.writeNvimAnimationSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }

        let summary = nvimAnimationSmokeSummary(
            shift,
            hasModelFrames: hasModelFrames,
            skiaFrames: skiaFrames
        )
        clearSmokeScrollShift()
        let result = ok ? "ok \(summary)\n" : "failed \(summary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func writeNativeSmokeResult(_ resultPath: String, retries: Int) {
        let skiaFrames = metalView.skiaFrames()
        let ok = skiaFrames > 0
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.writeNativeSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }

        let result = ok
            ? "ok native-smoke skia-frames=yes count=\(skiaFrames)\n"
            : "failed native-smoke skia-frames=no count=\(skiaFrames)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
    }

    private func waitForTerminalAfterNvimQuit(_ resultPath: String, retries: Int) {
        drainTerminalPanes()
        if activePaneMode() != .terminal, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForTerminalAfterNvimQuit(resultPath, retries: retries - 1)
            }
            return
        }

        metalView.resetSkiaFrameCount()
        writeToActivePane(Data("printf 'AFTERQA\\n'\r".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.writeTerminalNvimQuitSmokeResult(resultPath, retries: 8)
        }
    }

    private func writeTerminalNvimQuitSmokeResult(_ resultPath: String, retries: Int) {
        let modeOk = activePaneMode() == .terminal
        let skiaFrames = metalView.skiaFrames()
        let ok = modeOk && skiaFrames > 0
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.writeTerminalNvimQuitSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }

        let result = ok
            ? "ok terminal-nvim-quit mode=terminal skia-frames=\(skiaFrames)\n"
            : "failed terminal-nvim-quit mode=\(activePaneMode()) skia-frames=\(skiaFrames)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func writeTerminalNvimHandoffSmokeResult(_ resultPath: String, retries: Int) {
        let modeOk = activePaneMode() == .neovim
        let modelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        let textOk = terminalTextView.rendererModelContainsTexts(["HANDOFFNVIM"])
        let ok = modeOk && modelFrames && skiaFrames > 0 && textOk
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.writeTerminalNvimHandoffSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }

        let result = ok
            ? "ok terminal-nvim-handoff mode=neovim model-frames=yes " +
                "skia-frames=\(skiaFrames) text=yes\n"
            : "failed terminal-nvim-handoff mode=\(activePaneMode()) " +
                "model-frames=\(modelFrames ? "yes" : "no") " +
                "skia-frames=\(skiaFrames) text=\(textOk ? "yes" : "no")\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func writeTerminalExitClosesTabSmokeResult(_ resultPath: String, retries: Int) {
        drainTerminalPanes()
        let snapshot = core.snapshot()
        let tabs = snapshot?.tabs.count ?? 0
        let activeTab = snapshot?.active_tab ?? -1
        let ok = tabs == 1 && activeTab == 0 && activePaneMode() == .terminal
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.writeTerminalExitClosesTabSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }

        let result = ok
            ? "ok terminal-exit-closes-tab tabs=1 active=0\n"
            : "failed terminal-exit-closes-tab tabs=\(tabs) active=\(activeTab) " +
                "mode=\(activePaneMode())\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func writeTerminalNvimCwdSmokeResult(
        _ resultPath: String,
        expected: String,
        actualFile: String,
        retries: Int
    ) {
        let actual = (try? String(contentsOfFile: actualFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = activePaneMode() == .neovim && actual == expected
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.writeTerminalNvimCwdSmokeResult(
                    resultPath,
                    expected: expected,
                    actualFile: actualFile,
                    retries: retries - 1
                )
            }
            return
        }

        let result = ok
            ? "ok terminal-nvim-cwd cwd=\(expected)\n"
            : "failed terminal-nvim-cwd expected=\(expected) actual=\(actual ?? "nil") " +
                "mode=\(activePaneMode())\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func waitForTerminalBottomInputIdleThenType(_ resultPath: String, retries: Int) {
        let scrollPosition = abs(activePaneRendererScrollPosition())
        if scrollPosition > maxTerminalBottomInputSmokePosition, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForTerminalBottomInputIdleThenType(resultPath, retries: retries - 1)
            }
            return
        }

        metalView.resetSkiaFrameCount()
        writeToActivePane(Data("abc".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.writeTerminalBottomInputSmokeResult(
                resultPath,
                retries: 12,
                maxScrollPosition: 0
            )
        }
    }

    private func writeTerminalBottomInputSmokeResult(
        _ resultPath: String,
        retries: Int,
        maxScrollPosition: Double
    ) {
        let skiaFrames = metalView.skiaFrames()
        let scrollPosition = abs(activePaneRendererScrollPosition())
        let observedScrollPosition = max(maxScrollPosition, scrollPosition)
        let ok = skiaFrames > 0 &&
            observedScrollPosition <= maxTerminalBottomInputSmokePosition
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.writeTerminalBottomInputSmokeResult(
                    resultPath,
                    retries: retries - 1,
                    maxScrollPosition: observedScrollPosition
                )
            }
            return
        }

        let formattedPosition = String(format: "%.2f", observedScrollPosition)
        let result = ok
            ? "ok terminal-bottom-input no-scroll skia-frames=\(skiaFrames) " +
                "scroll-position=\(formattedPosition)\n"
            : "failed terminal-bottom-input unexpected-scroll skia-frames=\(skiaFrames) " +
                "scroll-position=\(formattedPosition)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func writeNvimSidePaneSmokeResult(_ resultPath: String, retries: Int) {
        let shift = peekSmokeScrollShift()
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        let ok = hasModelFrames && skiaFrames >= 2 && (shift.map { shift in
            abs(shift.rows) > maxOutputScrollAnimationRows && (shift.startCol ?? 0) > 0
        } ?? false)
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.writeNvimSidePaneSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }

        let summary = nvimAnimationSmokeSummary(
            shift,
            hasModelFrames: hasModelFrames,
            skiaFrames: skiaFrames
        )
        clearSmokeScrollShift()
        let result = ok ? "ok \(summary)\n" : "failed \(summary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func writeNvimNoScrollSmokeResult(_ resultPath: String, label: String) {
        let shift = consumeSmokeScrollShift()
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        let hasSkiaFrames = skiaFrames > 0
        let commandLineCount = terminalTextView.rendererModelTextOccurrences(":qa")
        let commandLineOk = label != "commandline" || commandLineCount == 1
        let summary = nvimAnimationSmokeSummary(
            shift,
            hasModelFrames: hasModelFrames,
            skiaFrames: skiaFrames
        )
        let commandSummary = label == "commandline" ? " cmdline=\(commandLineCount)" : ""
        let result = shift == nil && hasModelFrames && hasSkiaFrames && commandLineOk
            ? "ok \(label) no-scroll model-frames=yes skia-frames=yes\(commandSummary)\n"
            : "failed \(label) \(summary)\(commandSummary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func waitForNvimCursorMoveContent(_ resultPath: String, retries: Int) {
        guard terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker]) else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.waitForNvimCursorMoveContent(resultPath, retries: retries - 1)
                }
                return
            }
            writeNvimCursorMoveSmokeResult(
                resultPath,
                baselineScrollPosition: 0,
                maxScrollPosition: terminalTextView.rendererMaxScrollPosition()
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else {
                return
            }
            runNvimCommandOrWrite(
                "setlocal scrolloff=0 nosmoothscroll",
                fallback: Data()
            )
            runNvimCommandOrWrite(
                "normal! gg",
                fallback: Data("\u{1b}gg".utf8)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else {
                    return
                }
                clearSmokeScrollShift()
                metalView.resetSkiaFrameCount()
                let baseline = terminalTextView.rendererMaxScrollPosition()
                writeToActivePane(Data("jjk".utf8))
                sampleNvimCursorMoveScrollPosition(
                    resultPath,
                    retries: 20,
                    baselineScrollPosition: baseline,
                    maxScrollPosition: baseline
                )
            }
        }
    }

    private func waitForNvimFileTreeCursorMoveContent(_ resultPath: String, retries: Int) {
        guard let treeGrid = terminalTextView.rendererCursorParentInLeftSplit()
        else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.waitForNvimFileTreeCursorMoveContent(resultPath, retries: retries - 1)
                }
                return
            }
            writeNvimFileTreeCursorMoveSmokeResult(
                resultPath,
                cursorBefore: "none",
                cursorParentGrid: nil,
                populatedLinesBefore: 0,
                baselineScrollPosition: 0,
                maxScrollPosition: terminalTextView.rendererMaxScrollPosition()
            )
            return
        }

        runNvimCommandOrWrite(
            "normal! gg",
            fallback: Data("gg".utf8)
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else {
                return
            }
            clearSmokeScrollShift()
            metalView.resetSkiaFrameCount()
            let cursorBefore = terminalTextView.rendererModelCursorSummary()
            let populatedLinesBefore = terminalTextView.rendererPopulatedLineCount(
                gridID: treeGrid
            )
            let baseline = terminalTextView.rendererMaxScrollPosition()
            waitForNvimFileTreeCursorMoveCaptureTrigger(
                resultPath,
                retries: 1_000,
                cursorBefore: cursorBefore,
                cursorParentGrid: treeGrid,
                populatedLinesBefore: populatedLinesBefore,
                baselineScrollPosition: baseline,
                maxScrollPosition: baseline
            )
        }
    }

    private func waitForNvimFileTreeCloseOpen(_ resultPath: String, retries: Int) {
        guard let treeGrid = terminalTextView.rendererCursorParentInLeftSplit(),
              let boundary = terminalTextView.rendererVisibleWindowRightEdge(gridID: treeGrid)
        else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.waitForNvimFileTreeCloseOpen(resultPath, retries: retries - 1)
                }
                return
            }
            writeNvimFileTreeCloseSmokeResult(resultPath, retries: 0)
            return
        }

        nvimFileTreeCloseSmokeGrid = treeGrid
        nvimFileTreeCloseSmokeBoundary = boundary
        nvimFileTreeCloseSmokeBefore = terminalTextView.rendererModelWindowTextSummary()
        metalView.resetSkiaFrameCount()
        runNvimCommandOrWrite(nvimFileTreeCloseCommand(), fallback: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.writeNvimFileTreeCloseSmokeResult(resultPath, retries: 16)
        }
    }

    private func writeNvimFileTreeCloseSmokeResult(_ resultPath: String, retries: Int) {
        let treeGrid = nvimFileTreeCloseSmokeGrid
        let boundary = nvimFileTreeCloseSmokeBoundary
        let treeVisible = treeGrid.map {
            terminalTextView.rendererHasVisibleWindow(gridID: $0)
        } ?? true
        let occupied = boundary.map {
            terminalTextView.rendererModelOccupiedCellCount(column: $0)
        } ?? -1
        let skiaFrames = metalView.skiaFrames()
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let cursorParent = terminalTextView.rendererCursorParentGridID()
        let ok = treeGrid != nil
            && boundary != nil
            && !treeVisible
            && cursorParent != treeGrid
            && occupied == 0
            && skiaFrames >= 1
            && hasModelFrames
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.writeNvimFileTreeCloseSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }

        let geometry = terminalTextView.skiaGeometrySummary()
        let viewport = terminalTextView.skiaViewportSummary()
        let after = terminalTextView.rendererModelWindowTextSummary()
        let separator = terminalTextView.rendererModelRawTextStartSummary(
            label: "separator",
            text: "│"
        )
        let marker = terminalTextView.rendererModelTextStartSummary(
            label: "marker",
            text: "CLOSESMOKE"
        )
        let gridSummary = treeGrid.map(String.init) ?? "none"
        let boundarySummary = boundary.map(String.init) ?? "none"
        let cursorParentSummary = cursorParent.map(String.init) ?? "none"
        let treeVisibleSummary = treeVisible ? "yes" : "no"
        let modelFramesSummary = hasModelFrames ? "yes" : "no"
        let result = ok
            ? "ok file-tree-close grid=\(gridSummary) " +
                "boundary=\(boundarySummary) occupied=\(occupied) " +
                "tree-visible=no cursor-parent=\(cursorParentSummary) " +
                "model-frames=yes skia-frames=\(skiaFrames) geometry=\(geometry) " +
                "viewport=\(viewport) " +
                "marker=\(marker) separator=\(separator) " +
                "before=\(nvimFileTreeCloseSmokeBefore) after=\(after)\n"
            : "failed file-tree-close grid=\(gridSummary) " +
                "boundary=\(boundarySummary) occupied=\(occupied) " +
                "tree-visible=\(treeVisibleSummary) " +
                "cursor-parent=\(cursorParentSummary) " +
                "model-frames=\(modelFramesSummary) " +
                "skia-frames=\(skiaFrames) geometry=\(geometry) " +
                "viewport=\(viewport) " +
                "marker=\(marker) separator=\(separator) " +
                "before=\(nvimFileTreeCloseSmokeBefore) after=\(after)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
            NSApp.terminate(nil)
        }
    }

    private func waitForNvimFileTreeCursorMoveCaptureTrigger(
        _ resultPath: String,
        retries: Int,
        cursorBefore: String,
        cursorParentGrid: Int,
        populatedLinesBefore: Int,
        baselineScrollPosition: Double,
        maxScrollPosition: Double
    ) {
        let environment = ProcessInfo.processInfo.environment
        guard let triggerPath = environment["SATIN_NATIVE_SMOKE_CONTINUE"],
              !triggerPath.isEmpty
        else {
            startNvimFileTreeCursorMoveSampling(
                resultPath,
                cursorBefore: cursorBefore,
                cursorParentGrid: cursorParentGrid,
                populatedLinesBefore: populatedLinesBefore,
                baselineScrollPosition: baselineScrollPosition,
                maxScrollPosition: maxScrollPosition
            )
            return
        }

        if let readyPath = environment["SATIN_NATIVE_SMOKE_BASELINE_READY"],
           !readyPath.isEmpty
        {
            try? "ready\n".write(toFile: readyPath, atomically: true, encoding: .utf8)
        }

        guard FileManager.default.fileExists(atPath: triggerPath) else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    self?.waitForNvimFileTreeCursorMoveCaptureTrigger(
                        resultPath,
                        retries: retries - 1,
                        cursorBefore: cursorBefore,
                        cursorParentGrid: cursorParentGrid,
                        populatedLinesBefore: populatedLinesBefore,
                        baselineScrollPosition: baselineScrollPosition,
                        maxScrollPosition: maxScrollPosition
                    )
                }
                return
            }
            let result = "failed file-tree-cursor-move capture-trigger-timeout\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }

        startNvimFileTreeCursorMoveSampling(
            resultPath,
            cursorBefore: cursorBefore,
            cursorParentGrid: cursorParentGrid,
            populatedLinesBefore: populatedLinesBefore,
            baselineScrollPosition: baselineScrollPosition,
            maxScrollPosition: maxScrollPosition
        )
    }

    private func startNvimFileTreeCursorMoveSampling(
        _ resultPath: String,
        cursorBefore: String,
        cursorParentGrid: Int,
        populatedLinesBefore: Int,
        baselineScrollPosition: Double,
        maxScrollPosition: Double
    ) {
        writeToActivePane(Data("j".utf8))
        sampleNvimFileTreeCursorMoveScrollPosition(
            resultPath,
            retries: 20,
            cursorBefore: cursorBefore,
            cursorParentGrid: cursorParentGrid,
            populatedLinesBefore: populatedLinesBefore,
            baselineScrollPosition: baselineScrollPosition,
            maxScrollPosition: maxScrollPosition
        )
    }

    private func sampleNvimFileTreeCursorMoveScrollPosition(
        _ resultPath: String,
        retries: Int,
        cursorBefore: String,
        cursorParentGrid: Int,
        populatedLinesBefore: Int,
        baselineScrollPosition: Double,
        maxScrollPosition: Double
    ) {
        let observed = max(
            maxScrollPosition,
            terminalTextView.rendererMaxScrollPosition()
        )
        guard retries > 0 else {
            writeNvimFileTreeCursorMoveSmokeResult(
                resultPath,
                cursorBefore: cursorBefore,
                cursorParentGrid: cursorParentGrid,
                populatedLinesBefore: populatedLinesBefore,
                baselineScrollPosition: baselineScrollPosition,
                maxScrollPosition: observed
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.sampleNvimFileTreeCursorMoveScrollPosition(
                resultPath,
                retries: retries - 1,
                cursorBefore: cursorBefore,
                cursorParentGrid: cursorParentGrid,
                populatedLinesBefore: populatedLinesBefore,
                baselineScrollPosition: baselineScrollPosition,
                maxScrollPosition: observed
            )
        }
    }

    private func writeNvimFileTreeCursorMoveSmokeResult(
        _ resultPath: String,
        cursorBefore: String,
        cursorParentGrid: Int?,
        populatedLinesBefore: Int,
        baselineScrollPosition: Double,
        maxScrollPosition: Double
    ) {
        let shift = consumeSmokeScrollShift()
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        let cursorAfter = terminalTextView.rendererModelCursorSummary()
        let parentAfter = terminalTextView.rendererCursorParentGridID()
        let hasTreeWindow = cursorParentGrid.map {
            terminalTextView.rendererHasVisibleWindow(gridID: $0)
        } ?? false
        let populatedLinesAfter = cursorParentGrid.map {
            terminalTextView.rendererPopulatedLineCount(gridID: $0)
        } ?? 0
        let lineCapacityAfter = cursorParentGrid.map {
            terminalTextView.rendererLineCapacity(gridID: $0)
        } ?? 0
        let ok = shift == nil
            && cursorBefore != "none"
            && cursorAfter != cursorBefore
            && parentAfter == cursorParentGrid
            && lineCapacityAfter > 0
            && populatedLinesBefore == lineCapacityAfter
            && populatedLinesAfter == lineCapacityAfter
            && maxScrollPosition <= baselineScrollPosition + maxNvimCursorMoveSmokeGrowth
            && hasModelFrames
            && skiaFrames >= 2
            && hasTreeWindow
        let baseline = String(format: "%.3f", baselineScrollPosition)
        let peak = String(format: "%.3f", maxScrollPosition)
        let result = ok
            ? "ok file-tree-cursor-move cursor=\(cursorBefore)->\(cursorAfter) " +
                "grid=\(cursorParentGrid.map(String.init) ?? "none") no-new-scroll " +
                "tree-lines=\(populatedLinesBefore)/\(lineCapacityAfter)" +
                "->\(populatedLinesAfter)/\(lineCapacityAfter) " +
                "baseline=\(baseline) peak=\(peak) skia-frames=\(skiaFrames)\n"
            : "failed file-tree-cursor-move cursor=\(cursorBefore)->\(cursorAfter) " +
                "grid=\(cursorParentGrid.map(String.init) ?? "none")->" +
                "\(parentAfter.map(String.init) ?? "none") " +
                "tree-lines=\(populatedLinesBefore)/\(lineCapacityAfter)" +
                "->\(populatedLinesAfter)/\(lineCapacityAfter) " +
                "baseline=\(baseline) peak=\(peak) " +
                "scroll-hint=\(shift == nil ? "none" : "present") " +
                "model-frames=\(hasModelFrames ? "yes" : "no") " +
                "skia-frames=\(skiaFrames) tree-window=\(hasTreeWindow ? "yes" : "no") " +
                "\(terminalTextView.rendererViewportSummary())\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
            NSApp.terminate(nil)
        }
    }

    private func sampleNvimCursorMoveScrollPosition(
        _ resultPath: String,
        retries: Int,
        baselineScrollPosition: Double,
        maxScrollPosition: Double
    ) {
        let observed = max(
            maxScrollPosition,
            terminalTextView.rendererMaxScrollPosition()
        )
        guard retries > 0 else {
            writeNvimCursorMoveSmokeResult(
                resultPath,
                baselineScrollPosition: baselineScrollPosition,
                maxScrollPosition: observed
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.sampleNvimCursorMoveScrollPosition(
                resultPath,
                retries: retries - 1,
                baselineScrollPosition: baselineScrollPosition,
                maxScrollPosition: observed
            )
        }
    }

    private func writeNvimCursorMoveSmokeResult(
        _ resultPath: String,
        baselineScrollPosition: Double,
        maxScrollPosition: Double
    ) {
        let shift = consumeSmokeScrollShift()
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        let hasReadyMarker = terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker])
        let ok = shift == nil
            && maxScrollPosition <= baselineScrollPosition + maxNvimCursorMoveSmokeGrowth
            && hasModelFrames
            && skiaFrames >= 2
            && hasReadyMarker
        let baseline = String(format: "%.3f", baselineScrollPosition)
        let peak = String(format: "%.3f", maxScrollPosition)
        let result = ok
            ? "ok cursor-move no-new-scroll baseline=\(baseline) peak=\(peak) " +
                "skia-frames=\(skiaFrames)\n"
            : "failed cursor-move baseline=\(baseline) peak=\(peak) " +
                "scroll-hint=\(shift == nil ? "none" : "present") " +
                "model-frames=\(hasModelFrames ? "yes" : "no") " +
                "skia-frames=\(skiaFrames) marker=\(hasReadyMarker ? "yes" : "no") " +
                "\(terminalTextView.rendererViewportSummary()) " +
                "text=\(terminalTextView.rendererTextSummary())\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func writeNvimShapedTextSmokeResult(_ resultPath: String, retries: Int) {
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        let expected = shapedTextSmokeLabels()
        let expectedText = expected.map(\.text)
        let missingText = terminalTextView.rendererModelMissingTexts(expectedText)
        let hasText = missingText.isEmpty
        let ok = hasModelFrames && skiaFrames > 0 && hasText
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.writeNvimShapedTextSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }

        let rendererSummary = "model-frames=\(hasModelFrames ? "yes" : "no") " +
            "skia-frames=\(skiaFrames > 0 ? "yes" : "no") count=\(skiaFrames)"
        let missingSummary = missingText.isEmpty ? "none" : missingText.joined(separator: ",")
        let textSummary = "text=\(hasText ? "yes" : "no") missing=\(missingSummary)"
        let geometrySummary = "geometry=\(terminalTextView.skiaGeometrySummary())"
        let viewportSummary = "viewport=\(terminalTextView.skiaViewportSummary())"
        let cellSummary = "cells=\(terminalTextView.rendererModelCellSummary(expected))"
        let result = ok
            ? "ok shaped-text \(textSummary) \(rendererSummary) \(geometrySummary) " +
                "\(viewportSummary) \(cellSummary)\n"
            : "failed shaped-text \(textSummary) \(rendererSummary) \(geometrySummary) " +
                "\(viewportSummary) \(cellSummary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
            NSApp.terminate(nil)
        }
    }

    private func shapedTextSmokeLabels() -> [(label: String, text: String)] {
        [
            ("jp1", "日"),
            ("jp2", "本"),
            ("jp3", "語"),
            ("nerd", "\u{e0b0}"),
            ("combining", "e\u{301}"),
            ("ambiguous", "Ω"),
        ]
    }

    private func writeNvimSkiaSmokeResult(_ resultPath: String, retries: Int) {
        let marker = "SKIASMOKE"
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        let markerCount = terminalTextView.rendererModelTextOccurrences(marker)
        let markerCell = terminalTextView.rendererModelCellSummary([("marker", "S")])
        let ok = hasModelFrames && skiaFrames > 0 && markerCount == 1 && markerCell != "none"
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.writeNvimSkiaSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }

        let summary = [
            "model-frames=\(hasModelFrames ? "yes" : "no")",
            "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
            "count=\(skiaFrames)",
            "text=\(markerCount)",
            "geometry=\(terminalTextView.skiaGeometrySummary())",
            "viewport=\(terminalTextView.skiaViewportSummary())",
            "marker-cell=\(markerCell)",
        ].joined(separator: " ")
        let result = ok ? "ok nvim-skia \(summary)\n" : "failed nvim-skia \(summary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
            NSApp.terminate(nil)
        }
    }

    private func writeNvimImageSmokeResult(_ resultPath: String, retries: Int) {
        let imageCount = activePaneId
            .flatMap { terminalPane(for: $0)?.controlImageCount() } ?? 0
        let skiaFrames = metalView.skiaFrames()
        let ok = imageCount == 1 && skiaFrames > 0
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.writeNvimImageSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }

        let summary = [
            "images=\(imageCount)",
            "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
            "count=\(skiaFrames)",
            "geometry=\(terminalTextView.skiaGeometrySummary())",
            "viewport=\(terminalTextView.skiaViewportSummary())",
        ].joined(separator: " ")
        let result = ok ? "ok nvim-image \(summary)\n" : "failed nvim-image \(summary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
            NSApp.terminate(nil)
        }
    }

    private func writeNvimUiSurfacesSmokeResult(_ resultPath: String, retries: Int) {
        let counts = terminalTextView.rendererModelWindowKindCounts()
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        let rightSplitCount = terminalTextView.rendererModelTextOccurrences("RIGHTSPLIT")
        let rightSplitRaw = terminalTextView.rendererModelRawTextStartSummary(
            label: "right",
            text: "RIGHTSPLIT"
        )
        let floatCount = terminalTextView.rendererModelTextOccurrences("FLOATBOX")
        let statusCount = terminalTextView.rendererModelTextOccurrences("STATUSLINE")
        let statusRaw = terminalTextView.rendererModelRawTextStartSummary(
            label: "status",
            text: "STATUSLINE"
        )
        let messageCount = terminalTextView.rendererModelTextOccurrences("MSGBOX")
        let blendCellCount = terminalTextView.rendererModelBlendCellCount(minBlend: 35)
        let blendCellSummary = terminalTextView.rendererModelBlendCellSummary(minBlend: 35)
        let hasSplit = (counts["normal"] ?? 0) >= 2 && rightSplitCount == 1
        let hasFloat = (counts["float"] ?? 0) >= 1 && floatCount == 1
        let hasFixedSurfaces = messageCount == 1
        let hasBlend = blendCellCount > 0 && blendCellSummary != "none"
        let hasMessageSelection = nvimMessageSelectionSmoke.contains("overlay=yes") &&
            nvimMessageSelectionSmoke.contains("copied=yes")
        let ok = hasModelFrames && skiaFrames > 0 &&
            hasSplit && hasFloat && hasFixedSurfaces && hasBlend && hasMessageSelection
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.writeNvimUiSurfacesSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }

        let summary = [
            "model-frames=\(hasModelFrames ? "yes" : "no")",
            "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
            "count=\(skiaFrames)",
            "normal=\(counts["normal"] ?? 0)",
            "float=\(counts["float"] ?? 0)",
            "right=\(rightSplitCount)",
            "right-raw=\(rightSplitRaw)",
            "float-text=\(floatCount)",
            "status=\(statusCount)",
            "status-raw=\(statusRaw)",
            "message=\(messageCount)",
            "message-selection=\(nvimMessageSelectionSmoke.replacingOccurrences(of: " ", with: ","))",
            "blend-cells=\(blendCellCount)",
            "geometry=\(terminalTextView.skiaGeometrySummary())",
            "viewport=\(terminalTextView.skiaViewportSummary())",
            "windows=\(terminalTextView.rendererModelWindowTextSummary(limit: 8))",
            "blend-cell=\(blendCellSummary)",
        ].joined(separator: " ")
        let result = ok ? "ok ui-surfaces \(summary)\n" : "failed ui-surfaces \(summary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
            NSApp.terminate(nil)
        }
    }

    private func writeNvimPopupmenuSmokeResult(
        _ resultPath: String,
        retries: Int,
        settleFrames: Int = 12,
        pendingFrameCount: Int? = nil
    ) {
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        if let pendingFrameCount, skiaFrames < pendingFrameCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.writeNvimPopupmenuSmokeResult(
                    resultPath,
                    retries: retries,
                    settleFrames: settleFrames,
                    pendingFrameCount: pendingFrameCount
                )
            }
            return
        }
        let popupCount = terminalTextView.rendererModelTextOccurrences("POPUPONE")
        let popupCellSummary = terminalTextView.rendererModelTextStartSummary(
            label: "popup",
            text: "POPUPONE"
        )
        let ok = hasModelFrames && skiaFrames > 0 && popupCount == 1 && popupCellSummary != "none"
        if ok && settleFrames > 0 {
            metalView.needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.writeNvimPopupmenuSmokeResult(
                    resultPath,
                    retries: retries,
                    settleFrames: settleFrames - 1,
                    pendingFrameCount: skiaFrames + 1
                )
            }
            return
        }
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.writeNvimPopupmenuSmokeResult(
                    resultPath,
                    retries: retries - 1,
                    settleFrames: settleFrames,
                    pendingFrameCount: nil
                )
            }
            return
        }

        let summary = [
            "model-frames=\(hasModelFrames ? "yes" : "no")",
            "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
            "count=\(skiaFrames)",
            "popup=\(popupCount)",
            "geometry=\(terminalTextView.skiaGeometrySummary())",
            "viewport=\(terminalTextView.skiaViewportSummary())",
            "popup-cell=\(popupCellSummary)",
        ].joined(separator: " ")
        let result = ok ? "ok popupmenu \(summary)\n" : "failed popupmenu \(summary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
            NSApp.terminate(nil)
        }
    }

    private func writeNvimFileTreeSmokeResult(
        _ resultPath: String,
        openedPath: String,
        treeLinesPath: String,
        cwdPath: String,
        retries: Int
    ) {
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        let opened = (try? String(contentsOfFile: openedPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cwd = (try? String(contentsOfFile: cwdPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appCwd = nativeWorkingDirectory()
        let treeLines = (try? String(contentsOfFile: treeLinesPath, encoding: .utf8)) ?? ""
        let treeHasCargo = treeLines.contains("Cargo.toml")
        let treeLineCount = treeLines.split(separator: "\n", omittingEmptySubsequences: false).count
        let rawTarget = terminalTextView.rendererModelRawTextStartSummary(
            label: "cargo",
            text: "Cargo.toml"
        )
        let rawSrc = terminalTextView.rendererModelRawTextStartSummary(label: "src", text: "src")
        let rawReadme = terminalTextView.rendererModelRawTextStartSummary(
            label: "readme",
            text: "README.md"
        )
        let rawRepo = terminalTextView.rendererModelRawTextStartSummary(
            label: "repo",
            text: "satin"
        )
        let windows = terminalTextView.rendererModelWindowTextSummary()
        let hasTreeTarget = nvimFileTreeSmokeTarget != "none"
        let ok = hasModelFrames && skiaFrames > 0 && hasTreeTarget && opened == "Cargo.toml"
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.writeNvimFileTreeSmokeResult(
                    resultPath,
                    openedPath: openedPath,
                    treeLinesPath: treeLinesPath,
                    cwdPath: cwdPath,
                    retries: retries - 1
                )
            }
            return
        }

        let summary = [
            "model-frames=\(hasModelFrames ? "yes" : "no")",
            "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
            "count=\(skiaFrames)",
            "target=\(nvimFileTreeSmokeTarget)",
            "tree-cargo=\(treeHasCargo ? "yes" : "no")",
            "tree-lines=\(treeLineCount)",
            "cwd=\(cwd.isEmpty ? "none" : cwd)",
            "app-cwd=\(appCwd)",
            "raw=\(rawTarget)",
            "src=\(rawSrc)",
            "readme=\(rawReadme)",
            "repo=\(rawRepo)",
            "windows=\(windows)",
            "opened=\(opened.isEmpty ? "none" : opened)",
        ].joined(separator: " ")
        let result = ok ? "ok file-tree \(summary)\n" : "failed file-tree \(summary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
            NSApp.terminate(nil)
        }
    }

    private func writeNvimCursorSwitchSmokeResult(_ resultPath: String, retries: Int) {
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        let newTextCount = terminalTextView.rendererModelTextOccurrences("NEWTAB")
        let oldTextCount = terminalTextView.rendererModelTextOccurrences("OLDTAB")
        let cursor = terminalTextView.rendererModelCursorSummary()
        let ok = hasModelFrames && skiaFrames > 0 &&
            newTextCount == 1 && oldTextCount == 0 && cursor == "5:11"
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.writeNvimCursorSwitchSmokeResult(resultPath, retries: retries - 1)
            }
            return
        }

        let summary = [
            "model-frames=\(hasModelFrames ? "yes" : "no")",
            "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
            "count=\(skiaFrames)",
            "geometry=\(terminalTextView.skiaGeometrySummary())",
            "viewport=\(terminalTextView.skiaViewportSummary())",
            "old=17:59",
            "new=\(cursor)",
            "new-text=\(newTextCount)",
            "old-text=\(oldTextCount)",
        ].joined(separator: " ")
        let result = ok ? "ok cursor-switch \(summary)\n" : "failed cursor-switch \(summary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
            NSApp.terminate(nil)
        }
    }

    private func writeNvimCursorShapeSmokeResult(_ resultPath: String, retries: Int) {
        writeNvimCursorDetailSmokeResult(
            resultPath,
            label: "cursor-shape",
            expected: "5:11:bar:25:0:0:0",
            expectedText: "CURSORSHAPE",
            retries: retries
        )
    }

    private func writeNvimCursorBlinkSmokeResult(_ resultPath: String, retries: Int) {
        writeNvimCursorDetailSmokeResult(
            resultPath,
            label: "cursor-blink",
            expected: "5:11:bar:25:100:100:2000",
            expectedText: "CURSORBLINK",
            retries: retries,
            retryDelay: 0.15,
            requireSettledAnimation: false,
            settleFrames: 0
        )
    }

    private func writeNvimCursorDetailSmokeResult(
        _ resultPath: String,
        label: String,
        expected: String,
        expectedText: String,
        retries: Int,
        retryDelay: TimeInterval = 0.25,
        requireSettledAnimation: Bool = true,
        settleFrames: Int = 12,
        pendingFrameCount: Int? = nil
    ) {
        let hasModelFrames = terminalTextView.hasRendererModelFrames()
        let skiaFrames = metalView.skiaFrames()
        if let pendingFrameCount, skiaFrames < pendingFrameCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.writeNvimCursorDetailSmokeResult(
                    resultPath,
                    label: label,
                    expected: expected,
                    expectedText: expectedText,
                    retries: retries,
                    retryDelay: retryDelay,
                    requireSettledAnimation: requireSettledAnimation,
                    settleFrames: settleFrames,
                    pendingFrameCount: pendingFrameCount
                )
            }
            return
        }
        let cursor = terminalTextView.rendererModelCursorDetailSummary()
        let textCount = terminalTextView.rendererModelTextOccurrences(expectedText)
        let animationSettled = !requireSettledAnimation || !metalView.hasPendingSkiaFrame()
        let modelReady = hasModelFrames && skiaFrames > 0 && cursor == expected && textCount == 1
        if modelReady && animationSettled && settleFrames > 0 {
            metalView.needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.writeNvimCursorDetailSmokeResult(
                    resultPath,
                    label: label,
                    expected: expected,
                    expectedText: expectedText,
                    retries: retries,
                    retryDelay: retryDelay,
                    requireSettledAnimation: requireSettledAnimation,
                    settleFrames: settleFrames - 1,
                    pendingFrameCount: skiaFrames + 1
                )
            }
            return
        }
        let ok = modelReady && animationSettled
        if !ok, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                self?.writeNvimCursorDetailSmokeResult(
                    resultPath,
                    label: label,
                    expected: expected,
                    expectedText: expectedText,
                    retries: retries - 1,
                    retryDelay: retryDelay,
                    requireSettledAnimation: requireSettledAnimation,
                    settleFrames: settleFrames,
                    pendingFrameCount: nil
                )
            }
            return
        }

        let summary = [
            "model-frames=\(hasModelFrames ? "yes" : "no")",
            "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
            "count=\(skiaFrames)",
            "geometry=\(terminalTextView.skiaGeometrySummary())",
            "viewport=\(terminalTextView.skiaViewportSummary())",
            "cursor=\(cursor)",
            "text=\(textCount)",
            "animation-settled=\(animationSettled ? "yes" : "no")",
        ].joined(separator: " ")
        let result = ok ? "ok \(label) \(summary)\n" : "failed \(label) \(summary)\n"
        try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
            NSApp.terminate(nil)
        }
    }

    private func nvimFloatCommand() -> String {
        "lua vim.api.nvim_set_hl(0,'NormalFloat',{bg='#506070',blend=35}); " +
            "local b=vim.api.nvim_create_buf(false,true); " +
            "vim.api.nvim_buf_set_lines(b,0,-1,false,{'FLOATBOX'}); " +
            "local w=vim.api.nvim_open_win(b,true,{relative='editor',row=3,col=20,width=16,height=3,style='minimal'}); " +
            "vim.wo[w].winblend=35; vim.wo[w].winhl='Normal:NormalFloat'"
    }

    private func nvimSmokeStatuslineCommand() -> String {
        "lua vim.o.laststatus=2; vim.o.statusline='STATUSLINE'; " +
            "for _,w in ipairs(vim.api.nvim_list_wins()) do " +
            "pcall(vim.api.nvim_set_option_value,'statusline','STATUSLINE',{win=w}) end; " +
            "vim.cmd('redrawstatus!')"
    }

    private func nvimPopupmenuSetupCommand() -> String {
        [
            "enew!",
            "setlocal norelativenumber nonumber",
            "call setline(1, ['POPUPANCHOR'])",
            "set wildmenu wildmode=full",
            "lua vim.api.nvim_create_user_command('NvtermPopupDummy', " +
                "function(opts) vim.print(opts.args) end, " +
                "{nargs=1, complete=function() return {'POPUPONE','POPUPTWO'} end})",
        ].joined(separator: " | ")
    }

    private func nvimFileTreeOpenCommand() -> String {
        "set mouse=a | lua " +
            "if vim.fn.exists(':NvimTreeToggle') == 2 then " +
            "vim.cmd('NvimTreeToggle'); " +
            "if vim.fn.exists(':NvimTreeFocus') == 2 then vim.cmd('NvimTreeFocus') end " +
            "elseif vim.fn.exists(':Neotree') == 2 then " +
            "vim.cmd('Neotree filesystem reveal left') end"
    }

    private func nvimFileTreeCloseCommand() -> String {
        "lua if vim.fn.exists(':NvimTreeClose') == 2 then " +
            "vim.cmd('NvimTreeClose') " +
            "elseif vim.fn.exists(':Neotree') == 2 then vim.cmd('Neotree close') end"
    }

    private func clickNvimFileTreeSmokeTarget() {
        guard let position = terminalTextView.rendererModelTextStartPosition("Cargo.toml") else {
            nvimFileTreeSmokeTarget = "none"
            return
        }
        nvimFileTreeSmokeTarget = "\(position.row):\(position.col)"
        sendNvimMouseClick(row: Int64(position.row), col: Int64(position.col))
    }

    private func sendNvimMouseClick(row: Int64, col: Int64) {
        let press = NativeMouseInput(
            button: "left",
            action: "press",
            modifier: "",
            grid: 0,
            row: row,
            col: col
        )
        let release = NativeMouseInput(
            button: "left",
            action: "release",
            modifier: "",
            grid: 0,
            row: row,
            col: col
        )
        _ = sendMouseInputToActivePane(press)
        _ = sendMouseInputToActivePane(release)
    }

    private func exerciseNvimMessageSelectionSmoke() {
        guard let position = terminalTextView.rendererModelTextStartPosition("MSGBOX") else {
            nvimMessageSelectionSmoke = "overlay=no copied=no reason=missing-message"
            return
        }
        let pasteboard = NSPasteboard.general
        let previousItems: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        defer {
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                pasteboard.writeObjects(previousItems)
            }
        }

        let start = NativeMouseInput(
            button: "left",
            action: "press",
            modifier: "",
            grid: 0,
            row: Int64(position.row),
            col: Int64(position.col)
        )
        let endCol = Int64(position.col + "MSGBOX".count - 1)
        let drag = NativeMouseInput(
            button: "left",
            action: "drag",
            modifier: "",
            grid: 0,
            row: Int64(position.row),
            col: endCol
        )
        let release = NativeMouseInput(
            button: "left",
            action: "release",
            modifier: "",
            grid: 0,
            row: Int64(position.row),
            col: endCol
        )
        let pressHandling = sendMouseInputToActivePane(start)
        let dragHandling = sendMouseInputToActivePane(drag)
        let overlay = terminalTextView.rendererModelMessageSelectionSummary()
        let releaseHandling = sendMouseInputToActivePane(release)
        let copied = pasteboard.string(forType: .string) == "MSGBOX"
        let handled = pressHandling == .messageSelection &&
            dragHandling == .messageSelection &&
            releaseHandling == .messageSelection
        nvimMessageSelectionSmoke = [
            "overlay=\(handled && overlay != "none" ? "yes" : "no")",
            "copied=\(copied ? "yes" : "no")",
            "selection=\(overlay)",
        ].joined(separator: " ")
    }

    private func configureNvimCursorSmokeTab(marker: String, cursorRow: Int, cursorCol: Int) {
        let rowNumber = cursorRow + 1
        let colNumber = cursorCol + 1
        let command = [
            "enew!",
            "setlocal norelativenumber nonumber laststatus=0 noruler noshowmode virtualedit=all",
            "call setline(1, ['\(marker)'] + repeat([repeat(' ', 100)], 40))",
            "normal! \(rowNumber)G\(colNumber)|",
        ].joined(separator: " | ")
        runNvimCommandOrWrite(command, fallback: Data(":enew\r".utf8))
    }

    private func configureNvimCursorShapeSmoke() {
        let command = [
            "enew!",
            "set guicursor=i:ver25-blinkon0",
            "setlocal norelativenumber nonumber laststatus=0 noruler noshowmode virtualedit=all",
            "call setline(1, ['CURSORSHAPE'] + repeat([repeat(' ', 100)], 20))",
            "call cursor(6, 12)",
            "startinsert",
        ].joined(separator: " | ")
        runNvimCommandOrWrite(command, fallback: Data(":startinsert\r".utf8))
    }

    private func clearMarkedTextForVisualSmoke() {
        terminalTextView.inputContext?.discardMarkedText()
        terminalTextView.unmarkText()
    }

    private func configureNvimCursorNormalShapeSmoke() {
        let command = [
            "enew!",
            "set guicursor=n:block-blinkon0",
            "setlocal norelativenumber nonumber laststatus=0 noruler noshowmode virtualedit=all",
            "call setline(1, ['CURSORNORMAL'] + repeat([repeat(' ', 100)], 20))",
            "call cursor(6, 12)",
            "stopinsert",
        ].joined(separator: " | ")
        runNvimCommandOrWrite(command, fallback: Data("\u{1b}".utf8))
    }

    private func configureNvimCursorReplaceShapeSmoke() {
        let command = [
            "enew!",
            "set guicursor=r:hor20-blinkon0",
            "setlocal norelativenumber nonumber laststatus=0 noruler noshowmode virtualedit=all",
            "call setline(1, ['CURSORREPLACE'] + repeat([repeat(' ', 100)], 20))",
            "call cursor(6, 12)",
            "startreplace",
        ].joined(separator: " | ")
        runNvimCommandOrWrite(command, fallback: Data(":startreplace\r".utf8))
    }

    private func configureNvimCursorBlinkSmoke() {
        let command = [
            "enew!",
            "set guicursor=i:ver25-blinkwait100-blinkon100-blinkoff2000",
            "setlocal norelativenumber nonumber laststatus=0 noruler noshowmode virtualedit=all",
            "call setline(1, ['CURSORBLINK'] + repeat([repeat(' ', 100)], 20))",
            "call cursor(6, 12)",
            "startinsert",
        ].joined(separator: " | ")
        runNvimCommandOrWrite(command, fallback: Data(":startinsert\r".utf8))
    }

    private func configureNvimPopupmenuSmoke() {
        runNvimCommandOrWrite(
            nvimPopupmenuSetupCommand(),
            fallback: Data(":echo 'POPUPONE'\r".utf8)
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.writeToActivePane(Data(":NvtermPopupDummy P\t".utf8))
        }
    }

    private func configureNvimSkiaSmoke() {
        let command = [
            "enew!",
            "set laststatus=0 noruler noshowmode",
            "setlocal norelativenumber nonumber signcolumn=no foldcolumn=0 virtualedit=all",
            "call setline(1, ['SKIASMOKE', 'renderer basic smoke'])",
            "call cursor(2, 1)",
        ].joined(separator: " | ")
        runNvimCommandOrWrite(command, fallback: Data(":enew\r".utf8))
    }

    private func sendNvimImageSmokePlacement() {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA" +
            "DUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
        let lua = [
            "local e=string.char(27)",
            "local packet=e..'[4;6H'..e..'_Ga=T,f=100,t=d,i=901,z=0,w=240,h=160,q=2;" +
                png + "'..e..'\\\\'",
            "require('satin.image').write(packet)",
        ].joined(separator: ";")
        runNvimCommandOrWrite("lua \(lua)", fallback: Data())
    }

    private func openNvimSmokeBuffer(path: String, terminalCommand: String) {
        writeSmokeLines(path: path)
        switch activePaneMode() {
        case .terminal:
            let command = [
                "tmp=\(path)",
                "seq 1 300 > $tmp",
                terminalCommand,
            ].joined(separator: "; ")
            writeToActivePane(Data("\(command)\r".utf8))
        case .neovim:
            scheduleNvimCommand(
                neovimEditTopCommand(path),
                paneId: activePaneId,
                fallback: Data(":edit \(path)\r".utf8)
            )
        }
    }

    private func openNvimShapedTextSmokeBuffer(path: String, terminalCommand: String) {
        writeShapedTextSmokeLines(path: path)
        switch activePaneMode() {
        case .terminal:
            let command = [
                "tmp=\(path)",
                terminalCommand,
            ].joined(separator: "; ")
            writeToActivePane(Data("\(command)\r".utf8))
        case .neovim:
            scheduleNvimCommand(
                neovimEditTopCommand(path),
                paneId: activePaneId,
                fallback: Data(":edit \(path)\r".utf8)
            )
        }
    }

    private func writeSmokeLines(path: String) {
        let lines = [nvimSmokeReadyMarker] + (1...300).map(String.init)
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func writeShapedTextSmokeLines(path: String) {
        let lines = [
            "shaped 日本語 \u{e0b0} e\u{301} Ω",
            "latin ABC xyz",
            "nerd \u{e0b2}\u{f013}",
            "combining a\u{0308}",
            "ambiguous ·→",
        ]
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func nvimAnimationSmokeSummary(
        _ shift: OutputScrollShift?,
        hasModelFrames: Bool,
        skiaFrames: Int
    ) -> String {
        let rendererSummary = "model-frames=\(hasModelFrames ? "yes" : "no") " +
            "skia-frames=\(skiaFrames > 0 ? "yes" : "no") count=\(skiaFrames)"
        guard let shift else {
            return "missing-scroll-region-shift \(rendererSummary)"
        }
        var columns = ""
        if let startCol = shift.startCol, let endCol = shift.endCol {
            columns = " cols=\(startCol)..\(endCol)"
        }
        return "rows=\(shift.rows) start=\(shift.startRow) end=\(shift.endRow)\(columns) " +
            rendererSummary
    }

    private func clearSmokeScrollShift() {
        lastNvimModelScrollShift = nil
    }

    private func consumeSmokeScrollShift() -> OutputScrollShift? {
        defer {
            lastNvimModelScrollShift = nil
        }
        return lastNvimModelScrollShift
    }

    private func peekSmokeScrollShift() -> OutputScrollShift? {
        lastNvimModelScrollShift
    }

    private func activePaneRendererScrollPosition() -> Double {
        guard let paneId = activePaneId,
              let pane = terminalPanes[paneId] as? RustTerminalPane
        else {
            return 0
        }
        return pane.rendererScrollPosition()
    }

    private func runNvimCommandOrWrite(_ command: String, fallback: Data) {
        if !runNvimCommand(command) {
            writeToActivePane(fallback)
        }
    }

    private func scheduleNvimCommand(
        _ command: String,
        paneId: Int?,
        fallback: Data? = nil,
        delay: TimeInterval = nvimStartupCommandDelay
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let targetPaneId = paneId ?? self.activePaneId else {
                return
            }
            self.runNvimCommand(command, paneId: targetPaneId, fallback: fallback)
        }
    }

    private func scheduleNvimDirectoryCorrection(paneId: Int, directory: String) {
        scheduleNvimCommand(
            neovimChangeDirectoryCommand(directory),
            paneId: paneId,
            delay: nvimStartupCwdCorrectionDelay
        )
    }

    @discardableResult
    private func runNvimCommand(_ command: String) -> Bool {
        guard let paneId = activePaneId,
              let pane = terminalPanes[paneId] as? RustNeovimPane
        else {
            return false
        }
        let ok = pane.runCommand(command)
        if ok {
            drainTerminalPanes()
        }
        return ok
    }

    private func runNvimCommand(_ command: String, paneId: Int, fallback: Data?) {
        guard let pane = terminalPanes[paneId] as? RustNeovimPane else {
            return
        }
        if pane.runCommand(command) {
            drainTerminalPanes()
        } else if let fallback {
            pane.write(fallback)
            drainTerminalPanes()
        }
    }

    private func syncFromCore() {
        guard let snapshot = core.snapshot() else {
            return
        }

        lastSnapshot = snapshot
        syncTabs(snapshot)
        syncPaneLayout(snapshot)
        syncActivePane(snapshot)
        view.window?.title = windowTitle(snapshot)
    }

    private func selectTab(_ index: Int) {
        if let session = tmuxSession,
           let tab = lastSnapshot?.tabs.first(where: { $0.index == index }),
           let windowId = session.tmuxWindowIds[tab.id] {
            _ = session.gateway.tmuxCommand("select-window -t @\(windowId)")
            focusTerminal()
            return
        }
        _ = core.selectTab(index)
        syncFromCore()
        focusTerminal()
    }

    private func selectPane(_ paneId: Int) {
        if let session = tmuxSession, let tmuxPaneId = session.tmuxPaneIds[paneId] {
            guard session.gateway.tmuxCommand("select-pane -t %\(tmuxPaneId)") else {
                return
            }
            activePaneId = paneId
            updateActiveFrame()
            focusTerminal()
            return
        }
        guard core.selectPane(paneId) else {
            return
        }
        syncFromCore()
        focusTerminal()
    }

    private func selectTabForContextMenu(_ index: Int) {
        if let session = tmuxSession,
           let tab = lastSnapshot?.tabs.first(where: { $0.index == index }),
           let windowId = session.tmuxWindowIds[tab.id] {
            _ = session.gateway.tmuxCommand("select-window -t @\(windowId)")
            return
        }
        guard core.selectTab(index) else {
            return
        }
        syncFromCore()
    }

    private func syncTabs(_ snapshot: TerminalCoreSnapshot) {
        syncingTabs = true
        tabControl.segmentCount = snapshot.tabs.count
        for (idx, tab) in snapshot.tabs.enumerated() {
            tabControl.setLabel(tab.title, forSegment: idx)
            tabControl.setWidth(tabWidth(for: tab.title), forSegment: idx)
        }
        if snapshot.active_tab < tabControl.segmentCount {
            tabControl.selectedSegment = snapshot.active_tab
        }
        tabControl.sizeToFit()
        let activeTheme = snapshot.tabs.first {
            $0.index == snapshot.active_tab
        }?.theme
        backdropView.updateAccentColor(themeAccentColor(activeTheme))
        updateSessionControl()
        syncingTabs = false
    }

    private func syncPaneLayout(_ snapshot: TerminalCoreSnapshot) {
        guard let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab }) else {
            visiblePaneFrames = [:]
            terminalTextView.updatePaneFrames([:], activePaneId: nil)
            return
        }
        var frames: [Int: NSRect] = [:]
        collectPaneFrames(
            tab.layout,
            rect: terminalTextView.terminalContentRect(),
            frames: &frames
        )
        visiblePaneFrames = frames
        terminalTextView.updatePaneFrames(frames, activePaneId: tab.active_pane)
        for (paneId, frame) in frames {
            let pane = terminalPane(for: paneId)
            if !(pane is RustTmuxPane) {
                pane?.resize(grid: terminalTextView.terminalGridSize(for: frame))
            }
        }
        syncTmuxClientSize()
    }

    private func syncTmuxClientSize() {
        guard let session = tmuxSession else {
            return
        }
        let grid = tmuxClientGrid()
        if session.lastClientGrid?.cols == grid.cols,
           session.lastClientGrid?.rows == grid.rows {
            return
        }
        guard session.gateway.tmuxCommand("refresh-client -C \(grid.cols),\(grid.rows)") else {
            return
        }
        session.lastClientGrid = (grid.cols, grid.rows)
    }

    private func tmuxClientGrid() -> (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int) {
        terminalTextView.terminalGridSize(for: terminalTextView.terminalContentRect())
    }

    private func collectPaneFrames(
        _ layout: PaneLayoutSnapshot,
        rect: NSRect,
        frames: inout [Int: NSRect]
    ) {
        if layout.kind == "leaf", let paneId = layout.pane_id {
            frames[paneId] = rect.insetBy(dx: 1, dy: 1)
            return
        }
        guard let axis = layout.axis, let first = layout.first, let second = layout.second else {
            return
        }
        let ratio = CGFloat(min(max(layout.ratio ?? 0.5, 0.05), 0.95))
        if axis == "vertical" {
            let firstWidth = floor(rect.width * ratio)
            collectPaneFrames(
                first,
                rect: NSRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                frames: &frames
            )
            collectPaneFrames(
                second,
                rect: NSRect(
                    x: rect.minX + firstWidth,
                    y: rect.minY,
                    width: rect.width - firstWidth,
                    height: rect.height
                ),
                frames: &frames
            )
        } else {
            let firstHeight = floor(rect.height * ratio)
            collectPaneFrames(
                first,
                rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight),
                frames: &frames
            )
            collectPaneFrames(
                second,
                rect: NSRect(
                    x: rect.minX,
                    y: rect.minY + firstHeight,
                    width: rect.width,
                    height: rect.height - firstHeight
                ),
                frames: &frames
            )
        }
    }

    private func themeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Color Theme", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for theme in nativeThemeNames {
            let themeItem = menuItem(theme, #selector(setThemeFromMenu(_:)))
            themeItem.representedObject = theme
            themeItem.image = colorSwatchImage(themeAccentColor(theme))
            themeItem.state = theme == activeTheme() ? .on : .off
            submenu.addItem(themeItem)
        }
        item.submenu = submenu
        return item
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func activeTheme() -> String? {
        guard let snapshot = lastSnapshot else {
            return nil
        }
        return snapshot.tabs.first(where: { $0.index == snapshot.active_tab })?.theme
    }

    private func windowTitle(_ snapshot: TerminalCoreSnapshot) -> String {
        let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab })
        if let session = tmuxSession {
            return "\(tab?.title ?? session.sessionName) — tmux · \(session.sessionName) — "
                + nativeApplicationName
        }
        return "\(tab?.title ?? nativeApplicationName) — \(nativeApplicationName)"
    }

    private func configureTabControl() {
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        NativePlatformAppearance.configureTabControl(tabControl)
        tabControl.trackingMode = .selectOne
        tabControl.target = self
        tabControl.action = #selector(tabControlChanged(_:))
        tabControl.setAccessibilityLabel("Terminal Tabs")
    }

    private func configureToolbarControls() {
        sessionControlButton.title = "Local"
        sessionControlButton.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Local Terminal"
        )
        sessionControlButton.imagePosition = .imageLeading
        sessionControlButton.imageHugsTitle = true
        sessionControlButton.cell?.wraps = false
        sessionControlButton.cell?.lineBreakMode = .byTruncatingTail
        sessionControlButton.target = self
        sessionControlButton.action = #selector(showSessionSwitcher(_:))
        sessionControlButton.toolTip = "Switch between the local terminal and tmux sessions"
        sessionControlButton.setAccessibilityLabel("Terminal Session")

        toolbarActionControl.segmentCount = 3
        toolbarActionControl.trackingMode = .momentary
        toolbarActionControl.setImage(
            NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab"),
            forSegment: 0
        )
        toolbarActionControl.setImage(
            NSImage(
                systemSymbolName: "rectangle.split.2x1",
                accessibilityDescription: "Split Left and Right"
            ),
            forSegment: 1
        )
        toolbarActionControl.setImage(
            NSImage(
                systemSymbolName: "rectangle.split.1x2",
                accessibilityDescription: "Split Top and Bottom"
            ),
            forSegment: 2
        )
        for segment in 0..<3 {
            toolbarActionControl.setWidth(30, forSegment: segment)
        }
        toolbarActionControl.sizeToFit()
        toolbarActionControl.target = self
        toolbarActionControl.action = #selector(toolbarActionChanged(_:))
        toolbarActionControl.toolTip = "New Tab and Split Pane"
        toolbarActionControl.setAccessibilityLabel("Tab and Pane Actions")
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            SatinToolbarItemIdentifier.tabs,
            .flexibleSpace,
            SatinToolbarItemIdentifier.controls,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case SatinToolbarItemIdentifier.tabs:
            item.label = "Tabs"
            item.paletteLabel = "Terminal Tabs"
            item.view = tabControl
            item.visibilityPriority = .standard
        case SatinToolbarItemIdentifier.controls:
            item.label = "Session and Pane Actions"
            item.paletteLabel = "Session and Pane Actions"
            item.view = toolbarControlsView
            item.visibilityPriority = .high
        default:
            return nil
        }
        return item
    }

    @objc private func toolbarActionChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0:
            newTab(nil)
        case 1:
            splitVertical(nil)
        case 2:
            splitHorizontal(nil)
        default:
            return
        }
        focusTerminal()
    }

    @objc func showSessionSwitcher(_ sender: Any?) {
        if sessionPopover?.isShown == true {
            dismissSessionPopover()
            return
        }
        let controller = TmuxSessionPopoverController(
            sessions: discoveredTmuxSessions(),
            currentSessionName: tmuxSession?.sessionName
        )
        controller.onSelectLocal = { [weak self] in
            self?.dismissSessionPopover()
            self?.detachTmuxSession()
        }
        controller.onSelectSession = { [weak self] descriptor in
            self?.dismissSessionPopover()
            self?.attachTmuxSession(descriptor)
        }
        controller.onCreateSession = { [weak self] name in
            self?.dismissSessionPopover()
            self?.createTmuxSession(named: name)
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        sessionPopover = popover
        popover.show(
            relativeTo: sessionControlButton.bounds,
            of: sessionControlButton,
            preferredEdge: .maxY
        )
    }

    private func discoveredTmuxSessions() -> [NativeTmuxSessionDescriptor] {
        let socketPath = tmuxSession?.socketPath
        var descriptors = NativeTmuxSessionDiscovery.sessions(socketPath: socketPath)
        if let session = tmuxSession,
           !descriptors.contains(where: {
               $0.name == session.sessionName && $0.socketPath == session.socketPath
           }) {
            descriptors.append(
                NativeTmuxSessionDescriptor(
                    name: session.sessionName,
                    windowCount: lastSnapshot?.tabs.count ?? 1,
                    socketPath: session.socketPath
                )
            )
        }
        return descriptors.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func dismissSessionPopover() {
        sessionPopover?.performClose(nil)
        sessionPopover = nil
    }

    private func detachTmuxSession() {
        guard let session = tmuxSession else {
            focusTerminal()
            return
        }
        if !session.gateway.tmuxCommand("detach-client") {
            presentTmuxSessionError("Satin could not detach from the current tmux session.")
        }
    }

    private func attachTmuxSession(_ descriptor: NativeTmuxSessionDescriptor) {
        if let session = tmuxSession {
            guard descriptor.socketPath == session.socketPath else {
                presentTmuxSessionError(
                    "Detach to Local Terminal before connecting to a different tmux server."
                )
                return
            }
            guard descriptor.name != session.sessionName else {
                focusTerminal()
                return
            }
            if !session.gateway.tmuxCommand(
                "switch-client -t \(tmuxCommandArgument(descriptor.name))"
            ) {
                presentTmuxSessionError("Satin could not switch to that tmux session.")
            }
            return
        }
        runTmuxCommandInActiveShell(
            "command tmux -S \(shellQuote(descriptor.socketPath)) -CC attach-session "
                + "-t \(shellQuote(descriptor.name))"
        )
    }

    private func createTmuxSession(named name: String) {
        if let session = tmuxSession {
            let argument = tmuxCommandArgument(name)
            guard session.gateway.tmuxCommand("new-session -d -s \(argument)"),
                  session.gateway.tmuxCommand("switch-client -t \(argument)")
            else {
                presentTmuxSessionError("Satin could not create that tmux session.")
                return
            }
            return
        }
        runTmuxCommandInActiveShell(
            "command tmux -CC new-session -s \(shellQuote(name))"
        )
    }

    private func runTmuxCommandInActiveShell(_ command: String) {
        guard let paneId = activePaneId,
              terminalPanes[paneId] is RustTerminalPane
        else {
            presentTmuxSessionError("Select a terminal pane before connecting to tmux.")
            return
        }
        var input = Data([21])
        input.append(Data("\(command)\r".utf8))
        writeToActivePane(input)
    }

    private func presentTmuxSessionError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "tmux Session"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func updateSessionControl() {
        let title: String
        let symbol: String
        if let session = tmuxSession {
            title = "tmux · \(session.sessionName)"
                + (session.activeWindowZoomed ? " · Zoom" : "")
            symbol = "rectangle.stack"
        } else {
            title = "Local"
            symbol = "terminal"
        }
        sessionControlButton.title = title
        sessionControlButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )
        sessionControlButton.setAccessibilityValue(title)
        sessionControlButton.sizeToFit()
        NativePlatformAppearance.toolbarControlContentSizeDidChange(toolbarControlsView)
    }

    private func sessionControlTitle() -> String {
        sessionControlButton.title
    }

    private func tabWidth(for title: String) -> CGFloat {
        let measured = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
        return min(max(measured.width + 34, 112), 190)
    }

    private func configureTerminalTextView() {
        terminalTextView.translatesAutoresizingMaskIntoConstraints = false
        terminalTextView.wantsLayer = true
        terminalTextView.layer?.backgroundColor = NSColor.clear.cgColor
        terminalTextView.layer?.zPosition = 1
    }

    private func syncActivePane(_ snapshot: TerminalCoreSnapshot) {
        guard let paneId = activePaneId(in: snapshot) else {
            activePaneId = nil
            terminalTextView.setRendererModel(nil)
            return
        }

        if activePaneId != paneId {
            lastNvimModelScrollShift = nil
        }
        activePaneId = paneId
        _ = terminalPane(for: paneId)
        updateActiveFrame()
    }

    private func activePaneId(in snapshot: TerminalCoreSnapshot) -> Int? {
        snapshot.tabs.first(where: { $0.index == snapshot.active_tab })?.active_pane
    }

    private func terminalPane(for paneId: Int) -> NativePane? {
        if let pane = terminalPanes[paneId] {
            return pane
        }

        let cwd = paneWorkingDirectories[paneId]
            ?? pendingPaneWorkingDirectory
            ?? nativeWorkingDirectory()
        pendingPaneWorkingDirectory = nil
        let startupCommand = pendingPaneStartupCommand
        pendingPaneStartupCommand = nil
        let mode = paneModes[paneId] ?? pendingPaneMode ?? defaultPaneMode
        pendingPaneMode = nil
        guard let pane = makePane(
            paneId: paneId,
            grid: paneGridSize(paneId),
            cwd: cwd,
            mode: mode,
            startupCommand: startupCommand
        ) else {
            return nil
        }
        terminalPanes[paneId] = pane
        installPaneWakeup(paneId: paneId, pane: pane)
        paneModes[paneId] = pane.kind
        paneWorkingDirectories[paneId] = cwd
        (pane as? RustTerminalPane)?.setOptionAsAlt(optionAsAltEnabled)
        if pane.kind == .neovim {
            scheduleNvimDirectoryCorrection(
                paneId: paneId,
                directory: cwd
            )
        }
        return pane
    }

    private func makePane(
        paneId: Int,
        grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
        cwd: String,
        mode: NativePaneMode,
        startupCommand: [String]? = nil
    ) -> NativePane? {
        switch mode {
        case .terminal:
            return RustTerminalPane(
                grid: grid,
                cwd: cwd,
                shell: settings.shellPath,
                environment: controlEnvironment(paneId: paneId),
                startupCommand: startupCommand ?? []
            )
        case .neovim:
            let arguments = ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_CLEAN_NVIM"] == "1"
                ? ["-u", "NONE", "-n"]
                : []
            return RustNeovimPane(grid: grid, cwd: cwd, arguments: arguments)
        }
    }

    private func prepareFinderEditorLaunch(_ launch: NativeFinderEditorLaunch) {
        pendingPaneWorkingDirectory = launch.workingDirectory
        var startupCommand = launch.startupCommand(editor: settings.finderEditorCommand)
        if settings.finderEditorCommand == "nvim",
           FileManager.default.isExecutableFile(atPath: nvimLauncherPath) {
            startupCommand[0] = nvimLauncherPath
        }
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_SCENARIO"]
            == "finder-editor",
           settings.finderEditorCommand == "nvim" {
            startupCommand.insert(contentsOf: ["-u", "NONE", "-n"], at: 1)
        }
        pendingPaneStartupCommand = startupCommand
        pendingPaneMode = .terminal
    }

    private func controlEnvironment(paneId: Int) -> [String: String] {
        guard !controlSocketPath.isEmpty else {
            return [:]
        }
        let tabId = lastSnapshot?.tabs.first(where: { $0.panes.contains(paneId) })?.id ?? 0
        var environment = [
            "SATIN_SOCKET": controlSocketPath,
            "SATIN_TAB_ID": String(tabId),
            "SATIN_PANE_ID": String(paneId),
            "NVTERM_SOCKET": controlSocketPath,
            "NVTERM_TAB_ID": String(tabId),
            "NVTERM_PANE_ID": String(paneId),
        ]
        if !controlCliPath.isEmpty {
            environment["SATIN_CLI"] = controlCliPath
            let cliDirectory = URL(fileURLWithPath: controlCliPath)
                .deletingLastPathComponent()
                .path
            let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            environment["PATH"] = "\(cliDirectory):\(inheritedPath)"
        }
        if !nvimLauncherPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: nvimLauncherPath) {
            environment["SATIN_NVIM_LAUNCHER"] = nvimLauncherPath
        }
        if !zshIntegrationPath.isEmpty,
           FileManager.default.fileExists(
               atPath: URL(fileURLWithPath: zshIntegrationPath)
                   .appendingPathComponent(".zshrc")
                   .path
           ) {
            environment["SATIN_ZSH_INTEGRATION_DIR"] = zshIntegrationPath
        }
        return environment
    }

    private func resizeTerminalPanesToGrid() {
        if let snapshot = lastSnapshot {
            syncPaneLayout(snapshot)
        }
        updateActiveFrame()
    }

    private func paneGridSize(
        _ paneId: Int
    ) -> (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int) {
        guard let frame = visiblePaneFrames[paneId] else {
            return terminalTextView.terminalGridSize()
        }
        return terminalTextView.terminalGridSize(for: frame)
    }

    private func writeToActivePane(_ data: Data) {
        guard let paneId = activePaneId,
              let pane = terminalPane(for: paneId)
        else {
            return
        }
        pane.write(data)
        drainTerminalPanes()
    }

    private func sendKeyToActivePane(_ event: NSEvent, released: Bool) -> Bool {
        guard let paneId = activePaneId,
              let pane = terminalPane(for: paneId) as? RustTerminalPane
        else {
            return false
        }
        let handled = pane.key(event, released: released)
        if handled {
            drainTerminalPanes()
        }
        // The terminal encoder is authoritative even when a physical key has
        // no terminal representation. Never fall back to hand-built escapes.
        return true
    }

    private func writeTextToActivePane(_ text: String) {
        guard let paneId = activePaneId,
              let pane = terminalPane(for: paneId)
        else {
            return
        }
        if let terminal = pane as? RustTerminalPane {
            terminal.writeText(text)
        } else {
            pane.write(Data(text.utf8))
        }
        drainTerminalPanes()
    }

    private func sendMouseInputToActivePane(_ input: NativeMouseInput) -> NativeMouseHandling {
        guard let paneId = activePaneId, let pane = terminalPanes[paneId] else {
            return .unhandled
        }
        let handling = if let terminal = pane as? RustTerminalPane {
            terminal.mouse(input) ? NativeMouseHandling.handled : .unhandled
        } else if let neovim = pane as? RustNeovimPane {
            neovim.mouse(input)
        } else {
            NativeMouseHandling.unhandled
        }
        guard handling != .unhandled else {
            return .unhandled
        }
        drainTerminalPanes()
        if handling == .messageSelection {
            if let neovim = pane as? RustNeovimPane,
               let text = neovim.takeMessageSelectionText(),
               !text.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            updateActiveFrame()
        }
        return handling
    }

    private func setTerminalFocus(_ focused: Bool) {
        guard let paneId = activePaneId,
              let terminal = terminalPanes[paneId] as? RustTerminalPane
        else {
            return
        }
        terminal.focus(focused)
    }

    private func selectTerminalText(
        start: (row: Int, col: Int),
        end: (row: Int, col: Int),
        rectangular: Bool
    ) {
        guard let paneId = activePaneId,
              let pane = terminalPanes[paneId] as? RustTerminalPane
        else {
            return
        }
        pane.select(start: start, end: end, rectangular: rectangular)
        updateActiveFrame()
    }

    @discardableResult
    private func copySelection() -> Bool {
        guard let paneId = activePaneId,
              let pane = terminalPanes[paneId] as? RustTerminalPane,
              let text = pane.selectedText(),
              !text.isEmpty
        else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    private func openTerminalHyperlink(_ position: (row: Int, col: Int)) -> Bool {
        guard let paneId = activePaneId,
              let pane = terminalPanes[paneId] as? RustTerminalPane,
              let value = pane.hyperlink(row: position.row, col: position.col),
              let url = URL(string: value)
        else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    @discardableResult
    private func pasteClipboard() -> Bool {
        guard let paneId = activePaneId,
              let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty
        else {
            return false
        }
        if let pane = terminalPanes[paneId] as? RustTerminalPane {
            pane.paste(text)
        } else {
            terminalPanes[paneId]?.write(Data(text.utf8))
        }
        drainTerminalPanes()
        return true
    }

    @discardableResult
    private func selectAllTerminalText() -> Bool {
        guard let paneId = activePaneId,
              let pane = terminalPanes[paneId] as? RustTerminalPane
        else {
            return false
        }
        pane.selectAll()
        updateActiveFrame()
        return true
    }

    @discardableResult
    private func findInScrollback() -> Bool {
        guard let paneId = activePaneId,
              let pane = terminalPanes[paneId] as? RustTerminalPane
        else {
            return false
        }
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        input.stringValue = lastSearchQuery
        let alert = NSAlert()
        alert.messageText = "Find in Scrollback"
        alert.accessoryView = input
        alert.addButton(withTitle: "Find Next")
        alert.addButton(withTitle: "Find Previous")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
            focusTerminal()
            return true
        }
        let query = input.stringValue
        guard !query.isEmpty else {
            focusTerminal()
            return true
        }
        lastSearchQuery = query
        let found = pane.find(query, backwards: response == .alertSecondButtonReturn)
        if !found {
            NSSound.beep()
        }
        updateActiveFrame()
        focusTerminal()
        return true
    }

    private func activeWorkingDirectory() -> String {
        guard let paneId = activePaneId else {
            return nativeWorkingDirectory()
        }
        let cwd = (terminalPanes[paneId] as? RustTerminalPane)?.currentWorkingDirectory()
            ?? paneWorkingDirectories[paneId]
            ?? nativeWorkingDirectory()
        paneWorkingDirectories[paneId] = cwd
        return cwd
    }

    private func newPaneWorkingDirectory() -> String {
        settings.startupDirectory.isEmpty
            ? activeWorkingDirectory()
            : nativeWorkingDirectory()
    }

    private func restoreSessionIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SATIN_NATIVE_SMOKE_SCENARIO"] == nil,
              preferredBool(NativePreferenceKey.sessionRestore, defaultValue: true),
              let data = UserDefaults.standard.data(forKey: NativePreferenceKey.sessionState)
        else {
            return
        }
        if let schemaVersion = sessionSchemaVersion(in: data),
           schemaVersion > currentSessionSchemaVersion {
            NativeLog.sessionWarning("session_from_newer_version_preserved")
            return
        }
        guard let state = decodeSessionState(data), !state.tabs.isEmpty else {
            NativeLog.sessionWarning("session_decode_failed state_removed=true")
            UserDefaults.standard.removeObject(forKey: NativePreferenceKey.sessionState)
            return
        }
        pendingTmuxReattach = state.tmuxAttachment.flatMap(validatedTmuxAttachment)
        consumePersistedTmuxAttachment(state)
        for (index, saved) in state.tabs.enumerated() {
            if index > 0 {
                core.newTab()
            }
            guard let snapshot = core.snapshot(),
                  let tab = snapshot.tabs.first(where: { $0.index == index })
            else {
                continue
            }
            _ = core.selectTab(index)
            core.renameTab(index, title: saved.title)
            core.setTheme(saved.theme, tab: index)
            if let activePane = restoreSessionPane(saved.layout, paneId: tab.active_pane) {
                _ = core.selectPane(activePane)
            }
        }
        _ = core.selectTab(min(max(state.activeTab, 0), state.tabs.count - 1))
    }

    private func decodeSessionState(_ data: Data) -> NativeSessionState? {
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(NativeSessionState.self, from: data) {
            if state.schemaVersion == currentSessionSchemaVersion {
                return state
            }
            if state.schemaVersion == 2 {
                return NativeSessionState(
                    schemaVersion: currentSessionSchemaVersion,
                    activeTab: state.activeTab,
                    tabs: state.tabs
                )
            }
        }
        guard let legacy = try? decoder.decode(LegacyNativeSessionState.self, from: data) else {
            return nil
        }
        return NativeSessionState(
            schemaVersion: currentSessionSchemaVersion,
            activeTab: legacy.activeTab,
            tabs: legacy.tabs.map { tab in
                NativeSessionTab(
                    title: tab.title,
                    theme: tab.theme,
                    layout: NativeSessionPane(
                        kind: "leaf",
                        paneMode: NativePaneMode.terminal.sessionValue,
                        cwd: tab.cwd,
                        active: true
                    )
                )
            }
        )
    }

    private func consumePersistedTmuxAttachment(_ state: NativeSessionState) {
        guard state.tmuxAttachment != nil else {
            return
        }
        let consumed = sessionStateWithoutTmuxAttachment(state)
        guard let data = try? JSONEncoder().encode(consumed) else {
            NativeLog.sessionWarning("tmux_reattach_consume_encode_failed")
            return
        }
        UserDefaults.standard.set(data, forKey: NativePreferenceKey.sessionState)
    }

    private func sessionStateWithoutTmuxAttachment(
        _ state: NativeSessionState
    ) -> NativeSessionState {
        NativeSessionState(
            schemaVersion: currentSessionSchemaVersion,
            activeTab: state.activeTab,
            tabs: state.tabs
        )
    }

    private func schedulePendingTmuxReattach() {
        guard let attachment = pendingTmuxReattach,
              let paneId = activePaneId,
              let gateway = terminalPanes[paneId] as? RustTerminalPane
        else {
            return
        }
        pendingTmuxReattach = nil
        let command = "command tmux -S \(shellQuote(attachment.socketPath)) "
            + "-CC attach-session -t \(shellQuote(attachment.sessionName))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak gateway] in
            guard let self, let gateway, self.tmuxSession == nil, !gateway.isExited() else {
                return
            }
            gateway.write(Data("\(command)\r".utf8))
            self.drainTerminalPanes()
            NativeLog.lifecycleInfo(
                "tmux_reattach_started session=\(attachment.sessionName)"
            )
        }
    }

    private func sessionSchemaVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["schemaVersion"] as? Int
    }

    private func restoreSessionPane(_ saved: NativeSessionPane, paneId: Int) -> Int? {
        if saved.kind == "leaf" {
            paneWorkingDirectories[paneId] = saved.cwd.isEmpty
                ? nativeWorkingDirectory()
                : saved.cwd
            paneModes[paneId] = NativePaneMode(sessionValue: saved.paneMode)
            return saved.active ? paneId : nil
        }
        guard saved.kind == "split",
              let first = saved.first,
              let second = saved.second,
              core.selectPane(paneId)
        else {
            return nil
        }
        let axis = saved.axis == "horizontal" ? ffiSplitHorizontal : ffiSplitVertical
        guard let secondPaneId = core.splitActive(axis: axis) else {
            return nil
        }
        let firstActivePane = restoreSessionPane(first, paneId: paneId)
        let secondActivePane = restoreSessionPane(second, paneId: secondPaneId)
        return firstActivePane ?? secondActivePane
    }

    private func switchTerminalPaneToNeovim(
        paneId: Int,
        cwd requestedDirectory: String? = nil,
        executable: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        completion: NativeControlReply? = nil
    ) -> Bool {
        guard let terminal = terminalPanes[paneId] as? RustTerminalPane,
              suspendedTerminalSessions[paneId] == nil
        else {
            return false
        }
        let cwd = requestedDirectory
            ?? terminal.currentWorkingDirectory()
            ?? nativeWorkingDirectory()
        guard let pane = RustNeovimPane(
            grid: paneGridSize(paneId),
            cwd: cwd,
            executable: executable,
            arguments: arguments,
            environment: environment
        ) else {
            return false
        }
        paneWakeupSources.removeValue(forKey: paneId)?.cancel()
        metalView.forgetRuntime(terminal.renderHandle())
        terminalPanes.removeValue(forKey: paneId)
        suspendedTerminalSessions[paneId] = NativeSuspendedTerminalSession(
            pane: terminal,
            completion: completion
        )
        installSuspendedPaneWakeup(paneId: paneId, pane: terminal)
        terminalPanes[paneId] = pane
        installPaneWakeup(paneId: paneId, pane: pane)
        paneWorkingDirectories[paneId] = cwd
        paneModes[paneId] = .neovim
        scrollRemainders[paneId] = 0
        lastNvimModelScrollShift = nil
        scheduleNvimDirectoryCorrection(paneId: paneId, directory: cwd)
        drainTerminalPanes()
        updateActiveFrame()
        return true
    }

    private func scrollActivePane(deltaRows: CGFloat) {
        guard let paneId = activePaneId,
              let pane = terminalPane(for: paneId) as? RustTerminalPane
        else {
            return
        }

        let requestedRows = wholeScrollRows(deltaRows, paneId: paneId)
        guard requestedRows != 0 else {
            return
        }

        let movedRows = pane.scroll(rows: requestedRows)
        guard movedRows != 0 else {
            return
        }
        updateActiveFrame()
    }

    private func wholeScrollRows(_ deltaRows: CGFloat, paneId: Int) -> Int {
        let accumulated = (scrollRemainders[paneId] ?? 0) + deltaRows
        let wholeRows = Int(accumulated.rounded(.towardZero))
        scrollRemainders[paneId] = accumulated - CGFloat(wholeRows)
        return wholeRows
    }

    private func activePaneMode() -> NativePaneMode {
        guard let paneId = activePaneId,
              let pane = terminalPanes[paneId]
        else {
            return defaultPaneMode
        }
        return pane.kind
    }

    private func nativeWorkingDirectory() -> String {
        let configured = settings.startupDirectory
        var isDirectory: ObjCBool = false
        if !configured.isEmpty,
           FileManager.default.fileExists(atPath: configured, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return configured
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return home
        }
        return FileManager.default.currentDirectoryPath
    }

    private func neovimChangeDirectoryCommand(_ directory: String) -> String {
        "execute 'cd' fnameescape('\(vimSingleQuoted(directory))')"
    }

    private func neovimEditCommand(_ file: String) -> String {
        "execute 'edit!' fnameescape('\(vimSingleQuoted(file))')"
    }

    private func neovimEditTopCommand(_ file: String) -> String {
        "\(neovimEditCommand(file)) | normal! gg"
    }

    private func vimSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func installPaneWakeup(paneId: Int, pane: NativePane) {
        paneWakeupSources.removeValue(forKey: paneId)?.cancel()
        let descriptor = pane.wakeupFD()
        guard descriptor >= 0 else {
            return
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.drainTerminalPanes()
        }
        paneWakeupSources[paneId] = source
        source.resume()
    }

    private func installSuspendedPaneWakeup(paneId: Int, pane: RustTerminalPane) {
        suspendedPaneWakeupSources.removeValue(forKey: paneId)?.cancel()
        let descriptor = pane.wakeupFD()
        guard descriptor >= 0 else {
            return
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.drainSuspendedTerminalPane(paneId)
        }
        suspendedPaneWakeupSources[paneId] = source
        source.resume()
    }

    private func drainSuspendedTerminalPane(_ paneId: Int) {
        guard let pane = suspendedTerminalSessions[paneId]?.pane else {
            suspendedPaneWakeupSources.removeValue(forKey: paneId)?.cancel()
            return
        }
        _ = pane.drain()
        updateTerminalMetadata(pane, paneId: paneId)
    }

    private func removePaneRuntime(_ paneId: Int) {
        paneWakeupSources.removeValue(forKey: paneId)?.cancel()
        metalView.forgetRuntime(terminalPanes[paneId]?.renderHandle())
        terminalPanes.removeValue(forKey: paneId)
    }

    private func discardSuspendedTerminalSession(_ paneId: Int) {
        suspendedPaneWakeupSources.removeValue(forKey: paneId)?.cancel()
        let suspended = suspendedTerminalSessions.removeValue(forKey: paneId)
        suspended?.completion?(
            controlFailure("pane_closed", "The pane was closed while Neovim was active.")
        )
    }

    private func drainTerminalPanes() {
        var activePaneChanged = false
        var exitedNvimPanes: [Int] = []
        var exitedTerminalPanes: [Int] = []
        var tmuxEvents: [(paneId: Int, pane: RustTerminalPane, event: TmuxControlEvent)] = []
        for (paneId, pane) in terminalPanes {
            let changed = pane.drain()
            activePaneChanged = activePaneChanged || (changed && paneId == activePaneId)
            if let terminal = pane as? RustTerminalPane {
                while let event = terminal.takeTmuxEvent() {
                    tmuxEvents.append((paneId, terminal, event))
                }
                if terminal is RustTmuxPane {
                    updateTerminalBells(terminal)
                } else if tmuxSession?.gatewayPaneId != paneId {
                    updateTerminalMetadata(terminal, paneId: paneId)
                }
            }
            if pane.kind == .neovim && pane.isExited() {
                exitedNvimPanes.append(paneId)
            } else if pane.kind == .terminal && pane.isExited() {
                exitedTerminalPanes.append(paneId)
            }
        }
        for item in tmuxEvents {
            handleTmuxEvent(item.event, gatewayPaneId: item.paneId, gateway: item.pane)
        }
        for paneId in exitedNvimPanes {
            replaceExitedNeovimPane(paneId)
            activePaneChanged = activePaneChanged || paneId == activePaneId
        }
        if closeExitedTerminalPanes(exitedTerminalPanes) {
            return
        }
        if activePaneChanged {
            updateActiveFrame()
        }
    }

    private func handleTmuxEvent(
        _ event: TmuxControlEvent,
        gatewayPaneId: Int,
        gateway: RustTerminalPane
    ) {
        switch event.kind {
        case "entered":
            beginTmuxSession(gatewayPaneId: gatewayPaneId, gateway: gateway)
        case "pane_hydration":
            guard let paneId = event.pane_id, let bytes = event.data else {
                return
            }
            hydrateTmuxPane(paneId: paneId, data: Data(bytes))
        case "pane_output":
            guard let paneId = event.pane_id, let bytes = event.data else {
                return
            }
            feedTmuxOutput(paneId: paneId, data: Data(bytes))
        case "snapshot":
            guard let snapshot = event.snapshot else {
                return
            }
            applyTmuxSnapshot(snapshot, gatewayPaneId: gatewayPaneId, gateway: gateway)
        case "protocol_error":
            NativeLog.runtimeError("tmux_protocol_error message=\(event.message ?? "unknown")")
            endTmuxSession(gatewayPaneId: gatewayPaneId)
        case "command_error":
            NativeLog.runtimeError("tmux_command_error message=\(event.message ?? "unknown")")
        case "exited":
            endTmuxSession(gatewayPaneId: gatewayPaneId)
        default:
            NativeLog.runtimeError("tmux_unknown_event kind=\(event.kind)")
        }
    }

    private func beginTmuxSession(gatewayPaneId: Int, gateway: RustTerminalPane) {
        guard tmuxSession == nil, let workspace = core.snapshot() else {
            return
        }
        tmuxSession = NativeTmuxSession(
            gatewayPaneId: gatewayPaneId,
            gateway: gateway,
            savedWorkspace: workspace
        )
        NativeLog.lifecycleInfo("tmux_control_entered gateway_pane=\(gatewayPaneId)")
    }

    private func feedTmuxOutput(paneId: UInt32, data: Data) {
        guard let session = tmuxSession else {
            return
        }
        if let nativePaneId = session.nativePaneIds[paneId],
           let pane = terminalPanes[nativePaneId] as? RustTmuxPane {
            pane.feed(data)
            if nativePaneId == activePaneId {
                updateActiveFrame()
            }
            return
        }
        session.bufferedOutput[paneId, default: Data()].append(data)
    }

    private func hydrateTmuxPane(paneId: UInt32, data: Data) {
        guard let session = tmuxSession else {
            return
        }
        if let nativePaneId = session.nativePaneIds[paneId],
           let pane = terminalPanes[nativePaneId] as? RustTmuxPane {
            pane.feed(data)
            if let latest = session.latestPanes[paneId] {
                pane.syncCursor(latest)
            }
            if nativePaneId == activePaneId {
                updateActiveFrame()
            }
            return
        }
        session.bufferedOutput[paneId] = data
    }

    private func applyTmuxSnapshot(
        _ snapshot: TmuxSnapshot,
        gatewayPaneId: Int,
        gateway: RustTerminalPane
    ) {
        if tmuxSession == nil {
            beginTmuxSession(gatewayPaneId: gatewayPaneId, gateway: gateway)
        }
        guard let session = tmuxSession, session.gatewayPaneId == gatewayPaneId else {
            return
        }
        session.sessionName = snapshot.session_name
        session.socketPath = snapshot.socket_path
        session.serverPid = snapshot.server_pid
        session.activeWindowZoomed = snapshot.windows
            .first(where: { $0.window_id == snapshot.active_window_id })?.zoomed ?? false
        let paneSnapshots = snapshot.windows.flatMap(\.panes)
        session.latestPanes = Dictionary(
            uniqueKeysWithValues: paneSnapshots.map { ($0.pane_id, $0) }
        )
        let nextNativePaneIds = Dictionary(
            uniqueKeysWithValues: paneSnapshots.map { ($0.pane_id, session.nativePaneId($0.pane_id)) }
        )
        let stalePaneIds = Set(session.nativePaneIds.values).subtracting(nextNativePaneIds.values)
        for paneId in stalePaneIds {
            removePaneRuntime(paneId)
            paneModes.removeValue(forKey: paneId)
            paneWorkingDirectories.removeValue(forKey: paneId)
        }
        for pane in paneSnapshots {
            let nativePaneId = nextNativePaneIds[pane.pane_id] ?? session.nativePaneId(pane.pane_id)
            paneWorkingDirectories[nativePaneId] = pane.current_path
            let grid = tmuxPaneGrid(pane)
            if let runtime = terminalPanes[nativePaneId] as? RustTmuxPane {
                runtime.setCurrentCommand(pane.current_command)
                runtime.resize(grid: grid)
                runtime.syncCursor(pane)
                continue
            }
            guard let runtime = RustTmuxPane(
                grid: grid,
                paneId: pane.pane_id,
                gateway: session.gateway
            ) else {
                NativeLog.runtimeError("tmux_pane_create_failed pane=%\(pane.pane_id)")
                return
            }
            terminalPanes[nativePaneId] = runtime
            paneModes[nativePaneId] = .terminal
            runtime.setOptionAsAlt(optionAsAltEnabled)
            runtime.setCurrentCommand(pane.current_command)
            if let buffered = session.bufferedOutput.removeValue(forKey: pane.pane_id) {
                runtime.feed(buffered)
            }
            runtime.syncCursor(pane)
        }
        session.nativePaneIds = nextNativePaneIds
        session.tmuxPaneIds = Dictionary(
            uniqueKeysWithValues: nextNativePaneIds.map { ($0.value, $0.key) }
        )
        session.nativeTabIds = Dictionary(
            uniqueKeysWithValues: snapshot.windows.map {
                ($0.window_id, session.nativeTabId($0.window_id))
            }
        )
        session.tmuxWindowIds = Dictionary(
            uniqueKeysWithValues: session.nativeTabIds.map { ($0.value, $0.key) }
        )
        guard core.applyWorkspace(tmuxWorkspace(snapshot, session: session)) else {
            NativeLog.runtimeError("tmux_workspace_apply_failed")
            return
        }
        syncFromCore()
        saveSessionState()
    }

    private func tmuxWorkspace(
        _ snapshot: TmuxSnapshot,
        session: NativeTmuxSession
    ) -> TerminalCoreSnapshot {
        let theme = session.savedWorkspace.tabs
            .first(where: { $0.index == session.savedWorkspace.active_tab })?.theme ?? "Graphite"
        let tabs = snapshot.windows.enumerated().map { index, window in
            let visiblePanes = tmuxLayoutPaneIds(window.layout)
            return TerminalCoreTabSnapshot(
                id: session.nativeTabId(window.window_id),
                index: index,
                title: window.name,
                active_pane: session.nativePaneId(window.active_pane_id),
                theme: theme,
                panes: window.panes
                    .filter { visiblePanes.contains($0.pane_id) }
                    .map { session.nativePaneId($0.pane_id) },
                layout: tmuxLayout(window.layout, session: session)
            )
        }
        let active = tabs.firstIndex {
            $0.id == session.nativeTabId(snapshot.active_window_id)
        } ?? 0
        return TerminalCoreSnapshot(active_tab: active, tabs: tabs)
    }

    private func tmuxLayout(
        _ layout: TmuxLayoutSnapshot,
        session: NativeTmuxSession
    ) -> PaneLayoutSnapshot {
        if layout.kind == "leaf", let paneId = layout.pane_id {
            return PaneLayoutSnapshot(kind: "leaf", paneId: session.nativePaneId(paneId))
        }
        return PaneLayoutSnapshot(
            kind: "split",
            axis: layout.axis,
            ratio: layout.ratio,
            first: layout.first.map { tmuxLayout($0, session: session) },
            second: layout.second.map { tmuxLayout($0, session: session) }
        )
    }

    private func tmuxLayoutPaneIds(_ layout: TmuxLayoutSnapshot) -> Set<UInt32> {
        if layout.kind == "leaf", let paneId = layout.pane_id {
            return [paneId]
        }
        return (layout.first.map(tmuxLayoutPaneIds) ?? [])
            .union(layout.second.map(tmuxLayoutPaneIds) ?? [])
    }

    private func tmuxPaneGrid(
        _ pane: TmuxPaneSnapshot
    ) -> (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int) {
        let base = terminalTextView.terminalGridSize()
        let width = max(1, base.widthPixels * Int(pane.cols) / max(1, base.cols))
        let height = max(1, base.heightPixels * Int(pane.rows) / max(1, base.rows))
        return (Int(pane.rows), Int(pane.cols), width, height)
    }

    private func endTmuxSession(gatewayPaneId: Int) {
        guard let session = tmuxSession, session.gatewayPaneId == gatewayPaneId else {
            return
        }
        for paneId in session.nativePaneIds.values {
            removePaneRuntime(paneId)
            paneModes.removeValue(forKey: paneId)
            paneWorkingDirectories.removeValue(forKey: paneId)
            paneTitles.removeValue(forKey: paneId)
        }
        tmuxSession = nil
        guard core.applyWorkspace(session.savedWorkspace) else {
            NativeLog.runtimeError("tmux_workspace_restore_failed")
            return
        }
        syncFromCore()
        saveSessionState()
        NativeLog.lifecycleInfo("tmux_control_exited gateway_pane=\(gatewayPaneId)")
    }

    private func closeExitedTerminalPanes(_ paneIds: [Int]) -> Bool {
        var closed = false
        for paneId in paneIds {
            removeControlState(paneId)
            removePaneRuntime(paneId)
            scrollRemainders.removeValue(forKey: paneId)
            paneWorkingDirectories.removeValue(forKey: paneId)
            paneModes.removeValue(forKey: paneId)
            paneTitles.removeValue(forKey: paneId)
            closed = core.closePane(paneId) || closed
        }
        guard closed else {
            return false
        }
        guard let snapshot = core.snapshot(), !snapshot.tabs.isEmpty else {
            NSApp.terminate(nil)
            return true
        }
        syncFromCore()
        return true
    }

    private func replaceExitedNeovimPane(_ paneId: Int) {
        let exitCode = (terminalPanes[paneId] as? RustNeovimPane)?.exitCode() ?? 1
        removePaneRuntime(paneId)
        suspendedPaneWakeupSources.removeValue(forKey: paneId)?.cancel()
        if let suspended = suspendedTerminalSessions.removeValue(forKey: paneId) {
            if !suspended.pane.isExited() {
                let pane = suspended.pane
                terminalPanes[paneId] = pane
                pane.resize(grid: paneGridSize(paneId))
                pane.setOptionAsAlt(optionAsAltEnabled)
                _ = pane.drain()
                updateTerminalMetadata(pane, paneId: paneId)
                installPaneWakeup(paneId: paneId, pane: pane)
                paneModes[paneId] = .terminal
                scrollRemainders[paneId] = 0
                lastNvimModelScrollShift = nil
                suspended.completion?(.success(["pane": paneId, "exitCode": exitCode]))
                return
            }
            suspended.completion?(
                controlFailure("shell_exited", "The suspended shell exited before Neovim.")
            )
        }
        let cwd = paneWorkingDirectories[paneId] ?? nativeWorkingDirectory()
        guard let pane = RustTerminalPane(
            grid: paneGridSize(paneId),
            cwd: cwd,
            shell: settings.shellPath,
            environment: controlEnvironment(paneId: paneId)
        ) else {
            return
        }
        terminalPanes[paneId] = pane
        pane.setOptionAsAlt(optionAsAltEnabled)
        installPaneWakeup(paneId: paneId, pane: pane)
        paneModes[paneId] = .terminal
        scrollRemainders[paneId] = 0
        lastNvimModelScrollShift = nil
    }

    private func updateTerminalMetadata(_ pane: RustTerminalPane, paneId: Int) {
        if let cwd = pane.currentWorkingDirectory() {
            paneWorkingDirectories[paneId] = cwd
        }
        if let title = pane.title(), paneTitles[paneId] != title {
            paneTitles[paneId] = title
            if let tab = lastSnapshot?.tabs.first(where: { $0.active_pane == paneId }) {
                core.renameTab(tab.index, title: title)
                syncFromCore()
            }
        }
        let bells = pane.takeBellCount()
        handleTerminalBells(bells)
    }

    private func updateTerminalBells(_ pane: RustTerminalPane) {
        handleTerminalBells(pane.takeBellCount())
    }

    private func handleTerminalBells(_ bells: UInt64) {
        guard bells > 0 else {
            return
        }
        NSSound.beep()
        if notificationsEnabled, !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func updateActiveFrame() {
        guard let paneId = activePaneId,
              let pane = terminalPanes[paneId]
        else {
            terminalTextView.setRendererModel(nil)
            terminalTextView.setTerminalCursor(nil)
            return
        }

        if let pane = pane as? RustNeovimPane, let model = pane.rendererModel() {
            if let scrollHint = model.scroll_hint {
                lastNvimModelScrollShift = scrollHint.outputShift
            }
            terminalTextView.setTerminalCursor(nil)
            terminalTextView.setRendererModel(model)
            metalView.needsDisplay = true
            return
        }

        terminalTextView.setRendererModel(nil)
        terminalTextView.setTerminalCursor((pane as? RustTerminalPane)?.cursorPosition())
        metalView.needsDisplay = true
    }

    private func renderActiveMetalFrame(
        texture: MTLTexture,
        renderer: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let renderer else {
            return false
        }
        var frames = visiblePaneFrames.sorted { $0.key < $1.key }
        if frames.isEmpty, let paneId = activePaneId {
            frames = [(key: paneId, value: terminalTextView.terminalContentRect())]
        }
        var rendered = false
        for (index, entry) in frames.enumerated() {
            guard let pane = terminalPane(for: entry.key),
                  let renderHandle = pane.renderHandle()
            else {
                continue
            }
            let geometry = terminalTextView.skiaRenderGeometry(for: entry.value)
            let clear: UInt8 = index == 0 ? 1 : 0
            let ok: Bool
            if pane.kind == .terminal {
                ok = satin_skia_metal_render_terminal(
                    renderer,
                    renderHandle,
                    metalObjectPointer(texture),
                    Int32(texture.width),
                    Int32(texture.height),
                    geometry.originX,
                    geometry.originY,
                    geometry.contentWidth,
                    geometry.contentHeight,
                    geometry.cellWidth,
                    geometry.cellHeight,
                    clear
                ) != 0
            } else {
                ok = satin_skia_metal_render_nvim(
                    renderer,
                    renderHandle,
                    metalObjectPointer(texture),
                    Int32(texture.width),
                    Int32(texture.height),
                    geometry.originX,
                    geometry.originY,
                    geometry.contentWidth,
                    geometry.contentHeight,
                    geometry.cellWidth,
                    geometry.cellHeight,
                    clear
                ) != 0
            }
            rendered = rendered || ok
        }
        return rendered
    }
}

final class SatinAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow?
    private var shellController: TerminalShellViewController?
    private let settingsStore = NativeSettingsStore()
    private var settingsWindowController: NativeSettingsWindowController?
    private var controlServer: NativeControlServer?
    private let updateChecker = AppUpdateChecker()
    private let updateInstaller = AppUpdateInstaller()
    private var updateCheckID: UUID?
    private var updateTask: URLSessionDataTask?
    private var updateProgressAlert: NSAlert?
    private var pendingFinderPaths: [String] = []
    private var launchedForFinderEditor = false
    private var observesKeyWindow = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        sender.reply(toOpenOrPrint: routeFinderPaths(filenames) ? .success : .failure)
    }

    @objc func openFilesInEditor(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        var paths = urls.map(\.path)
        if paths.isEmpty,
           let filenames = pasteboard.propertyList(
               forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
           ) as? [String] {
            paths = filenames
        }
        if paths.isEmpty, let text = pasteboard.string(forType: .string) {
            paths = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        if !routeFinderPaths(paths) {
            error.pointee = "Satin could not open the selected items." as NSString
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NativeLog.started()
        var settings = settingsStore.load()
        let environment = ProcessInfo.processInfo.environment
        if environment["SATIN_NATIVE_SMOKE_SCENARIO"] == "finder-editor" {
            let smokeEditor = environment["SATIN_NATIVE_SMOKE_FINDER_EDITOR"] ?? "nvim"
            settings.finderEditorCommand = NativeSettingsStore.isValidFinderEditorCommand(
                smokeEditor
            ) ? smokeEditor : "nvim"
            let smokeShell = environment["SATIN_NATIVE_SMOKE_FINDER_SHELL"] ?? "/bin/bash"
            if NativeSettingsStore.isValidShellPath(smokeShell) {
                settings.shellPath = smokeShell
            }
        }
        let initialFinderLaunch = NativeFinderEditorLaunch(paths: pendingFinderPaths)
        launchedForFinderEditor = initialFinderLaunch != nil
        guard let core = RustCore(defaultTheme: settings.defaultTheme) else {
            presentFatalError(
                title: "Terminal Core Failed",
                message: "The Rust terminal core could not be initialized. Check Console for details."
            )
            return
        }

        guard let controller = TerminalShellViewController(
            core: core,
            settings: settings,
            initialFinderLaunch: initialFinderLaunch
        ) else {
            presentFatalError(
                title: "Metal Renderer Unavailable",
                message: "A Metal-capable GPU and the bundled Skia renderer are required."
            )
            return
        }
        let socketPath = NativeControlEnvironment.socketPath()
        guard let controlServer = NativeControlServer(socketPath: socketPath) else {
            presentFatalError(
                title: "Control Server Failed",
                message: "The owner-only Unix control socket could not be created."
            )
            return
        }
        controller.configureControl(
            socketPath: socketPath,
            cliPath: NativeControlEnvironment.cliPath(),
            nvimLauncherPath: NativeControlEnvironment.nvimLauncherPath(),
            zshIntegrationPath: NativeControlEnvironment.zshIntegrationPath()
        )
        controlServer.onRequest = { [weak controller] request, reply in
            controller?.handleControlRequest(request, reply: reply)
        }
        self.controlServer = controlServer
        let contentRect = NSRect(x: 0, y: 0, width: 1100, height: 720)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = nativeApplicationName
        NativePlatformAppearance.configureWindow(
            window,
            role: .terminal
        )
        window.tabbingMode = .preferred
        controller.view.frame = NSRect(origin: .zero, size: contentRect.size)
        window.contentViewController = controller
        window.toolbar = controller.toolbar()
        self.window = window
        self.shellController = controller
        if !observesKeyWindow {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyWindowDidChange(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            observesKeyWindow = true
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        pendingFinderPaths.removeAll()
        let settingsController = NativeSettingsWindowController(store: settingsStore)
        settingsController.onChange = { [weak self] settings in
            self?.shellController?.applySettings(settings)
            self?.buildMainMenu()
        }
        self.settingsWindowController = settingsController

        buildMainMenu()
        applySmokeScenarioIfNeeded(controller)
        controller.focusTerminal()
        writeSmokeWindowIdIfNeeded(window)
        scheduleSmokeShotIfNeeded(window)
        scheduleAutomaticUpdateCheck()
    }

    private func presentFatalError(title: String, message: String) {
        NativeLog.runtimeError("fatal_error title=\(title) message=\(message)")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_SCENARIO"] == nil,
           !launchedForFinderEditor {
            shellController?.saveSessionState()
        }
    }

    private func routeFinderPaths(_ paths: [String]) -> Bool {
        guard let launch = NativeFinderEditorLaunch(paths: paths) else {
            return false
        }
        if let shellController {
            return shellController.openFinderItems(launch)
        }
        pendingFinderPaths.append(contentsOf: launch.paths)
        return true
    }

    @objc func newTab(_ sender: Any?) {
        shellController?.newTab(sender)
    }

    @objc func splitVertical(_ sender: Any?) {
        shellController?.splitVertical(sender)
    }

    @objc func splitHorizontal(_ sender: Any?) {
        shellController?.splitHorizontal(sender)
    }

    @objc func renameActiveTab(_ sender: Any?) {
        shellController?.renameActiveTab(sender)
    }

    @objc func openNativeNeovim(_ sender: Any?) {
        shellController?.openNativeNeovim(sender)
    }

    @objc func closeActivePane(_ sender: Any?) {
        shellController?.closeActivePane(sender)
    }

    @objc private func keyWindowDidChange(_ notification: Notification) {
        buildMainMenu()
    }

    @objc func showSessionSwitcher(_ sender: Any?) {
        shellController?.showSessionSwitcher(sender)
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindowController?.present()
    }

    @objc func zoomIn(_ sender: Any?) {
        shellController?.zoomIn(sender)
    }

    @objc func zoomOut(_ sender: Any?) {
        shellController?.zoomOut(sender)
    }

    @objc func resetZoom(_ sender: Any?) {
        shellController?.resetZoom(sender)
    }

    @objc func selectTabFromShortcut(_ sender: NSMenuItem) {
        shellController?.selectTabFromShortcut(sender.tag)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard !nativeIsDevelopmentBuild else {
            return
        }
        beginUpdateCheck(interactive: true)
    }

    @objc func showAcknowledgements(_ sender: Any?) {
        guard let notices = Bundle.main.url(
            forResource: "THIRD_PARTY_NOTICES",
            withExtension: "md",
            subdirectory: "Legal"
        ) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([notices])
    }

    private func scheduleAutomaticUpdateCheck() {
        guard !nativeIsDevelopmentBuild,
              ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_SCENARIO"] == nil
        else {
            return
        }
        guard settingsStore.shouldAutomaticallyCheckForUpdates() else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.beginUpdateCheck(interactive: false)
        }
    }

    private func beginUpdateCheck(interactive: Bool) {
        guard let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            if interactive {
                presentUpdateError(AppUpdateError.invalidCurrentVersion)
            }
            return
        }

        if interactive {
            updateTask?.cancel()
        } else if updateTask != nil {
            return
        }

        let checkID = UUID()
        updateCheckID = checkID
        updateTask = updateChecker.check(currentVersion: currentVersion) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.updateCheckID == checkID else {
                    return
                }
                self.updateCheckID = nil
                self.updateTask = nil
                self.settingsStore.recordUpdateCheck()
                switch result {
                case .success(.current):
                    NativeLog.lifecycleInfo("update_check_current version=\(currentVersion)")
                    if interactive {
                        self.presentCurrentVersion(currentVersion)
                    }
                case let .success(.available(update)):
                    NativeLog.lifecycleInfo(
                        "update_available current=\(currentVersion) latest=\(update.version)"
                    )
                    self.presentAvailableUpdate(update, currentVersion: currentVersion)
                case let .failure(error):
                    NativeLog.lifecycleError(
                        "update_check_failed error=\(error.localizedDescription)"
                    )
                    if interactive {
                        self.presentUpdateError(error)
                    }
                }
            }
        }
    }

    private func presentAvailableUpdate(
        _ update: AvailableAppUpdate,
        currentVersion: String
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Satin \(update.version) is available"
        alert.informativeText = """
        You are running \(currentVersion). The update will be downloaded from GitHub, verified \
        with the embedded publisher key, installed, and restarted.
        """
        alert.addButton(withTitle: "Update and Restart")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            beginInstallingUpdate(update)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(update.releaseNotesURL)
        default:
            break
        }
    }

    private func beginInstallingUpdate(_ update: AvailableAppUpdate) {
        guard updateProgressAlert == nil, let window else {
            return
        }
        let progress = NSProgressIndicator(
            frame: NSRect(x: 0, y: 0, width: 320, height: 20)
        )
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Installing Satin \(update.version)…"
        alert.informativeText = "Downloading and verifying the signed Apple Silicon update."
        alert.accessoryView = progress
        updateProgressAlert = alert
        alert.beginSheetModal(for: window)

        updateInstaller.prepare(update: update) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                window.endSheet(alert.window)
                self.updateProgressAlert = nil
                switch result {
                case let .success(prepared):
                    do {
                        try self.updateInstaller.launch(prepared)
                        NativeLog.lifecycleInfo(
                            "update_install_ready version=\(prepared.version)"
                        )
                        NSApp.terminate(nil)
                    } catch {
                        self.updateInstaller.discard(prepared)
                        NativeLog.lifecycleError(
                            "update_install_launch_failed error=\(error.localizedDescription)"
                        )
                        self.presentUpdateInstallError(error, update: update)
                    }
                case let .failure(error):
                    NativeLog.lifecycleError(
                        "update_install_failed error=\(error.localizedDescription)"
                    )
                    self.presentUpdateInstallError(error, update: update)
                }
            }
        }
    }

    private func presentUpdateInstallError(
        _ error: Error,
        update: AvailableAppUpdate
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Install Update"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Download Manually")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(update.downloadURL)
        }
    }

    private func presentCurrentVersion(_ currentVersion: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Satin is up to date"
        alert.informativeText = "Version \(currentVersion) is the latest available release."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentUpdateError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Check for Updates"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(sessionMenuItem())
        mainMenu.addItem(windowMenuItem())
        mainMenu.addItem(helpMenuItem())
        NSApp.mainMenu = mainMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        let requiresTerminalWindow = action == #selector(newTab(_:))
            || action == #selector(splitVertical(_:))
            || action == #selector(splitHorizontal(_:))
            || action == #selector(renameActiveTab(_:))
            || action == #selector(openNativeNeovim(_:))
            || action == #selector(closeActivePane(_:))
            || action == #selector(selectTabFromShortcut(_:))
            || action == #selector(showSessionSwitcher(_:))
            || action == #selector(zoomIn(_:))
            || action == #selector(zoomOut(_:))
            || action == #selector(resetZoom(_:))
        return !requiresTerminalWindow || NSApp.keyWindow === window
    }

    private func applySmokeScenarioIfNeeded(_ controller: TerminalShellViewController) {
        let environment = ProcessInfo.processInfo.environment
        switch environment["SATIN_NATIVE_SMOKE_SCENARIO"] {
        case "settings":
            settingsWindowController?.present()
        case "1":
            controller.applySmokeScenario(resultPath: environment["SATIN_NATIVE_SMOKE_RESULT"])
        case "terminal-bottom-input":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyTerminalBottomInputSmokeScenario(resultPath: path)
            }
        case "terminal-exit-closes-tab":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyTerminalExitClosesTabSmokeScenario(resultPath: path)
            }
        case "finder-editor":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyFinderEditorSmokeScenario(resultPath: path)
            }
        case "session-schema":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applySessionSchemaSmokeScenario(resultPath: path)
            }
        case "tmux-native":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyTmuxNativeSmokeScenario(resultPath: path)
            }
        case "tmux-reattach":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty,
               let sessionName = environment["SATIN_NATIVE_SMOKE_TMUX_SESSION"],
               let socketPath = environment["SATIN_NATIVE_SMOKE_TMUX_SOCKET"],
               let expectedContent = environment["SATIN_NATIVE_SMOKE_TMUX_CONTENT"] {
                controller.applyTmuxReattachSmokeScenario(
                    resultPath: path,
                    sessionName: sessionName,
                    socketPath: socketPath,
                    expectedContent: expectedContent
                )
            }
        case "tmux-reattach-missing":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty,
               let sessionName = environment["SATIN_NATIVE_SMOKE_TMUX_SESSION"],
               let socketPath = environment["SATIN_NATIVE_SMOKE_TMUX_SOCKET"] {
                controller.applyMissingTmuxReattachSmokeScenario(
                    resultPath: path,
                    sessionName: sessionName,
                    socketPath: socketPath
                )
            }
        case "tab-bar-actions":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyTabBarActionsSmokeScenario(resultPath: path)
            }
        case "home-cwd":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyHomeWorkingDirectorySmokeScenario(resultPath: path)
            }
        case "terminal-resize":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyTerminalResizeSmokeScenario(resultPath: path)
            }
        case "terminal-nvim-handoff":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyTerminalNvimHandoffSmokeScenario(resultPath: path)
            }
        case "shell-nvim-native":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyShellNvimNativeSmokeScenario(resultPath: path)
            }
        case "terminal-nvim-cwd":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyTerminalNvimCwdSmokeScenario(resultPath: path)
            }
        case "terminal-nvim-quit":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyTerminalNvimQuitSmokeScenario(resultPath: path)
            }
        case "nvim-scroll":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimScrollSmokeScenario(resultPath: path)
            }
        case "nvim-jump":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimJumpSmokeScenario(resultPath: path)
            }
        case "nvim-side-pane":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimSidePaneSmokeScenario(resultPath: path)
            }
        case "nvim-commandline":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimCommandLineSmokeScenario(resultPath: path)
            }
        case "nvim-cursor-move":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimCursorMoveSmokeScenario(resultPath: path)
            }
        case "nvim-shaped-text":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimShapedTextSmokeScenario(resultPath: path)
            }
        case "nvim-skia":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimSkiaSmokeScenario(resultPath: path)
            }
        case "nvim-image":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimImageSmokeScenario(resultPath: path)
            }
        case "nvim-ui-surfaces":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimUiSurfacesSmokeScenario(resultPath: path)
            }
        case "nvim-popupmenu":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimPopupmenuSmokeScenario(resultPath: path)
            }
        case "nvim-file-tree":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimFileTreeSmokeScenario(resultPath: path)
            }
        case "nvim-file-tree-cursor-move":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimFileTreeCursorMoveSmokeScenario(resultPath: path)
            }
        case "nvim-file-tree-close":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimFileTreeCloseSmokeScenario(resultPath: path)
            }
        case "nvim-cursor-switch":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimCursorSwitchSmokeScenario(resultPath: path)
            }
        case "nvim-cursor-shape":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimCursorShapeSmokeScenario(resultPath: path)
            }
        case "nvim-cursor-normal-shape":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimCursorNormalShapeSmokeScenario(resultPath: path)
            }
        case "nvim-cursor-replace-shape":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimCursorReplaceShapeSmokeScenario(resultPath: path)
            }
        case "nvim-cursor-blink":
            if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                controller.applyNvimCursorBlinkSmokeScenario(resultPath: path)
            }
        default:
            break
        }
    }

    private func scheduleSmokeShotIfNeeded(_ window: NSWindow) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SATIN_NATIVE_SMOKE_SHOT"], !path.isEmpty else {
            return
        }
        let targetWindow = environment["SATIN_NATIVE_SMOKE_SCENARIO"] == "settings"
            ? settingsWindowController?.window ?? window
            : window

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak targetWindow] in
            if let targetWindow {
                self.writeSmokeShot(path: path, window: targetWindow)
            }
            NSApp.terminate(nil)
        }
    }

    private func writeSmokeWindowIdIfNeeded(_ window: NSWindow) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SATIN_NATIVE_SMOKE_WINDOW_ID"], !path.isEmpty else {
            return
        }
        let targetWindow = environment["SATIN_NATIVE_SMOKE_SCENARIO"] == "settings"
            ? settingsWindowController?.window ?? window
            : window
        writeSmokeWindowId(path: path, window: targetWindow, attempts: 20)
    }

    private func writeSmokeWindowId(path: String, window: NSWindow, attempts: Int) {
        if window.windowNumber > 0 {
            try? "\(window.windowNumber)\n".write(
                toFile: path,
                atomically: true,
                encoding: .utf8
            )
            return
        }
        if let windowId = cgWindowNumberForCurrentProcess() {
            try? "\(windowId)\n".write(
                toFile: path,
                atomically: true,
                encoding: .utf8
            )
            return
        }
        guard attempts > 0 else {
            try? "\(window.windowNumber)\n".write(
                toFile: path,
                atomically: true,
                encoding: .utf8
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak window] in
            guard let window else {
                return
            }
            self?.writeSmokeWindowId(path: path, window: window, attempts: attempts - 1)
        }
    }

    private func cgWindowNumberForCurrentProcess() -> Int? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        return windows
            .filter { info in
                cgWindowInt(info[kCGWindowOwnerPID as String]) == pid &&
                    cgWindowInt(info[kCGWindowLayer as String]) == 0
            }
            .max { lhs, rhs in
                cgWindowArea(lhs) < cgWindowArea(rhs)
            }
            .flatMap { cgWindowInt($0[kCGWindowNumber as String]) }
    }

    private func cgWindowArea(_ info: [String: Any]) -> Double {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else {
            return 0
        }
        let width = cgWindowBoundValue(bounds["Width"])
        let height = cgWindowBoundValue(bounds["Height"])
        return width * height
    }

    private func cgWindowInt(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Int32:
            return Int(value)
        case let value as Int64:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        default:
            return nil
        }
    }

    private func cgWindowBoundValue(_ value: Any?) -> Double {
        switch value {
        case let value as Double:
            return value
        case let value as CGFloat:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return 0
        }
    }

    private func writeSmokeShot(path: String, window: NSWindow) {
        guard let contentView = window.contentView else {
            return
        }
        contentView.setFrameSize(contentView.window?.contentLayoutRect.size ?? contentView.frame.size)
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()
        let bounds = contentView.bounds
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return
        }
        contentView.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(
            withTitle: "About \(nativeApplicationName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Quit \(nativeApplicationName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.submenu = menu
        return item
    }

    private func sessionMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Session")
        menu.addItem(targetedItem("Switch Terminal Session…", #selector(showSessionSwitcher(_:)), ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(commandItem("New Tab", #selector(newTab(_:)), .newTab))
        menu.addItem(commandItem("Split Vertical", #selector(splitVertical(_:)), .splitVertical))
        menu.addItem(commandItem("Split Horizontal", #selector(splitHorizontal(_:)), .splitHorizontal))
        menu.addItem(commandItem("Close Pane", #selector(closeActivePane(_:)), .closePane))
        menu.addItem(NSMenuItem.separator())
        for shortcutNumber in 1...9 {
            let title = shortcutNumber == 9 ? "Select Last Tab" : "Select Tab \(shortcutNumber)"
            let menuItem = targetedItem(title, #selector(selectTabFromShortcut(_:)), "\(shortcutNumber)")
            menuItem.tag = shortcutNumber
            menu.addItem(menuItem)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(commandItem("Rename Session", #selector(renameActiveTab(_:)), .renameSession))
        menu.addItem(
            commandItem(
                "Open Native Neovim",
                #selector(openNativeNeovim(_:)),
                .openNativeNeovim
            )
        )
        item.submenu = menu
        return item
    }

    private func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Find",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "f"
        )
        item.submenu = menu
        return item
    }

    private func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        menu.addItem(commandItem("Zoom In", #selector(zoomIn(_:)), .zoomIn))
        menu.addItem(commandItem("Zoom Out", #selector(zoomOut(_:)), .zoomOut))
        menu.addItem(commandItem("Actual Size", #selector(resetZoom(_:)), .actualSize))
        item.submenu = menu
        return item
    }

    private func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    private func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        if !nativeIsDevelopmentBuild {
            menu.addItem(
                commandItem(
                    "Check for Updates…",
                    #selector(checkForUpdates(_:)),
                    .checkForUpdates
                )
            )
            menu.addItem(NSMenuItem.separator())
        }
        let acknowledgements = NSMenuItem(
            title: "Acknowledgements…",
            action: #selector(showAcknowledgements(_:)),
            keyEquivalent: ""
        )
        acknowledgements.target = self
        menu.addItem(acknowledgements)
        item.submenu = menu
        return item
    }

    private func commandItem(
        _ title: String,
        _ action: Selector,
        _ command: NativeCommandID
    ) -> NSMenuItem {
        let shortcut = settingsStore.load().shortcut(for: command)
        let terminalOwnsShortcuts = terminalWindowOwnsCommandShortcuts()
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: terminalOwnsShortcuts ? shortcut.keyEquivalent : ""
        )
        item.target = self
        item.keyEquivalentModifierMask = terminalOwnsShortcuts ? shortcut.modifiers : []
        return item
    }

    private func targetedItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: terminalWindowOwnsCommandShortcuts() ? key : ""
        )
        item.target = self
        return item
    }

    private func terminalWindowOwnsCommandShortcuts() -> Bool {
        guard let window else {
            return false
        }
        guard let keyWindow = NSApp.keyWindow else {
            return window.isVisible
        }
        return keyWindow === window
    }
}

@main
struct SatinApplication {
    private static func failDiagnostic(_ message: String) -> Never {
        fputs("\(message)\n", stderr)
        exit(EXIT_FAILURE)
    }

    static func main() {
        if let releaseRoot = ProcessInfo.processInfo.environment[
            "SATIN_UPDATE_VERIFY_INSTALLABLE_RELEASE_ROOT"
        ] {
            let root = URL(fileURLWithPath: releaseRoot, isDirectory: true)
            if !AppUpdateInstaller.verifyInstallableRelease(at: root) {
                failDiagnostic("installable release verification failed")
            }
            print("installable release verification passed")
            return
        }
        if let releaseRoot = ProcessInfo.processInfo.environment[
            "SATIN_UPDATE_VERIFY_RELEASE_ROOT"
        ] {
            let root = URL(fileURLWithPath: releaseRoot, isDirectory: true)
            if !AppUpdateInstaller.verifyRelease(at: root) {
                failDiagnostic("signed release verification failed")
            }
            print("signed release verification passed")
            return
        }
        if ProcessInfo.processInfo.environment["SATIN_UPDATE_SELF_TEST"] == "1" {
            if !AppUpdateChecker.runSelfTests()
                || !AppUpdateInstaller.runSelfTests()
                || !NativeSettingsStore.runSelfTests()
                || !NativeFinderEditorLaunch.runSelfTests() {
                failDiagnostic("update self-test failed")
            }
            print("update self-test passed")
            return
        }
        if let currentVersion = ProcessInfo.processInfo.environment[
            "SATIN_UPDATE_LIVE_CHECK_VERSION"
        ] {
            let expected = ProcessInfo.processInfo.environment[
                "SATIN_UPDATE_LIVE_CHECK_EXPECTED"
            ] ?? "current"
            if !AppUpdateChecker.runLiveSmoke(
                currentVersion: currentVersion,
                expected: expected
            ) {
                failDiagnostic("update live smoke failed")
            }
            return
        }

        NativeSettingsStore.migrateLegacyDefaultsIfNeeded()
        let app = NSApplication.shared
        let delegate = SatinAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
