import Darwin
import Foundation

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
