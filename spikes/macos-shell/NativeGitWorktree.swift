import Foundation

/// A git worktree Satin keeps beside its repository: the main checkout at
/// `/path/repo` and its worktrees in `/path/repo.worktrees`, one folder per
/// branch. Where a worktree lives is what marks it as Satin's, so a pane's
/// header can tell it from its directory alone, with no state to keep.
struct NativeGitWorktree: Equatable {
    /// The worktree's top directory.
    let path: String
    /// The main checkout the worktree belongs to.
    let repository: String
    /// The branch it has checked out; nil when its HEAD is detached.
    let branch: String?

    static let folderSuffix = ".worktrees"

    /// Where Satin puts the worktree of branch for the main checkout at
    /// repository. A slash in the branch name becomes a hyphen, so that every
    /// worktree is one folder deep.
    static func location(repository: String, branch: String) -> String {
        // Not standardized: that too would drop a leading `/private`.
        let root = URL(fileURLWithPath: repository)
        return root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + folderSuffix, isDirectory: true)
            .appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-"))
            .path
    }

    /// path with its links resolved as the system resolves them, which is how
    /// git names a checkout. Foundation's own resolution drops a leading
    /// `/private`, so it would name `/private/var/...` as `/var/...`.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        defer {
            free(resolved)
        }
        return String(cString: resolved)
    }

    /// Whether directory is inside a git checkout, read from the file system.
    static func isInsideCheckout(_ directory: String) -> Bool {
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return true
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                return false
            }
            url = parent
        }
    }

    /// The Satin worktree that holds directory, read from the file system.
    static func containing(_ directory: String) -> NativeGitWorktree? {
        var url = URL(fileURLWithPath: canonicalPath(directory))
        while true {
            let marker = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                // The nearest checkout decides: a main checkout or a repository
                // nested in a worktree is not that worktree.
                return isDirectory.boolValue ? nil : worktree(top: url, marker: marker)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                return nil
            }
            url = parent
        }
    }

    /// The worktree whose `.git` file is marker, when it lives where Satin puts
    /// the worktrees of its repository.
    private static func worktree(top: URL, marker: URL) -> NativeGitWorktree? {
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
            let line = text.split(separator: "\n").first,
            line.hasPrefix("gitdir: ")
        else {
            return nil
        }
        let named = String(line.dropFirst("gitdir: ".count))
        // Git writes the path relative to the worktree when asked to.
        let gitDirectory = URL(
            fileURLWithPath: canonicalPath(
                URL(fileURLWithPath: named, relativeTo: top).standardizedFileURL.path
            )
        )
        let worktrees = gitDirectory.deletingLastPathComponent()
        let common = worktrees.deletingLastPathComponent()
        guard worktrees.lastPathComponent == "worktrees", common.lastPathComponent == ".git" else {
            return nil
        }
        let repository = common.deletingLastPathComponent()
        let folder = repository.deletingLastPathComponent()
            .appendingPathComponent(repository.lastPathComponent + folderSuffix)
        guard top.deletingLastPathComponent().path == folder.path else {
            return nil
        }
        let head = try? String(
            contentsOf: gitDirectory.appendingPathComponent("HEAD"),
            encoding: .utf8
        )
        let reference = head?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = "ref: refs/heads/"
        return NativeGitWorktree(
            path: top.path,
            repository: repository.path,
            branch: reference.hasPrefix(prefix) ? String(reference.dropFirst(prefix.count)) : nil
        )
    }
}

/// Git as Satin runs it for worktrees.
struct NativeGit {
    struct Failure: Error, Equatable {
        let message: String
    }

    let executable: String
    /// The environment git runs in; nil runs it in Satin's.
    var environment: [String: String]?

    func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 120)
        -> NativeProcessOutput?
    {
        NativeTmuxProcessRunner.run(
            executable: executable,
            arguments: ["-C", directory] + arguments,
            environment: environment,
            timeout: timeout
        )
    }

    /// The main checkout of the repository directory is in; nil for a bare
    /// repository or none.
    func repository(of directory: String) -> String? {
        guard let output = run(["worktree", "list", "--porcelain"], in: directory, timeout: 10),
            output.status == 0, !output.timedOut
        else {
            return nil
        }
        let text = String(decoding: output.standardOutput, as: UTF8.self)
        let first = text.components(separatedBy: "\n\n").first ?? ""
        let lines = first.split(separator: "\n").map(String.init)
        guard let line = lines.first, line.hasPrefix("worktree "), !lines.contains("bare") else {
            return nil
        }
        return String(line.dropFirst("worktree ".count))
    }

    func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"),
            let output = run(["check-ref-format", "--branch", name], in: "/", timeout: 10)
        else {
            return false
        }
        return output.status == 0 && !output.timedOut
    }

    /// Checks branch out in a new worktree beside the repository directory is
    /// in: the branch when there is one, else a new branch from directory's
    /// HEAD.
    func createWorktree(from directory: String, branch: String) -> Result<
        NativeGitWorktree, Failure
    > {
        guard let repository = repository(of: directory) else {
            return .failure(Failure(message: "The pane’s directory is not in a git repository."))
        }
        guard isValidBranchName(branch) else {
            return .failure(Failure(message: "“\(branch)” is not a valid branch name."))
        }
        let path = NativeGitWorktree.location(repository: repository, branch: branch)
        guard !FileManager.default.fileExists(atPath: path) else {
            return .failure(Failure(message: "\(path) already exists."))
        }
        let existing = run(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
            in: repository,
            timeout: 10
        )
        let arguments =
            existing?.status == 0
            ? ["worktree", "add", path, branch]
            : ["worktree", "add", "-b", branch, path, "HEAD"]
        guard let output = run(arguments, in: directory) else {
            return .failure(Failure(message: "Satin could not run git."))
        }
        guard output.status == 0, !output.timedOut else {
            return .failure(
                Failure(
                    message: Self.message(output, otherwise: "git could not create the worktree.")))
        }
        return .success(NativeGitWorktree(path: path, repository: repository, branch: branch))
    }

    /// Whether the worktree holds changes git would lose on removing it. A
    /// worktree git cannot read counts as one that does.
    func hasChanges(_ worktree: NativeGitWorktree) -> Bool {
        guard let output = run(["status", "--porcelain"], in: worktree.path, timeout: 10),
            output.status == 0, !output.timedOut
        else {
            return true
        }
        return !output.standardOutput.isEmpty
    }

    /// Removes the worktree's directory. Its branch and commits stay. git
    /// refuses a worktree with changes, and Satin does not force it.
    func removeWorktree(_ worktree: NativeGitWorktree) -> Result<Void, Failure> {
        guard let output = run(["worktree", "remove", worktree.path], in: worktree.repository)
        else {
            return .failure(Failure(message: "Satin could not run git."))
        }
        guard output.status == 0, !output.timedOut else {
            return .failure(
                Failure(
                    message: Self.message(output, otherwise: "git could not delete the worktree.")))
        }
        // The folder of worktrees goes with the last one in it.
        let folder = URL(fileURLWithPath: worktree.path).deletingLastPathComponent().path
        if (try? FileManager.default.contentsOfDirectory(atPath: folder))?.isEmpty == true {
            try? FileManager.default.removeItem(atPath: folder)
        }
        return .success(())
    }

    private static func message(_ output: NativeProcessOutput, otherwise: String) -> String {
        if output.timedOut {
            return "git took too long to answer."
        }
        let text = String(decoding: output.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? otherwise : text
    }
}

extension NativeGitWorktree {
    /// Runs real git against repositories in a temporary folder, with no
    /// global or system configuration, so the user's hooks never run.
    static func runSelfTests() -> Bool {
        guard let executable = NativeTmuxExecutableResolver.locate("git", shellPath: "") else {
            return false
        }
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("satin-worktree-test-\(UUID().uuidString)", isDirectory: true)
        // A path resolves its links only once it exists, and git names the
        // checkout by its resolved path.
        try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: canonicalPath(scratch.path), isDirectory: true)
        defer {
            try? fileManager.removeItem(at: root)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = "Satin"
        environment["GIT_AUTHOR_EMAIL"] = "satin@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Satin"
        environment["GIT_COMMITTER_EMAIL"] = "satin@example.invalid"
        let git = NativeGit(executable: executable, environment: environment)
        let repository = root.appendingPathComponent("project", isDirectory: true).path
        let nested = repository + "/src/deep"
        guard
            (try? fileManager.createDirectory(atPath: nested, withIntermediateDirectories: true))
                != nil,
            git.run(["init", "--quiet", "--initial-branch=main"], in: repository)?.status == 0,
            fileManager.createFile(atPath: repository + "/README", contents: Data("one\n".utf8)),
            // A tracked file, so that the worktree has the nested folder too.
            fileManager.createFile(atPath: nested + "/keep", contents: Data()),
            git.run(["add", "--all"], in: repository)?.status == 0,
            git.run(["commit", "--quiet", "-m", "first"], in: repository)?.status == 0,
            git.run(["branch", "existing"], in: repository)?.status == 0
        else {
            return expect(false, "a scratch repository")
        }
        return runLocationSelfTests(repository: repository, nested: nested)
            && runCreationSelfTests(git: git, repository: repository, nested: nested)
    }

    /// Reports a failed step on standard error, so that a failing run names it.
    private static func expect(_ passed: Bool, _ step: String) -> Bool {
        if !passed {
            FileHandle.standardError.write(Data("git worktree self-test: \(step)\n".utf8))
        }
        return passed
    }

    private static func runLocationSelfTests(repository: String, nested: String) -> Bool {
        expect(
            location(repository: "/work/app", branch: "fix/scroll")
                == "/work/app.worktrees/fix-scroll",
            "a branch's folder"
        )
            && expect(
                location(repository: "/work/app/", branch: "main") == "/work/app.worktrees/main",
                "a trailing slash"
            )
            && expect(isInsideCheckout(nested), "inside a checkout")
            && expect(
                !isInsideCheckout(
                    URL(fileURLWithPath: repository).deletingLastPathComponent().path),
                "outside a checkout"
            )
            && expect(containing(nested) == nil, "a main checkout is no worktree")
    }

    private static func runCreationSelfTests(git: NativeGit, repository: String, nested: String)
        -> Bool
    {
        let fileManager = FileManager.default
        guard
            expect(git.repository(of: nested) == repository, "the main checkout"),
            expect(!git.isValidBranchName("bad..name"), "an invalid name"),
            expect(!git.isValidBranchName("-x"), "an option for a name"),
            expect(git.isValidBranchName("fix/scroll"), "a valid name")
        else {
            return false
        }
        guard case .failure = git.createWorktree(from: nested, branch: "bad..name"),
            case .success(let created) = git.createWorktree(from: nested, branch: "fix/scroll"),
            case .success(let checkedOut) = git.createWorktree(from: repository, branch: "existing")
        else {
            return expect(false, "creating worktrees")
        }
        guard
            expect(
                created.path == location(repository: repository, branch: "fix/scroll"),
                "where it was made"
            ),
            expect(fileManager.fileExists(atPath: created.path + "/README"), "its files"),
            expect(containing(created.path + "/src/deep") == created, "found from inside it"),
            expect(git.repository(of: created.path) == repository, "its main checkout"),
            expect(containing(checkedOut.path)?.branch == "existing", "an existing branch")
        else {
            return false
        }
        guard case .failure = git.createWorktree(from: nested, branch: "fix/scroll") else {
            return expect(false, "a second worktree in the same place")
        }
        // A worktree made elsewhere is not Satin's.
        let elsewhere = URL(fileURLWithPath: repository).deletingLastPathComponent()
            .appendingPathComponent("elsewhere").path
        guard
            expect(
                git.run(["worktree", "add", "--quiet", elsewhere, "-b", "other"], in: repository)?
                    .status == 0 && containing(elsewhere) == nil,
                "a worktree made elsewhere"
            ),
            expect(!git.hasChanges(created), "a clean worktree"),
            fileManager.createFile(atPath: created.path + "/scratch", contents: Data()),
            expect(git.hasChanges(created), "a worktree with changes")
        else {
            return false
        }
        // Changes keep a worktree; without them it goes, and its branch stays.
        guard case .failure = git.removeWorktree(created),
            fileManager.fileExists(atPath: created.path),
            (try? fileManager.removeItem(atPath: created.path + "/scratch")) != nil
        else {
            return expect(false, "changes keep a worktree")
        }
        guard case .success = git.removeWorktree(created),
            case .success = git.removeWorktree(checkedOut)
        else {
            return expect(false, "deleting worktrees")
        }
        let folder = URL(fileURLWithPath: created.path).deletingLastPathComponent().path
        return expect(!fileManager.fileExists(atPath: created.path), "the worktree is gone")
            && expect(
                git.run(
                    ["show-ref", "--verify", "--quiet", "refs/heads/fix/scroll"], in: repository)?
                    .status == 0,
                "its branch stays"
            )
            && expect(!fileManager.fileExists(atPath: folder), "the empty folder is gone")
    }
}
