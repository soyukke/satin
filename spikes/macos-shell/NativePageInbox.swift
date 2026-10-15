import Foundation

/// The pages agents have saved, and which of their versions you have read.
/// It watches the page store's folder and reloads the list when an agent
/// adds a page or a version. What has been read lives in the store, so a
/// page read on another client of it, such as a phone, is read here too.
final class NativePageInbox {
    /// Where the versions read were kept before the store kept them.
    static let legacySeenKey = "pagesSeenVersions"
    /// Set once the store keeps what has been read.
    static let storeMarksKey = "pagesReadInStore"

    /// Called after every reload, with the pages that became unread.
    var onChange: (([NativeArtifactListItem]) -> Void)?
    /// Keeps marks in the store: `satin page read` with these selectors.
    var persistRead: (([String]) -> Void)?

    private(set) var pages: [NativeArtifactListItem] = []
    /// The versions read: what the store listed, and what was marked here
    /// before the store's next listing.
    private var seen: [String: UInt32] = [:]
    private let defaults: UserDefaults
    private var source: DispatchSourceFileSystemObject?
    private var load: ((@escaping ([NativeArtifactListItem]) -> Void) -> Void)?
    private var loaded = false
    private var pendingReload: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        persistRead?(["\(page.id)@v\(page.version)"])
        onChange?([])
    }

    func apply(_ listed: [NativeArtifactListItem]) {
        let firstLoad = !loaded
        loaded = true
        for page in listed where page.readVersion > (seen[page.id] ?? 0) {
            seen[page.id] = page.readVersion
        }
        if firstLoad, !defaults.bool(forKey: Self.storeMarksKey) {
            moveMarksToStore(listed)
        }
        let before = Set(unread.map { "\($0.id)@\($0.version)" })
        pages = listed
        let arrived = firstLoad ? [] : unread.filter { !before.contains("\($0.id)@\($0.version)") }
        onChange?(arrived)
    }

    /// Hands the store the versions read that this Mac kept for itself.
    /// Without any, the pages already there count as read, so an upgrade
    /// does not bury you in old pages.
    private func moveMarksToStore(_ listed: [NativeArtifactListItem]) {
        let legacy = defaults.dictionary(forKey: Self.legacySeenKey) as? [String: Int]
        var selectors: [String] = []
        for page in listed {
            let kept = legacy.map { UInt32(clamping: $0[page.id] ?? 0) } ?? page.version
            let read = min(kept, page.version)
            if read > (seen[page.id] ?? 0) {
                seen[page.id] = read
                selectors.append("\(page.id)@v\(read)")
            }
        }
        if !selectors.isEmpty {
            persistRead?(selectors)
        }
        defaults.removeObject(forKey: Self.legacySeenKey)
        defaults.set(true, forKey: Self.storeMarksKey)
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
    let suite = "dev.soyukke.satin.page-inbox-self-test"
    guard let defaults = UserDefaults(suiteName: suite) else {
        return false
    }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    func page(_ id: String, _ version: UInt32, read: UInt32 = 0) -> NativeArtifactListItem {
        NativeArtifactListItem(
            id: id, title: id, kind: "markdown", version: version, updatedAtMs: 0, preview: "",
            readVersion: read)
    }
    let inbox = NativePageInbox(defaults: defaults)
    var arrivals: [[NativeArtifactListItem]] = []
    var persisted: [[String]] = []
    inbox.onChange = { arrivals.append($0) }
    inbox.persistRead = { persisted.append($0) }
    // The pages there before the store kept marks count as read.
    inbox.apply([page("old", 2)])
    guard inbox.unread.isEmpty, arrivals.last?.isEmpty == true, persisted == [["old@v2"]] else {
        return false
    }
    inbox.apply([page("new", 1), page("old", 3, read: 2)])
    guard inbox.unread.map(\.id) == ["new", "old"], arrivals.last?.count == 2 else {
        return false
    }
    inbox.markRead(page("old", 3))
    guard persisted.last == ["old@v3"], inbox.unread.map(\.id) == ["new"] else {
        return false
    }
    // A page read on another client of the store is read here once listed.
    inbox.apply([page("new", 1, read: 1), page("old", 3, read: 3)])
    guard inbox.unread.isEmpty else {
        return false
    }
    // Marks this Mac kept for itself move to the store once.
    defaults.removePersistentDomain(forName: suite)
    defaults.set(["kept": 1], forKey: NativePageInbox.legacySeenKey)
    let upgraded = NativePageInbox(defaults: defaults)
    var moved: [[String]] = []
    upgraded.persistRead = { moved.append($0) }
    upgraded.apply([page("kept", 2), page("unseen", 1)])
    return moved == [["kept@v1"]] && upgraded.unread.map(\.id) == ["kept", "unseen"]
        && defaults.object(forKey: NativePageInbox.legacySeenKey) == nil
        && defaults.bool(forKey: NativePageInbox.storeMarksKey)
}
