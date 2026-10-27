import CLibgit2
import Darwin
import Foundation

/// Bridge for configured external clean/smudge drivers. libgit2 provides the
/// checkout and attribute machinery, but external filters are application
/// supplied. The filter registry is installed once before repository work.
nonisolated enum NativeGitFilters {
  private nonisolated(unsafe) static let registration: UnsafeMutablePointer<git_filter> = {
    let filter = UnsafeMutablePointer<git_filter>.allocate(capacity: 1)
    filter.initialize(to: git_filter())
    _ = git_filter_init(filter, UInt32(GIT_FILTER_VERSION))
    filter.pointee.attributes = UnsafePointer(strdup("filter"))
    filter.pointee.check = { _, payload, _, values in
      guard let value = values?.pointee, git_attr_value(value) == GIT_ATTR_VALUE_STRING else {
        return Int32(GIT_PASSTHROUGH.rawValue)
      }
      guard let name = strdup(value) else { return -1 }
      payload?.pointee = UnsafeMutableRawPointer(name)
      return 0
    }
    filter.pointee.apply = { _, payload, output, input, source in
      guard let name = payload?.pointee, let output, let input, let source else { return -1 }
      return apply(
        driver: String(cString: name.assumingMemoryBound(to: CChar.self)),
        output: output, input: input, source: source
      )
    }
    filter.pointee.cleanup = { _, payload in free(payload) }
    return filter
  }()

  // Hold one libgit2 initialization for the process lifetime, so the shared
  // filter registry remains installed while repository calls run concurrently.
  private static let installed: Bool = {
    guard git_libgit2_init() >= 0 else { return false }
    if git_filter_register("supacode-external", registration, GIT_FILTER_DRIVER_PRIORITY) == 0 { return true }
    git_libgit2_shutdown()
    return false
  }()

  static func ensureInstalled() throws {
    guard installed else { throw NativeGitRepository.Failure(message: "Unable to register external Git filters") }
  }

  private static func apply(
    driver: String,
    output: UnsafeMutablePointer<git_buf>,
    input: UnsafePointer<git_buf>,
    source: OpaquePointer
  ) -> Int32 {
    guard let repository = git_filter_source_repo(source) else { return -1 }
    var config: OpaquePointer?
    guard git_repository_config(&config, repository) == 0, let config else { return -1 }
    defer { git_config_free(config) }
    let mode = git_filter_source_mode(source) == GIT_FILTER_SMUDGE ? "smudge" : "clean"
    guard let pathPointer = git_filter_source_path(source), let workdir = git_repository_workdir(repository) else {
      return -1
    }
    let path = String(cString: pathPointer)
    var required: Int32 = 0
    _ = git_config_get_bool(&required, config, "filter.\(driver).required")
    var processCommand = git_buf()
    defer { git_buf_dispose(&processCommand) }
    if git_config_get_string_buf(&processCommand, config, "filter.\(driver).process") == 0,
      let executable = processCommand.ptr
    {
      do {
        let contents = input.pointee.ptr.map { Data(bytes: $0, count: input.pointee.size) } ?? Data()
        guard
          let result = try GitFilterProcess.apply(
            command: String(cString: executable), directory: String(cString: workdir),
            driver: driver, mode: mode, path: path, input: contents
          )
        else {
          if required == 0 { return Int32(GIT_PASSTHROUGH.rawValue) }
          _ = git_error_set_str(Int32(GIT_ERROR_FILTER.rawValue), "external process filter rejected content")
          return -1
        }
        return result.withUnsafeBytes { bytes in
          git_buf_set(output, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count)
        }
      } catch {
        if required == 0 { return Int32(GIT_PASSTHROUGH.rawValue) }
        _ = git_error_set_str(Int32(GIT_ERROR_FILTER.rawValue), "external process filter failed")
        return -1
      }
    }
    var command = git_buf()
    defer { git_buf_dispose(&command) }
    guard git_config_get_string_buf(&command, config, "filter.\(driver).\(mode)") == 0,
      let commandPointer = command.ptr
    else { return Int32(GIT_PASSTHROUGH.rawValue) }
    let quotedPath = "'" + path.replacing("'", with: "'\\''") + "'"
    let commandText = String(cString: commandPointer).replacing("%f", with: quotedPath)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", commandText]
    var environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    let helperPaths = [
      "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/run/current-system/sw/bin", home + "/.local/bin",
      home + "/.nix-profile/bin",
    ]
    environment["PATH"] = ([environment["PATH"] ?? ""] + helperPaths).filter { !$0.isEmpty }.joined(separator: ":")
    process.environment = environment
    process.currentDirectoryURL = URL(fileURLWithPath: String(cString: workdir), isDirectory: true)
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.standardError
    do {
      try process.run()
      let contents = input.pointee.ptr.map { Data(bytes: $0, count: input.pointee.size) } ?? Data()
      DispatchQueue.global().async {
        try? stdin.fileHandleForWriting.write(contentsOf: contents)
        try? stdin.fileHandleForWriting.close()
      }
      let result = stdout.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      if process.terminationStatus != 0 {
        if required == 0 { return Int32(GIT_PASSTHROUGH.rawValue) }
        _ = git_error_set_str(Int32(GIT_ERROR_FILTER.rawValue), "external filter failed")
        return -1
      }
      return result.withUnsafeBytes { bytes in
        git_buf_set(output, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count)
      }
    } catch {
      _ = git_error_set_str(Int32(GIT_ERROR_FILTER.rawValue), "unable to launch external filter")
      return -1
    }
  }
}
