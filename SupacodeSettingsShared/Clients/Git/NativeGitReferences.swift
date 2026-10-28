import CLibgit2
import Foundation

nonisolated extension NativeGitRepository {
  public struct Branch: Sendable {
    public let referenceName: String
    public let name: String
    public let upstream: String?
  }

  public static func isBare(at directory: URL) throws -> Bool {
    try withRepository(at: directory) { git_repository_is_bare($0) != 0 }
  }

  /// Read a file from a treeish without consulting the working tree.
  public static func committedFile(at directory: URL, ref: String, path: String) throws -> Data? {
    try withRepository(at: directory) { repository in
      var object: OpaquePointer?
      guard git_revparse_single(&object, repository, ref) == 0, let object else { throw failure() }
      defer { git_object_free(object) }
      var tree: OpaquePointer?
      guard git_object_peel(&tree, object, GIT_OBJECT_TREE) == 0, let tree else { throw failure() }
      defer { git_object_free(tree) }
      var entry: OpaquePointer?
      let lookup = git_tree_entry_bypath(&entry, tree, path)
      if lookup == GIT_ENOTFOUND.rawValue { return nil }
      guard lookup == 0, let entry else { throw failure() }
      defer { git_tree_entry_free(entry) }
      guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return nil }
      var blob: OpaquePointer?
      guard git_blob_lookup(&blob, repository, git_tree_entry_id(entry)) == 0, let blob else { throw failure() }
      defer { git_blob_free(blob) }
      let size = Int(git_blob_rawsize(blob))
      guard size > 0 else { return Data() }
      guard let bytes = git_blob_rawcontent(blob) else { throw failure() }
      return Data(bytes: bytes, count: size)
    }
  }

  /// Disable upstream resolution for name-only queries: libgit2 snapshots the
  /// repository configuration for each upstream, even when it is not consumed.
  public static func branches(at directory: URL, remote: Bool, includeUpstream: Bool = true) throws -> [Branch] {
    try withRepository(at: directory) { repository in
      var iterator: OpaquePointer?
      guard git_branch_iterator_new(&iterator, repository, remote ? GIT_BRANCH_REMOTE : GIT_BRANCH_LOCAL) == 0,
        let iterator
      else { throw failure() }
      defer { git_branch_iterator_free(iterator) }
      var result: [(full: String, branch: Branch)] = []
      while true {
        var ref: OpaquePointer?
        var type = remote ? GIT_BRANCH_REMOTE : GIT_BRANCH_LOCAL
        let status = git_branch_next(&ref, &type, iterator)
        if status == GIT_ITEROVER.rawValue { break }
        guard status == 0, let ref else { throw failure() }
        defer { git_reference_free(ref) }
        guard let fullPointer = git_reference_name(ref) else { continue }
        let full = String(cString: fullPointer)
        var upstream = git_buf()
        defer { git_buf_dispose(&upstream) }
        let hasUpstream = includeUpstream && !remote && git_branch_upstream_name(&upstream, repository, full) == 0
        let upstreamName = hasUpstream && upstream.ptr != nil ? String(cString: upstream.ptr) : nil
        result.append(
          (
            full,
            Branch(
              referenceName: full,
              name: shortReference(repository, full),
              upstream: upstreamName.map { shortReference(repository, $0) }
            )
          ))
      }
      return result.sorted { $0.full.utf8.lexicographicallyPrecedes($1.full.utf8) }.map(\.branch)
    }
  }

  /// Actual branch names for collision checks, even when a tag shares a name.
  public static func localBranchNames(at directory: URL) throws -> Set<String> {
    Set(try branches(at: directory, remote: false, includeUpstream: false).map {
      String($0.referenceName.dropFirst("refs/heads/".count)).lowercased()
    })
  }

  public static func remoteNames(at directory: URL) throws -> [String] {
    try withRepository(at: directory) { repository in
      var names = git_strarray()
      guard git_remote_list(&names, repository) == 0 else { throw failure() }
      defer { git_strarray_dispose(&names) }
      guard let strings = names.strings else { return [] }
      return (0..<names.count).compactMap { strings[$0].map { String(cString: $0) } }
        .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
  }

  /// A remote explicitly selected by a CLI through a remote.<name> config key.
  public static func configuredRemote(at directory: URL, marker: String) throws -> (url: String, value: String)? {
    try withRepository(at: directory) { repository in
      var config: OpaquePointer?
      guard git_repository_config_snapshot(&config, repository) == 0, let config else { throw failure() }
      defer { git_config_free(config) }
      var remotes = git_strarray()
      guard git_remote_list(&remotes, repository) == 0 else { throw failure() }
      defer { git_strarray_dispose(&remotes) }
      guard let names = remotes.strings else { return nil }
      for index in 0..<remotes.count {
        guard let name = names[index] else { continue }
        var value = git_buf()
        defer { git_buf_dispose(&value) }
        let key = "remote.\(String(cString: name)).\(marker)"
        guard git_config_get_string_buf(&value, config, key) == 0, let text = value.ptr else { continue }
        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, repository, name) == 0, let remote else { continue }
        defer { git_remote_free(remote) }
        guard let url = git_remote_url(remote) else { continue }
        return (String(cString: url), String(cString: text))
      }
      return nil
    }
  }

  /// Fetch URLs in Git's remote-list order, with origin preferred and
  /// `url.*.insteadOf` rewrites applied by libgit2.
  public static func remoteURLs(at directory: URL) throws -> [String] {
    try withRepository(at: directory) { repository in
      var names = git_strarray()
      guard git_remote_list(&names, repository) == 0 else { throw failure() }
      defer { git_strarray_dispose(&names) }
      guard let strings = names.strings else { return [] }
      var ordered = (0..<names.count).compactMap { strings[$0].map { String(cString: $0) } }
        .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
      if let origin = ordered.firstIndex(of: "origin") {
        ordered.remove(at: origin)
        ordered.insert("origin", at: 0)
      }
      var config: OpaquePointer?
      guard git_repository_config_snapshot(&config, repository) == 0, let config else { throw failure() }
      defer { git_config_free(config) }
      return ordered.compactMap { name in
        // Git uses the first fetch URL when a remote has several; libgit2's
        // named remote lookup instead selects the last config value.
        var iterator: OpaquePointer?
        guard git_config_multivar_iterator_new(&iterator, config, "remote.\(name).url", nil) == 0,
          let iterator
        else { return nil }
        defer { git_config_iterator_free(iterator) }
        var entry: UnsafeMutablePointer<git_config_entry>?
        guard git_config_next(&entry, iterator) == 0, let value = entry?.pointee.value else { return nil }
        var remote: OpaquePointer?
        guard git_remote_create_anonymous(&remote, repository, value) == 0, let remote else { return nil }
        defer { git_remote_free(remote) }
        return git_remote_url(remote).map { String(cString: $0) }
      }
    }
  }

  public static func defaultRemoteBranch(at directory: URL) throws -> String? {
    try withRepository(at: directory) { repository in
      var symbolic: OpaquePointer?
      if git_reference_lookup(&symbolic, repository, "refs/remotes/origin/HEAD") == 0, let symbolic {
        defer { git_reference_free(symbolic) }
        if let target = git_reference_symbolic_target(symbolic) {
          let name = String(cString: target)
          if referenceExists(repository, name) {
            let prefix = "refs/remotes/"
            return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
          }
        }
      }
      return referenceExists(repository, "origin/main") ? "origin/main" : nil
    }
  }

  public static func localHead(at directory: URL) throws -> String? {
    try withRepository(at: directory) { repository in
      var head: OpaquePointer?
      guard git_repository_head(&head, repository) == 0, let head else { return nil }
      defer { git_reference_free(head) }
      guard git_reference_is_branch(head) != 0, let name = git_reference_name(head) else { return nil }
      return shortReference(repository, String(cString: name))
    }
  }

  public static func symbolicHead(at directory: URL) throws -> String? {
    try withRepository(at: directory) { repository in
      var head: OpaquePointer?
      guard git_repository_head(&head, repository) == 0, let head else { return nil }
      defer { git_reference_free(head) }
      guard git_reference_is_branch(head) != 0, let name = git_reference_name(head) else { return "HEAD" }
      return shortReference(repository, String(cString: name))
    }
  }

  public static func validBranchName(_ name: String, at directory: URL) throws -> Bool {
    try withRepository(at: directory) { repository in
      var candidate = name
      if name.hasPrefix("@{-"), name.hasSuffix("}") {
        var object: OpaquePointer?
        var reference: OpaquePointer?
        guard git_revparse_ext(&object, &reference, repository, name) == 0 else { return false }
        defer { if let object { git_object_free(object) }; if let reference { git_reference_free(reference) } }
        guard let reference, let shortName = git_reference_shorthand(reference) else { return false }
        candidate = String(cString: shortName)
      }
      var valid: Int32 = 0
      guard git_branch_name_is_valid(&valid, candidate) == 0 else { throw failure() }
      return valid != 0
    }
  }

  public static func renameBranch(_ oldName: String, to newName: String, at directory: URL) throws {
    try withRepository(at: directory) { repository in
      var branch: OpaquePointer?
      guard git_branch_lookup(&branch, repository, oldName, GIT_BRANCH_LOCAL) == 0, let branch else { throw failure() }
      defer { git_reference_free(branch) }
      var renamed: OpaquePointer?
      guard git_branch_move(&renamed, branch, newName, 0) == 0 else { throw failure() }
      if let renamed { git_reference_free(renamed) }
    }
  }

  public static func deleteBranch(_ name: String, at directory: URL) throws {
    try withRepository(at: directory) { repository in
      var branch: OpaquePointer?
      guard git_branch_lookup(&branch, repository, name, GIT_BRANCH_LOCAL) == 0, let branch else { throw failure() }
      defer { git_reference_free(branch) }
      guard git_branch_delete(branch) == 0 else { throw failure() }
    }
  }

  public static func setUpstream(_ upstream: String?, for branchName: String, at directory: URL) throws {
    try withRepository(at: directory) { repository in
      var branch: OpaquePointer?
      let lookup = git_branch_lookup(&branch, repository, branchName, GIT_BRANCH_LOCAL)
      if lookup == GIT_ENOTFOUND.rawValue, upstream == nil { return }
      guard lookup == 0, let branch else { throw failure() }
      defer { git_reference_free(branch) }
      if upstream == nil {
        var name = git_buf()
        defer { git_buf_dispose(&name) }
        let result = git_branch_upstream_name(&name, repository, git_reference_name(branch))
        if result == GIT_ENOTFOUND.rawValue { return }
        guard result == 0 else { throw failure() }
      }
      if let upstream, upstream.hasPrefix("refs/remotes/") {
        try setQualifiedRemoteUpstream(upstream, branch: branch, repository: repository)
        return
      }
      let shortUpstream = upstream.map { value in
        for prefix in ["refs/heads/", "refs/remotes/"] where value.hasPrefix(prefix) {
          return String(value.dropFirst(prefix.count))
        }
        return value
      }
      let result = shortUpstream.map { value in
        value.withCString { git_branch_set_upstream(branch, $0) }
      } ?? git_branch_set_upstream(branch, nil)
      guard result == 0 else { throw failure() }
    }
  }

  private static func setQualifiedRemoteUpstream(
    _ upstream: String, branch: OpaquePointer, repository: OpaquePointer
  ) throws {
    var reference: OpaquePointer?
    guard git_reference_lookup(&reference, repository, upstream) == 0, let reference else { throw failure() }
    defer { git_reference_free(reference) }
    var remoteName = git_buf()
    defer { git_buf_dispose(&remoteName) }
    guard git_branch_remote_name(&remoteName, repository, upstream) == 0, let remoteNamePointer = remoteName.ptr
    else { throw failure() }
    var remote: OpaquePointer?
    guard git_remote_lookup(&remote, repository, remoteNamePointer) == 0, let remote else { throw failure() }
    defer { git_remote_free(remote) }
    var merge = git_buf()
    defer { git_buf_dispose(&merge) }
    var found = false
    for index in 0..<git_remote_refspec_count(remote) {
      guard let refspec = git_remote_get_refspec(remote, index),
        git_refspec_direction(refspec) == GIT_DIRECTION_FETCH,
        git_refspec_dst_matches(refspec, upstream) != 0 else { continue }
      guard git_refspec_rtransform(&merge, refspec, upstream) == 0 else { throw failure() }
      found = true
      break
    }
    guard found, let mergePointer = merge.ptr, let branchPointer = git_reference_name(branch) else {
      throw Failure(message: "Unable to determine the upstream branch")
    }
    let branchRef = String(cString: branchPointer)
    let shortName = String(branchRef.dropFirst("refs/heads/".count))
    var config: OpaquePointer?
    guard git_repository_config(&config, repository) == 0, let config else { throw failure() }
    defer { git_config_free(config) }
    guard git_config_set_string(config, "branch.\(shortName).remote", remoteNamePointer) == 0,
      git_config_set_string(config, "branch.\(shortName).merge", mergePointer) == 0
    else { throw failure() }
  }

  public static func upstreamExists(_ name: String, at directory: URL) throws -> Bool {
    try withRepository(at: directory) { repository in
      let qualified = name.hasPrefix("refs/heads/") || name.hasPrefix("refs/remotes/")
      let candidates = qualified ? [name] : ["refs/heads/\(name)", "refs/remotes/\(name)"]
      for candidate in candidates {
        var reference: OpaquePointer?
        let result = git_reference_lookup(&reference, repository, candidate)
        if result == GIT_ENOTFOUND.rawValue || result == GIT_EINVALIDSPEC.rawValue { continue }
        guard result == 0, let reference else { throw failure() }
        defer { git_reference_free(reference) }
        var resolved: OpaquePointer?
        let resolve = git_reference_resolve(&resolved, reference)
        if resolve == GIT_ENOTFOUND.rawValue { continue }
        guard resolve == 0, let resolved else { throw failure() }
        git_reference_free(resolved)
        return true
      }
      return false
    }
  }

  private static func referenceExists(_ repository: OpaquePointer, _ name: String) -> Bool {
    var object: OpaquePointer?
    let result = git_revparse_single(&object, repository, name)
    if let object { git_object_free(object) }
    return result == 0
  }

  private static func shortReference(_ repository: OpaquePointer, _ full: String) -> String {
    let prefixes = ["refs/heads/", "refs/remotes/", "refs/tags/"]
    guard let prefix = prefixes.first(where: { full.hasPrefix($0) }) else { return full }
    let name = String(full.dropFirst(prefix.count))
    let category = String(prefix.dropFirst("refs/".count))
    for candidate in [name, category + name, full] {
      let possibilities = Set([
        candidate, "refs/" + candidate, "refs/tags/" + candidate,
        "refs/heads/" + candidate, "refs/remotes/" + candidate,
        "refs/remotes/" + candidate + "/HEAD",
      ])
      var matches = Set<String>()
      for possibility in possibilities {
        var reference: OpaquePointer?
        if git_reference_lookup(&reference, repository, possibility) == 0 {
          matches.insert(possibility)
          if let reference { git_reference_free(reference) }
        }
      }
      if matches.isEmpty || matches == [full] { return candidate }
    }
    return full
  }
}
