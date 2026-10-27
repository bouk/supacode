import CLibgit2
import Darwin
import Foundation

/// Swift worktree orchestration backed by Git for repository mutations.
@main
enum NativeWT {
  struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  struct GlobalOptions {
    var baseDirectory = ""
  }

  struct SwitchOptions {
    var branch = ""
    var baseRef = ""
    var path = ""
    var fetch = false
    var copy = CopyOptions()
  }

  struct CopyOptions {
    var ignored = false
    var untracked = false
    var modified = false
    var tracked = false
    var force = false
    var verbose = false
    var dryRun = false
    var hasFiles: Bool { ignored || untracked || modified || tracked }
  }

  struct Worktree {
    var path: String
    var branch: String?
    var head: String = ""
    var isBare = false
    var adminName: String? = nil
  }

  static func main() {
    do {
      guard git_libgit2_init() >= 0 else { throw Failure("unable to initialize libgit2") }
      defer { git_libgit2_shutdown() }
      try run(Array(CommandLine.arguments.dropFirst()))
    } catch {
      FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  static func run(_ arguments: [String]) throws {
    var arguments = arguments[...]
    var global = GlobalOptions()
    while let argument = arguments.first, argument.hasPrefix("--base-dir") {
      arguments.removeFirst()
      if argument == "--base-dir" {
        guard let value = arguments.first, !value.isEmpty else { throw Failure("missing value for --base-dir") }
        global.baseDirectory = value
        arguments.removeFirst()
      } else if argument.hasPrefix("--base-dir=") {
        global.baseDirectory = String(argument.dropFirst("--base-dir=".count))
      } else {
        throw Failure("unknown flag '\(argument)'")
      }
    }
    guard let command = arguments.popFirst() else { output(WTUsage.general); exit(1) }
    if command == "-h" || command == "--help" { output(WTUsage.general); return }
    if command.hasPrefix("--") { throw Failure("unknown flag '\(command)'") }
    if command == "help" {
      guard let name = arguments.first else { output(WTUsage.general); return }
      guard let text = usage(for: name) else { throw Failure("unknown command '\(name)'") }
      output(text)
      return
    }
    if ["switch", "sw", "exec", "sync", "ls", "rm", "merge"].contains(command),
      arguments.prefix(while: { $0 != "--" }).contains(where: { $0 == "-h" || $0 == "--help" }),
      let text = usage(for: command)
    {
      output(text)
      return
    }
    let cwd = FileManager.default.currentDirectoryPath
    switch command {
    case "__prewarm":
      let args = Array(arguments)
      guard args.isEmpty || (args.count == 2 && args[0] == "--from") else {
        throw Failure("invalid prewarm arguments")
      }
      try WTPrewarm.prepare(root: try Repository.root(at: cwd), baseRef: args.isEmpty ? "" : args[1])
    case "root":
      output(try Repository.root(at: cwd))
    case "__branches":
      for branch in try Repository.localBranches(at: cwd) { output(branch) }
    case "base":
      output(baseDirectory(root: try Repository.root(at: cwd), override: global.baseDirectory))
    case "here":
      let root = try Repository.root(at: cwd)
      let base = baseDirectory(root: root, override: global.baseDirectory)
      let current = try Repository.currentWorktree(at: cwd)
      guard current.path.hasPrefix(base + "/"), let branch = current.branch else { throw Failure("not in a workspace") }
      output(branch)
    case "ls":
      try listWorktrees(Array(arguments), global: global, cwd: cwd)
    case "__app-ls":
      try listWorktrees(["--json"], global: global, cwd: cwd, hidePrewarm: true)
    case "rm", "sync", "merge":
      // Preserve upstream wt's Git semantics for compatibility-sensitive
      // mutations while retaining native worktree creation and prewarming.
      let compatibility = URL(fileURLWithPath: executablePath()).deletingLastPathComponent()
        .appending(path: "wt-compat").path(percentEncoded: false)
      var commandArguments = ["/bin/bash", compatibility]
      if !global.baseDirectory.isEmpty { commandArguments += ["--base-dir", global.baseDirectory] }
      commandArguments.append(command)
      commandArguments.append(contentsOf: arguments)
      var argv = commandArguments.map { strdup($0) }
      argv.append(nil)
      defer { for argument in argv { free(argument) } }
      execv("/bin/bash", &argv)
      throw Failure("unable to launch wt compatibility command")
    case "switch", "sw":
      let options = try parseSwitch(Array(arguments))
      output(try openWorktree(options, global: global, cwd: cwd))
    case "exec":
      let (options, command) = try parseExec(Array(arguments))
      let directory = try openWorktree(options, global: global, cwd: cwd)
      guard chdir(directory) == 0 else { throw Failure("unable to enter workspace") }
      // Replace this process as wt does, preserving signals and the exact exit
      // status of the requested command rather than wrapping it in a child.
      var argv = command.map { strdup($0) }
      argv.append(nil)
      defer { for argument in argv { free(argument) } }
      execvp(command[0], &argv)
      let code: Int32 = errno == ENOENT ? 127 : 126
      FileHandle.standardError.write(Data("error: unable to execute '\(command[0])'\n".utf8))
      exit(code)
    case "completion":
      guard let shell = arguments.first else { output(WTUsage.completion); exit(1) }
      switch shell {
      case "bash": output(WTUsage.bash)
      case "zsh": output(WTUsage.zsh)
      case "fish":
        output(WTUsage.fish.replacing("__NATIVE_WT_EXECUTABLE__", with: executablePath().replacing("'", with: "'\\''")))
      default: throw Failure("unknown shell '\(shell)'")
      }
    default:
      throw Failure("unknown command '\(command)'")
    }
  }

  static func usage(for command: String) -> String? {
    switch command {
    case "help": WTUsage.general
    case "switch", "sw": WTUsage.switchCommand
    case "exec": WTUsage.exec
    case "sync": WTUsage.sync
    case "ls": WTUsage.ls
    case "rm": WTUsage.rm
    case "merge": WTUsage.merge
    case "here": WTUsage.here
    case "base": WTUsage.base
    case "root": WTUsage.root
    case "completion": WTUsage.completion
    default: nil
    }
  }

  static func executablePath() -> String {
    let command = CommandLine.arguments[0]
    if command.contains("/") {
      return URL(fileURLWithPath: command).standardizedFileURL.path
    }
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false)
    for path in paths {
      let candidate = (path.isEmpty ? "." : String(path)) + "/" + command
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return URL(fileURLWithPath: candidate).standardizedFileURL.path
      }
    }
    return command
  }

  static func parseSwitch(_ arguments: [String]) throws -> SwitchOptions {
    var options = SwitchOptions()
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      switch argument {
      case "--from", "--path":
        guard let value = remaining.popFirst(), !value.isEmpty else { throw Failure("missing value for \(argument)") }
        if argument == "--from" { options.baseRef = value } else { options.path = value }
      case "--fetch": options.fetch = true
      case "--copy-all":
        options.copy.ignored = true; options.copy.untracked = true
        options.copy.modified = true; options.copy.tracked = true
      case "--copy-ignored": options.copy.ignored = true
      case "--copy-untracked": options.copy.untracked = true
      case "--copy-modified": options.copy.modified = true
      case "--force", "-f": options.copy.force = true
      case "--verbose", "-v": options.copy.verbose = true
      default:
        if argument.hasPrefix("--from=") { options.baseRef = String(argument.dropFirst(7)) }
        else if argument.hasPrefix("--path=") { options.path = String(argument.dropFirst(7)) }
        else if argument.hasPrefix("--") { throw Failure("unknown flag '\(argument)'") }
        else if options.branch.isEmpty { options.branch = argument }
        else { throw Failure("unexpected argument '\(argument)'") }
      }
    }
    guard !options.branch.isEmpty else { throw Failure("missing branch") }
    return options
  }

  static func parseExec(_ arguments: [String]) throws -> (SwitchOptions, [String]) {
    var options = SwitchOptions()
    var remaining = arguments[...]
    var command: [String] = []
    while let argument = remaining.popFirst() {
      switch argument {
      case "--":
        command = Array(remaining)
        remaining = []
      case "--from", "--path":
        guard let value = remaining.popFirst(), !value.isEmpty else { throw Failure("missing value for \(argument)") }
        if argument == "--from" { options.baseRef = value } else { options.path = value }
      case "--fetch": options.fetch = true
      default:
        if argument.hasPrefix("--from=") { options.baseRef = String(argument.dropFirst(7)) }
        else if argument.hasPrefix("--path=") { options.path = String(argument.dropFirst(7)) }
        else if argument.hasPrefix("--") { throw Failure("unknown flag '\(argument)'") }
        else if options.branch.isEmpty { options.branch = argument }
        else { throw Failure("missing -- before command") }
      }
    }
    guard !options.branch.isEmpty else { throw Failure("missing branch") }
    guard !command.isEmpty else { throw Failure("missing command") }
    return (options, command)
  }

  static func openWorktree(_ options: SwitchOptions, global: GlobalOptions, cwd: String) throws -> String {
    let root = try Repository.root(at: cwd)
    let worktrees = try Repository.worktrees(at: root)
    let source = options.copy.hasFiles ? try copySource(root: root, cwd: cwd, worktrees: worktrees) : nil
    if let existing = worktrees.first(where: { !$0.isBare && $0.branch == options.branch }) { return existing.path }
    let base = baseDirectory(root: root, override: global.baseDirectory)
    let path = options.path.isEmpty
      ? base + "/" + options.branch
      : absolute(options.path, relativeTo: root)
    let branchExists = try Repository.branchExists(at: root, name: options.branch)
    if branchExists {
      guard !options.path.isEmpty else { throw Failure("branch exists without worktree: '\(options.branch)'") }
      guard !worktrees.contains(where: { $0.path == path }) else { throw Failure("worktree path already in use: '\(path)'") }
    } else {
      if options.fetch { try Repository.fetch(at: root) }
      if !options.baseRef.isEmpty {
        guard try Repository.refIsCommit(at: root, ref: options.baseRef) else {
          throw Failure("invalid --from ref '\(options.baseRef)'")
        }
      }
    }
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let claimed = !branchExists && ProcessInfo.processInfo.environment["SUPACODE_USE_PREWARM"] == "1"
      ? try WTPrewarm.claim(root: root, destination: path, branch: options.branch, baseRef: options.baseRef) : false
    if !claimed {
      try Repository.createWorktree(at: root, path: path, branch: options.branch, baseRef: options.baseRef, existing: branchExists)
    } else {
      // The app uses Git's announcement as proof that this operation created
      // the named checkout. A warm claim needs the same proof for cancellation.
      FileHandle.standardError.write(Data("Preparing worktree (new branch '\(options.branch)')\n".utf8))
    }
    if let source {
      try FileCopier.copy(from: source, to: path, options: options.copy)
    }
    return path
  }

  static func absolute(_ path: String, relativeTo root: String) -> String {
    path.hasPrefix("/") ? path : root + "/" + path
  }

  static func baseDirectory(root: String, override: String) -> String {
    let chosen = override.isEmpty ? (ProcessInfo.processInfo.environment["GIT_WT_BASE"] ?? "") : override
    let path = chosen.isEmpty ? root + "/.worktrees" : absolute(chosen, relativeTo: root)
    return path != "/" && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  static func output(_ value: String) {
    FileHandle.standardOutput.write(Data("\(value)\n".utf8))
  }

  static func listWorktrees(_ arguments: [String], global: GlobalOptions, cwd: String, hidePrewarm: Bool = false) throws {
    var plain = false
    var json = false
    for argument in arguments {
      switch argument {
      case "--plain": plain = true
      case "--json": json = true
      default:
        throw Failure(argument.hasPrefix("--") ? "unknown flag '\(argument)'" : "unexpected argument '\(argument)'")
      }
    }
    guard !(plain && json) else { throw Failure("cannot use --plain and --json together") }
    let root = try Repository.root(at: cwd)
    var worktrees = try Repository.worktrees(at: root)
    if hidePrewarm, let warm = try WTPrewarm.ownedWorktree(root: root) {
      worktrees.removeAll { $0.path == warm }
    }
    if !global.baseDirectory.isEmpty {
      let base = baseDirectory(root: root, override: global.baseDirectory)
      worktrees = worktrees.filter { $0.isBare || $0.path.hasPrefix(base + "/") }
    }
    if json {
      let entries = worktrees.map { worktree in
        let branch = worktree.isBare ? "(bare)" : (worktree.branch ?? "")
        return "{\"branch\":\"\(jsonEscape(branch))\",\"path\":\"\(jsonEscape(worktree.path))\","
          + "\"head\":\"\(jsonEscape(worktree.head))\",\"is_bare\":\(worktree.isBare ? "true" : "false")}"
      }
      output("[\(entries.joined(separator: ","))]")
    } else if plain || isatty(STDOUT_FILENO) == 0 {
      for worktree in worktrees { output("\(worktree.isBare ? "(bare)" : (worktree.branch ?? ""))\t\(worktree.path)") }
    } else {
      for worktree in worktrees {
        let branch = worktree.isBare ? "(bare)" : (worktree.branch ?? "")
        output(branch.padding(toLength: max(30, branch.count), withPad: " ", startingAt: 0) + " "
          + worktree.path.padding(toLength: max(60, worktree.path.count), withPad: " ", startingAt: 0)
          + " " + worktree.head)
      }
    }
  }

  static func jsonEscape(_ value: String) -> String {
    value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
  }

  static func copySource(root: String, cwd: String, worktrees: [Worktree]) throws -> String {
    if try !Repository.isBare(at: cwd) { return root }
    guard let source = worktrees.first(where: { !$0.isBare && FileManager.default.fileExists(atPath: $0.path) }) else {
      throw Failure("no linked worktree found for copy operations")
    }
    return source.path
  }

  enum FileCopier {
    static func copy(from source: String, to destination: String, options: CopyOptions) throws {
      if source == destination || sameFile(source, destination) { return }
      let paths = try candidates(source: source, options: options)
      for path in paths {
        let relative = path.hasSuffix("/") ? String(path.dropLast()) : path
        let sourcePath = source + "/" + relative
        let destinationPath = destination + "/" + relative
        guard kind(sourcePath) != nil else { continue }
        if options.dryRun {
          if options.verbose { stderr("would copy \(path)") }
          NativeWT.output(path)
        } else {
          if options.verbose { stderr("copy \(relative)") }
          copyItem(sourcePath, destinationPath, force: options.force)
        }
      }
    }

    static func candidates(source: String, options: CopyOptions) throws -> [String] {
      let paths = try Repository.copyCandidates(at: source, options: options)
      let root = try Repository.root(at: source)
      let nested = try Repository.worktrees(at: root).compactMap { worktree -> String? in
        guard !worktree.isBare, worktree.path.hasPrefix(source + "/") else { return nil }
        return String(worktree.path.dropFirst(source.count + 1))
      }
      var directories: [String] = []
      var result: [String] = []
      for path in Set(paths).sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
        let relative = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !relative.isEmpty, !relative.hasPrefix(".git/") else { continue }
        guard !nested.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") || $0.hasPrefix(relative + "/") }) else { continue }
        guard !directories.contains(where: { relative.hasPrefix($0 + "/") }) else { continue }
        result.append(path)
        if path.hasSuffix("/") { directories.append(relative) }
      }
      return result
    }

    /// Best effort like wt's copy path. Preserve symlinks and use APFS clones
    /// for files where possible, falling back to a normal copy.
    static func copyItem(_ source: String, _ destination: String, force: Bool) {
      let manager = FileManager.default
      guard let sourceKind = kind(source) else { return }
      let destinationKind = kind(destination)
      if sourceKind == .typeDirectory {
        if let destinationKind, destinationKind != .typeDirectory {
          guard force else { return }
          try? manager.removeItem(atPath: destination)
        }
        if kind(destination) == nil {
          try? manager.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
          if (try? manager.copyItem(atPath: source, toPath: destination)) != nil { return }
        }
        try? manager.createDirectory(atPath: destination, withIntermediateDirectories: true)
        guard kind(destination) == .typeDirectory,
          let children = try? manager.contentsOfDirectory(atPath: source) else { return }
        for child in children { copyItem(source + "/" + child, destination + "/" + child, force: force) }
        return
      }
      if destinationKind != nil {
        guard force else { return }
        try? manager.removeItem(atPath: destination)
      }
      try? manager.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      if sourceKind == .typeRegular, clonefile(source, destination, 0) == 0 { return }
      try? manager.copyItem(atPath: source, toPath: destination)
    }

    static func kind(_ path: String) -> FileAttributeType? {
      (try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType
    }

    static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
      var left = stat()
      var right = stat()
      return stat(lhs, &left) == 0 && stat(rhs, &right) == 0 && left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    static func stderr(_ value: String) {
      FileHandle.standardError.write(Data("\(value)\n".utf8))
    }
  }

  /// The opt-in machine-readable stream is kept separate from wt's stdout,
  /// which is reserved for the resulting path and remains script-compatible.
  final class CheckoutProgress {
    private var lastPercent = -1

    func report(completed: Int, total: Int) {
      guard total > 0 else { return }
      let percent = Int((Double(completed) / Double(total)) * 100)
      guard percent != lastPercent else { return }
      lastPercent = percent
      FileCopier.stderr("SUPACODE_CHECKOUT_PROGRESS \(completed) \(total)")
    }
  }

  enum Repository {
    static func fetch(at path: String) throws {
      try WTGit.run(at: path, arguments: ["fetch", "origin"])
    }

    static func createWorktree(at root: String, path: String, branch: String, baseRef: String, existing: Bool, runHook: Bool = true, lock: Bool = false) throws {
      var arguments: [String] = []
      if !runHook { arguments += ["-c", "core.hooksPath=/dev/null"] }
      arguments += ["worktree", "add"]
      if lock { arguments += ["--lock", "--reason={\"owner\":\"supacode\"}"] }
      if !runHook { arguments.append("--detach") }
      else if !existing { arguments += ["-b", branch] }
      arguments.append(path)
      if !runHook { arguments.append(baseRef.isEmpty ? "HEAD" : baseRef) }
      else if existing { arguments.append(branch) }
      else if !baseRef.isEmpty { arguments.append(baseRef) }
      try WTGit.run(at: root, arguments: arguments, progress: true)
    }

    static func localBranches(at path: String) throws -> [String] {
      try withRepository(at: path) { repository in
        var iterator: OpaquePointer?
        guard git_branch_iterator_new(&iterator, repository, GIT_BRANCH_LOCAL) == 0, let iterator else { throw failure() }
        defer { git_branch_iterator_free(iterator) }
        var branches: [String] = []
        while true {
          var reference: OpaquePointer?
          var kind = GIT_BRANCH_LOCAL
          let status = git_branch_next(&reference, &kind, iterator)
          if status == GIT_ITEROVER.rawValue { break }
          guard status == 0, let reference else { throw failure() }
          defer { git_reference_free(reference) }
          if let name = git_reference_shorthand(reference) { branches.append(String(cString: name)) }
        }
        return branches.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
      }
    }

    static func copyCandidates(at path: String, options: CopyOptions) throws -> [String] {
      var paths: [String] = []
      if options.tracked { paths += try WTGit.paths(at: path, arguments: []) }
      if options.ignored {
        paths += try WTGit.paths(at: path, arguments: ["--others", "--ignored", "--exclude-standard", "--directory"])
      }
      if options.untracked { paths += try WTGit.paths(at: path, arguments: ["--others", "--exclude-standard"]) }
      if options.modified { paths += try WTGit.paths(at: path, arguments: ["--modified"]) }
      return paths
    }

    static func isBare(at path: String) throws -> Bool {
      try withRepository(at: path) { git_repository_is_bare($0) != 0 }
    }

    static func branchExists(at path: String, name: String) throws -> Bool {
      try withRepository(at: path) { repository in
        var reference: OpaquePointer?
        let status = git_reference_lookup(&reference, repository, "refs/heads/\(name)")
        if let reference { git_reference_free(reference) }
        return status == 0
      }
    }

    static func refIsCommit(at path: String, ref: String) throws -> Bool {
      try withRepository(at: path) { repository in
        var object: OpaquePointer?
        let status = git_revparse_single(&object, repository, "\(ref)^{commit}")
        if let object { git_object_free(object) }
        return status == 0
      }
    }

    static func root(at path: String) throws -> String {
      try withRepository(at: path) { repository in
        guard let common = git_repository_commondir(repository) else { throw failure() }
        var mainRepository: OpaquePointer?
        guard git_repository_open(&mainRepository, common) == 0, let mainRepository else { throw failure() }
        defer { git_repository_free(mainRepository) }
        let directory = git_repository_is_bare(mainRepository) != 0 ? common : git_repository_workdir(mainRepository)
        guard let directory else { throw failure() }
        return try physicalPath(directory)
      }
    }

    static func currentWorktree(at path: String) throws -> Worktree {
      try withRepository(at: path) { repository in
        guard let directory = git_repository_workdir(repository) else { throw failure() }
        let physical = try physicalPath(directory)
        var reference: OpaquePointer?
        guard git_repository_head(&reference, repository) == 0, let reference else {
          return Worktree(path: physical, branch: nil)
        }
        defer { git_reference_free(reference) }
        let branch = git_reference_is_branch(reference) != 0
          ? git_reference_shorthand(reference).map { String(cString: $0) } : nil
        return Worktree(path: physical, branch: branch)
      }
    }

    static func worktrees(at root: String) throws -> [Worktree] {
      try withRepository(at: root) { repository in
        guard let common = git_repository_commondir(repository) else { throw failure() }
        var main: OpaquePointer?
        guard git_repository_open(&main, common) == 0, let main else { throw failure() }
        defer { git_repository_free(main) }
        let bare = git_repository_is_bare(main) != 0
        guard let mainPath = bare ? common : git_repository_workdir(main) else { throw failure() }
        let mainReference = bare ? (branch: nil as String?, head: "") : referenceInfo(main, name: "HEAD")
        var result = [Worktree(path: try physicalPath(mainPath), branch: mainReference.branch, head: mainReference.head, isBare: bare)]

        var names = git_strarray()
        guard git_worktree_list(&names, main) == 0 else { throw failure() }
        defer { git_strarray_dispose(&names) }
        if let strings = names.strings {
          for index in 0..<names.count {
            guard let namePointer = strings[index] else { continue }
            let name = String(cString: namePointer)
            var worktree: OpaquePointer?
            guard git_worktree_lookup(&worktree, main, name) == 0, let worktree else { throw failure() }
            defer { git_worktree_free(worktree) }
            guard let pathPointer = git_worktree_path(worktree) else { throw failure() }
            let rawPath = String(cString: pathPointer)
            let path = (try? physicalPath(pathPointer)) ?? rawPath
            let reference = referenceInfo(main, name: "worktrees/\(name)/HEAD")
            result.append(Worktree(path: path, branch: reference.branch, head: reference.head, adminName: name))
          }
        }
        return result
      }
    }

    static func referenceInfo(_ repository: OpaquePointer, name: String) -> (branch: String?, head: String) {
      var reference: OpaquePointer?
      guard git_reference_lookup(&reference, repository, name) == 0, let reference else {
        return (nil, String(repeating: "0", count: 40))
      }
      defer { git_reference_free(reference) }
      let symbolic = git_reference_symbolic_target(reference).map { String(cString: $0) }
      let prefix = "refs/heads/"
      let branch = symbolic.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
      var resolved: OpaquePointer?
      guard git_reference_resolve(&resolved, reference) == 0, let resolved else {
        return (branch, String(repeating: "0", count: 40))
      }
      defer { git_reference_free(resolved) }
      guard let oid = git_reference_target(resolved), let hex = git_oid_tostr_s(oid) else {
        return (branch, String(repeating: "0", count: 40))
      }
      return (branch, String(cString: hex))
    }

    static func withRepository<T>(at path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
      guard git_libgit2_init() >= 0 else { throw failure() }
      defer { git_libgit2_shutdown() }
      var repository: OpaquePointer?
      guard git_repository_open_ext(&repository, path, 0, nil) == 0, let repository else { throw Failure("not a git repository") }
      defer { git_repository_free(repository) }
      return try body(repository)
    }

    static func physicalPath(_ path: UnsafePointer<CChar>) throws -> String {
      guard let physical = realpath(path, nil) else { throw Failure("unable to resolve repository path") }
      defer { free(physical) }
      return String(cString: physical)
    }

    static func failure() -> Failure {
      let message = git_error_last().flatMap { $0.pointee.message }.map { String(cString: $0) }
      return Failure(message ?? "unable to open repository")
    }
  }
}
