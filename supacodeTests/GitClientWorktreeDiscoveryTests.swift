import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

nonisolated final class GitWorktreeDiscoveryRecorder: @unchecked Sendable {
  struct Invocation: Equatable {
    let executablePath: String
    let arguments: [String]
    let currentDirectoryPath: String?
  }

  private let lock = NSLock()
  private var runInvocationsValue: [Invocation] = []
  private var loginInvocationsValue: [Invocation] = []

  func recordRun(executableURL: URL, arguments: [String], currentDirectoryURL: URL?) {
    lock.lock()
    runInvocationsValue.append(
      Invocation(
        executablePath: executableURL.path(percentEncoded: false),
        arguments: arguments,
        currentDirectoryPath: currentDirectoryURL?.path(percentEncoded: false)
      )
    )
    lock.unlock()
  }

  func recordLogin(executableURL: URL, arguments: [String], currentDirectoryURL: URL?) {
    lock.lock()
    loginInvocationsValue.append(
      Invocation(
        executablePath: executableURL.path(percentEncoded: false),
        arguments: arguments,
        currentDirectoryPath: currentDirectoryURL?.path(percentEncoded: false)
      )
    )
    lock.unlock()
  }

  func runInvocations() -> [Invocation] {
    lock.lock()
    let value = runInvocationsValue
    lock.unlock()
    return value
  }

  func loginInvocations() -> [Invocation] {
    lock.lock()
    let value = loginInvocationsValue
    lock.unlock()
    return value
  }
}

struct GitClientWorktreeDiscoveryTests {
  @Test func nativeRepositoryRootResolvesNestedDirectory() async throws {
    let repository = FileManager.default.temporaryDirectory
      .appending(path: "native-git-root-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: repository) }
    let git = repository.appending(path: ".git", directoryHint: .isDirectory)
    let nested = repository.appending(path: "nested", directoryHint: .isDirectory)
    for directory in [git.appending(path: "objects"), git.appending(path: "refs/heads"), nested] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try "ref: refs/heads/main\n".write(to: git.appending(path: "HEAD"), atomically: true, encoding: .utf8)
    try "[core]\nrepositoryformatversion = 0\nbare = false\n".write(
      to: git.appending(path: "config"), atomically: true, encoding: .utf8)
    let root = try NativeGitRepository.root(at: nested)
    #expect(root.resolvingSymlinksInPath() == repository.resolvingSymlinksInPath())
    let liveRoot = try await GitClientDependency.liveValue.repoRoot(nested)
    #expect(liveRoot.resolvingSymlinksInPath() == repository.resolvingSymlinksInPath())
    let executable = try #require(Bundle.main.url(forResource: "wt", withExtension: nil, subdirectory: "git-wt"))
    let handle = try FileHandle(forReadingFrom: executable)
    defer { try? handle.close() }
    #expect(try handle.read(upToCount: 4) == Data([0xcf, 0xfa, 0xed, 0xfe]))
    let worktrees = try await GitClient().worktrees(for: repository)
    #expect(worktrees.count == 1)
    #expect(worktrees.first?.workingDirectory.resolvingSymlinksInPath() == repository.resolvingSymlinksInPath())
  }

  @Test func repoRootUsesDirectBundledWtExecution() async throws {
    let recorder = GitWorktreeDiscoveryRecorder()
    let shell = ShellClient(
      run: { executableURL, arguments, currentDirectoryURL in
        recorder.recordRun(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        return ShellOutput(stdout: "/tmp/repo\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        recorder.recordLogin(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        Issue.record("repoRoot should not use runLogin when direct execution succeeds")
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GitClient(shell: shell)
    let worktreeURL = URL(fileURLWithPath: "/tmp/repo/worktree")

    let root = try await client.repoRoot(for: worktreeURL)

    #expect(root.standardizedFileURL.path(percentEncoded: false).hasSuffix("/tmp/repo"))
    let runs = recorder.runInvocations()
    #expect(runs.count == 1)
    if let invocation = runs.first {
      #expect(invocation.arguments == ["root"])
      let normalizedPath = URL(fileURLWithPath: invocation.currentDirectoryPath ?? "")
        .standardizedFileURL
        .path(percentEncoded: false)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      #expect(normalizedPath == "tmp/repo")
    } else {
      Issue.record("Expected one direct bundled wt invocation for repoRoot")
    }
    #expect(recorder.loginInvocations().isEmpty)
  }

  @Test func worktreesUseDirectBundledWtExecution() async throws {
    let recorder = GitWorktreeDiscoveryRecorder()
    let output = """
      [
        {"branch":"main","path":"/tmp/repo","head":"abc","is_bare":false},
        {"branch":"feature","path":"/tmp/repo/.worktrees/feature","head":"def","is_bare":false}
      ]
      """
    let shell = ShellClient(
      run: { executableURL, arguments, currentDirectoryURL in
        recorder.recordRun(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        return ShellOutput(stdout: output, stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        recorder.recordLogin(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        Issue.record("worktrees should not use runLogin when direct execution succeeds")
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    let worktrees = try await client.worktrees(for: repoRoot)

    #expect(worktrees.map(\.id) == ["/tmp/repo", "/tmp/repo/.worktrees/feature"])
    let runs = recorder.runInvocations()
    #expect(runs.count == 1)
    if let invocation = runs.first {
      #expect(invocation.arguments == ["__app-ls"])
      #expect(invocation.currentDirectoryPath == "/tmp/repo")
    } else {
      Issue.record("Expected one direct bundled wt invocation for worktree discovery")
    }
    #expect(recorder.loginInvocations().isEmpty)
  }

  @Test func worktreesFlagMissingWorkingDirectoryAsOrphan() async throws {
    let tempRoot = URL(filePath: "/tmp", directoryHint: .isDirectory)
      .appending(path: "wt-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
    let repoURL = tempRoot.appending(path: "repo", directoryHint: .isDirectory)
    let liveURL =
      tempRoot
      .appending(path: "repo", directoryHint: .isDirectory)
      .appending(path: ".worktrees", directoryHint: .isDirectory)
      .appending(path: "live", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: liveURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let repoPath = repoURL.path(percentEncoded: false)
    let livePath = liveURL.path(percentEncoded: false)
    let missingPath = tempRoot.appending(path: "vanished", directoryHint: .isDirectory)
      .path(percentEncoded: false)
    let output = """
      [
        {"branch":"main","path":"\(repoPath)","head":"abc","is_bare":false},
        {"branch":"live","path":"\(livePath)","head":"def","is_bare":false},
        {"branch":"phantom","path":"\(missingPath)","head":"ghi","is_bare":false}
      ]
      """
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: output, stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let worktrees = try await client.worktrees(for: repoURL)
    let byID = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, $0) })

    #expect(byID[WorktreeID(repoPath)]?.isMissing == false)
    #expect(byID[WorktreeID(livePath)]?.isMissing == false)
    #expect(byID[WorktreeID(missingPath)]?.isMissing == true)
  }

  @Test func repoRootFallsBackToLoginShellWhenDirectExecutionCannotResolveGit() async throws {
    let recorder = GitWorktreeDiscoveryRecorder()
    let shell = ShellClient(
      run: { executableURL, arguments, currentDirectoryURL in
        recorder.recordRun(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        throw ShellClientError(
          command: "wt root",
          stdout: "",
          stderr: "git: command not found",
          exitCode: 127
        )
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        recorder.recordLogin(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        return ShellOutput(stdout: "/tmp/repo\n", stderr: "", exitCode: 0)
      }
    )
    let client = GitClient(shell: shell)

    let root = try await client.repoRoot(for: URL(fileURLWithPath: "/tmp/repo/worktree"))

    #expect(root.standardizedFileURL.path(percentEncoded: false).hasSuffix("/tmp/repo"))
    #expect(recorder.runInvocations().count == 1)
    #expect(recorder.loginInvocations().count == 1)
    if let invocation = recorder.loginInvocations().first {
      #expect(invocation.arguments == ["root"])
      let normalizedPath = URL(fileURLWithPath: invocation.currentDirectoryPath ?? "")
        .standardizedFileURL
        .path(percentEncoded: false)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      #expect(normalizedPath == "tmp/repo")
    } else {
      Issue.record("Expected login-shell fallback invocation for repoRoot")
    }
  }

  @Test func worktreesDoNotFallbackToLoginShellForRegularFailures() async {
    let recorder = GitWorktreeDiscoveryRecorder()
    let shell = ShellClient(
      run: { executableURL, arguments, currentDirectoryURL in
        recorder.recordRun(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        throw ShellClientError(
          command: "wt ls --json",
          stdout: "",
          stderr: "permission denied",
          exitCode: 1
        )
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        recorder.recordLogin(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        Issue.record("worktrees should not fallback to runLogin for regular command failures")
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GitClient(shell: shell)

    await #expect(throws: GitClientError.self) {
      _ = try await client.worktrees(for: URL(fileURLWithPath: "/tmp/repo"))
    }

    #expect(recorder.runInvocations().count == 1)
    #expect(recorder.loginInvocations().isEmpty)
  }
}
