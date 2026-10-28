import Foundation
import SupacodeSettingsShared

/// Uses gh's active account, keychain and environment-token precedence without
/// ever logging credentials or persisting a second copy of them.
actor GithubCredentials {
  private let shell: ShellClient
  private let resolver: ForgeCLIExecutableResolver
  private let configuredHosts: @Sendable () async throws -> Set<String>
  private var cached: [String: (token: String, fetchedAt: ContinuousClock.Instant)] = [:]
  private var inFlight: [String: Task<String, Error>] = [:]

  init(
    shell: ShellClient,
    fallbackExecutableURLs: [URL],
    configuredHosts: (@Sendable () async throws -> Set<String>)? = nil
  ) {
    self.shell = shell
    self.resolver = ForgeCLIExecutableResolver(executableName: "gh", fallbackExecutableURLs: fallbackExecutableURLs)
    self.configuredHosts = configuredHosts ?? { Self.localConfiguredHosts() }
  }

  func isAvailable() async -> Bool {
    (try? await resolver.executableURL(shell: shell)) != nil
  }

  func token(for host: String) async throws -> String {
    let host = host.lowercased()
    if let entry = cached[host], entry.fetchedAt.duration(to: .now) < .seconds(60) { return entry.token }
    if let task = inFlight[host] { return try await task.value }
    let task = Task { [shell, resolver] in
      do {
        let executable = try await resolver.executableURL(shell: shell)
        let output: ShellOutput
        do {
          output = try await shell.runLogin(executable, ["auth", "token", "--hostname", host], nil, log: false)
        } catch {
          guard ForgeCLIExecutableResolver.shouldRetryExecution(after: error) else { throw error }
          await resolver.invalidate()
          let executable = try await resolver.executableURL(shell: shell)
          output = try await shell.runLogin(executable, ["auth", "token", "--hostname", host], nil, log: false)
        }
        // Shell startup banners precede gh's result. Tokens are one line.
        guard let last = output.stdout.split(whereSeparator: \.isNewline).last else {
          throw URLError(.userAuthenticationRequired)
        }
        let token = last.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
          throw URLError(.userAuthenticationRequired)
        }
        return token
      } catch is ForgeCLIResolutionError {
        throw GithubCLIError.unavailable
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Shell errors may include stdout. Never forward them: stdout can contain a token.
        throw GithubCLIError.commandFailed(
          "Could not read GitHub credentials for \(host). Run gh auth login --hostname \(host).")
      }
    }
    inFlight[host] = task
    defer { inFlight[host] = nil }
    let token = try await task.value
    cached[host] = (token, .now)
    return token
  }

  func invalidate(_ host: String) { cached[host.lowercased()] = nil }

  func authenticatedHosts() async throws -> Set<String> {
    var hosts = try await configuredHosts()
    hosts.insert(ProcessInfo.processInfo.environment["GH_HOST"] ?? "github.com")
    var authenticated: Set<String> = []
    for host in hosts where (try? await token(for: host)) != nil { authenticated.insert(host.lowercased()) }
    return authenticated
  }

  nonisolated static func hosts(in configuration: String) -> Set<String> {
    Set(
      configuration.split(whereSeparator: \.isNewline).compactMap { line in
        guard line.first?.isWhitespace == false, line.hasSuffix(":") else { return nil }
        let host = String(line.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return !host.isEmpty && !host.contains(where: { $0.isWhitespace || $0 == "/" }) ? host.lowercased() : nil
      })
  }

  nonisolated private static func localConfiguredHosts() -> Set<String> {
    let env = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser
    let config =
      env["GH_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
      ?? env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0).appending(path: "gh") }
      ?? home.appending(path: ".config/gh")
    guard let text = try? String(contentsOf: config.appending(path: "hosts.yml"), encoding: .utf8) else { return [] }
    return hosts(in: text)
  }
}
