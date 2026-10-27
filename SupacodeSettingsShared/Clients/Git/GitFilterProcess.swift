import Foundation

/// Git's version-2 long-running filter protocol. A session owns one process
/// per driver and serializes requests to that process, as Git does per command.
nonisolated enum GitFilterProcess {
  private static let sessionKey = "app.supabit.git-filter-session"

  static func withSession<T>(_ body: () throws -> T) rethrows -> T {
    let dictionary = Thread.current.threadDictionary
    if dictionary[sessionKey] != nil { return try body() }
    let session = Session()
    dictionary[sessionKey] = session
    defer {
      dictionary.removeObject(forKey: sessionKey)
      session.close()
    }
    return try body()
  }

  /// Close filters before replacing the current process with a user command.
  static func finishSession() {
    let dictionary = Thread.current.threadDictionary
    guard let session = dictionary[sessionKey] as? Session else { return }
    dictionary.removeObject(forKey: sessionKey)
    session.close()
  }

  /// Returns nil for a filter-declared error. Protocol and transport errors
  /// throw; the caller applies Git's `filter.<driver>.required` policy.
  static func apply(command: String, directory: String, driver: String, mode: String, path: String, input: Data) throws
    -> Data?
  {
    if let session = Thread.current.threadDictionary[sessionKey] as? Session {
      return try session.apply(
        command: command, directory: directory, driver: driver, mode: mode, path: path, input: input)
    }
    return try withSession {
      try apply(command: command, directory: directory, driver: driver, mode: mode, path: path, input: input)
    }
  }

  private final class Session {
    private var processes: [String: Channel] = [:]
    private var aborted: Set<String> = []

    func apply(command: String, directory: String, driver: String, mode: String, path: String, input: Data) throws
      -> Data?
    {
      let key = directory + "\0" + driver + "\0" + command
      if aborted.contains(key) { return nil }
      let channel: Channel
      if let existing = processes[key] {
        channel = existing
      } else {
        channel = try Channel(command: command, directory: directory)
        processes[key] = channel
      }
      do {
        let result = try channel.filter(mode: mode, path: path, input: input)
        if result.abort { aborted.insert(key) }
        return result.data
      } catch {
        channel.close()
        processes.removeValue(forKey: key)
        throw error
      }
    }

    func close() {
      for channel in processes.values { channel.close() }
      processes.removeAll()
    }
  }

  private struct ProtocolFailure: Error {}

  private final class Channel {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var capabilities: Set<String> = []

    init(command: String, directory: String) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", command]
      process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
      var environment = ProcessInfo.processInfo.environment
      let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
      let paths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/run/current-system/sw/bin", home + "/.local/bin",
        home + "/.nix-profile/bin",
      ]
      environment["PATH"] = ([environment["PATH"] ?? ""] + paths).filter { !$0.isEmpty }.joined(separator: ":")
      process.environment = environment
      let stdin = Pipe()
      let stdout = Pipe()
      process.standardInput = stdin
      process.standardOutput = stdout
      process.standardError = FileHandle.standardError
      self.process = process
      self.input = stdin.fileHandleForWriting
      self.output = stdout.fileHandleForReading
      do {
        try process.run()
        try sendText("git-filter-client\n")
        try sendText("version=2\n")
        try flush()
        let welcome = try readList().compactMap { String(data: $0, encoding: .utf8) }
        guard welcome.contains("git-filter-server\n"), welcome.contains("version=2\n") else { throw ProtocolFailure() }
        try sendText("capability=clean\n")
        try sendText("capability=smudge\n")
        try flush()
        capabilities = Set(
          try readList().compactMap { data in
            guard let line = String(data: data, encoding: .utf8), line.hasPrefix("capability=") else { return nil }
            return String(line.dropFirst("capability=".count)).trimmingCharacters(in: .newlines)
          })
      } catch {
        close()
        throw error
      }
    }

    func filter(mode: String, path: String, input data: Data) throws -> (data: Data?, abort: Bool) {
      guard capabilities.contains(mode) else { return (nil, false) }
      try sendText("command=\(mode)\n")
      try sendText("pathname=\(path)\n")
      try flush()
      var offset = 0
      while offset < data.count {
        let end = min(offset + 65_516, data.count)
        try send(data.subdata(in: offset..<end))
        offset = end
      }
      try flush()
      let status = try readStatus()
      guard status == "success" else { return (nil, status == "abort") }
      var result = Data()
      for chunk in try readList() { result.append(chunk) }
      let trailer = try readStatus(allowEmpty: true)
      if trailer != nil && trailer != "success" { return (nil, trailer == "abort") }
      return (result, false)
    }

    private func readStatus(allowEmpty: Bool = false) throws -> String? {
      let packets = try readList()
      if packets.isEmpty && allowEmpty { return nil }
      for packet in packets {
        guard let line = String(data: packet, encoding: .utf8), line.hasPrefix("status=") else { continue }
        return String(line.dropFirst("status=".count)).trimmingCharacters(in: .newlines)
      }
      throw ProtocolFailure()
    }

    private func sendText(_ text: String) throws { try send(Data(text.utf8)) }
    private func flush() throws { try input.write(contentsOf: Data("0000".utf8)) }
    private func send(_ data: Data) throws {
      guard data.count <= 65_516 else { throw ProtocolFailure() }
      try input.write(contentsOf: Data(String(format: "%04x", data.count + 4).utf8))
      try input.write(contentsOf: data)
    }

    private func readList() throws -> [Data] {
      var result: [Data] = []
      while true {
        let header = try readExactly(4)
        guard let hex = String(data: header, encoding: .ascii), let length = Int(hex, radix: 16) else {
          throw ProtocolFailure()
        }
        if length == 0 { return result }
        guard length >= 4, length <= 65_520 else { throw ProtocolFailure() }
        result.append(try readExactly(length - 4))
      }
    }

    private func readExactly(_ count: Int) throws -> Data {
      var result = Data()
      while result.count < count {
        guard let chunk = try output.read(upToCount: count - result.count), !chunk.isEmpty else {
          throw ProtocolFailure()
        }
        result.append(chunk)
      }
      return result
    }

    func close() {
      // EOF lets the filter finish its own cleanup; terminating immediately
      // after its response can interrupt writes the filter performs on exit.
      try? input.close()
      if process.isRunning { process.waitUntilExit() }
      try? output.close()
    }
  }
}
