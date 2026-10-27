import CLibgit2
import Foundation

/// Git credential-helper protocol for libgit2 HTTP authentication.
nonisolated enum GitFetchCredentials {
  final class Context {
    let repository: OpaquePointer
    var attempted = false
    var acquired: Credentials?
    var rejected = false
    init(repository: OpaquePointer) { self.repository = repository }
  }

  static let callback: git_credential_acquire_cb = { output, url, username, allowed, payload in
    guard let output, let url, let payload else { return GIT_PASSTHROUGH.rawValue }
    let context = Unmanaged<Context>.fromOpaque(payload).takeUnretainedValue()
    let name = username.map { String(cString: $0) }
    if allowed & UInt32(GIT_CREDENTIAL_USERNAME.rawValue) != 0, let name {
      return git_credential_username_new(output, name)
    }
    guard allowed & UInt32(GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue) != 0 else {
      return GIT_PASSTHROUGH.rawValue
    }
    if context.attempted {
      context.rejected = true
      return GIT_PASSTHROUGH.rawValue
    }
    context.attempted = true
    guard let credentials = try? resolve(url: String(cString: url), username: name, repository: context.repository) else {
      return GIT_PASSTHROUGH.rawValue
    }
    context.acquired = credentials
    return git_credential_userpass_plaintext_new(output, credentials.username, credentials.password)
  }

  struct Credentials {
    let username: String
    let password: String
    let helpers: [String]
    let fields: [String: String]
  }

  static func resolve(url: String, username: String?, repository: OpaquePointer) throws -> Credentials? {
    guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
      ["https", "http"].contains(scheme), let host = components.host else { return nil }
    let port = components.port.map { ":\($0)" } ?? ""
    let authority = host + port
    guard !authority.contains("\n"), !(username ?? "").contains("\n") else { return nil }
    var config: OpaquePointer?
    guard git_repository_config_snapshot(&config, repository) == 0, let config else { return nil }
    defer { git_config_free(config) }
    var iterator: OpaquePointer?
    guard git_config_iterator_new(&iterator, config) == 0, let iterator else { return nil }
    defer { git_config_iterator_free(iterator) }
    var settings: [(scope: Int, order: Int, key: String, value: String)] = []
    var entry: UnsafeMutablePointer<git_config_entry>?
    var order = 0
    while git_config_next(&entry, iterator) == 0, let entry {
      guard let keyPointer = entry.pointee.name, let valuePointer = entry.pointee.value else { continue }
      let key = String(cString: keyPointer)
      guard key.hasPrefix("credential.") else { continue }
      let tail = String(key.dropFirst("credential.".count))
      let suffixes = ["helper", "username", "usehttppath"]
      guard let suffix = suffixes.first(where: { tail == $0 || tail.hasSuffix("." + $0) }) else { continue }
      let scope: Int
      if tail == suffix {
        scope = 0
      } else {
        let pattern = String(tail.dropLast(suffix.count + 1))
        guard let match = URLComponents(string: pattern), match.scheme?.lowercased() == scheme,
          match.host?.lowercased() == host.lowercased(), match.port == components.port,
          match.user == nil || match.user == (username ?? components.user) else { continue }
        let matchPath = match.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let actualPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard matchPath.isEmpty || actualPath == matchPath || actualPath.hasPrefix(matchPath + "/") else { continue }
        scope = 1 + matchPath.utf8.count + (match.user == nil ? 0 : 1)
      }
      settings.append((scope, order, suffix, String(cString: valuePointer)))
      order += 1
    }
    settings.sort { $0.scope == $1.scope ? $0.order < $1.order : $0.scope < $1.scope }
    var helpers: [String] = []
    var effectiveUsername = username ?? components.user
    var usePath = false
    for setting in settings {
      switch setting.key {
      case "helper":
        if setting.value.isEmpty { helpers.removeAll() } else { helpers.append(setting.value) }
      case "username":
        if username == nil, components.user == nil { effectiveUsername = setting.value }
      case "usehttppath": usePath = ["true", "yes", "on", "1"].contains(setting.value.lowercased())
      default: break
      }
    }
    var fields = ["protocol": scheme, "host": authority]
    if usePath, !components.path.isEmpty { fields["path"] = String(components.path.drop(while: { $0 == "/" })) }
    if let effectiveUsername { fields["username"] = effectiveUsername }
    for helper in helpers {
      guard let text = run(helper: helper, operation: "get", fields: fields) else { continue }
      for line in text.split(whereSeparator: \.isNewline) {
        guard let separator = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<separator])
        if key == "username" || key == "password" { fields[key] = String(line[line.index(after: separator)...]) }
      }
      if let user = fields["username"], let password = fields["password"] {
        return Credentials(username: user, password: password, helpers: helpers, fields: fields)
      }
    }
    return nil
  }

  static func finish(_ context: Context, success: Bool) {
    guard let credentials = context.acquired, success || context.rejected else { return }
    let operation = success ? "store" : "erase"
    for helper in credentials.helpers {
      _ = run(helper: helper, operation: operation, fields: credentials.fields)
    }
  }

  private static func run(helper: String, operation: String, fields: [String: String]) -> String? {
    let command: String
    if helper.hasPrefix("!") { command = String(helper.dropFirst()) + " " + operation }
    else if helper.hasPrefix("/") { command = helper + " " + operation }
    else { command = "git-credential-" + helper + " " + operation }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    let helperDirectories = [
      "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
      "/usr/libexec/git-core", "/Library/Developer/CommandLineTools/usr/libexec/git-core",
      "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core",
      NSHomeDirectory() + "/.local/bin",
    ]
    environment["PATH"] = ([environment["PATH"]].compactMap { $0 }.filter { !$0.isEmpty } + helperDirectories)
      .joined(separator: ":")
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let request = fields.keys.sorted().compactMap { key -> String? in
      guard let value = fields[key], !value.contains("\n"), !value.contains("\r") else { return nil }
      return "\(key)=\(value)\n"
    }.joined() + "\n"
    try? input.fileHandleForWriting.write(contentsOf: Data(request.utf8))
    try? input.fileHandleForWriting.close()
    let response = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: response, encoding: .utf8)
  }
}
