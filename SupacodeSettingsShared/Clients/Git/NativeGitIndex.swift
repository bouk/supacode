import CLibgit2
import Darwin
import Foundation

nonisolated extension NativeGitRepository {
  /// Stage one literal path. The standard Git index lock is held from the
  /// initial read through the final rename, so concurrent Git writers cannot
  /// have their updates overwritten.
  public static func stage(_ path: String, at directory: URL) throws {
    try NativeGitFilters.ensureInstalled()
    try GitFilterProcess.withSession {
      try withLockedIndex(at: directory) { repository, index in
        try validateIndexPath(path)
        guard let workdir = git_repository_workdir(repository) else { throw failure() }
        let absolute = String(cString: workdir) + path
        var statInfo = stat()
        if lstat(absolute, &statInfo) == 0 {
          var ignored: Int32 = 0
          guard git_ignore_path_is_ignored(&ignored, repository, path) == 0 else { throw failure() }
          if ignored != 0, !(0...3).contains(where: { git_index_get_bypath(index, path, Int32($0)) != nil }) {
            throw Failure(message: "The path is ignored")
          }
          guard git_index_add_bypath(index, path) == 0 else { throw failure() }
        } else if errno == ENOENT {
          guard (0...3).contains(where: { git_index_get_bypath(index, path, Int32($0)) != nil }) else {
            throw Failure(message: "The path does not match a tracked file")
          }
          guard git_index_remove_bypath(index, path) == 0 else { throw failure() }
        } else {
          throw Failure(message: "Unable to inspect the file")
        }
      }
    }
  }

  /// Restore one literal index entry from HEAD. On an unborn branch HEAD is
  /// the empty tree, matching `git reset -- <path>`.
  public static func unstage(_ path: String, at directory: URL) throws {
    try withLockedIndex(at: directory) { repository, index in
      try validateIndexPath(path)
      let conflictResult = git_index_conflict_remove(index, path)
      guard conflictResult == 0 || conflictResult == GIT_ENOTFOUND.rawValue else { throw failure() }
      var tree: OpaquePointer?
      let result = git_revparse_single(&tree, repository, "HEAD^{tree}")
      if result == 0, let tree {
        defer { git_object_free(tree) }
        var entry: OpaquePointer?
        let entryResult = git_tree_entry_bypath(&entry, tree, path)
        if entryResult == 0, let entry {
          defer { git_tree_entry_free(entry) }
          guard git_tree_entry_type(entry) != GIT_OBJECT_TREE, let oid = git_tree_entry_id(entry) else {
            throw Failure(message: "Expected a file path")
          }
          var indexEntry = git_index_entry()
          indexEntry.id = oid.pointee
          indexEntry.mode = UInt32(git_tree_entry_filemode(entry).rawValue)
          let status = path.withCString { pointer in
            indexEntry.path = pointer
            return git_index_add(index, &indexEntry)
          }
          guard status == 0 else { throw failure() }
          return
        }
        guard entryResult == GIT_ENOTFOUND.rawValue else { throw failure() }
      } else if result != GIT_ENOTFOUND.rawValue && result != GIT_EUNBORNBRANCH.rawValue {
        throw failure()
      }
      let removed = git_index_remove_bypath(index, path)
      guard removed == 0 || removed == GIT_ENOTFOUND.rawValue else { throw failure() }
    }
  }

  /// Restore one tracked path in both the working tree and index from HEAD.
  /// The index lock stays held while checkout filters and filesystem writes run.
  public static func discardTracked(_ path: String, at directory: URL) throws {
    try NativeGitFilters.ensureInstalled()
    try GitFilterProcess.withSession {
      try withLockedIndex(at: directory) { repository, index in
        try validateIndexPath(path)
        var tree: OpaquePointer?
        guard git_revparse_single(&tree, repository, "HEAD^{tree}") == 0, let tree else { throw failure() }
        defer { git_object_free(tree) }
        var entry: OpaquePointer?
        let entryResult = git_tree_entry_bypath(&entry, tree, path)
        defer { if let entry { git_tree_entry_free(entry) } }
        guard entryResult == 0 || entryResult == GIT_ENOTFOUND.rawValue else { throw failure() }
        if entryResult == GIT_ENOTFOUND.rawValue,
          !(0...3).contains(where: { git_index_get_bypath(index, path, Int32($0)) != nil })
        {
          throw Failure(message: "The path does not match a tracked file")
        }
        if let entry, git_tree_entry_type(entry) == GIT_OBJECT_TREE { throw Failure(message: "Expected a file path") }
        var checkout = git_checkout_options()
        guard git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)) == 0 else { throw failure() }
        checkout.checkout_strategy = UInt32(
          GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_RECREATE_MISSING.rawValue
            | GIT_CHECKOUT_DONT_UPDATE_INDEX.rawValue | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue)
        guard let value = strdup(path) else { throw Failure(message: "Unable to prepare file path") }
        defer { free(value) }
        var pointer: UnsafeMutablePointer<CChar>? = value
        let result = withUnsafeMutablePointer(to: &pointer) { paths in
          checkout.paths = git_strarray(strings: paths, count: 1)
          return git_checkout_tree(repository, tree, &checkout)
        }
        guard result == 0 else { throw failure() }
        let conflictResult = git_index_conflict_remove(index, path)
        guard conflictResult == 0 || conflictResult == GIT_ENOTFOUND.rawValue else { throw failure() }
        if let entry, let oid = git_tree_entry_id(entry) {
          var indexEntry = git_index_entry()
          indexEntry.id = oid.pointee
          indexEntry.mode = UInt32(git_tree_entry_filemode(entry).rawValue)
          let status = path.withCString { name in
            indexEntry.path = name
            return git_index_add(index, &indexEntry)
          }
          guard status == 0 else { throw failure() }
        } else {
          guard git_index_remove_bypath(index, path) == 0 else { throw failure() }
        }
      }
    }
  }

  private static func validateIndexPath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, !path.hasPrefix("/"),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" })
    else {
      throw Failure(message: "Invalid repository-relative path")
    }
  }

  private static func withLockedIndex(at directory: URL, _ body: (OpaquePointer, OpaquePointer) throws -> Void) throws {
    try withRepository(at: directory) { repository in
      var original: OpaquePointer?
      guard git_repository_index(&original, repository) == 0, let original else { throw failure() }
      defer { git_index_free(original) }
      guard let pointer = git_index_path(original) else { throw Failure(message: "Repository has no index path") }
      let indexPath = String(cString: pointer)
      let lockPath = indexPath + ".lock"
      let lockFD = open(lockPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
      guard lockFD >= 0 else {
        if errno == EEXIST { throw Failure(message: "index.lock is held by another Git process") }
        throw Failure(message: "Unable to lock the Git index")
      }
      var owned = stat()
      guard fstat(lockFD, &owned) == 0 else {
        close(lockFD)
        throw Failure(message: "Unable to inspect index lock")
      }
      var committed = false
      defer {
        close(lockFD)
        var current = stat()
        if !committed, lstat(lockPath, &current) == 0, current.st_dev == owned.st_dev, current.st_ino == owned.st_ino {
          unlink(lockPath)
        }
      }
      let temporary = indexPath + ".supacode-" + UUID().uuidString
      defer {
        unlink(temporary)
        unlink(temporary + ".lock")
      }
      let sourceFD = open(indexPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      if sourceFD >= 0 {
        defer { close(sourceFD) }
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
          throw Failure(message: "Git index is not a regular file")
        }
        let tempFD = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard tempFD >= 0 else { throw Failure(message: "Unable to create temporary Git index") }
        let copyResult = fcopyfile(sourceFD, tempFD, nil, copyfile_flags_t(COPYFILE_DATA))
        close(tempFD)
        guard copyResult == 0 else { throw Failure(message: "Unable to copy the Git index") }
        _ = fchmod(lockFD, sourceInfo.st_mode & 0o777)
      } else if errno != ENOENT {
        throw Failure(message: "Unable to read the Git index")
      }
      var index: OpaquePointer?
      guard git_index_open(&index, temporary) == 0, let index else { throw failure() }
      defer { git_index_free(index) }
      guard git_repository_set_index(repository, index) == 0 else { throw failure() }
      try body(repository, index)
      guard git_index_write(index) == 0 else { throw failure() }
      let resultFD = open(temporary, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard resultFD >= 0 else { throw Failure(message: "Unable to read updated Git index") }
      defer { close(resultFD) }
      guard fcopyfile(resultFD, lockFD, nil, copyfile_flags_t(COPYFILE_DATA)) == 0, fsync(lockFD) == 0 else {
        throw Failure(message: "Unable to write the Git index")
      }
      var current = stat()
      guard lstat(lockPath, &current) == 0, current.st_dev == owned.st_dev, current.st_ino == owned.st_ino else {
        throw Failure(message: "Git index lock was replaced")
      }
      guard rename(lockPath, indexPath) == 0 else { throw Failure(message: "Unable to replace the Git index") }
      committed = true
    }
  }
}
