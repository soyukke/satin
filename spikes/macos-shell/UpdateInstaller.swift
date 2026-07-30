import CryptoKit
import Foundation

struct UpdateManifest: Decodable {
    struct Signature: Decodable {
        let algorithm: String
        let keyID: String
        let value: String
    }

    let schemaVersion: Int
    let version: String
    let build: String
    let channel: String
    let minimumMacOS: String
    let architecture: String
    let archive: String
    let archiveSize: Int64
    let sha256: String
    let downloadURL: URL
    let notarized: Bool
    let signature: Signature
}

struct PreparedAppUpdate {
    let version: String
    let currentApplication: URL
    let stagedApplication: URL
    let destinationApplication: URL
    let backupApplication: URL
    let trashBackup: URL
    let helper: URL
}

enum AppUpdateInstallError: LocalizedError {
    case invalidManifest
    case invalidSigningKey
    case invalidSignature
    case archiveTooLarge
    case archiveSizeMismatch
    case checksumMismatch
    case downloadFailed
    case invalidApplication
    case unsupportedOperatingSystem
    case unsupportedInstallLocation
    case installLocationNotWritable
    case missingInstallHelper
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            return "The update manifest is invalid."
        case .invalidSigningKey:
            return "The embedded update signing key is invalid."
        case .invalidSignature:
            return "The update publisher signature is invalid."
        case .archiveTooLarge:
            return "The update archive exceeds the allowed size."
        case .archiveSizeMismatch:
            return "The downloaded update size does not match its manifest."
        case .checksumMismatch:
            return "The downloaded update checksum does not match its manifest."
        case .downloadFailed:
            return "The update could not be downloaded from GitHub."
        case .invalidApplication:
            return "The update does not contain a valid Satin application."
        case .unsupportedOperatingSystem:
            return "This update requires a newer version of macOS."
        case .unsupportedInstallLocation:
            return "Move the application to Applications before updating it."
        case .installLocationNotWritable:
            return "The Applications folder is not writable by the current user."
        case .missingInstallHelper:
            return "The bundled update installer is unavailable."
        case let .toolFailed(tool):
            return "\(tool) failed while preparing the update."
        }
    }
}

enum UpdateArchiveVerifier {
    private struct SigningKey: Decodable {
        let schemaVersion: Int
        let algorithm: String
        let keyID: String
        let publicKey: String
    }

    static func verify(
        archive: Data,
        manifest: UpdateManifest,
        signingKeyData: Data
    ) throws {
        let key: SigningKey
        do {
            key = try JSONDecoder().decode(SigningKey.self, from: signingKeyData)
        } catch {
            throw AppUpdateInstallError.invalidSigningKey
        }
        guard key.schemaVersion == 1,
              key.algorithm == "ed25519",
              manifest.signature.algorithm == key.algorithm,
              manifest.signature.keyID == key.keyID,
              let publicKeyData = Data(base64Encoded: key.publicKey),
              publicKeyData.count == 32,
              let signature = Data(base64Encoded: manifest.signature.value),
              signature.count == 64
        else {
            throw AppUpdateInstallError.invalidSigningKey
        }

        let digest = SHA256.hash(data: archive)
        let actualSHA = digest.map { String(format: "%02x", $0) }.joined()
        guard actualSHA == manifest.sha256 else {
            throw AppUpdateInstallError.checksumMismatch
        }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw AppUpdateInstallError.invalidSigningKey
        }
        guard publicKey.isValidSignature(signature, for: archive) else {
            throw AppUpdateInstallError.invalidSignature
        }
    }
}

final class AppUpdateInstaller {
    private static let maximumManifestBytes = 65_536
    private static let maximumArchiveBytes: Int64 = 536_870_912
    private static let legacyAppName = "Neovide Tabs.app"
    private static let targetAppName = "Satin.app"
    private static let targetBundleIdentifier = "dev.soyukke.satin"
    private let session: URLSession
    private let workerQueue = DispatchQueue(
        label: "dev.soyukke.satin.update-installer",
        qos: .userInitiated
    )

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func runSelfTests() -> Bool {
        let archive = Data("signed-update-self-test".utf8)
        let privateKey = Curve25519.Signing.PrivateKey()
        guard let signature = try? privateKey.signature(for: archive),
              let signingKeyData = try? JSONSerialization.data(withJSONObject: [
                  "schemaVersion": 1,
                  "algorithm": "ed25519",
                  "keyID": "self-test",
                  "publicKey": privateKey.publicKey.rawRepresentation.base64EncodedString(),
              ])
        else {
            return false
        }
        let digest = SHA256.hash(data: archive)
        let sha256 = digest.map { String(format: "%02x", $0) }.joined()
        let manifest = UpdateManifest(
            schemaVersion: 2,
            version: "1.2.3",
            build: "1",
            channel: "development",
            minimumMacOS: "14.0",
            architecture: "arm64",
            archive: "Satin-1.2.3-macOS-arm64.zip",
            archiveSize: Int64(archive.count),
            sha256: sha256,
            downloadURL: URL(string: "https://github.com/example/update.zip")!,
            notarized: false,
            signature: UpdateManifest.Signature(
                algorithm: "ed25519",
                keyID: "self-test",
                value: signature.base64EncodedString()
            )
        )
        do {
            try UpdateArchiveVerifier.verify(
                archive: archive,
                manifest: manifest,
                signingKeyData: signingKeyData
            )
            try UpdateArchiveVerifier.verify(
                archive: archive + Data([0]),
                manifest: manifest,
                signingKeyData: signingKeyData
            )
            return false
        } catch AppUpdateInstallError.checksumMismatch {
            return true
        } catch {
            return false
        }
    }

    static func verifyRelease(at root: URL) -> Bool {
        let manifestURL = root.appendingPathComponent("latest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(
                  UpdateManifest.self,
                  from: manifestData
              ),
              let keyURL = Bundle.main.url(
                  forResource: "update-signing-public-key",
                  withExtension: "json"
              ),
              let signingKeyData = try? Data(contentsOf: keyURL)
        else {
            return false
        }
        let archiveURL = root.appendingPathComponent(manifest.archive)
        guard let archive = try? Data(contentsOf: archiveURL, options: .mappedIfSafe),
              Int64(archive.count) == manifest.archiveSize
        else {
            return false
        }
        do {
            try UpdateArchiveVerifier.verify(
                archive: archive,
                manifest: manifest,
                signingKeyData: signingKeyData
            )
            return true
        } catch {
            return false
        }
    }

    static func verifyInstallableRelease(at root: URL) -> Bool {
        let manifestURL = root.appendingPathComponent("latest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(
                  UpdateManifest.self,
                  from: manifestData
              ),
              let keyURL = Bundle.main.url(
                  forResource: "update-signing-public-key",
                  withExtension: "json"
              ),
              let signingKeyData = try? Data(contentsOf: keyURL)
        else {
            return false
        }
        let archiveURL = root.appendingPathComponent(manifest.archive)
        guard let archive = try? Data(contentsOf: archiveURL, options: .mappedIfSafe),
              Int64(archive.count) == manifest.archiveSize
        else {
            return false
        }
        let extractionRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "satin-installable-release-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { discard(extractionRoot) }
        do {
            try UpdateArchiveVerifier.verify(
                archive: archive,
                manifest: manifest,
                signingKeyData: signingKeyData
            )
            try FileManager.default.createDirectory(
                at: extractionRoot,
                withIntermediateDirectories: false
            )
            try run("/usr/bin/ditto", [
                "-x",
                "-k",
                archiveURL.path,
                extractionRoot.path,
            ])
            try validateApplication(
                extractionRoot.appendingPathComponent(
                    targetAppName,
                    isDirectory: true
                ),
                manifest: manifest
            )
            return true
        } catch {
            return false
        }
    }

    func prepare(
        update: AvailableAppUpdate,
        completion: @escaping (Result<PreparedAppUpdate, Error>) -> Void
    ) {
        guard update.archiveSize > 0,
              update.archiveSize <= Self.maximumArchiveBytes
        else {
            completion(.failure(AppUpdateInstallError.archiveTooLarge))
            return
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "satin-update-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false
            )
        } catch {
            completion(.failure(error))
            return
        }

        fetchManifest(update: update) { [weak self] result in
            guard let self else {
                Self.discard(root)
                return
            }
            switch result {
            case let .failure(error):
                Self.discard(root)
                completion(.failure(error))
            case let .success(manifest):
                self.downloadArchive(update: update, into: root) { downloadResult in
                    switch downloadResult {
                    case let .failure(error):
                        Self.discard(root)
                        completion(.failure(error))
                    case let .success(archiveURL):
                        self.workerQueue.async {
                            do {
                                let prepared = try self.validateAndStage(
                                    update: update,
                                    manifest: manifest,
                                    archiveURL: archiveURL,
                                    workRoot: root
                                )
                                Self.discard(root)
                                completion(.success(prepared))
                            } catch {
                                Self.discard(root)
                                completion(.failure(error))
                            }
                        }
                    }
                }
            }
        }
    }

    func launch(_ prepared: PreparedAppUpdate) throws {
        guard prepared.currentApplication == Bundle.main.bundleURL.standardizedFileURL,
              prepared.destinationApplication.deletingLastPathComponent()
                == prepared.currentApplication.deletingLastPathComponent(),
              prepared.destinationApplication.lastPathComponent == Self.targetAppName,
              FileManager.default.fileExists(atPath: prepared.stagedApplication.path),
              FileManager.default.fileExists(atPath: prepared.helper.path)
        else {
            throw AppUpdateInstallError.invalidApplication
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            prepared.helper.path,
            prepared.currentApplication.path,
            prepared.stagedApplication.path,
            prepared.destinationApplication.path,
            prepared.backupApplication.path,
            prepared.trashBackup.path,
            String(ProcessInfo.processInfo.processIdentifier),
            "launch",
        ]
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    func discard(_ prepared: PreparedAppUpdate) {
        let parent = prepared.currentApplication.deletingLastPathComponent()
        guard prepared.stagedApplication.deletingLastPathComponent() == parent,
              prepared.stagedApplication.lastPathComponent.hasPrefix(
                ".Satin.update."
              ),
              prepared.stagedApplication.pathExtension == "app"
        else {
            return
        }
        Self.discard(prepared.stagedApplication)
    }

    private func fetchManifest(
        update: AvailableAppUpdate,
        completion: @escaping (Result<UpdateManifest, Error>) -> Void
    ) {
        var request = URLRequest(
            url: update.manifestURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Satin/\(update.version)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(AppUpdateInstallError.downloadFailed))
                return
            }
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let data,
                  data.count <= Self.maximumManifestBytes
            else {
                completion(.failure(AppUpdateInstallError.downloadFailed))
                return
            }
            do {
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
                try Self.validate(manifest: manifest, for: update)
                completion(.success(manifest))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func downloadArchive(
        update: AvailableAppUpdate,
        into root: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        var request = URLRequest(
            url: update.downloadURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 300
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Satin/\(update.version)", forHTTPHeaderField: "User-Agent")
        session.downloadTask(with: request) { temporaryURL, response, error in
            guard error == nil,
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let temporaryURL
            else {
                completion(.failure(AppUpdateInstallError.downloadFailed))
                return
            }
            let archiveURL = root.appendingPathComponent(update.archiveName)
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)
                let size = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard Int64(size ?? -1) == update.archiveSize else {
                    throw AppUpdateInstallError.archiveSizeMismatch
                }
                completion(.success(archiveURL))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func validateAndStage(
        update: AvailableAppUpdate,
        manifest: UpdateManifest,
        archiveURL: URL,
        workRoot: URL
    ) throws -> PreparedAppUpdate {
        guard let keyURL = Bundle.main.url(
            forResource: "update-signing-public-key",
            withExtension: "json"
        ) else {
            throw AppUpdateInstallError.invalidSigningKey
        }
        let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let signingKeyData = try Data(contentsOf: keyURL)
        try UpdateArchiveVerifier.verify(
            archive: archive,
            manifest: manifest,
            signingKeyData: signingKeyData
        )

        let extractionRoot = workRoot.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extractionRoot,
            withIntermediateDirectories: false
        )
        try Self.run("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extractionRoot.path])
        let extractedApp = extractionRoot.appendingPathComponent(
            Self.targetAppName,
            isDirectory: true
        )
        try Self.validateApplication(extractedApp, manifest: manifest)

        let currentApp = Bundle.main.bundleURL.standardizedFileURL
        let parent = currentApp.deletingLastPathComponent()
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .standardizedFileURL
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL
        guard (
            currentApp.lastPathComponent == Self.legacyAppName
                || currentApp.lastPathComponent == Self.targetAppName
        ),
              currentApp.pathExtension == "app",
              parent == systemApplications || parent == userApplications
        else {
            throw AppUpdateInstallError.unsupportedInstallLocation
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw AppUpdateInstallError.installLocationNotWritable
        }
        guard let helper = Bundle.main.url(forResource: "apply-update", withExtension: nil) else {
            throw AppUpdateInstallError.missingInstallHelper
        }

        let destination = parent.appendingPathComponent(
            Self.targetAppName,
            isDirectory: true
        )
        guard (
            currentApp == destination
                || !FileManager.default.fileExists(atPath: destination.path)
        )
        else {
            throw AppUpdateInstallError.invalidApplication
        }
        let identifier = UUID().uuidString
        let staged = parent.appendingPathComponent(
            ".Satin.update.\(identifier).app",
            isDirectory: true
        )
        let currentBaseName = currentApp.deletingPathExtension().lastPathComponent
        let backup = parent.appendingPathComponent(
            ".\(currentBaseName).previous.\(identifier).app",
            isDirectory: true
        )
        let trashRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
        let trashBackup = trashRoot.appendingPathComponent(
            "\(currentBaseName).previous.\(identifier).app",
            isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: staged.path),
              !FileManager.default.fileExists(atPath: backup.path),
              !FileManager.default.fileExists(atPath: trashBackup.path)
        else {
            throw AppUpdateInstallError.invalidApplication
        }

        try Self.run("/usr/bin/ditto", [extractedApp.path, staged.path])
        do {
            try Self.validateApplication(staged, manifest: manifest)
        } catch {
            Self.discard(staged)
            throw error
        }
        return PreparedAppUpdate(
            version: update.version,
            currentApplication: currentApp,
            stagedApplication: staged,
            destinationApplication: destination,
            backupApplication: backup,
            trashBackup: trashBackup,
            helper: helper
        )
    }

    private static func validate(
        manifest: UpdateManifest,
        for update: AvailableAppUpdate
    ) throws {
        guard let minimumMacOS = operatingSystemVersion(manifest.minimumMacOS) else {
            throw AppUpdateInstallError.invalidManifest
        }
        guard manifest.schemaVersion == 2,
              manifest.version == update.version,
              !manifest.build.isEmpty,
              manifest.channel == "development" || manifest.channel == "production",
              manifest.architecture == "arm64",
              manifest.archive == update.archiveName,
              manifest.archiveSize == update.archiveSize,
              manifest.downloadURL == update.downloadURL,
              manifest.sha256.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil,
              manifest.signature.algorithm == "ed25519",
              !manifest.signature.keyID.isEmpty,
              Data(base64Encoded: manifest.signature.value)?.count == 64
        else {
            throw AppUpdateInstallError.invalidManifest
        }
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumMacOS) else {
            throw AppUpdateInstallError.unsupportedOperatingSystem
        }
    }

    private static func operatingSystemVersion(
        _ rawValue: String
    ) -> OperatingSystemVersion? {
        let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = components.count == 3 ? Int(components[2]) : 0,
              major >= 0,
              minor >= 0,
              patch >= 0
        else {
            return nil
        }
        return OperatingSystemVersion(
            majorVersion: major,
            minorVersion: minor,
            patchVersion: patch
        )
    }

    private static func validateApplication(
        _ app: URL,
        manifest: UpdateManifest
    ) throws {
        let values = try app.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == targetBundleIdentifier,
              bundle.object(
                  forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String == manifest.version,
              bundle.object(forInfoDictionaryKey: "CFBundleVersion")
                  as? String == manifest.build,
              bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion")
                  as? String == manifest.minimumMacOS,
              let executable = bundle.executableURL
        else {
            throw AppUpdateInstallError.invalidApplication
        }
        let architectures = try run("/usr/bin/lipo", ["-archs", executable.path])
        guard String(decoding: architectures, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "arm64"
        else {
            throw AppUpdateInstallError.invalidApplication
        }
        try run("/usr/bin/codesign", [
            "--verify",
            "--deep",
            "--strict",
            app.path,
        ])
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            throw AppUpdateInstallError.toolFailed(
                URL(fileURLWithPath: executable).lastPathComponent
            )
        }
        return outputData
    }

    private static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
