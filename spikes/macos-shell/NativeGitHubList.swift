import Foundation

/// The open pull requests and issues of the GitHub repository a pane's
/// folder is a checkout of, for the items sidebar.
struct NativeGitHubList: Equatable {
    /// `owner/name`.
    let repository: String
    let pulls: [NativeSidebarItem]
    let issues: [NativeSidebarItem]
}

/// `owner/name` of a GitHub remote's URL, in any of the forms git takes:
/// `git@github.com:owner/name.git`, `https://github.com/owner/name` and
/// `ssh://git@github.com/owner/name.git`. Nil for another host.
func nativeGitHubRepository(remote: String) -> String? {
    var rest = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in [
        "git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/",
        "git://github.com/",
    ]
    where rest.hasPrefix(prefix) {
        rest = String(rest.dropFirst(prefix.count))
        if rest.hasSuffix("/") {
            rest.removeLast()
        }
        if rest.hasSuffix(".git") {
            rest.removeLast(4)
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return rest
    }
    return nil
}

/// The rows of what `gh pr list` or `gh issue list` printed as JSON with
/// `number,title,url,author` (and `isDraft` for pull requests). Nil when it
/// is not that.
func nativeGitHubItems(_ data: Data, kind: NativeSidebarItemKind) -> [NativeSidebarItem]? {
    guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        return nil
    }
    return rows.compactMap { row in
        guard let number = row["number"] as? Int, let title = row["title"] as? String,
            let url = row["url"] as? String
        else {
            return nil
        }
        var detail = (row["author"] as? [String: Any])?["login"] as? String ?? ""
        if row["isDraft"] as? Bool == true {
            detail += detail.isEmpty ? "draft" : " · draft"
        }
        return NativeSidebarItem(
            kind: kind, text: url, detail: detail, label: "#\(number) \(title)")
    }
}

/// Fetches the lists with `gh` off the main thread and keeps them a minute.
/// What a folder's repository is, is kept five. Called on the main thread.
final class NativeGitHubLists {
    static let listFreshFor: TimeInterval = 60
    static let repositoryFreshFor: TimeInterval = 300
    static let limit = 20

    private struct Tools {
        let git: String?
        let gh: String?
    }

    private let queue = DispatchQueue(label: "dev.soyukke.satin.github", qos: .utility)
    /// Read and written on the queue only.
    private var tools: Tools?
    private var repositories: [String: (repository: String?, at: Date)] = [:]
    private var lists: [String: (list: NativeGitHubList?, at: Date)] = [:]
    private var fetching = Set<String>()

    /// The list of the folder's repository as last fetched. One older than a
    /// minute is asked for again, and `changed` is called once it is in.
    func list(folder: String?, shellPath: String, changed: @escaping () -> Void)
        -> NativeGitHubList?
    {
        guard let folder else {
            return nil
        }
        let now = Date()
        let known = repositories[folder].flatMap {
            now.timeIntervalSince($0.at) < Self.repositoryFreshFor ? $0 : nil
        }
        guard let known else {
            fetch(folder: folder, repository: nil, shellPath: shellPath, changed: changed)
            return nil
        }
        guard let repository = known.repository else {
            return nil
        }
        let cached = lists[repository]
        if cached.map({ now.timeIntervalSince($0.at) >= Self.listFreshFor }) ?? true {
            fetch(folder: folder, repository: repository, shellPath: shellPath, changed: changed)
        }
        return cached?.list
    }

    private func fetch(
        folder: String, repository: String?, shellPath: String, changed: @escaping () -> Void
    ) {
        let key = repository ?? folder
        guard fetching.insert(key).inserted else {
            return
        }
        queue.async { [self] in
            let tools =
                self.tools
                ?? Tools(
                    git: NativeTmuxExecutableResolver.locate("git", shellPath: shellPath),
                    gh: NativeTmuxExecutableResolver.locate("gh", shellPath: shellPath))
            self.tools = tools
            let found = repository ?? Self.repository(of: folder, git: tools.git)
            let list = found.flatMap { Self.fetchList($0, gh: tools.gh) }
            DispatchQueue.main.async { [self] in
                fetching.remove(key)
                let now = Date()
                repositories[folder] = (found, now)
                if let found {
                    let before = lists[found]?.list
                    // A failed fetch keeps what was there until it succeeds.
                    lists[found] = (list ?? before, now)
                    if list != before {
                        changed()
                    }
                }
            }
        }
    }

    private static func repository(of folder: String, git: String?) -> String? {
        guard let git,
            let output = NativeTmuxProcessRunner.run(
                executable: git, arguments: ["-C", folder, "remote", "get-url", "origin"],
                timeout: 3),
            !output.timedOut, output.status == 0
        else {
            return nil
        }
        return nativeGitHubRepository(
            remote: String(decoding: output.standardOutput, as: UTF8.self))
    }

    private static func fetchList(_ repository: String, gh: String?) -> NativeGitHubList? {
        guard let gh else {
            return nil
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        func items(_ command: String, fields: String, kind: NativeSidebarItemKind)
            -> [NativeSidebarItem]?
        {
            guard
                let output = NativeTmuxProcessRunner.run(
                    executable: gh,
                    arguments: [
                        command, "list", "--repo", repository, "--state", "open",
                        "--limit", String(limit), "--json", fields,
                    ],
                    environment: environment, timeout: 15),
                !output.timedOut
            else {
                NativeLog.runtimeError(
                    "github_list_failed repo=\(repository) list=\(command) reason=timeout")
                return nil
            }
            guard output.status == 0 else {
                NativeLog.runtimeError(
                    "github_list_failed repo=\(repository) list=\(command) status=\(output.status)")
                return nil
            }
            return nativeGitHubItems(output.standardOutput, kind: kind)
        }
        guard let pulls = items("pr", fields: "number,title,url,author,isDraft", kind: .pull),
            let issues = items("issue", fields: "number,title,url,author", kind: .issue)
        else {
            return nil
        }
        return NativeGitHubList(repository: repository, pulls: pulls, issues: issues)
    }
}

func runNativeGitHubListSelfTests() -> Bool {
    let json = Data(
        """
        [{"number": 12, "title": "Count visits per user", "url": "https://github.com/alice/visits/pull/12",
          "author": {"login": "alice"}, "isDraft": true},
         {"number": 9, "title": "Users", "url": "https://github.com/alice/visits/issues/9", "author": {"login": "bob"}},
         {"title": "no number"}]
        """.utf8)
    return nativeGitHubRepository(remote: "git@github.com:alice/visits.git\n") == "alice/visits"
        && nativeGitHubRepository(remote: "https://github.com/alice/visits") == "alice/visits"
        && nativeGitHubRepository(remote: "https://github.com/alice/visits.git/") == "alice/visits"
        && nativeGitHubRepository(remote: "ssh://git@github.com/alice/visits.git") == "alice/visits"
        && nativeGitHubRepository(remote: "https://gitlab.com/alice/visits") == nil
        && nativeGitHubRepository(remote: "https://github.com/alice") == nil
        && nativeGitHubRepository(remote: "https://github.com/alice/visits/tree/main") == nil
        && nativeGitHubItems(json, kind: .pull) == [
            .init(
                kind: .pull, text: "https://github.com/alice/visits/pull/12",
                detail: "alice · draft",
                label: "#12 Count visits per user"),
            .init(
                kind: .pull, text: "https://github.com/alice/visits/issues/9", detail: "bob",
                label: "#9 Users"),
        ]
        && nativeGitHubItems(Data("{}".utf8), kind: .issue) == nil
        && NativeSidebarItemKind.pull.opens && NativeSidebarItemKind.issue.opens
        && !NativeSidebarItemKind.quote.opens
        && NativeItemRowView.action(kind: .issue, x: 40, width: 276, option: false) == .open
        && NativeItemRowView.action(kind: .pull, x: 260, width: 276, option: false) == .copy
}
