import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

actor LineChangesShellCallStore {
  private(set) var calls: [[String]] = []

  func record(_ arguments: [String]) {
    calls.append(arguments)
  }
}

struct GitClientLineChangesTests {
  @Test func nativeLineChangesMatchGitForIndexAndWorktree() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "native-diff-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = root.path(percentEncoded: false)
    func git(_ arguments: [String]) async throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = arguments
      process.environment = ProcessInfo.processInfo.environment.merging([
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
      ]) { _, value in value }
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try await process.runToExit()
      guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
    }
    let shell = ShellClient(
      run: { _, _, _ in
        Issue.record("Native line changes launched a subprocess")
        throw CocoaError(.fileReadUnknown)
      },
      runLoginImpl: { _, _, _, _ in
        Issue.record("Native line changes launched a login shell")
        throw CocoaError(.fileReadUnknown)
      }
    )
    let native = GitClient(shell: shell, nativeReferences: true)
    let gitClient = GitClient()
    try await git(["init", "-b", "main", path])
    #expect((await native.lineChanges(at: root))?.added == nil) // An unborn HEAD fails like Git.
    try "first\nsecond\nthird\n".write(to: root.appending(path: "tracked"), atomically: true, encoding: .utf8)
    try "gone\n".write(to: root.appending(path: "removed"), atomically: true, encoding: .utf8)
    try "one\ntwo\nthree\n".write(to: root.appending(path: "original"), atomically: true, encoding: .utf8)
    try await git(["-C", path, "add", "."])
    try await git(["-C", path, "commit", "-m", "initial"])
    try "first\nstaged\nthird\n".write(to: root.appending(path: "tracked"), atomically: true, encoding: .utf8)
    try await git(["-C", path, "add", "tracked"])
    try "first\nunstaged\nthird\nfourth\n".write(to: root.appending(path: "tracked"), atomically: true, encoding: .utf8)
    try await git(["-C", path, "rm", "removed"])
    try await git(["-C", path, "mv", "original", "renamed"])
    try "untracked\n".write(to: root.appending(path: "untracked"), atomically: true, encoding: .utf8)
    let nativeChanges = await native.lineChanges(at: root)
    let gitChanges = await gitClient.lineChanges(at: root)
    #expect(nativeChanges?.added == gitChanges?.added)
    #expect(nativeChanges?.removed == gitChanges?.removed)
    #expect(nativeChanges?.added == 2)
    #expect(nativeChanges?.removed == 2)
    try await git(["-C", path, "config", "diff.renames", "false"])
    let withoutRenames = await native.lineChanges(at: root)
    let gitWithoutRenames = await gitClient.lineChanges(at: root)
    #expect(withoutRenames?.added == gitWithoutRenames?.added)
    #expect(withoutRenames?.removed == gitWithoutRenames?.removed)
    #expect(withoutRenames?.added == 5)
    #expect(withoutRenames?.removed == 5)
  }

  @Test func lineChangesUsesShortstatAndParsesOutput() async {
    let store = LineChangesShellCallStore()
    let output = " 1 file changed, 12 insertions(+), 3 deletions(-)\n"
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: output, stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 12)
    #expect(changes?.removed == 3)
    let calls = await store.calls
    #expect(calls.count == 1)
    let args = calls[0]
    #expect(args.first == "git")
    #expect(args.contains("--no-optional-locks"))
    #expect(args.contains("diff"))
    #expect(args.contains("HEAD"))
    #expect(args.contains("--shortstat"))
    #expect(!args.contains("--numstat"))
  }

  @Test func lineChangesHandlesMissingDeletions() async {
    let output = " 1 file changed, 5 insertions(+)\n"
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: output, stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 5)
    #expect(changes?.removed == 0)
  }

  @Test func lineChangesParsesShortstatLine() async {
    let output = "1 file changed, 10 insertions(+), 4 deletions(-)\n"
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: output, stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 10)
    #expect(changes?.removed == 4)
  }

  @Test func lineChangesHandlesEmptyOutput() async {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "\n", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 0)
    #expect(changes?.removed == 0)
  }

  @Test func lineChangesSkipsWhenIndexLocked() async throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let gitDirectory = tempRoot.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)
    let lockURL = gitDirectory.appending(path: "index.lock")
    try Data().write(to: lockURL)
    let store = LineChangesShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: tempRoot)

    #expect(changes == nil)
    let calls = await store.calls
    #expect(calls.isEmpty)
  }
}
