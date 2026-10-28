import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated struct GithubCLIClient: Sendable {
  var latestRun: @Sendable (URL, String) async throws -> ForgeWorkflowRun?
  var resolveRemoteInfo: @Sendable (URL) async -> GithubRemoteInfo?
  var batchPullRequests: @Sendable (String, String, String, [String]) async throws -> [String: ForgePullRequest]
  var mergePullRequest:
    @Sendable (URL, GithubRemoteInfo?, Int, PullRequestMergeStrategy, PullRequestMergeAction) async throws ->
      PullRequestMergeOutcome
  var closePullRequest: @Sendable (URL, GithubRemoteInfo?, Int) async throws -> Void
  var markPullRequestReady: @Sendable (URL, GithubRemoteInfo?, Int) async throws -> Void
  var pullRequestDiff: @Sendable (GithubRemoteInfo, Int) async throws -> String
  var rerunFailedJobs: @Sendable (URL, Int) async throws -> Void
  var failedRunLogs: @Sendable (URL, Int) async throws -> String
  var runLogs: @Sendable (URL, Int) async throws -> String
  var isAvailable: @Sendable () async -> Bool
  var authStatus: @Sendable () async throws -> GithubAuthStatus?
  var authenticatedHosts: @Sendable () async throws -> Set<String>
}

nonisolated extension GithubCLIClient: DependencyKey {
  static let liveValue = live()

  /// GitHub operations use the native HTTP client; gh is only the credential provider.
  static func live(
    shell: ShellClient = .liveValue,
    fallbackExecutableURLs: [URL] = ForgeCLIExecutableResolver.defaultFallbackExecutableURLs(executableName: "gh"),
    git: GitClientDependency? = nil,
    configuredHosts: (@Sendable () async throws -> Set<String>)? = nil,
    repositorySelection: (@Sendable (URL) async -> GithubRepositorySelection?)? = nil
  ) -> GithubCLIClient {
    @Dependency(GithubHTTPClient.self) var http
    let credentials = GithubCredentials(
      shell: shell, fallbackExecutableURLs: fallbackExecutableURLs, configuredHosts: configuredHosts)
    let api = GithubAPIClient(http: http, credentials: credentials, git: git, repositorySelection: repositorySelection)
    return GithubCLIClient(
      latestRun: { try await api.latestRun(root: $0, branch: $1) },
      resolveRemoteInfo: { await api.resolveRemoteInfo(root: $0) },
      batchPullRequests: { try await api.batchPullRequests(host: $0, owner: $1, repo: $2, branches: $3) },
      mergePullRequest: { try await api.merge(root: $0, remote: $1, number: $2, strategy: $3, action: $4) },
      closePullRequest: { try await api.close(root: $0, remote: $1, number: $2) },
      markPullRequestReady: { try await api.markReady(root: $0, remote: $1, number: $2) },
      pullRequestDiff: { try await api.diff(remote: $0, number: $1) },
      rerunFailedJobs: { try await api.rerun(root: $0, runID: $1) },
      failedRunLogs: { try await api.logs(root: $0, runID: $1, failedOnly: true) },
      runLogs: { try await api.logs(root: $0, runID: $1, failedOnly: false) },
      isAvailable: { await credentials.isAvailable() },
      authStatus: { try await api.authStatus() },
      authenticatedHosts: { try await credentials.authenticatedHosts() }
    )
  }

  static let testValue = GithubCLIClient(
    latestRun: { _, _ in nil },
    resolveRemoteInfo: { _ in nil },
    batchPullRequests: { _, _, _, _ in [:] },
    mergePullRequest: { _, _, _, _, _ in .merged },
    closePullRequest: { _, _, _ in },
    markPullRequestReady: { _, _, _ in },
    pullRequestDiff: { _, _ in "" },
    rerunFailedJobs: { _, _ in },
    failedRunLogs: { _, _ in "" },
    runLogs: { _, _ in "" },
    isAvailable: { true },
    authStatus: { GithubAuthStatus(username: "testuser", host: "github.com") },
    authenticatedHosts: { ["github.com"] }
  )
}

nonisolated extension DependencyValues {
  var githubCLI: GithubCLIClient {
    get { self[GithubCLIClient.self] }
    set { self[GithubCLIClient.self] = newValue }
  }
}
