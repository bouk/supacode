import Foundation
import SupacodeSettingsShared

/// Preserve gh repo set-default without invoking gh repo view. An explicit
/// choice of a fork must not silently follow its parent repository.
nonisolated struct GithubRepositorySelection: Sendable {
  let remote: GithubRemoteInfo

  static func native(at root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
    if let override = environment["GH_REPO"], let remote = parse(override, host: environment["GH_HOST"] ?? "github.com")
    {
      return Self(remote: remote)
    }
    guard let selection = try? NativeGitRepository.configuredRemote(at: root, marker: "gh-resolved") else { return nil }
    return Self.from(url: selection.url, resolution: selection.value)
  }

  static func remote(at root: URL, shell: ShellClient) async -> Self? {
    do {
      let output = try await shell.runLogin(
        URL(fileURLWithPath: "/usr/bin/env"),
        ["git", "config", "--get-regexp", #"^remote\..*\.gh-resolved$"#], root, log: false)
      for line in output.stdout.split(whereSeparator: \.isNewline) {
        let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, parts[0].hasPrefix("remote."), parts[0].hasSuffix(".gh-resolved") else { continue }
        let name = String(parts[0].dropFirst("remote.".count).dropLast(".gh-resolved".count))
        let url = try await shell.runLogin(
          URL(fileURLWithPath: "/usr/bin/env"), ["git", "remote", "get-url", name], root, log: false)
        if let selection = Self.from(
          url: url.stdout.trimmingCharacters(in: .whitespacesAndNewlines), resolution: String(parts[1]))
        {
          return selection
        }
      }
    } catch {}
    return nil
  }

  private static func from(url: String, resolution: String) -> Self? {
    guard let parsed = GitRemote.parse(url), parsed.pathComponents.count == 2 else { return nil }
    let remote = GithubRemoteInfo(host: parsed.host, owner: parsed.pathComponents[0], repo: parsed.pathComponents[1])
    if resolution == "base" { return Self(remote: remote) }
    return parse(resolution, host: remote.host).map { Self(remote: $0) }
  }

  private static func parse(_ repository: String, host: String) -> GithubRemoteInfo? {
    let parts = repository.split(separator: "/")
    if parts.count == 2 { return GithubRemoteInfo(host: host, owner: String(parts[0]), repo: String(parts[1])) }
    if parts.count == 3 {
      return GithubRemoteInfo(host: String(parts[0]), owner: String(parts[1]), repo: String(parts[2]))
    }
    return nil
  }
}
