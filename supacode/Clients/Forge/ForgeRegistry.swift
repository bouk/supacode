import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Registered forges and per-repository resolution: override, exact known
/// hosts, authenticated-host membership, substrings; never a default.
struct ForgeRegistry: Sendable {
  var resolveForgeID: @MainActor @Sendable (URL, RemoteHost?) async -> ForgeID?
  var client: @Sendable (ForgeID) -> ForgeClient?
  var capabilities: @Sendable (ForgeID) -> ForgeCapabilities?
}

/// Short-lived caches so bursts of per-repo resolution (selection refreshes,
/// user actions, the sweep itself) don't spawn an auth-status or git process
/// per call.
private actor ForgeResolutionCache {
  private struct AuthKey: Hashable {
    let forgeID: ForgeID
    let host: RemoteHost?
  }

  private var hostsByForge: [AuthKey: (hosts: Set<String>, fetchedAt: ContinuousClock.Instant)] = [:]
  private var remoteHostsByRepo: [RepositorySettingsKeyID: (host: String?, fetchedAt: ContinuousClock.Instant)] = [:]
  private let ttl: Duration = .seconds(30)
  // Nil can mean either "no remote" or a transient git failure; keep it long
  // enough to spare the sweep, short enough that a fixed remote is picked up.
  private let negativeTTL: Duration = .seconds(5)
  private let clock = ContinuousClock()

  func authenticatedHosts(
    for forgeID: ForgeID,
    host: RemoteHost?,
    fetch: @Sendable () async throws -> Set<String>
  ) async -> Set<String> {
    let key = AuthKey(forgeID: forgeID, host: host)
    if let cached = hostsByForge[key], cached.fetchedAt.duration(to: clock.now) < ttl {
      return cached.hosts
    }
    do {
      let hosts = try await fetch()
      hostsByForge[key] = (hosts, clock.now)
      return hosts
    } catch {
      // A transient failure must not pin an empty host set for a full TTL.
      SupaLogger("ForgeRegistry").warning("Authenticated-hosts read failed for \(forgeID.rawValue): \(error)")
      return hostsByForge[key]?.hosts ?? []
    }
  }

  func remoteHost(
    for rootURL: URL,
    host: RemoteHost?,
    fetch: @Sendable () async -> String?
  ) async -> String? {
    let key = RepositorySettingsKey(rootURL: rootURL, host: host).id
    if let cached = remoteHostsByRepo[key] {
      let age = cached.fetchedAt.duration(to: clock.now)
      if age < (cached.host == nil ? negativeTTL : ttl) {
        return cached.host
      }
    }
    var host = await fetch()
    if host?.isEmpty == true {
      host = nil
    }
    remoteHostsByRepo[key] = (host, clock.now)
    return host
  }
}

private let forgeResolutionCache = ForgeResolutionCache()

extension ForgeRegistry {
  /// Every registered forge, in a stable dispatch order.
  nonisolated static let registeredForgeIDs: [ForgeID] = [.github, .gitlab]

  /// Enabled forges in registry order, the one filter every gate shares.
  nonisolated static func enabledForgeIDs(in settings: GlobalSettings) -> [ForgeID] {
    var enabled: [ForgeID] = []
    for forgeID in registeredForgeIDs {
      guard settings.forgeIntegrationEnabled(forID: forgeID.rawValue) else { continue }
      enabled.append(forgeID)
    }
    return enabled
  }

  nonisolated static func registeredClient(for forgeID: ForgeID) -> ForgeClient? {
    switch forgeID {
    case .github: .github
    case .gitlab: .gitlab
    default: nil
    }
  }

  nonisolated static func knownHostSubstrings(for forgeID: ForgeID) -> [String] {
    switch forgeID {
    case .github: ["github"]
    case .gitlab: ["gitlab"]
    default: []
    }
  }

  nonisolated static func candidate(
    for forgeID: ForgeID,
    authenticatedHosts: Set<String>
  ) -> ForgeResolver.Candidate {
    ForgeResolver.Candidate(
      id: forgeID,
      authenticatedHosts: authenticatedHosts,
      knownHostSubstrings: knownHostSubstrings(for: forgeID)
    )
  }
}

nonisolated extension ForgeRegistry: DependencyKey {
  static let liveValue = ForgeRegistry(
    resolveForgeID: { rootURL, host in
      await ForgeRegistry.resolveLive(rootURL: rootURL, host: host)
    },
    client: { forgeID in
      ForgeRegistry.registeredClient(for: forgeID)
    },
    capabilities: { forgeID in
      ForgeCapabilities.forID(forgeID)
    }
  )

  static let testValue = ForgeRegistry(
    resolveForgeID: { _, _ in .github },
    client: { forgeID in
      ForgeRegistry.registeredClient(for: forgeID)
    },
    capabilities: { forgeID in
      ForgeCapabilities.forID(forgeID)
    }
  )

  @MainActor
  private static func resolveLive(rootURL: URL, host: RemoteHost?) async -> ForgeID? {
    @Shared(.settingsFile) var settingsFile

    let enabledForgeIDs = enabledForgeIDs(in: settingsFile.global)
    // An explicit override needs no remote read.
    let override = RepositorySettingsKey(rootURL: rootURL, host: host).currentSettings().forgeID
    if let override, !override.isEmpty {
      return ForgeResolver.resolve(
        host: nil,
        override: override,
        candidates: enabledForgeIDs.map { candidate(for: $0, authenticatedHosts: []) }
      )
    }

    @Dependency(GitClientDependency.self) var gitClient
    let remoteHost = await forgeResolutionCache.remoteHost(for: rootURL, host: host) {
      await gitClient.gitRemote(rootURL)?.host
    }
    guard let remoteHost = remoteHost?.lowercased(), !remoteHost.isEmpty else { return nil }

    // Exact well-known hosts resolve without touching any CLI's auth
    // configuration; ambiguous hosts take the full ladder below.
    let exactKnownHosts: [String: ForgeID] = ["github.com": .github, "gitlab.com": .gitlab]
    if let known = exactKnownHosts[remoteHost], enabledForgeIDs.contains(known) {
      return known
    }

    @Dependency(GithubCLIClient.self) var githubCLI
    @Dependency(GitLabCLIClient.self) var gitlabCLI
    var candidates: [ForgeResolver.Candidate] = []
    for forgeID in enabledForgeIDs {
      let hosts = await forgeResolutionCache.authenticatedHosts(for: forgeID, host: host) {
        switch forgeID {
        case .github: try await githubCLI.authenticatedHosts()
        case .gitlab: await gitlabCLI.authenticatedHosts()
        default: []
        }
      }
      candidates.append(candidate(for: forgeID, authenticatedHosts: hosts))
    }
    return ForgeResolver.resolve(host: remoteHost, override: nil, candidates: candidates)
  }
}

extension ForgeRegistry {
  /// Run repository and forge commands where the checkout and CLI credentials live.
  /// Local registries keep their injected clients unchanged.
  func forHost(_ host: RemoteHost?) -> Self {
    guard let host else { return self }
    @Dependency(ShellClient.self) var shell
    let environment = RemoteForgeEnvironment(host: host, base: shell)
    return Self(
      resolveForgeID: { root, host in
        await environment.run { await self.resolveForgeID(root, host) }
      },
      client: { id in self.client(id).map { environment.scope($0) } },
      capabilities: capabilities
    )
  }
}

private struct RemoteForgeEnvironment: Sendable {
  let git: GitClientDependency
  let github: GithubCLIClient
  let gitlab: GitLabCLIClient

  init(host: RemoteHost, base: ShellClient) {
    let shell = ShellClient.ssh(host: host, base: base)
    git = .ssh(host: host, base: base)
    // A local Homebrew path says nothing about the remote host's executables.
    github = .live(
      shell: shell, fallbackExecutableURLs: [], git: git,
      configuredHosts: {
        let script =
          #"printf '%s:\n' "${GH_HOST:-github.com}"; config=${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}; if [ -f "$config/hosts.yml" ]; then grep -E '^[A-Za-z0-9._-]+:$' "$config/hosts.yml"; fi"#
        let output = try await shell.runLogin(URL(fileURLWithPath: "/bin/sh"), ["-c", script], nil, log: false)
        return GithubCredentials.hosts(in: output.stdout)
      }, repositorySelection: { await GithubRepositorySelection.remote(at: $0, shell: shell) })
    gitlab = .live(shell: shell, fallbackExecutableURLs: [], remoteConfiguration: true)
  }

  @MainActor
  func run<T>(_ operation: () async throws -> T) async rethrows -> T {
    try await withDependencies {
      $0[GitClientDependency.self] = git
      $0[GithubCLIClient.self] = github
      $0[GitLabCLIClient.self] = gitlab
    } operation: {
      try await operation()
    }
  }

  nonisolated func scope(_ client: ForgeClient) -> ForgeClient {
    ForgeClient(
      resolveProject: { root in await run { await client.resolveProject(root) } },
      fetchSummaries: { project, branches in try await run { try await client.fetchSummaries(project, branches) } },
      fetchDetail: { project, number in try await run { try await client.fetchDetail(project, number) } },
      mergePullRequest: { root, project, number, strategy, action in
        try await run { try await client.mergePullRequest(root, project, number, strategy, action) }
      },
      closePullRequest: { root, project, number in
        try await run { try await client.closePullRequest(root, project, number) }
      },
      markPullRequestReady: { root, project, number in
        try await run { try await client.markPullRequestReady(root, project, number) }
      },
      pullRequestDiff: { project, number in try await run { try await client.pullRequestDiff(project, number) } },
      latestRun: { root, branch in try await run { try await client.latestRun(root, branch) } },
      rerunFailedJobs: { root, run in try await self.run { try await client.rerunFailedJobs(root, run) } },
      failedRunLogs: { root, run in try await self.run { try await client.failedRunLogs(root, run) } },
      runLogs: { root, run in try await self.run { try await client.runLogs(root, run) } },
      isAvailable: { await run { await client.isAvailable() } }
    )
  }
}
