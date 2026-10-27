import CLibgit2
import Foundation

nonisolated extension NativeGitRepository {
  public enum Change: Sendable {
    case added, modified, deleted
  }

  public struct StatusEntry: Sendable {
    public let path: String
    public let index: Change?
    public let worktree: Change?
    public let untracked: Bool
    public let conflicted: Bool
    public let ignored: Bool
  }

  /// Compare HEAD with the combined index and working directory, excluding
  /// untracked files, as `git diff HEAD --shortstat` does.
  public static func lineChanges(at directory: URL) throws -> (added: Int, removed: Int) {
    try NativeGitFilters.ensureInstalled()
    return try GitFilterProcess.withSession {
      try withRepository(at: directory) { repository in
        var object: OpaquePointer?
        guard git_revparse_single(&object, repository, "HEAD^{tree}") == 0, let object else { throw failure() }
        defer { git_object_free(object) }
        var diff: OpaquePointer?
        guard git_diff_tree_to_workdir_with_index(&diff, repository, object, nil) == 0, let diff else {
          throw failure()
        }
        defer { git_diff_free(diff) }
        guard git_diff_find_similar(diff, nil) == 0 else { throw failure() }
        var stats: OpaquePointer?
        guard git_diff_get_stats(&stats, diff) == 0, let stats else { throw failure() }
        defer { git_diff_stats_free(stats) }
        return (Int(git_diff_stats_insertions(stats)), Int(git_diff_stats_deletions(stats)))
      }
    }
  }

  /// Enumerate untracked and ignored files using the repository's standard
  /// excludes, descending into directories just like `ls-files --others`.
  public static func otherFileCount(at directory: URL, ignored: Bool) throws -> Int {
    try otherFiles(at: directory, ignored: ignored).count
  }

  public static func otherFiles(at directory: URL, ignored: Bool) throws -> [String] {
    try NativeGitFilters.ensureInstalled()
    return try GitFilterProcess.withSession {
      try withRepository(at: directory) { repository in
        var options = git_status_options()
        guard git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)) == 0 else { throw failure() }
        options.show = GIT_STATUS_SHOW_WORKDIR_ONLY
        options.flags = ignored
          ? UInt32(
            GIT_STATUS_OPT_INCLUDE_IGNORED.rawValue | GIT_STATUS_OPT_RECURSE_IGNORED_DIRS.rawValue
              | GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue)
          : UInt32(GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue)
        var statuses: OpaquePointer?
        guard git_status_list_new(&statuses, repository, &options) == 0, let statuses else { throw failure() }
        defer { git_status_list_free(statuses) }
        var paths: [String] = []
        let mask = UInt32(ignored ? GIT_STATUS_IGNORED.rawValue : GIT_STATUS_WT_NEW.rawValue)
        for index in 0..<git_status_list_entrycount(statuses) {
          guard let entry = git_status_byindex(statuses, index) else { continue }
          let flags = UInt32(entry.pointee.status.rawValue)
          if flags & mask != 0, let path = entry.pointee.index_to_workdir?.pointee.new_file.path {
            paths.append(String(cString: path))
          }
        }
        return paths
      }
    }
  }

  /// Evaluate only the supplied ignore rules, without the source repository's
  /// .gitignore files or the user's global excludes.
  public static func excludedPaths(_ paths: [String], patterns: String, at directory: URL) throws -> Set<String> {
    try withRepository(at: directory) { source in
      let temporary = FileManager.default.temporaryDirectory.appending(path: "supacode-ignore-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: temporary) }
      var repository: OpaquePointer?
      guard git_repository_init(&repository, temporary.path(percentEncoded: false), 1) == 0, let repository else {
        throw failure()
      }
      defer { git_repository_free(repository) }
      var config: OpaquePointer?
      guard git_repository_config(&config, repository) == 0, let config else { throw failure() }
      defer { git_config_free(config) }
      guard git_config_set_string(config, "core.excludesfile", "/dev/null") == 0 else { throw failure() }
      var sourceConfig: OpaquePointer?
      guard git_repository_config_snapshot(&sourceConfig, source) == 0, let sourceConfig else { throw failure() }
      defer { git_config_free(sourceConfig) }
      var ignoreCase: Int32 = 0
      if git_config_get_bool(&ignoreCase, sourceConfig, "core.ignorecase") == 0 {
        guard git_config_set_bool(config, "core.ignorecase", ignoreCase) == 0 else { throw failure() }
      }
      guard git_ignore_add_rule(repository, patterns) == 0 else { throw failure() }
      var excluded: Set<String> = []
      var ignoredDirectories: [String: Bool] = [:]
      for path in paths {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var ancestor = ""
        var matched = false
        for component in components.dropLast() {
          ancestor += String(component) + "/"
          let isIgnored: Bool
          if let cached = ignoredDirectories[ancestor] {
            isIgnored = cached
          } else {
            var ignored: Int32 = 0
            guard git_ignore_path_is_ignored(&ignored, repository, ancestor) == 0 else { throw failure() }
            isIgnored = ignored != 0
            ignoredDirectories[ancestor] = isIgnored
          }
          if isIgnored { matched = true; break }
        }
        if !matched {
          var ignored: Int32 = 0
          guard git_ignore_path_is_ignored(&ignored, repository, path) == 0 else { throw failure() }
          matched = ignored != 0
        }
        if matched { excluded.insert(path) }
      }
      return excluded
    }
  }

  public static func status(at directory: URL) throws -> [StatusEntry] {
    try NativeGitFilters.ensureInstalled()
    return try GitFilterProcess.withSession {
      try withRepository(at: directory) { repository in
        var options = git_status_options()
        guard git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)) == 0 else { throw failure() }
        options.flags = UInt32(
          GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_INCLUDE_IGNORED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue | GIT_STATUS_OPT_SORT_CASE_SENSITIVELY.rawValue)
        var statuses: OpaquePointer?
        guard git_status_list_new(&statuses, repository, &options) == 0, let statuses else { throw failure() }
        defer { git_status_list_free(statuses) }
        return (0..<git_status_list_entrycount(statuses)).compactMap { index in
          guard let entry = git_status_byindex(statuses, index) else { return nil }
          let flags = UInt32(entry.pointee.status.rawValue)
          let worktreePath = entry.pointee.index_to_workdir?.pointee.new_file.path
          let indexPath = entry.pointee.head_to_index?.pointee.new_file.path
          guard let path = worktreePath ?? indexPath else { return nil }
          let indexChange: Change? =
            flags & UInt32(GIT_STATUS_INDEX_NEW.rawValue) != 0
            ? .added
            : flags & UInt32(GIT_STATUS_INDEX_DELETED.rawValue) != 0
              ? .deleted
              : flags
                & UInt32(
                  GIT_STATUS_INDEX_MODIFIED.rawValue | GIT_STATUS_INDEX_TYPECHANGE.rawValue
                    | GIT_STATUS_INDEX_RENAMED.rawValue) != 0 ? .modified : nil
          let worktreeChange: Change? =
            flags & UInt32(GIT_STATUS_WT_DELETED.rawValue) != 0
            ? .deleted
            : flags
              & UInt32(
                GIT_STATUS_WT_MODIFIED.rawValue | GIT_STATUS_WT_TYPECHANGE.rawValue
                  | GIT_STATUS_WT_RENAMED.rawValue) != 0 ? .modified : nil
          return StatusEntry(
            path: String(cString: path), index: indexChange, worktree: worktreeChange,
            untracked: flags & UInt32(GIT_STATUS_WT_NEW.rawValue) != 0,
            conflicted: flags & UInt32(GIT_STATUS_CONFLICTED.rawValue) != 0,
            ignored: flags & UInt32(GIT_STATUS_IGNORED.rawValue) != 0
          )
        }
      }
    }
  }
}
