import Foundation

/// The pages agents have saved, and which of their versions you have read.
/// It watches the page store's folder and reloads the list when an agent
/// adds a page or a version.
final class NativePageInbox {
    static let seenKey = "pagesSeenVersions"

    /// Called after every reload, with the pages that became unread.
    var onChange: (([NativeArtifactListItem]) -> Void)?

    private(set) var pages: [NativeArtifactListItem] = []
    private var seen: [String: UInt32]
    private let defaults: UserDefaults
    private var source: DispatchSourceFileSystemObject?
    private var load: ((@escaping ([NativeArtifactListItem]) -> Void) -> Void)?
    private var loaded = false
    private var pendingReload: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.seenKey) as? [String: Int]
        seen = (stored ?? [:]).compactMapValues { UInt32(exactly: $0) }
    }

    var unread: [NativeArtifactListItem] {
        pages.filter { isUnread($0) }
    }

    func isUnread(_ page: NativeArtifactListItem) -> Bool {
        (seen[page.id] ?? 0) < page.version
    }

    /// Starts watching root; load lists the pages, newest first.
    func start(root: URL, load: @escaping (@escaping ([NativeArtifactListItem]) -> Void) -> Void) {
        self.load = load
        watch(root)
        reload()
    }

    func reload() {
        load? { [weak self] pages in
            self?.apply(pages)
        }
    }

    func markRead(_ page: NativeArtifactListItem) {
        guard isUnread(page) else {
            return
        }
        seen[page.id] = page.version
        save()
        onChange?([])
    }

    func apply(_ listed: [NativeArtifactListItem]) {
        let firstLoad = !loaded
        loaded = true
        // The pages that were there before Satin first kept track count as
        // read, so an upgrade does not bury you in old pages.
        if firstLoad, defaults.object(forKey: Self.seenKey) == nil {
            for page in listed {
                seen[page.id] = page.version
            }
            save()
        }
        let before = Set(unread.map { "\($0.id)@\($0.version)" })
        pages = listed
        let arrived = firstLoad ? [] : unread.filter { !before.contains("\($0.id)@\($0.version)") }
        onChange?(arrived)
    }

    private func save() {
        defaults.set(seen.mapValues { Int($0) }, forKey: Self.seenKey)
    }

    private func watch(_ root: URL) {
        source?.cancel()
        source = nil
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(root.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .link], queue: .main)
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    /// An add writes several files; one reload after they settle is enough.
    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

func runNativePageInboxSelfTests() -> Bool {
    guard let defaults = UserDefaults(suiteName: "dev.soyukke.satin.page-inbox-self-test") else {
        return false
    }
    defaults.removePersistentDomain(forName: "dev.soyukke.satin.page-inbox-self-test")
    defer { defaults.removePersistentDomain(forName: "dev.soyukke.satin.page-inbox-self-test") }
    func page(_ id: String, _ version: UInt32) -> NativeArtifactListItem {
        NativeArtifactListItem(
            id: id, title: id, kind: "markdown", version: version, updatedAtMs: 0, preview: "")
    }
    let inbox = NativePageInbox(defaults: defaults)
    var arrivals: [[NativeArtifactListItem]] = []
    inbox.onChange = { arrivals.append($0) }
    inbox.apply([page("old", 2)])
    guard inbox.unread.isEmpty, arrivals.last?.isEmpty == true else {
        return false
    }
    inbox.apply([page("new", 1), page("old", 3)])
    guard inbox.unread.map(\.id) == ["new", "old"], arrivals.last?.count == 2 else {
        return false
    }
    inbox.markRead(page("old", 3))
    let reopened = NativePageInbox(defaults: defaults)
    reopened.apply([page("new", 1), page("old", 3)])
    return reopened.unread.map(\.id) == ["new"]
}
