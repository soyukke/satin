import Foundation

final class RustCore {
    private let handle: UnsafeMutableRawPointer

    init?(defaultTheme: String = nativeThemeNames[0]) {
        let handle = defaultTheme.withCString { value in
            satinCoreCreateWithTheme(value)
        }
        guard let handle else {
            return nil
        }
        self.handle = handle
    }

    deinit {
        satinCoreDestroy(handle)
    }

    func snapshot() -> TerminalCoreSnapshot? {
        decode(satinCoreSnapshotJson(handle), as: TerminalCoreSnapshot.self)
    }

    func applyWorkspace(_ snapshot: TerminalCoreSnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot),
            let json = String(data: data, encoding: .utf8)
        else {
            return false
        }
        return json.withCString { value in
            satinCoreApplyWorkspaceJson(handle, value) != 0
        }
    }

    @discardableResult
    func newTab() -> Int {
        satinCoreNewTab(handle)
    }

    func splitActive(axis: UInt32) -> Int? {
        let paneId = satinCoreSplitActive(handle, axis)
        return paneId >= 0 ? paneId : nil
    }

    func resizeSplit(firstPaneId: Int, secondPaneId: Int, ratio: Double) -> Bool {
        satinCoreResizeSplit(handle, firstPaneId, secondPaneId, ratio) != 0
    }

    func closePane(_ paneId: Int) -> Bool {
        satinCoreClosePane(handle, paneId) != 0
    }

    func selectTab(_ index: Int) -> Bool {
        satinCoreSelectTab(handle, index) != 0
    }

    func moveTab(_ tabId: Int, to index: Int) -> Bool {
        satinCoreMoveTab(handle, tabId, index) != 0
    }

    func selectPane(_ paneId: Int) -> Bool {
        satinCoreSelectPane(handle, paneId) != 0
    }

    func paneInDirection(_ direction: NativePaneDirection) -> Int? {
        let paneId = satinCorePaneInDirection(handle, direction.rawValue)
        return paneId >= 0 ? paneId : nil
    }

    func renameTab(_ index: Int, title: String) {
        title.withCString { value in
            _ = satinCoreRenameTab(handle, index, value)
        }
    }

    func setTheme(_ theme: String, tab index: Int) {
        theme.withCString { value in
            _ = satinCoreSetTabTheme(handle, index, value)
        }
    }

    func setDefaultTheme(_ theme: String) {
        theme.withCString { value in
            _ = satinCoreSetDefaultTheme(handle, value)
        }
    }

    private func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, as type: T.Type)
        -> T?
    {
        guard let pointer else {
            return nil
        }
        defer {
            satinStringFree(pointer)
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
