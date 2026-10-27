import CLibgit2
import Darwin
import Foundation

/// A private, per-repository checkout. Preparation is deliberately independent
/// of user worktrees: it never removes or resets an existing directory.
enum WTPrewarm {
  private struct Marker: Codable {
    let owner: String
    let version: Int
    let worktree: String
    let adminName: String
    var claimDestination: String? = nil
    var claimBranch: String? = nil
  }

  static func prepare(root: String, baseRef: String) throws {
    try NativeWT.Repository.withRepository(at: root) { repository in
      guard let common = git_repository_commondir(repository) else { throw NativeWT.Repository.failure() }
      let commonPath = try NativeWT.Repository.physicalPath(common)
      let pool = commonPath + "/supacode-prewarm"
      try makePrivateDirectory(pool)
      let lockPath = pool + "/lock"
      let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw NativeWT.Failure("unable to open prewarm lock") }
      defer { close(fd) }
      if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        if errno == EWOULDBLOCK || errno == EAGAIN { return }
        throw NativeWT.Failure("unable to lock prewarm checkout")
      }
      defer { flock(fd, LOCK_UN) }
      let path = pool + "/worktree"
      let markerPath = pool + "/owner.json"
      let fm = FileManager.default
      if pathExists(markerPath) {
        // Never replace an existing checkout, even if it appears damaged or
        // dirty. A future claim must validate the marker and checkout first.
        let data = try Data(contentsOf: URL(fileURLWithPath: markerPath))
        let marker = try JSONDecoder().decode(Marker.self, from: data)
        guard marker.owner == "supacode", marker.version == 1, marker.worktree == path else {
          throw NativeWT.Failure("unrecognized prewarm checkout")
        }
        if fm.fileExists(atPath: path + "/.git") { return }
        // A claim may have been interrupted after the directory was moved.
        // Repair only the administrative back-reference after verifying both
        // sides of the link, then leave the recovered checkout untouched.
        guard !pathExists(path), let destination = marker.claimDestination,
          try recoverMovedCheckout(marker: marker, common: commonPath, destination: destination) else {
          throw NativeWT.Failure("unrecognized prewarm checkout")
        }
        try fm.removeItem(atPath: markerPath)
      }
      guard !pathExists(path) else { throw NativeWT.Failure("prewarm path is already in use") }
      try NativeWT.Repository.createWorktree(
        at: root, path: path, branch: "", baseRef: baseRef, existing: false, runHook: false, lock: true)
      guard let entry = try NativeWT.Repository.worktrees(at: root).first(where: { $0.path == path }),
        let adminName = entry.adminName else { throw NativeWT.Failure("unable to identify prewarm checkout") }
      // Git installs the ownership lock before checkout begins.
      var prepared: OpaquePointer?
      guard git_worktree_lookup(&prepared, repository, adminName) == 0, let prepared else {
        throw NativeWT.Repository.failure()
      }
      defer { git_worktree_free(prepared) }
      var currentReason = git_buf()
      defer { git_buf_dispose(&currentReason) }
      guard git_worktree_is_locked(&currentReason, prepared) == 1,
        let text = currentReason.ptr, let data = String(cString: text).data(using: .utf8),
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        object["owner"] as? String == "supacode" else {
        throw NativeWT.Failure("prewarm checkout lock changed during preparation")
      }
      let marker = Marker(owner: "supacode", version: 1, worktree: path, adminName: adminName)
      let markerFD = open(markerPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard markerFD >= 0 else { throw NativeWT.Failure("unable to claim prewarm marker") }
      let markerFile = FileHandle(fileDescriptor: markerFD, closeOnDealloc: true)
      defer { try? markerFile.close() }
      try markerFile.write(contentsOf: JSONEncoder().encode(marker))
    }
  }

  /// Claim only a verified, pristine checkout. Before the rename all failures
  /// fall back to normal creation; after it, errors are surfaced so the moved
  /// directory is never silently overwritten or discarded.
  static func claim(root: String, destination: String, branch: String, baseRef: String) throws -> Bool {
    try NativeWT.Repository.withRepository(at: root) { repository in
      guard let common = git_repository_commondir(repository) else { return false }
      let commonPath = try NativeWT.Repository.physicalPath(common)
      let pool = commonPath + "/supacode-prewarm"
      var directory = stat()
      guard lstat(pool, &directory) == 0, (directory.st_mode & S_IFMT) == S_IFDIR else { return false }
      let fd = open(pool + "/lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { return false }
      defer { close(fd) }
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
      defer { flock(fd, LOCK_UN) }
      let path = pool + "/worktree"
      let markerPath = pool + "/owner.json"
      var markerInfo = stat()
      guard lstat(markerPath, &markerInfo) == 0, (markerInfo.st_mode & S_IFMT) == S_IFREG,
        let data = try? Data(contentsOf: URL(fileURLWithPath: markerPath)),
        let marker = try? JSONDecoder().decode(Marker.self, from: data),
        marker.owner == "supacode", marker.version == 1, marker.worktree == path,
        !marker.adminName.isEmpty, !marker.adminName.contains("/"),
        marker.adminName != ".", marker.adminName != "..", !pathExists(destination) else { return false }
      var tree: OpaquePointer?
      guard git_worktree_lookup(&tree, repository, marker.adminName) == 0, let tree else { return false }
      defer { git_worktree_free(tree) }
      guard let registeredPath = git_worktree_path(tree), String(cString: registeredPath) == path,
        git_worktree_validate(tree) == 0 else { return false }
      var lockReason = git_buf()
      defer { git_buf_dispose(&lockReason) }
      let lockStatus = git_worktree_is_locked(&lockReason, tree)
      guard lockStatus >= 0 else { return false }
      if lockStatus == 1 {
        guard let text = lockReason.ptr,
          let data = String(cString: text).data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          object["owner"] as? String == "supacode" else { return false }
      }
      var worktreeInfo = stat()
      var linkInfo = stat()
      guard lstat(path, &worktreeInfo) == 0, (worktreeInfo.st_mode & S_IFMT) == S_IFDIR,
        lstat(path + "/.git", &linkInfo) == 0, (linkInfo.st_mode & S_IFMT) == S_IFREG else { return false }
      let admin = commonPath + "/worktrees/" + marker.adminName
      var adminInfo = stat()
      var gitdirInfo = stat()
      guard lstat(admin, &adminInfo) == 0, (adminInfo.st_mode & S_IFMT) == S_IFDIR,
        lstat(admin + "/gitdir", &gitdirInfo) == 0, (gitdirInfo.st_mode & S_IFMT) == S_IFREG else { return false }
      var checkout: OpaquePointer?
      guard git_repository_open(&checkout, path) == 0, let checkout else { return false }
      defer { git_repository_free(checkout) }
      guard git_repository_is_worktree(checkout) != 0, git_repository_head_detached(checkout) == 1,
        let actualAdmin = git_repository_path(checkout),
        (try? NativeWT.Repository.physicalPath(actualAdmin)) == admin else { return false }
      guard (try? WTGit.isClean(at: path)) == true else { return false }
      var object: OpaquePointer?
      let revision = baseRef.isEmpty ? "HEAD^{commit}" : "\(baseRef)^{commit}"
      guard git_revparse_single(&object, repository, revision) == 0, let object else { return false }
      defer { git_object_free(object) }
      guard let objectID = git_object_id(object), let hex = git_oid_tostr_s(objectID) else { return false }
      let commit = String(cString: hex)
      try WTGit.run(
        at: path, arguments: ["-c", "core.hooksPath=/dev/null", "checkout", "--detach", "--progress", commit],
        progress: true)
      // Record the destination before moving so a crash cannot make the
      // checkout's location unknowable. A stranded claim is left untouched
      // for recovery; it is never silently recreated or discarded.
      var journal = marker
      journal.claimDestination = destination
      journal.claimBranch = branch
      try JSONEncoder().encode(journal).write(to: URL(fileURLWithPath: markerPath), options: .atomic)
      do {
        if lockStatus == 1 { try WTGit.run(at: root, arguments: ["worktree", "unlock", path]) }
        try WTGit.run(at: root, arguments: ["worktree", "move", path, destination])
      } catch {
        if pathExists(path), !pathExists(destination) {
          try? WTGit.run(at: root, arguments: ["worktree", "lock", "--reason={\"owner\":\"supacode\"}", path])
          try JSONEncoder().encode(marker).write(to: URL(fileURLWithPath: markerPath), options: .atomic)
          return false
        }
        throw error
      }
      // Git creates the branch and invokes post-checkout; retain the journal
      // if either operation fails so recovery never discards the checkout.
      try WTGit.run(at: destination, arguments: ["switch", "--no-track", "-c", branch])
      try FileManager.default.removeItem(atPath: markerPath)
      return true
    }
  }

  /// Hide only an intact checkout that is demonstrably ours; a damaged or
  /// unrecognized entry remains visible so the user can inspect it.
  static func ownedWorktree(root: String) throws -> String? {
    try NativeWT.Repository.withRepository(at: root) { repository in
      guard let common = git_repository_commondir(repository) else { return nil }
      let commonPath = try NativeWT.Repository.physicalPath(common)
      let pool = commonPath + "/supacode-prewarm"
      let path = pool + "/worktree"
      var info = stat()
      guard lstat(pool, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
        lstat(pool + "/owner.json", &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
        lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
        lstat(path + "/.git", &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
        let data = try? Data(contentsOf: URL(fileURLWithPath: pool + "/owner.json")),
        let marker = try? JSONDecoder().decode(Marker.self, from: data),
        marker.owner == "supacode", marker.version == 1, marker.worktree == path,
        !marker.adminName.isEmpty, !marker.adminName.contains("/"),
        marker.adminName != ".", marker.adminName != ".." else { return nil }
      var worktree: OpaquePointer?
      guard git_worktree_lookup(&worktree, repository, marker.adminName) == 0, let worktree else { return nil }
      defer { git_worktree_free(worktree) }
      guard git_worktree_validate(worktree) == 0, let registered = git_worktree_path(worktree),
        String(cString: registered) == path else { return nil }
      var checkout: OpaquePointer?
      guard git_repository_open(&checkout, path) == 0, let checkout else { return nil }
      defer { git_repository_free(checkout) }
      guard git_repository_is_worktree(checkout) != 0, let admin = git_repository_path(checkout),
        (try? NativeWT.Repository.physicalPath(admin)) == commonPath + "/worktrees/" + marker.adminName else { return nil }
      return path
    }
  }

  private static func recoverMovedCheckout(marker: Marker, common: String, destination: String) throws -> Bool {
    guard destination.hasPrefix("/"), !marker.adminName.isEmpty,
      !marker.adminName.contains("/"), marker.adminName != ".", marker.adminName != ".." else { return false }
    let admin = common + "/worktrees/" + marker.adminName
    var info = stat()
    guard lstat(destination, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      lstat(destination + "/.git", &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      lstat(admin, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      lstat(admin + "/gitdir", &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
    let pointer = try String(contentsOfFile: destination + "/.git", encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard pointer.hasPrefix("gitdir: ") else { return false }
    let pointerPath = String(pointer.dropFirst("gitdir: ".count))
    let destinationURL = URL(fileURLWithPath: destination, isDirectory: true)
    let pointerURL = URL(fileURLWithPath: pointerPath, relativeTo: destinationURL).standardizedFileURL
    guard (try? pointerURL.path(percentEncoded: false).withCString { try NativeWT.Repository.physicalPath($0) }) == admin
    else { return false }
    let backReference = try String(contentsOfFile: admin + "/gitdir", encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let adminURL = URL(fileURLWithPath: admin, isDirectory: true)
    let backURL = URL(fileURLWithPath: backReference, relativeTo: adminURL).standardizedFileURL
    let previous = URL(fileURLWithPath: marker.worktree, isDirectory: true).appending(path: ".git").standardizedFileURL
    let current = destinationURL.appending(path: ".git").standardizedFileURL
    guard backURL == previous || backURL == current else { return false }
    if backURL != current {
      try WTGit.run(at: destination, arguments: ["worktree", "repair", destination])
    }
    return true
  }

  private static func pathExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  private static func makePrivateDirectory(_ path: String) throws {
    var info = stat()
    if lstat(path, &info) == 0 {
      guard (info.st_mode & S_IFMT) == S_IFDIR else { throw NativeWT.Failure("prewarm directory is not a directory") }
      return
    }
    guard errno == ENOENT else { throw NativeWT.Failure("unable to inspect prewarm directory") }
    if mkdir(path, 0o700) == 0 { return }
    // Another process may have created the directory between lstat and mkdir.
    guard errno == EEXIST, lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
      throw NativeWT.Failure("unable to create prewarm directory")
    }
  }
}
