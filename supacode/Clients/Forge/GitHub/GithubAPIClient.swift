import Dependencies
import Foundation
import SupacodeSettingsShared

/// Native, typed GitHub REST/GraphQL operations. Authentication is supplied by gh;
/// no GitHub operation is executed by the CLI.
nonisolated struct GithubAPIClient: Sendable {
  let http: GithubHTTPClient
  let credentials: GithubCredentials
  let git: GitClientDependency?
  var repositorySelection: (@Sendable (URL) async -> GithubRepositorySelection?)? = nil

  private func remote(root: URL, provided: GithubRemoteInfo? = nil) async throws -> GithubRemoteInfo {
    if let provided { return provided }
    guard let remote = await resolveRemoteInfo(root: root) else {
      throw GithubCLIError.commandFailed("Could not resolve the GitHub repository for this worktree.")
    }
    return remote
  }

  func resolveRemoteInfo(root: URL) async -> GithubRemoteInfo? {
    @Dependency(GitClientDependency.self) var dependency
    let git = git ?? dependency
    let selection: GithubRepositorySelection?
    if let repositorySelection {
      selection = await repositorySelection(root)
    } else if self.git == nil {
      selection = GithubRepositorySelection.native(at: root)
    } else {
      selection = nil
    }
    let candidate: GithubRemoteInfo?
    if let selection {
      candidate = selection.remote
    } else if let known = await git.remoteInfo(root) {
      candidate = known
    } else if let remote = await git.gitRemote(root), remote.pathComponents.count == 2 {
      // Forge resolution already identified GitHub; Enterprise hostnames need
      // not contain "github".
      candidate = GithubRemoteInfo(host: remote.host, owner: remote.pathComponents[0], repo: remote.pathComponents[1])
    } else {
      candidate = nil
    }
    guard let remote = candidate else { return nil }
    do {
      let repository = try await rest(Repository.self, remote: remote, path: "")
      // Like gh, prefer the base repository when working in a fork.
      let base = selection == nil ? repository.parent ?? repository : repository
      return GithubRemoteInfo(host: remote.host, owner: base.owner.login, repo: base.name)
    } catch {
      return remote
    }
  }

  func batchPullRequests(host: String, owner: String, repo: String, branches: [String]) async throws -> [String:
    ForgePullRequest]
  {
    var seen: Set<String> = []
    let branches = branches.filter { !$0.isEmpty && seen.insert($0).inserted }
    let chunks = stride(from: 0, to: branches.count, by: 5).map { Array(branches[$0..<min($0 + 5, branches.count)]) }
    return try await withThrowingTaskGroup(of: (Int, [String: ForgePullRequest]).self) { group in
      var next = 0
      for _ in 0..<min(3, chunks.count) {
        let index = next
        group.addTask {
          (index, try await self.pullRequests(host: host, owner: owner, repo: repo, branches: chunks[index]))
        }
        next += 1
      }
      var results: [Int: [String: ForgePullRequest]] = [:]
      while let (index, chunk) = try await group.next() {
        results[index] = chunk
        if next < chunks.count {
          let index = next
          group.addTask {
            (index, try await self.pullRequests(host: host, owner: owner, repo: repo, branches: chunks[index]))
          }
          next += 1
        }
      }
      return results.keys.sorted().reduce(into: [:]) { $0.merge(results[$1] ?? [:]) { _, new in new } }
    }
  }

  private func pullRequests(host: String, owner: String, repo: String, branches: [String]) async throws -> [String:
    ForgePullRequest]
  {
    @Dependency(\.continuousClock) var clock
    var optional = Set(GithubOptionalPullRequestField.allCases)
    var gatewayRetried = false
    while true {
      let (query, aliases) = GithubPullRequestQuery.batchQuery(branches: branches, optionalFields: optional)
      do {
        let response = try await graphQL(
          GithubGraphQLPullRequestResponse.self, host: host, query: query,
          variables: ["owner": owner, "repo": repo])
        return response.pullRequestsByBranch(aliasMap: aliases, owner: owner, repo: repo)
      } catch GithubCLIError.gatewayTimeout where !gatewayRetried {
        gatewayRetried = true
        try await clock.sleep(for: .seconds(1))
      } catch {
        let rejected = GithubOptionalPullRequestField.rejected(by: error).intersection(optional)
        guard !rejected.isEmpty else { throw error }
        optional.subtract(rejected)
      }
    }
  }

  func merge(
    root: URL, remote provided: GithubRemoteInfo?, number: Int, strategy: PullRequestMergeStrategy,
    action: PullRequestMergeAction
  ) async throws -> PullRequestMergeOutcome {
    let remote = try await remote(root: root, provided: provided)
    let state = try await mergeState(remote: remote, number: number)
    guard state.state == "OPEN", !state.isDraft else {
      throw GithubCLIError.commandFailed("Only open pull requests that are ready for review can be merged.")
    }
    if action == .disableAutoMerge {
      try await mutate(
        host: remote.host, operation: "disablePullRequestAutoMerge", inputType: "DisablePullRequestAutoMergeInput",
        input: ["pullRequestId": state.id])
      return .autoMergeDisabled
    }
    if state.isInMergeQueue == true { return .queued }
    if state.autoMergeRequest != nil { return .autoMergeEnabled }
    guard state.mergeable != "CONFLICTING", state.mergeStateStatus != "DIRTY" else {
      throw GithubCLIError.commandFailed("Resolve the pull request's merge conflicts before merging.")
    }
    var input: [String: String] = ["pullRequestId": state.id, "expectedHeadOid": state.headRefOid]
    let immediate = ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(state.mergeStateStatus ?? "")
    if state.isMergeQueueEnabled == true, immediate {
      try await mutate(
        host: remote.host, operation: "enqueuePullRequest", inputType: "EnqueuePullRequestInput", input: input)
      return .queued
    }
    input["mergeMethod"] = strategy.rawValue.uppercased()
    if !immediate, state.viewerCanEnableAutoMerge == true || state.isMergeQueueEnabled == true {
      try await mutate(
        host: remote.host, operation: "enablePullRequestAutoMerge", inputType: "EnablePullRequestAutoMergeInput",
        input: input)
      return .autoMergeEnabled
    }
    guard immediate else {
      throw GithubCLIError.commandFailed(
        "GitHub's branch requirements prohibit merging. Auto-merge is unavailable for this pull request.")
    }
    try await mutate(host: remote.host, operation: "mergePullRequest", inputType: "MergePullRequestInput", input: input)
    return .merged
  }

  func close(root: URL, remote provided: GithubRemoteInfo?, number: Int) async throws {
    let remote = try await remote(root: root, provided: provided)
    _ = try await request(remote: remote, path: "/pulls/\(number)", method: "PATCH", body: ["state": "closed"])
  }

  func markReady(root: URL, remote provided: GithubRemoteInfo?, number: Int) async throws {
    let remote = try await remote(root: root, provided: provided)
    let state = try await mergeState(remote: remote, number: number)
    try await mutate(
      host: remote.host, operation: "markPullRequestReadyForReview", inputType: "MarkPullRequestReadyForReviewInput",
      input: ["pullRequestId": state.id])
  }

  func diff(remote: GithubRemoteInfo, number: Int) async throws -> String {
    String(
      decoding: try await request(remote: remote, path: "/pulls/\(number)", accept: "application/vnd.github.diff"),
      as: UTF8.self)
  }

  func latestRun(root: URL, branch: String) async throws -> ForgeWorkflowRun? {
    let remote = try await remote(root: root)
    let runs = try await rest(
      Runs.self, remote: remote, path: "/actions/runs",
      query: [URLQueryItem(name: "branch", value: branch), URLQueryItem(name: "per_page", value: "1")])
    return runs.workflow_runs.first.map { run in
      ForgeWorkflowRun(
        databaseId: run.id, workflowName: run.name, name: run.name, displayTitle: run.display_title,
        status: run.status, conclusion: run.conclusion, createdAt: run.created_at, updatedAt: run.updated_at)
    }
  }

  func rerun(root: URL, runID: Int) async throws {
    let remote = try await remote(root: root)
    _ = try await request(remote: remote, path: "/actions/runs/\(runID)/rerun-failed-jobs", method: "POST")
  }

  func logs(root: URL, runID: Int, failedOnly: Bool) async throws -> String {
    let remote = try await remote(root: root)
    var page = 1
    var output: [String] = []
    while true {
      let response = try await rest(
        Jobs.self, remote: remote, path: "/actions/runs/\(runID)/jobs",
        query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: "\(page)")])
      for job in response.jobs
      where !failedOnly || ["failure", "timed_out", "startup_failure"].contains(job.conclusion ?? "") {
        try Task.checkCancellation()
        let data = try await request(
          remote: remote, path: "/actions/jobs/\(job.id)/logs", accept: "application/vnd.github+json")
        output.append("\(job.name)\n\(String(decoding: data, as: UTF8.self))")
      }
      guard response.jobs.count == 100 else { break }
      page += 1
    }
    return output.joined(separator: "\n\n")
  }

  func authStatus() async throws -> GithubAuthStatus? {
    let hosts = try await credentials.authenticatedHosts().sorted { lhs, rhs in
      if lhs == "github.com" { return true }
      if rhs == "github.com" { return false }
      return lhs < rhs
    }
    guard let host = hosts.first else { return nil }
    let data = try await send(host: host, url: Self.url(host: host, path: "/user"))
    let user = try Self.decoder().decode(User.self, from: data)
    return GithubAuthStatus(username: user.login, host: host)
  }

  private func mergeState(remote: GithubRemoteInfo, number: Int) async throws -> MergeState {
    var optional = Set(GithubOptionalPullRequestField.allCases).subtracting([
      .mergeQueueEntry, .latestOpinionatedReviews,
    ])
    while true {
      do {
        let selections = optional.sorted { $0.rawValue < $1.rawValue }.map(\.selection).joined(separator: "\n")
        let response = try await graphQL(
          MergeResponse.self, host: remote.host,
          query: """
            query($owner: String!, $repo: String!, $number: Int!) {
              repository(owner: $owner, name: $repo) {
                pullRequest(number: $number) {
                  id state isDraft headRefOid mergeable mergeStateStatus
                  \(selections)
                }
              }
            }
            """, variables: ["owner": remote.owner, "repo": remote.repo, "number": number])
        guard let state = response.data.repository.pullRequest else {
          throw GithubCLIError.commandFailed("Pull request #\(number) was not found.")
        }
        return state
      } catch {
        let rejected = GithubOptionalPullRequestField.rejected(by: error).intersection(optional)
        guard !rejected.isEmpty else { throw error }
        optional.subtract(rejected)
      }
    }
  }

  private func mutate(host: String, operation: String, inputType: String, input: [String: String]) async throws {
    let query = "mutation($input: \(inputType)!) { \(operation)(input: $input) { clientMutationId } }"
    let data = try await graphQLData(host: host, query: query, variables: ["input": input])
    let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let result = (envelope?["data"] as? [String: Any])?[operation] as? [String: Any], !result.isEmpty else {
      throw GithubCLIError.commandFailed("GitHub did not confirm the pull request update.")
    }
  }

  private func graphQL<T: Decodable>(_ type: T.Type, host: String, query: String, variables: [String: Any]) async throws
    -> T
  {
    try Self.decoder().decode(type, from: await graphQLData(host: host, query: query, variables: variables))
  }

  private func graphQLData(host: String, query: String, variables: [String: Any]) async throws -> Data {
    let url = try Self.url(host: host, path: "", graphQL: true)
    let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    let data = try await send(host: host, url: url, method: "POST", body: body)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    if let errors = object?["errors"] as? [[String: Any]], !errors.isEmpty {
      let message = errors.compactMap { $0["message"] as? String }.joined(separator: "\n")
      throw GithubCLIError.commandFailed(message.isEmpty ? "GitHub rejected the GraphQL request." : message)
    }
    guard object?["data"] is [String: Any] else { throw GithubCLIError.commandFailed("GitHub returned no data.") }
    return data
  }

  private func rest<T: Decodable>(_ type: T.Type, remote: GithubRemoteInfo, path: String, query: [URLQueryItem] = [])
    async throws -> T
  {
    try Self.decoder().decode(type, from: await request(remote: remote, path: path, query: query))
  }

  private func request(
    remote: GithubRemoteInfo, path: String, method: String = "GET", query: [URLQueryItem] = [],
    body: [String: String]? = nil, accept: String = "application/vnd.github+json"
  ) async throws -> Data {
    guard
      [remote.owner, remote.repo].allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\")
      })
    else { throw URLError(.badURL) }
    let url = try Self.url(host: remote.host, path: "/repos/\(remote.owner)/\(remote.repo)" + path, query: query)
    return try await send(
      host: remote.host, url: url, method: method,
      body: body.map { try JSONEncoder().encode($0) }, accept: accept)
  }

  private func send(
    host: String, url: URL, method: String = "GET", body: Data? = nil,
    accept: String = "application/vnd.github+json"
  ) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 30
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("Supacode", forHTTPHeaderField: "User-Agent")
    for attempt in 0...1 {
      request.setValue("Bearer \(try await credentials.token(for: host))", forHTTPHeaderField: "Authorization")
      let (data, response) = try await http.data(request)
      if response.statusCode == 401, attempt == 0 {
        await credentials.invalidate(host)
        continue
      }
      if response.statusCode == 504 { throw GithubCLIError.gatewayTimeout }
      guard (200..<300).contains(response.statusCode) else {
        let message = (try? JSONDecoder().decode(APIError.self, from: data))?.message
        throw GithubCLIError.commandFailed(message ?? "GitHub request failed (HTTP \(response.statusCode)).")
      }
      return data
    }
    throw URLError(.userAuthenticationRequired)
  }

  static func url(host: String, path: String, query: [URLQueryItem] = [], graphQL: Bool = false) throws -> URL {
    guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }) else {
      throw URLError(.badURL)
    }
    var components = URLComponents()
    components.scheme = "https"
    let host = host.lowercased()
    let cloud = host == "github.com" || host.hasSuffix(".ghe.com")
    components.host = cloud ? "api.\(host)" : host
    components.path =
      graphQL
      ? (cloud ? "/graphql" : "/api/graphql")
      : (cloud ? "" : "/api/v3") + path
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else { throw URLError(.badURL) }
    return url
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private struct APIError: Decodable { let message: String }
  private struct User: Decodable { let login: String }
  private final class Repository: Decodable, Sendable {
    let name: String
    let owner: User
    let parent: Repository?
  }
  private struct Runs: Decodable { let workflow_runs: [Run] }
  private struct Run: Decodable {
    let id: Int
    let name: String?
    let display_title: String?
    let status: String
    let conclusion: String?
    let created_at: Date?
    let updated_at: Date?
  }
  private struct Jobs: Decodable { let jobs: [Job] }
  private struct Job: Decodable {
    let id: Int
    let name: String
    let conclusion: String?
  }
  private struct MergeResponse: Decodable {
    let data: Container
    struct Container: Decodable { let repository: PullRequestContainer }
    struct PullRequestContainer: Decodable { let pullRequest: MergeState? }
  }
  private struct MergeState: Decodable {
    let id: String
    let state: String
    let isDraft: Bool
    let headRefOid: String
    let mergeable: String?
    let mergeStateStatus: String?
    let isMergeQueueEnabled: Bool?
    let isInMergeQueue: Bool?
    let viewerCanEnableAutoMerge: Bool?
    let autoMergeRequest: AutoMergeRequest?
    struct AutoMergeRequest: Decodable { let enabledAt: String }
  }
}
