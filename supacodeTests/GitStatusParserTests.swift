import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct GitStatusParserTests {
  @Test func nativeStatusMatchesGitForMixedChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "native-status-\(UUID().uuidString)")
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
        "PATH": (ProcessInfo.processInfo.environment["PATH"] ?? "")
          + ":/run/current-system/sw/bin:/opt/homebrew/bin:/usr/local/bin",
      ]) { _, new in new }
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try await process.runToExit()
      let bytes = output.fileHandleForReading.readDataToEndOfFile()
      guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
      return String(decoding: bytes, as: UTF8.self)
    }
    let path = root.path(percentEncoded: false)
    _ = try await git(["init", "-b", "main", path])
    try FileManager.default.createDirectory(at: root.appending(path: "mixed"), withIntermediateDirectories: true)
    for name in ["modified", "deleted", "cached", "mixed/tracked"] {
      try "old\n".write(to: root.appending(path: name), atomically: true, encoding: .utf8)
    }
    try "ignored/\nmixed/hidden\n".write(to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
    _ = try await git(["-C", path, "add", "."])
    _ = try await git(["-C", path, "commit", "-m", "initial"])
    try "staged\n".write(to: root.appending(path: "modified"), atomically: true, encoding: .utf8)
    _ = try await git(["-C", path, "add", "modified"])
    try "unstaged\n".write(to: root.appending(path: "modified"), atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: root.appending(path: "deleted"))
    _ = try await git(["-C", path, "rm", "--cached", "cached"])
    try "new\n".write(to: root.appending(path: "new file"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: root.appending(path: "ignored"), withIntermediateDirectories: true)
    try "ignored\n".write(to: root.appending(path: "ignored/file"), atomically: true, encoding: .utf8)
    try "ignored\n".write(to: root.appending(path: "mixed/hidden"), atomically: true, encoding: .utf8)
    let output = try await git([
      "-C", path, "--no-optional-locks", "status", "--porcelain=v2", "-z",
      "--untracked-files=all", "--ignored=matching", "--no-renames",
    ])
    let expected = GitStatusSnapshot.parse(porcelainV2: output)
    let shell = ShellClient(
      run: { _, _, _ in
        Issue.record("Native status launched Git")
        throw CocoaError(.fileReadUnknown)
      },
      runLoginImpl: { _, _, _, _ in
        Issue.record("Native status launched a shell")
        throw CocoaError(.fileReadUnknown)
      }
    )
    let client = GitClient(shell: shell, nativeReferences: true)
    let actual = try #require(await client.fileStatus(at: root))
    #expect(actual == expected)
    try await client.stageFile("new file", in: root)
    let staged = try await git(["-C", path, "show", ":new file"])
    #expect(staged == "new\n")
    try await client.unstageFile("new file", in: root)
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "new file").path(percentEncoded: false)))
    #expect(try await git(["-C", path, "diff", "--cached", "--name-only"]).contains("new file") == false)
    try await client.discardTrackedFile("modified", in: root)
    #expect(try String(contentsOf: root.appending(path: "modified"), encoding: .utf8) == "old\n")
    #expect(try await git(["-C", path, "diff", "--cached", "--name-only"]).contains("modified") == false)

    _ = try await git(["-C", path, "reset", "--hard", "HEAD"])
    _ = try await git(["-C", path, "checkout", "-b", "other"])
    try "other\n".write(to: root.appending(path: "modified"), atomically: true, encoding: .utf8)
    _ = try await git(["-C", path, "add", "modified"])
    _ = try await git(["-C", path, "commit", "-m", "other"])
    _ = try await git(["-C", path, "checkout", "main"])
    try "main\n".write(to: root.appending(path: "modified"), atomically: true, encoding: .utf8)
    _ = try await git(["-C", path, "add", "modified"])
    _ = try await git(["-C", path, "commit", "-m", "main"])
    _ = try? await git(["-C", path, "merge", "other"])
    let conflictOutput = try await git([
      "-C", path, "--no-optional-locks", "status", "--porcelain=v2", "-z",
      "--untracked-files=all", "--ignored=matching", "--no-renames",
    ])
    let conflict = try #require(await GitClient(shell: shell, nativeReferences: true).fileStatus(at: root))
    #expect(conflict == GitStatusSnapshot.parse(porcelainV2: conflictOutput))
    #expect(conflict.statuses["modified"]?.isConflicted == true)
    if (try? await git(["lfs", "version"])) != nil {
      _ = try await git(["-C", path, "merge", "--abort"])
      _ = try await git(["-C", path, "lfs", "install", "--local"])
      _ = try await git(["-C", path, "lfs", "track", "*.asset"])
      let asset = root.appending(path: "file.asset")
      try "lfs contents\n".write(to: asset, atomically: true, encoding: .utf8)
      _ = try await git(["-C", path, "add", ".gitattributes", "file.asset"])
      _ = try await git(["-C", path, "commit", "-m", "lfs"])
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: asset.path(percentEncoded: false)
      )
      let gitOutput = try await git([
        "-C", path, "--no-optional-locks", "status", "--porcelain=v2", "-z",
        "--untracked-files=all", "--ignored=matching", "--no-renames",
      ])
      let lfsStatus = try #require(await GitClient(shell: shell, nativeReferences: true).fileStatus(at: root))
      #expect(lfsStatus == GitStatusSnapshot.parse(porcelainV2: gitOutput))
      #expect(lfsStatus.statuses["file.asset"] == nil)
    }
  }

  // MARK: - Porcelain v2 record builders

  /// An ordinary (`1`) record: 8 fixed fields then the path.
  private static func ordinary(_ codes: String, _ path: String) -> String {
    "1 \(codes) N... 100644 100644 100644 1111111 2222222 \(path)"
  }

  /// A rename/copy (`2`) record; the original path is a separate token.
  private static func renamed(_ codes: String, from origin: String, to path: String) -> String {
    "2 \(codes) N... 100644 100644 100644 1111111 2222222 R100 \(path)\0\(origin)"
  }

  /// An unmerged (`u`) record: 10 fixed fields then the path.
  private static func unmerged(_ codes: String, _ path: String) -> String {
    "u \(codes) N... 100644 100644 100644 100644 1111111 2222222 3333333 \(path)"
  }

  /// Joins records into the NUL-delimited, NUL-terminated stream git emits.
  private static func stream(_ records: [String]) -> String {
    records.map { $0 + "\0" }.joined()
  }

  // MARK: - Axis parsing

  @Test func emptyOutputIsCleanSnapshot() {
    #expect(GitStatusSnapshot.parse(porcelainV2: "") == .empty)
  }

  @Test func unstagedModificationSetsWorktreeAxisOnly() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".M", "a.txt")]))
    #expect(snapshot.statuses["a.txt"]?.worktree == .modified)
    #expect(snapshot.statuses["a.txt"]?.index == nil)
  }

  @Test func stagedModificationSetsIndexAxisOnly() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary("M.", "a.txt")]))
    #expect(snapshot.statuses["a.txt"]?.index == .modified)
    #expect(snapshot.statuses["a.txt"]?.worktree == nil)
  }

  @Test func stagedThenEditedSetsBothAxes() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary("MM", "a.txt")]))
    #expect(snapshot.statuses["a.txt"]?.index == .modified)
    #expect(snapshot.statuses["a.txt"]?.worktree == .modified)
  }

  @Test func stagedAddAndDeleteMapToKinds() {
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream([Self.ordinary("A.", "new.txt"), Self.ordinary("D.", "gone.txt")])
    )
    #expect(snapshot.statuses["new.txt"]?.index == .added)
    #expect(snapshot.statuses["gone.txt"]?.index == .deleted)
  }

  @Test func untrackedAndIgnoredAreDistinct() {
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream(["? scratch.log", "! node_modules/"])
    )
    #expect(snapshot.statuses["scratch.log"]?.isUntracked == true)
    // The wholly-ignored directory is reported once, trailing slash stripped.
    #expect(snapshot.ignoredPrefixes == ["node_modules"])
    #expect(snapshot.statuses["node_modules"] == nil)
  }

  @Test func conflictSetsConflictedFlag() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.unmerged("UU", "clash.txt")]))
    #expect(snapshot.statuses["clash.txt"]?.isConflicted == true)
  }

  // MARK: - Record framing

  @Test func renameRecordConsumesItsOriginTokenWithoutDesync() {
    // A `2` record embeds a second NUL for the origin path; a following ordinary
    // record must still parse, proving the stream didn't desync.
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream([
        Self.renamed("R.", from: "old.txt", to: "new.txt"),
        Self.ordinary(".M", "after.txt"),
      ])
    )
    #expect(snapshot.statuses["new.txt"]?.index == .modified)
    #expect(snapshot.statuses["after.txt"]?.worktree == .modified)
    // The origin token was consumed, not parsed as a bogus entry.
    #expect(snapshot.statuses["old.txt"] == nil)
  }

  @Test func pathWithSpacesIsPreserved() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".M", "my notes.txt")]))
    #expect(snapshot.statuses["my notes.txt"]?.worktree == .modified)
  }

  @Test func trailingNulProducesNoPhantomEntry() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".M", "a.txt")]))
    #expect(snapshot.statuses.count == 1)
  }

  // MARK: - Ancestor rollup

  @Test func changedFileRollsUpToEachAncestorDirectory() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".M", "a/b/c.txt")]))
    #expect(Set(snapshot.changedAncestors.keys) == ["a", "a/b"])
    // Every ancestor level rolls up, and the file itself is not an ancestor.
    #expect(snapshot.changedAncestors["a"] == .modified)
    #expect(snapshot.changedAncestors["a/b"] == .modified)
    #expect(snapshot.changedAncestors["a/b/c.txt"] == nil)
  }

  @Test func ignoredEntryDoesNotRollUp() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream(["! build/artifacts/"]))
    #expect(snapshot.changedAncestors.isEmpty)
  }

  // MARK: - Decoration resolution

  @Test func fileDecorationReflectsStateAndStagedness() {
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream([Self.ordinary("M.", "staged.txt"), Self.ordinary(".M", "dirty.txt")])
    )
    #expect(
      snapshot.decoration(for: "staged.txt", isDirectory: false, isExpanded: false)
        == .file(state: .modified, isStaged: true)
    )
    #expect(
      snapshot.decoration(for: "dirty.txt", isDirectory: false, isExpanded: false)
        == .file(state: .modified, isStaged: false)
    )
  }

  @Test func bothAxesDecorateFromTheStagedSide() {
    // Staged-modified then worktree-deleted: the staged index change wins the
    // letter, and the row reads as staged.
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary("MD", "a.txt")]))
    #expect(snapshot.statuses["a.txt"]?.index == .modified)
    #expect(snapshot.statuses["a.txt"]?.worktree == .deleted)
    #expect(
      snapshot.decoration(for: "a.txt", isDirectory: false, isExpanded: false)
        == .file(state: .modified, isStaged: true)
    )
  }

  @Test func untrackedFileDecoratesAsUnstagedAdd() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream(["? fresh.txt"]))
    #expect(
      snapshot.decoration(for: "fresh.txt", isDirectory: false, isExpanded: false)
        == .file(state: .added, isStaged: false)
    )
  }

  @Test func rmCachedFileDecoratesAsStagedDeletionNotAdded() {
    // `git rm --cached` reports a staged deletion plus an untracked working copy
    // for one path; the tracked deletion wins over the untracked side.
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream([Self.ordinary("D.", "rm-cached.txt"), "? rm-cached.txt"])
    )
    #expect(
      snapshot.decoration(for: "rm-cached.txt", isDirectory: false, isExpanded: false)
        == .file(state: .deleted, isStaged: true)
    )
  }

  @Test func rmCachedFolderRollsUpAsModifiedNotAdded() {
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream([Self.ordinary("D.", "dir/rm-cached.txt"), "? dir/rm-cached.txt"])
    )
    #expect(
      snapshot.decoration(for: "dir", isDirectory: true, isExpanded: false)
        == .file(state: .modified, isStaged: false)
    )
  }

  @Test func conflictDecoratesAsConflicted() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.unmerged("UU", "clash.txt")]))
    #expect(
      snapshot.decoration(for: "clash.txt", isDirectory: false, isExpanded: false)
        == .file(state: .conflicted, isStaged: false)
    )
  }

  @Test func collapsedDirectoryWithChangesReadsAsModifiedButExpandedDoesNot() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".M", "a/b/c.txt")]))
    #expect(
      snapshot.decoration(for: "a", isDirectory: true, isExpanded: false)
        == .file(state: .modified, isStaged: false)
    )
    #expect(snapshot.decoration(for: "a", isDirectory: true, isExpanded: true) == nil)
  }

  @Test func collapsedDirectoryOfOnlyAdditionsReadsAsAdded() {
    // Both an untracked file and a staged add roll up as an addition.
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream(["? new/a.txt", Self.ordinary("A.", "new/b.txt")])
    )
    #expect(
      snapshot.decoration(for: "new", isDirectory: true, isExpanded: false)
        == .file(state: .added, isStaged: false)
    )
  }

  @Test func collapsedDirectoryMixingAddsAndModificationsReadsAsModified() {
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream(["? mix/new.txt", Self.ordinary(".M", "mix/edited.txt")])
    )
    #expect(
      snapshot.decoration(for: "mix", isDirectory: true, isExpanded: false)
        == .file(state: .modified, isStaged: false)
    )
  }

  @Test func collapsedDirectoryOfIntentToAddReadsAsAdded() {
    // `git add -N` reports a worktree-axis add (`.A`); the folder must agree
    // with the file row, which renders it as added.
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".A", "add/new.txt")]))
    #expect(
      snapshot.decoration(for: "add", isDirectory: true, isExpanded: false)
        == .file(state: .added, isStaged: false)
    )
    #expect(
      snapshot.decoration(for: "add/new.txt", isDirectory: false, isExpanded: false)
        == .file(state: .added, isStaged: false)
    )
  }

  @Test func additionRollsUpAsAddedToEveryAncestorLevel() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream(["? a/b/c.txt"]))
    #expect(snapshot.changedAncestors["a"] == .added)
    #expect(snapshot.changedAncestors["a/b"] == .added)
  }

  @Test func siblingAdditionStaysAddedWhileParentModified() {
    // A modification and a nested addition under the same root: the root reads
    // modified, but the addition-only subfolder stays added.
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream([Self.ordinary(".M", "a/mod.txt"), "? a/sub/new.txt"])
    )
    #expect(
      snapshot.decoration(for: "a", isDirectory: true, isExpanded: false)
        == .file(state: .modified, isStaged: false)
    )
    #expect(
      snapshot.decoration(for: "a/sub", isDirectory: true, isExpanded: false)
        == .file(state: .added, isStaged: false)
    )
  }

  @Test func collapsedDirectoryOfOnlyDeletionsReadsAsModified() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary("D.", "a/gone.txt")]))
    #expect(
      snapshot.decoration(for: "a", isDirectory: true, isExpanded: false)
        == .file(state: .modified, isStaged: false)
    )
  }

  @Test func collapsedDirectoryOfOnlyConflictsReadsAsModified() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.unmerged("UU", "a/clash.txt")]))
    #expect(
      snapshot.decoration(for: "a", isDirectory: true, isExpanded: false)
        == .file(state: .modified, isStaged: false)
    )
  }

  @Test func ignoredPrefixDimsTheWholeSubtree() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream(["! node_modules/"]))
    #expect(snapshot.decoration(for: "node_modules", isDirectory: true, isExpanded: false) == .ignored)
    #expect(snapshot.decoration(for: "node_modules/lib/x.js", isDirectory: false, isExpanded: false) == .ignored)
    // A sibling that merely shares a name prefix is not dimmed.
    #expect(snapshot.decoration(for: "node_modules_backup", isDirectory: true, isExpanded: false) == nil)
  }

  @Test(arguments: ["build output", "缓存/编译", "cafe\u{301}/📦"])
  func ignoredAncestorsRespectPathBoundaries(root: String) {
    let snapshot = GitStatusSnapshot(ignoredPrefixes: [root])
    for path in [root, root + "/nested/file.txt"] {
      #expect(snapshot.decoration(for: path, isDirectory: false, isExpanded: false) == .ignored)
      #expect(snapshot.decoration(for: path, isDirectory: true, isExpanded: true) == .ignored)
    }
    for path in [root + "-backup/nested/file.txt", "parent/" + root + "/file.txt"] {
      #expect(snapshot.decoration(for: path, isDirectory: false, isExpanded: false) == nil)
    }
  }

  @Test func trackedChangeTakesPrecedenceOverIgnoredAncestor() {
    let path = "build/tracked.txt"
    let snapshot = GitStatusSnapshot(
      statuses: [path: GitFileStatus(index: .modified)], ignoredPrefixes: ["build"]
    )
    #expect(
      snapshot.decoration(for: path, isDirectory: false, isExpanded: false)
        == .file(state: .modified, isStaged: true)
    )
  }

  // MARK: - Discard classification

  private static func discardKind(_ records: [String]) -> GitDiscardKind? {
    GitStatusSnapshot.parse(porcelainV2: Self.stream(records)).statuses.values.first?.discardKind
  }

  @Test func discardKindRoutesEachState() {
    #expect(Self.discardKind(["? new.txt"]) == .trash)
    #expect(Self.discardKind([Self.ordinary("A.", "staged-new.txt")]) == .trash)
    #expect(Self.discardKind([Self.ordinary(".M", "mod.txt")]) == .restore)
    #expect(Self.discardKind([Self.ordinary("MM", "both.txt")]) == .restore)
    #expect(Self.discardKind([Self.unmerged("UU", "clash.txt")]) == nil)
    // `git rm --cached` reports a staged deletion AND an untracked working copy
    // for one path; it has a committed version, so discard restores, not trashes.
    #expect(Self.discardKind([Self.ordinary("D.", "rm-cached.txt"), "? rm-cached.txt"]) == .restore)
  }

  @Test func cleanPathHasNoDecoration() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".M", "a.txt")]))
    #expect(snapshot.decoration(for: "b.txt", isDirectory: false, isExpanded: false) == nil)
  }
}
