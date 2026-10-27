import CLibgit2
import Foundation

/// Operations that access the repository directly through libgit2.
public nonisolated enum NativeGitRepository {
  public struct Failure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
  }

  /// Return the root of the main checkout (or the bare repository), even when
  /// called from a linked checkout or a directory beneath it.
  public static func root(at directory: URL) throws -> URL {
    try withRepository(at: directory) { repository in
      guard let common = git_repository_commondir(repository) else { throw failure() }
      var main: OpaquePointer?
      guard git_repository_open(&main, common) == 0, let main else { throw failure() }
      defer { git_repository_free(main) }
      guard let root = git_repository_is_bare(main) != 0 ? common : git_repository_workdir(main),
        let physical = realpath(root, nil)
      else { throw failure() }
      defer { free(physical) }
      return URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }
  }

  public static func commonDirectory(at directory: URL) throws -> URL {
    try withRepository(at: directory) { repository in
      guard let path = git_repository_commondir(repository) else { throw failure() }
      return URL(fileURLWithPath: String(cString: path), isDirectory: true).standardizedFileURL
    }
  }

  public static func fetch(_ remote: String, at directory: URL) throws {
    try withRepository(at: directory) { repository in
      guard GitNativeFetch.fetch(repository: repository, name: remote) == 0 else { throw failure() }
    }
  }

  /// Remove one explicitly identified linked worktree, never other entries.
  public static func removeWorktree(at directory: URL, name: String, removeWorkingDirectory: Bool) throws {
    try withRepository(at: directory) { repository in
      var worktree: OpaquePointer?
      guard git_worktree_lookup(&worktree, repository, name) == 0, let worktree else { throw failure() }
      defer { git_worktree_free(worktree) }
      var options = git_worktree_prune_options()
      guard git_worktree_prune_options_init(&options, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION)) == 0 else {
        throw failure()
      }
      options.flags = UInt32(GIT_WORKTREE_PRUNE_VALID.rawValue | GIT_WORKTREE_PRUNE_LOCKED.rawValue)
      if removeWorkingDirectory { options.flags |= UInt32(GIT_WORKTREE_PRUNE_WORKING_TREE.rawValue) }
      guard git_worktree_prune(worktree, &options) == 0 else { throw failure() }
    }
  }

  /// Prune a missing linked worktree only when its .git backlink is absent.
  /// libgit2 rechecks the lock before removing metadata.
  public static func pruneMissingWorktree(at directory: URL, name: String) throws {
    try withRepository(at: directory) { repository in
      var worktree: OpaquePointer?
      guard git_worktree_lookup(&worktree, repository, name) == 0, let worktree else { throw failure() }
      defer { git_worktree_free(worktree) }
      guard let path = git_worktree_path(worktree) else { throw failure() }
      let backlink = URL(fileURLWithPath: String(cString: path), isDirectory: true).appending(path: ".git")
      if FileManager.default.fileExists(atPath: backlink.path(percentEncoded: false)) { return }
      var options = git_worktree_prune_options()
      guard git_worktree_prune_options_init(&options, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION)) == 0 else {
        throw failure()
      }
      // libgit2 regards an existing directory as valid even without its .git
      // backlink, whereas Git's prune reclaims that broken entry.
      options.flags = UInt32(GIT_WORKTREE_PRUNE_VALID.rawValue)
      let prunable = git_worktree_is_prunable(worktree, &options)
      if prunable == 0 { return }
      guard prunable > 0 else { throw failure() }
      guard git_worktree_prune(worktree, &options) == 0 else { throw failure() }
    }
  }

  static func withRepository<T>(at directory: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
    guard git_libgit2_init() >= 0 else { throw failure() }
    defer { git_libgit2_shutdown() }
    var repository: OpaquePointer?
    guard git_repository_open_ext(&repository, directory.path(percentEncoded: false), 0, nil) == 0,
      let repository
    else { throw failure() }
    defer { git_repository_free(repository) }
    return try body(repository)
  }

  static func failure() -> Failure {
    let message = git_error_last().flatMap { $0.pointee.message }.map { String(cString: $0) }
    return Failure(message: message ?? "Unable to access repository")
  }
}
