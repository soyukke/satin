import Foundation

extension NativeSettingsStore {
    static func isValidShellPath(_ value: String) -> Bool {
        isValidOptionalExecutablePath(value)
    }

    static func isValidTmuxExecutablePath(_ value: String) -> Bool {
        isValidOptionalExecutablePath(value)
    }

    private static func isValidOptionalExecutablePath(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return true
        }
        return (value as NSString).isAbsolutePath
            && FileManager.default.isExecutableFile(atPath: value)
    }

    static func isValidStartupDirectory(_ value: String) -> Bool {
        guard !value.isEmpty, (value as NSString).isAbsolutePath else {
            return value.isEmpty
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func isValidFinderEditorCommand(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.utf8.count <= 1_024,
            value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            return false
        }
        if value.contains("/") {
            return (value as NSString).isAbsolutePath
                && FileManager.default.isExecutableFile(atPath: value)
        }
        guard value != ".", value != ".." else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar)
                    || "._+-".unicodeScalars.contains(scalar))
        }
    }
}
