import Darwin
import Foundation

/// Runs Git mutations while keeping stdout reserved for wt's result path.
enum WTGit {
  static func paths(at directory: String, arguments: [String]) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory, "ls-files", "-z"] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NativeWT.Failure("Unable to list files for copying") }
    return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
  }

  static func isClean(at directory: String) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory, "status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=all"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    var hasOutput = false
    while true {
      let data = output.fileHandleForReading.availableData
      if data.isEmpty { break }
      hasOutput = true
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NativeWT.Failure("Unable to check prewarmed worktree status") }
    return !hasOutput
  }

  static func run(at directory: String, arguments: [String], progress: Bool = false) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory] + arguments
    let useTerminal = progress && ProcessInfo.processInfo.environment["SUPACODE_WT_PROGRESS"] == "1"
    var master: Int32 = -1
    var slave: Int32 = -1
    let pipe = Pipe()
    if useTerminal {
      var size = winsize()
      size.ws_col = 120
      size.ws_row = 40
      guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw NativeWT.Failure("Unable to open progress terminal") }
      let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
      process.standardOutput = terminal
      process.standardError = terminal
    } else {
      process.standardOutput = pipe
      process.standardError = pipe
    }
    do { try process.run() } catch {
      if master >= 0 { close(master) }
      if slave >= 0 { close(slave) }
      throw error
    }
    if slave >= 0 { close(slave) }
    defer { if master >= 0 { close(master) } }
    var pending = Data()
    var lastOutput = ""
    let reporter = NativeWT.CheckoutProgress()
    func handle(_ data: Data) {
      guard !data.isEmpty else { return }
      let line = String(decoding: data, as: UTF8.self)
      lastOutput = String((lastOutput + line + "\n").suffix(4096))
      if progress, ProcessInfo.processInfo.environment["SUPACODE_WT_PROGRESS"] == "1",
        let match = line.firstMatch(of: #/(\d+)/(\d+)/#),
        (line.contains("Updating files") || line.contains("Checking out files")),
        let completed = Int(match.1), let total = Int(match.2), total > 0
      {
        reporter.report(completed: completed, total: total)
      } else {
        NativeWT.FileCopier.stderr(line)
      }
    }
    while true {
      let chunk: Data
      if useTerminal {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = read(master, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        chunk = Data(buffer.prefix(count))
      } else {
        chunk = pipe.fileHandleForReading.availableData
        if chunk.isEmpty { break }
      }
      pending.append(chunk)
      while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
        handle(pending.prefix(upTo: end))
        pending.removeSubrange(...end)
      }
    }
    handle(pending)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NativeWT.Failure(lastOutput.isEmpty ? "Git operation failed" : lastOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}
