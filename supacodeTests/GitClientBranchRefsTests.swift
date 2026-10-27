import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

actor ShellCallStore {
  private(set) var calls: [[String]] = []

  func record(_ arguments: [String]) {
    calls.append(arguments)
  }
}

struct GitClientBranchRefsTests {
  @Test func localMutationsUseGitEvenWhenNativeReadsAreEnabled() async throws {
    let calls = ShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await calls.record(arguments)
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClientDependency.make(shell: shell, nativeLocal: true)
    let root = URL(fileURLWithPath: "/tmp/git-mutation-fixture")
    try await client.fetchRemote("origin", root)
    try await client.renameBranch("old", "new", root)
    try await client.stageFile("file", root)
    try await client.unstageFile("file", root)
    try await client.setUpstreamBranch("new", "origin/main", root)
    try await client.unsetUpstreamBranch("new", root)
    let invocations = await calls.calls
    #expect(invocations.count == 6)
    #expect(invocations.allSatisfy { $0.contains("git") })
    #expect(invocations.contains { $0.contains("fetch") })
    #expect(invocations.contains { $0.contains("-m") && $0.contains("branch") })
    #expect(invocations.contains { $0.contains("add") && $0.contains("--literal-pathspecs") })
    #expect(invocations.contains { $0.contains("reset") && $0.contains("--literal-pathspecs") })
    #expect(invocations.contains { $0.contains("--set-upstream-to") })
    #expect(invocations.contains { $0.contains("--unset-upstream") })
  }

  @Test func credentialHelpersReceiveURLContextAndCombineResponses() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "credential-helper-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["init", root.path(percentEncoded: false)]
    process.environment = ProcessInfo.processInfo.environment.merging([
      "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"
    ]) { _, value in value }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try await process.runToExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
    let helper = root.appending(path: "helper.sh")
    let usernameHelper = root.appending(path: "username-helper.sh")
    try "#!/bin/sh\ncat >/dev/null\nprintf 'username=test-user\\n'\n"
      .write(to: usernameHelper, atomically: true, encoding: .utf8)
    try "#!/bin/sh\ninput=$(cat)\nprintf '%s' \"$input\" | grep -q '^host=example.test:8443$' || exit 1\nprintf '%s' \"$input\" | grep -q '^path=team/repo$' || exit 1\nprintf '%s' \"$input\" | grep -q '^username=test-user$' || exit 1\nprintf 'password=test-password\\n'\n"
      .write(to: helper, atomically: true, encoding: .utf8)
    let config = root.appending(path: ".git/config")
    let existing = try String(contentsOf: config, encoding: .utf8)
    try (existing + "\n[credential]\n  helper = !sh \(usernameHelper.path(percentEncoded: false))\n[credential \"https://example.test:8443\"]\n  helper = !sh \(helper.path(percentEncoded: false))\n  useHttpPath = true\n")
      .write(to: config, atomically: true, encoding: .utf8)
    let result = try NativeGitRepository.withRepository(at: root) { repository in
      try GitFetchCredentials.resolve(url: "https://example.test:8443/team/repo", username: nil, repository: repository)
    }
    #expect(result?.username == "test-user")
    #expect(result?.password == "test-password")
  }
  @Test func nativeQueriesReadBranchesWithoutLaunchingGit() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "native-refs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func git(_ args: [String]) async throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = args
      process.environment = ProcessInfo.processInfo.environment.merging([
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
      ]) { _, new in new }
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try await process.runToExit()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
      return String(decoding: data, as: UTF8.self)
    }
    let path = root.path(percentEncoded: false)
    _ = try await git(["init", "-b", "main", path])
    try "fixture".write(to: root.appending(path: "file"), atomically: true, encoding: .utf8)
    _ = try await git(["-C", path, "add", "file"])
    _ = try await git(["-C", path, "commit", "-m", "initial"])
    let head = try await git(["-C", path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try await git(["-C", path, "remote", "add", "origin", "https://example.invalid/repo"])
    _ = try await git(["-C", path, "update-ref", "refs/remotes/origin/main", head])
    _ = try await git(["-C", path, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
    _ = try await git(["-C", path, "branch", "feature"])
    _ = try await git(["-C", path, "branch", "--set-upstream-to=origin/main", "feature"])
    let shell = ShellClient(
      run: { _, _, _ in
        Issue.record("Native reference query launched a subprocess")
        throw CocoaError(.fileReadUnknown)
      },
      runLoginImpl: { _, _, _, _ in
        Issue.record("Native reference query launched a login shell")
        throw CocoaError(.fileReadUnknown)
      }
    )
    let client = GitClient(shell: shell, nativeReferences: true)
    let bare = root.appending(path: "remote.git")
    _ = try await git(["init", "--bare", bare.path(percentEncoded: false)])
    _ = try await git(["-C", path, "remote", "add", "upstream", bare.path(percentEncoded: false)])
    _ = try await git(["-C", path, "push", "upstream", "main"])
    _ = try await git(["-C", path, "config", "--add", "remote.upstream.url", "/missing/fetch-remote"])
    try await client.fetchRemote("upstream", for: root)
    #expect(try await client.upstreamBranchExists("refs/remotes/upstream/main", for: root))
    _ = try await git(["-C", path, "remote", "remove", "upstream"])
    for name in ["feature/new", "-invalid", "HEAD", "a..b", "foo.lock", "valid"] {
      let native = await client.isValidBranchName(name, for: root)
      let accepted = (try? await git(["-C", path, "check-ref-format", "--branch", name])) != nil
      #expect(native == accepted)
    }
    #expect(try await client.upstreamBranchExists("origin/main", for: root))
    #expect(try await client.upstreamBranchExists("refs/remotes/origin/main", for: root))
    #expect(try await !client.upstreamBranchExists("missing", for: root))
    #expect(try await !client.upstreamBranchExists("bad..name", for: root))
    _ = try await git(["-C", path, "branch", "origin/main"])
    try await client.setUpstreamBranch("feature", to: "refs/remotes/origin/main", for: root)
    #expect(try await git(["-C", path, "config", "branch.feature.remote"])
      .trimmingCharacters(in: .whitespacesAndNewlines) == "origin")
    #expect(try await git(["-C", path, "config", "branch.feature.merge"])
      .trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/main")
    _ = try await git(["-C", path, "branch", "-D", "origin/main"])
    _ = try await git(["-C", path, "config", "--add", "remote.origin.fetch", "+refs/heads/special/*:refs/remotes/alternate/*"])
    _ = try await git(["-C", path, "update-ref", "refs/remotes/alternate/test", head])
    try await client.setUpstreamBranch("feature", to: "refs/remotes/alternate/test", for: root)
    #expect(try await git(["-C", path, "config", "branch.feature.merge"])
      .trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/special/test")
    _ = try await git(["-C", path, "update-ref", "-d", "refs/remotes/alternate/test"])
    try await client.setUpstreamBranch("feature", to: "refs/remotes/origin/main", for: root)
    #expect(try await git(["-C", path, "rev-parse", "--abbrev-ref", "feature@{upstream}"])
      .trimmingCharacters(in: .whitespacesAndNewlines) == "origin/main")
    let linked = root.appending(path: "linked-worktree")
    _ = try await git(["-C", path, "worktree", "add", linked.path(percentEncoded: false), "feature"])
    try await client.renameBranch(from: "feature", to: "renamed", for: root)
    #expect(await client.symbolicHeadBranch(at: linked) == "renamed")
    #expect(try await git(["-C", path, "rev-parse", "--abbrev-ref", "renamed@{upstream}"])
      .trimmingCharacters(in: .whitespacesAndNewlines) == "origin/main")
    try await client.unsetUpstreamBranch("renamed", for: root)
    try await client.unsetUpstreamBranch("renamed", for: root)
    try await client.unsetUpstreamBranch("missing", for: root)
    _ = try await git(["-C", path, "worktree", "remove", linked.path(percentEncoded: false)])
    try await client.renameBranch(from: "renamed", to: "feature", for: root)
    try await client.setUpstreamBranch("feature", to: "origin/main", for: root)
    #expect(try await client.isBareRepository(for: root) == false)
    #expect(try await client.localBranchNames(for: root) == ["feature", "main"])
    let namesOnly = try NativeGitRepository.branches(at: root, remote: false, includeUpstream: false)
    #expect(namesOnly.map(\.name) == ["feature", "main"])
    #expect(namesOnly.allSatisfy { $0.upstream == nil })
    let withUpstreams = try NativeGitRepository.branches(at: root, remote: false)
    #expect(withUpstreams.first { $0.name == "feature" }?.upstream == "origin/main")
    #expect(try await client.remoteNames(for: root) == ["origin"])
    #expect(try await client.branchRefs(for: root) == ["main", "origin/main"])
    #expect(try await client.defaultRemoteBranchRef(for: root) == "origin/main")
    #expect(await client.automaticWorktreeBaseRef(for: root) == "origin/main")
    let inventory = try await client.branchInventory(for: root, remoteNames: ["origin"])
    #expect(inventory.localBranches == ["feature", "main"])
    #expect(inventory.remotes.first?.branches == ["main"])
    _ = try await git(["-C", path, "tag", "main"])
    let gitBranches = try await git(["-C", path, "for-each-ref", "--format=%(refname:short)", "refs/heads"])
      .split(whereSeparator: \.isNewline).map(String.init)
    let nativeBranches = try NativeGitRepository.branches(at: root, remote: false).map(\.name)
    #expect(nativeBranches == gitBranches)
    // Skipping upstream resolution must retain Git's unambiguous short names,
    // including a local branch whose name collides with a tag.
    let namesOnlyInventory = try await client.branchInventory(for: root, remoteNames: ["origin"])
    #expect(Set(namesOnlyInventory.localBranches) == Set(gitBranches))
    #expect(try await client.localBranchNames(for: root) == ["feature", "main"])
    _ = try await git(["-C", path, "remote", "remove", "origin"])
    #expect(await client.automaticWorktreeBaseRef(for: root) == "heads/main")
    _ = try await git(["-C", path, "checkout", "--detach"])
    #expect(await client.symbolicHeadBranch(at: root) == "HEAD")
    #expect(await client.automaticWorktreeBaseRef(for: root) == nil)
  }

  @Test func branchRefsUsesUpstreamsOrLocalRefs() async throws {
    let store = ShellCallStore()
    let output = """
      feature\torigin/feature
      main\t
      bugfix\torigin/bugfix
      """
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: output, stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    let refs = try await client.branchRefs(for: repoRoot)

    let expected = ["origin/bugfix", "origin/feature", "main"]
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    #expect(refs == expected)
    let calls = await store.calls
    #expect(calls.count == 1)
    let args = calls[0]
    #expect(args.first == "git")
    #expect(args.contains("for-each-ref"))
    #expect(args.contains("refs/heads"))
    #expect(args.contains("--format=%(refname:short)\t%(upstream:short)"))
  }

  @Test func branchRefsDropsOriginHead() async throws {
    let output = """
      head\torigin/HEAD
      main\torigin/main
      """
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: output, stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    let refs = try await client.branchRefs(for: repoRoot)

    #expect(refs == ["origin/main"])
  }

  @Test func defaultRemoteBranchRefStripsPrefix() async throws {
    let shell = ShellClient(
      run: { _, _, _ in
        ShellOutput(stdout: "refs/remotes/origin/develop\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let ref = try await client.defaultRemoteBranchRef(for: URL(fileURLWithPath: "/tmp/repo"))

    #expect(ref == "origin/develop")
  }

  @Test func defaultRemoteBranchRefReturnsNilOnError() async throws {
    let shell = ShellClient(
      run: { _, _, _ in
        throw ShellClientError(command: "git", stdout: "", stderr: "boom", exitCode: 1)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let ref = try await client.defaultRemoteBranchRef(for: URL(fileURLWithPath: "/tmp/repo"))

    #expect(ref == nil)
  }

  @Test func defaultRemoteBranchRefFallsBackToOriginMain() async throws {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("symbolic-ref") {
          throw ShellClientError(command: "git", stdout: "", stderr: "missing", exitCode: 1)
        }
        if arguments.contains("rev-parse") {
          return ShellOutput(stdout: "hash", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let ref = try await client.defaultRemoteBranchRef(for: URL(fileURLWithPath: "/tmp/repo"))

    #expect(ref == "origin/main")
  }

  @Test func automaticWorktreeBaseRefUsesResolvedDefault() async throws {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("symbolic-ref") {
          return ShellOutput(stdout: "refs/remotes/origin/develop\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("rev-parse") {
          return ShellOutput(stdout: "hash", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let ref = await client.automaticWorktreeBaseRef(for: URL(fileURLWithPath: "/tmp/repo"))

    #expect(ref == "origin/develop")
  }

  @Test func automaticWorktreeBaseRefReturnsNilWhenUnavailable() async throws {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("symbolic-ref") || arguments.contains("rev-parse") {
          throw ShellClientError(command: "git", stdout: "", stderr: "missing", exitCode: 1)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let ref = await client.automaticWorktreeBaseRef(for: URL(fileURLWithPath: "/tmp/repo"))

    #expect(ref == nil)
  }

  @Test func branchInventoryGroupsAndSortsLocalAndRemoteBranches() async throws {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("refs/heads") {
          return ShellOutput(stdout: "main\nfeature\nalpha\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("refs/remotes") {
          return ShellOutput(
            stdout: "origin/HEAD\norigin/main\norigin/dev\nupstream/main\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.last == "remote" {
          return ShellOutput(stdout: "origin\nupstream\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let inventory = try await client.branchInventory(
      for: URL(fileURLWithPath: "/tmp/repo"),
      remoteNames: ["origin", "upstream"]
    )

    #expect(inventory.localBranches == ["alpha", "feature", "main"])
    #expect(inventory.remotes.map(\.name) == ["origin", "upstream"])
    #expect(inventory.remotes.first?.branches == ["dev", "main"])
    #expect(inventory.remotes.last?.branches == ["main"])
  }

  @Test func groupRemoteBranchesOrdersOriginFirstThenAlphabetical() {
    let groups = GitReferenceQueries.groupRemoteBranches(
      refs: ["upstream/main", "fork/feature", "origin/dev", "origin/main"],
      remoteNames: ["upstream", "fork", "origin"]
    )

    #expect(groups.map(\.name) == ["origin", "fork", "upstream"])
    #expect(groups[0].branches == ["dev", "main"])
  }

  @Test func localBranchNameStripsLongestMatchingRemote() {
    #expect(
      GitReferenceQueries.localBranchName(fromRemoteRef: "origin/main", remoteNames: ["origin"])
        == "main"
    )
    #expect(
      GitReferenceQueries.localBranchName(
        fromRemoteRef: "upstream/feature/x",
        remoteNames: ["up", "upstream"]
      ) == "feature/x"
    )
    #expect(
      GitReferenceQueries.localBranchName(fromRemoteRef: "main", remoteNames: ["origin"]) == nil
    )
  }
}
