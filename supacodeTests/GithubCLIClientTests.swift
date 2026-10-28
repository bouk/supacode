import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

nonisolated struct GithubCLIClientTests {
  private actor RequestGate {
    private var arrivals = 0
    private var active = 0
    private var maximum = 0
    private var opened = false
    private var ready: CheckedContinuation<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
      arrivals += 1
      active += 1
      maximum = max(maximum, active)
      if arrivals == 3 {
        ready?.resume()
        ready = nil
      }
      if !opened { await withCheckedContinuation { waiting.append($0) } }
    }
    func leave() { active -= 1 }
    func waitUntilThree() async {
      if arrivals < 3 { await withCheckedContinuation { ready = $0 } }
    }
    func open() {
      opened = true
      waiting.forEach { $0.resume() }
      waiting = []
    }
    func snapshot() -> (count: Int, maximum: Int) { (arrivals, maximum) }
  }

  @Test func batchConcurrencyAndCredentialLookupAreBounded() async throws {
    let gate = RequestGate()
    let tokens = LockIsolated<[[String]]>([])
    let client = Self.api(
      { request in
        await gate.enter()
        await gate.leave()
        return Self.response(request, #"{"data":{"repository":{"branch0":{"nodes":[]}}}}"#)
      }, credentials: Self.credentials(calls: tokens))
    let task = Task {
      try await client.batchPullRequests(
        host: "github.com", owner: "owner", repo: "repo",
        branches: (0..<40).map { "feature-\($0)" })
    }
    await gate.waitUntilThree()
    #expect(await gate.snapshot().maximum == 3)
    await gate.open()
    _ = try await task.value
    #expect(await gate.snapshot().count == 8)
    #expect(tokens.value.count == 1)
  }

  @Test func logRedirectsNeverForwardTokensToStorage() {
    var request = URLRequest(url: URL(string: "https://storage.example.com/log.txt")!)
    request.setValue("Bearer fake-secret", forHTTPHeaderField: "Authorization")
    let original = URL(string: "https://api.github.com/repos/owner/repo/actions/jobs/1/logs")!
    #expect(
      GithubHTTPClient.redirectedRequest(request, from: original)?.value(forHTTPHeaderField: "Authorization") == nil)
    request.url = URL(string: "http://storage.example.com/log.txt")!
    #expect(GithubHTTPClient.redirectedRequest(request, from: original) == nil)
    request.url = URL(string: "https://api.github.com/log.txt")!
    #expect(
      GithubHTTPClient.redirectedRequest(request, from: original)?.value(forHTTPHeaderField: "Authorization")
        == "Bearer fake-secret")
  }

  @Test @MainActor func nativeRepositorySelectionHonorsGhSetDefault() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "github-default-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.path(percentEncoded: false)
    try await Self.git(["init", path])
    try await Self.git(["-C", path, "remote", "add", "origin", "https://github.com/me/fork.git"])
    try await Self.git(["-C", path, "config", "remote.origin.gh-resolved", "base"])
    #expect(
      GithubRepositorySelection.native(at: directory, environment: [:])?.remote
        == GithubRemoteInfo(host: "github.com", owner: "me", repo: "fork"))
    try await Self.git(["-C", path, "config", "remote.origin.gh-resolved", "upstream/repo"])
    #expect(
      GithubRepositorySelection.native(at: directory, environment: [:])?.remote
        == Self.remoteWithOwner("upstream"))
    #expect(
      GithubRepositorySelection.native(at: directory, environment: ["GH_REPO": "other/project"])?.remote
        == GithubRemoteInfo(host: "github.com", owner: "other", repo: "project"))
  }

  private static func git(_ arguments: [String]) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging([
      "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    ]) { _, new in new }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try await process.runToExit()
    #expect(process.terminationStatus == 0)
  }

  private static func remoteWithOwner(_ owner: String) -> GithubRemoteInfo {
    GithubRemoteInfo(host: "github.com", owner: owner, repo: "repo")
  }

  @Test func explicitRepositorySelectionDoesNotFollowAForkParent() async {
    var client = Self.api { request in
      Self.response(
        request, #"{"name":"repo","owner":{"login":"owner"},"parent":{"name":"parent","owner":{"login":"upstream"}}}"#)
    }
    client.repositorySelection = { _ in GithubRepositorySelection(remote: Self.remote) }
    #expect(await client.resolveRemoteInfo(root: Self.root) == Self.remote)
  }

  @Test func enterpriseRepositoryCanHaveAnArbitraryHostname() async {
    var client = Self.api { request in
      #expect(request.url?.absoluteString == "https://code.example.com/api/v3/repos/team/repo")
      return Self.response(request, #"{"name":"repo","owner":{"login":"team"}}"#)
    }
    var git = GitClientDependency.testValue
    git.gitRemote = { _ in GitRemote.parse("git@code.example.com:team/repo.git") }
    client = GithubAPIClient(http: client.http, credentials: client.credentials, git: git)
    #expect(
      await client.resolveRemoteInfo(root: Self.root)
        == GithubRemoteInfo(host: "code.example.com", owner: "team", repo: "repo"))
  }

  @Test func authStatusUsesTheAPIWithGhsActiveToken() async throws {
    let client = Self.api { request in
      #expect(request.url?.absoluteString == "https://api.github.com/user")
      return Self.response(request, #"{"login":"octocat"}"#)
    }
    #expect(try await client.authStatus() == GithubAuthStatus(username: "octocat", host: "github.com"))
  }

  @Test func credentialFailuresNeverExposeTokenOutput() async {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in
        throw ShellClientError(command: "gh auth token", stdout: "fake-secret-token", stderr: "failed", exitCode: 1)
      })
    let credentials = GithubCredentials(shell: shell, fallbackExecutableURLs: [])
    do {
      _ = try await credentials.token(for: "github.com")
      Issue.record("Expected an authentication error")
    } catch {
      #expect(!error.localizedDescription.contains("fake-secret-token"))
      #expect(error.localizedDescription.contains("gh auth login"))
    }
  }

  private static let root = URL(fileURLWithPath: "/tmp/github-api-test")
  private static let remote = GithubRemoteInfo(host: "github.com", owner: "owner", repo: "repo")

  private static func response(_ request: URLRequest, _ text: String, status: Int = 200) -> (Data, HTTPURLResponse) {
    (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }

  private static func body(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private static func credentials(calls: LockIsolated<[[String]]> = .init([])) -> GithubCredentials {
    let shell = ShellClient(
      run: { _, arguments, _ in
        #expect(arguments == ["gh"])
        return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executable, arguments, _, log in
        #expect(executable.lastPathComponent == "gh")
        #expect(Array(arguments.prefix(2)) == ["auth", "token"])
        #expect(log == false)
        calls.withValue { $0.append(arguments) }
        return ShellOutput(stdout: "shell banner\nghp_fake_test_token\n", stderr: "", exitCode: 0)
      })
    return GithubCredentials(shell: shell, fallbackExecutableURLs: [], configuredHosts: { ["github.com"] })
  }

  private static func api(
    _ send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
    credentials: GithubCredentials? = nil
  ) -> GithubAPIClient {
    var git = GitClientDependency.testValue
    git.remoteInfo = { _ in remote }
    return GithubAPIClient(http: GithubHTTPClient(data: send), credentials: credentials ?? Self.credentials(), git: git)
  }

  private static func state(
    status: String = "BLOCKED", canEnable: Bool = true, queue: Bool = false,
    queued: Bool = false, enabled: Bool = false, conflicting: Bool = false
  ) -> String {
    """
    {"data":{"repository":{"pullRequest":{
      "id":"PR_42","state":"OPEN","isDraft":false,"headRefOid":"expected-head",
      "mergeable":"\(conflicting ? "CONFLICTING" : "MERGEABLE")","mergeStateStatus":"\(status)",
      "isMergeQueueEnabled":\(queue),"isInMergeQueue":\(queued),"viewerCanEnableAutoMerge":\(canEnable),
      "autoMergeRequest":\(enabled ? "{\"enabledAt\":\"2026-10-28T00:00:00Z\"}" : "null")
    }}}}
    """
  }

  @Test(arguments: ["BLOCKED", "BEHIND", "UNKNOWN"])
  func protectedBranchesEnableAutoMerge(status: String) async throws {
    let mutations = LockIsolated<[String]>([])
    let calls = LockIsolated<[[String]]>([])
    let client = Self.api(
      { request in
        #expect(request.url?.absoluteString == "https://api.github.com/graphql")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_fake_test_token")
        let body = try Self.body(request)
        let query = try #require(body["query"] as? String)
        if query.hasPrefix("mutation") {
          mutations.withValue { $0.append(query) }
          #expect(query.contains("enablePullRequestAutoMerge"))
          let variables = try #require(body["variables"] as? [String: Any])
          let input = try #require(variables["input"] as? [String: String])
          #expect(input == ["pullRequestId": "PR_42", "expectedHeadOid": "expected-head", "mergeMethod": "SQUASH"])
          return Self.response(request, #"{"data":{"enablePullRequestAutoMerge":{"clientMutationId":null}}}"#)
        }
        return Self.response(request, Self.state(status: status))
      }, credentials: Self.credentials(calls: calls))
    #expect(
      try await client.merge(root: Self.root, remote: Self.remote, number: 42, strategy: .squash, action: .merge)
        == .autoMergeEnabled)
    #expect(mutations.value.count == 1)
    #expect(calls.value == [["auth", "token", "--hostname", "github.com"]])
  }

  @Test(arguments: ["CLEAN", "HAS_HOOKS", "UNSTABLE"])
  func readyPullRequestsMergeDirectly(status: String) async throws {
    let client = Self.api { request in
      let query = try #require(Self.body(request)["query"] as? String)
      if query.hasPrefix("mutation") {
        #expect(query.contains("mergePullRequest(input:"))
        return Self.response(request, #"{"data":{"mergePullRequest":{"clientMutationId":null}}}"#)
      }
      return Self.response(request, Self.state(status: status))
    }
    #expect(
      try await client.merge(
        root: Self.root, remote: Self.remote, number: 42, strategy: .rebase, action: .enableAutoMerge) == .merged)
  }

  @Test(arguments: [false, true]) func mergeQueueUsesGitHubPolicy(ready: Bool) async throws {
    let operation = ready ? "enqueuePullRequest" : "enablePullRequestAutoMerge"
    let client = Self.api { request in
      let query = try #require(Self.body(request)["query"] as? String)
      if query.hasPrefix("mutation") {
        #expect(query.contains(operation))
        let input = try #require((Self.body(request)["variables"] as? [String: Any])?["input"] as? [String: String])
        #expect(input["expectedHeadOid"] == "expected-head")
        if ready { #expect(input["mergeMethod"] == nil) }
        return Self.response(request, "{\"data\":{\"\(operation)\":{\"clientMutationId\":null}}}")
      }
      return Self.response(request, Self.state(status: ready ? "CLEAN" : "BLOCKED", canEnable: false, queue: true))
    }
    let result = try await client.merge(
      root: Self.root, remote: Self.remote, number: 42, strategy: .squash, action: .enqueue)
    #expect(result == (ready ? .queued : .autoMergeEnabled))
  }

  @Test(arguments: [false, true]) func alreadyScheduledRequestsAreNotMutated(queued: Bool) async throws {
    let client = Self.api { request in
      let query = try #require(Self.body(request)["query"] as? String)
      #expect(!query.hasPrefix("mutation"))
      return Self.response(request, Self.state(queued: queued, enabled: !queued))
    }
    #expect(
      try await client.merge(
        root: Self.root, remote: Self.remote, number: 42, strategy: .merge, action: .enableAutoMerge)
        == (queued ? .queued : .autoMergeEnabled))
  }

  @Test func disableAutoMergeIsExplicit() async throws {
    let client = Self.api { request in
      let query = try #require(Self.body(request)["query"] as? String)
      if query.hasPrefix("mutation") {
        #expect(query.contains("disablePullRequestAutoMerge"))
        return Self.response(request, #"{"data":{"disablePullRequestAutoMerge":{"clientMutationId":null}}}"#)
      }
      return Self.response(request, Self.state(enabled: true))
    }
    #expect(
      try await client.merge(
        root: Self.root, remote: Self.remote, number: 42, strategy: .merge, action: .disableAutoMerge)
        == .autoMergeDisabled)
  }

  @Test(arguments: [false, true]) func blockedOrConflictingRequestsCannotBypassPolicy(conflicting: Bool) async {
    let client = Self.api { request in
      let query = try #require(Self.body(request)["query"] as? String)
      #expect(!query.hasPrefix("mutation"))
      return Self.response(request, Self.state(canEnable: false, conflicting: conflicting))
    }
    await #expect(throws: (any Error).self) {
      try await client.merge(root: Self.root, remote: Self.remote, number: 42, strategy: .merge, action: .merge)
    }
  }

  @Test func mutationErrorsAreNotRetriedOrReportedAsSuccess() async {
    let mutations = LockIsolated(0)
    let client = Self.api { request in
      if (try #require(Self.body(request)["query"] as? String)).hasPrefix("mutation") {
        mutations.withValue { $0 += 1 }
        return Self.response(
          request, #"{"data":{"mergePullRequest":null},"errors":[{"message":"Head branch changed"}]}"#)
      }
      return Self.response(request, Self.state(status: "CLEAN"))
    }
    await #expect(throws: GithubCLIError.commandFailed("Head branch changed")) {
      try await client.merge(root: Self.root, remote: Self.remote, number: 42, strategy: .merge, action: .merge)
    }
    #expect(mutations.value == 1)
  }

  @Test func restOperationsUseNativeHTTP() async throws {
    let paths = LockIsolated<[String]>([])
    let client = Self.api { request in
      let path = request.url!.path
      paths.withValue { $0.append(path) }
      if path == "/repos/owner/repo" {
        return Self.response(request, #"{"name":"repo","owner":{"login":"owner"}}"#)
      }
      if path.hasSuffix("/pulls/42"), request.httpMethod == "PATCH" {
        let data = try #require(request.httpBody)
        #expect(try JSONDecoder().decode([String: String].self, from: data) == ["state": "closed"])
        return Self.response(request, "{}")
      }
      if path.hasSuffix("/pulls/42") {
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.diff")
        return Self.response(request, "diff --git a/file b/file\n")
      }
      if path.hasSuffix("/actions/runs") {
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "a & b")
        return Self.response(
          request,
          #"{"workflow_runs":[{"id":12,"name":"CI","display_title":"Build","status":"completed","conclusion":"failure","created_at":"2026-10-28T00:00:00Z","updated_at":"2026-10-28T00:00:01Z"}]}"#
        )
      }
      if path.hasSuffix("/jobs") {
        return Self.response(
          request,
          #"{"jobs":[{"id":1,"name":"Passing","conclusion":"success"},{"id":2,"name":"Failing","conclusion":"failure"}]}"#
        )
      }
      if path.hasSuffix("/logs") { return Self.response(request, "log text") }
      #expect(path.hasSuffix("/rerun-failed-jobs"))
      #expect(request.httpMethod == "POST")
      return Self.response(request, "", status: 201)
    }
    try await client.close(root: Self.root, remote: Self.remote, number: 42)
    #expect(try await client.diff(remote: Self.remote, number: 42) == "diff --git a/file b/file\n")
    #expect(try await client.latestRun(root: Self.root, branch: "a & b")?.databaseId == 12)
    try await client.rerun(root: Self.root, runID: 12)
    #expect(try await client.logs(root: Self.root, runID: 12, failedOnly: true) == "Failing\nlog text")
    #expect(!paths.value.contains("/repos/owner/repo/actions/jobs/1/logs"))
    #expect(try await client.logs(root: Self.root, runID: 12, failedOnly: false).contains("Passing\nlog text"))
  }

  @Test func resolvesForkToBaseRepositoryWithoutGhRepoView() async {
    let client = Self.api { request in
      Self.response(
        request, #"{"name":"fork","owner":{"login":"me"},"parent":{"name":"base","owner":{"login":"upstream"}}}"#)
    }
    #expect(
      await client.resolveRemoteInfo(root: Self.root)
        == GithubRemoteInfo(host: "github.com", owner: "upstream", repo: "base"))
  }

  @Test func enterpriseEndpointsAndCredentialsStayOnTheirHost() async throws {
    let calls = LockIsolated<[[String]]>([])
    let client = Self.api(
      { request in
        #expect(request.url?.host == "github.example.com")
        #expect(request.url?.path == "/api/v3/repos/team/repo/pulls/1")
        return Self.response(request, "diff")
      }, credentials: Self.credentials(calls: calls))
    _ = try await client.diff(
      remote: GithubRemoteInfo(host: "github.example.com", owner: "team", repo: "repo"), number: 1)
    #expect(calls.value.last?.last == "github.example.com")
    #expect(try GithubAPIClient.url(host: "github.example.com", path: "", graphQL: true).path == "/api/graphql")
  }

  @Test func unauthorizedResponseRefreshesTheGhTokenOnce() async throws {
    let count = LockIsolated(0)
    let calls = LockIsolated<[[String]]>([])
    let client = Self.api(
      { request in
        let attempt = count.withValue {
          $0 += 1
          return $0
        }
        return Self.response(request, attempt == 1 ? "{}" : "diff", status: attempt == 1 ? 401 : 200)
      }, credentials: Self.credentials(calls: calls))
    #expect(try await client.diff(remote: Self.remote, number: 1) == "diff")
    #expect(calls.value.count == 2)
  }

  @Test(.dependencies) func batchRequestsDeduplicateEscapeAndRetryOldEnterpriseFields() async throws {
    let count = LockIsolated(0)
    let client = Self.api { request in
      let attempt = count.withValue {
        $0 += 1
        return $0
      }
      let query = try #require(Self.body(request)["query"] as? String)
      #expect(query.contains(#"headRefName: "feature\"name""#))
      #expect(!query.contains("branch1:"))
      if attempt == 1 {
        return Self.response(
          request, #"{"errors":[{"message":"Field 'isMergeQueueEnabled' doesn't exist on type 'PullRequest'"}]}"#)
      }
      #expect(!query.contains("isMergeQueueEnabled"))
      return Self.response(request, #"{"data":{"repository":{"branch0":{"nodes":[]}}}}"#)
    }
    #expect(
      try await client.batchPullRequests(
        host: "github.com", owner: "owner", repo: "repo", branches: ["feature\"name", "feature\"name", ""]
      ).isEmpty)
    #expect(count.value == 2)
  }

  @Test(.dependencies) func batchGatewayRetryIsBounded() async {
    let count = LockIsolated(0)
    let client = Self.api { request in
      count.withValue { $0 += 1 }
      return Self.response(request, "gateway timeout", status: 504)
    }
    await withDependencies {
      $0.continuousClock = ImmediateClock()
    } operation: {
      await #expect(throws: GithubCLIError.gatewayTimeout) {
        try await client.batchPullRequests(host: "github.com", owner: "owner", repo: "repo", branches: ["feature"])
      }
    }
    #expect(count.value == 2)
  }

  @Test func credentialsParseHostsWithoutReadingTokensAsHosts() {
    #expect(
      GithubCredentials.hosts(in: "github.com:\n  oauth_token: secret\ngithub.example.com:\n  users:\n") == [
        "github.com", "github.example.com",
      ])
  }
  @Test func balancedSpansReturnsCleanObjectUnchanged() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: #"{"a":1}"#).map(String.init) == [#"{"a":1}"#])
  }

  @Test func balancedSpansStripBannerBeforeObject() {
    let noisy = "fastfetch banner line\nanother line\n" + #"{"hosts":{}}"#
    #expect(GithubCLIOutput.balancedJSONSpans(in: noisy).map(String.init) == [#"{"hosts":{}}"#])
  }

  @Test func balancedSpansStripBannerBeforeArray() {
    let noisy = "nvm: now using node v20\n" + #"[{"x":1},{"y":2}]"#
    #expect(GithubCLIOutput.balancedJSONSpans(in: noisy).map(String.init) == [#"[{"x":1},{"y":2}]"#])
  }

  @Test func balancedSpansDropTrailingNoise() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: "{\"a\":1}\nshell goodbye").map(String.init) == [#"{"a":1}"#])
  }

  @Test func balancedSpansIgnoreBracesInsideStrings() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: #"{"a":"}]"}"#).map(String.init) == [#"{"a":"}]"}"#])
  }

  @Test func balancedSpansIgnoreEscapedQuoteInsideString() {
    // The escaped quote keeps the scanner in-string, so the brace before it is not a premature close.
    #expect(GithubCLIOutput.balancedJSONSpans(in: #"{"a":"}\""}"#).map(String.init) == [#"{"a":"}\""}"#])
  }

  @Test func balancedSpansReturnBothTopLevelObjectsInOrder() {
    let input = #"{"a":1}"# + "\n" + #"{"b":2}"#
    #expect(GithubCLIOutput.balancedJSONSpans(in: input).map(String.init) == [#"{"a":1}"#, #"{"b":2}"#])
  }

  @Test func balancedSpansSkipUnbalancedOpener() {
    // A stray brace from a verbose login shell must not swallow the real trailing payload.
    let noisy = "chpwd () {\n" + #"[{"databaseId":7}]"#
    #expect(GithubCLIOutput.balancedJSONSpans(in: noisy).map(String.init) == [#"[{"databaseId":7}]"#])
  }

  @Test func balancedSpansReturnEmptyForPureNoise() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: "no json here at all").isEmpty)
  }

  @Test func balancedSpansReturnEmptyForEmptyInput() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: "   \n  ").isEmpty)
  }

  @Test func balancedSpansReturnEmptyForUnterminatedPayload() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: #"{"a":1"#).isEmpty)
  }

  private struct SingleKeyPayload: Decodable, Equatable {
    let value: Int
  }

  @Test func decodeSkipsBracketBearingBannerBeforeObject() throws {
    let noisy = "warn [deprecated]\n" + #"{"value":1}"#
    let decoded = try GithubCLIOutput.decode(SingleKeyPayload.self, from: noisy)
    #expect(decoded == SingleKeyPayload(value: 1))
  }

  @Test func decodeSkipsVersionManagerBannerBeforeObject() throws {
    let noisy = "[nvm] using node v20\n" + #"{"hosts":{}}"#
    let decoded = try GithubCLIOutput.decode(GithubAuthStatusResponse.self, from: noisy)
    #expect(decoded.hosts.isEmpty)
  }

  @Test func activeAccountScansAllHostsForActiveAccount() {
    let response = GithubAuthStatusResponse(hosts: [
      "ghe.acme.com": [.init(active: false, login: "work")],
      "github.com": [.init(active: true, login: "sbertix")],
    ])

    let active = GithubAuthStatusParsing.activeAccount(in: response)

    #expect(active?.host == "github.com")
    #expect(active?.login == "sbertix")
  }

  @Test func activeAccountReturnsNilWhenNoAccountActive() {
    let response = GithubAuthStatusResponse(hosts: [
      "github.com": [.init(active: false, login: "sbertix")]
    ])

    #expect(GithubAuthStatusParsing.activeAccount(in: response) == nil)
  }

  @Test func activeAccountPrefersGithubComWhenMultipleHostsActive() {
    let response = GithubAuthStatusResponse(hosts: [
      "ghe.acme.com": [.init(active: true, login: "work")],
      "github.com": [.init(active: true, login: "sbertix")],
    ])

    let active = GithubAuthStatusParsing.activeAccount(in: response)

    #expect(active?.host == "github.com")
    #expect(active?.login == "sbertix")
  }

  @Test func activeAccountSortsHostsWhenGithubComAbsent() {
    let response = GithubAuthStatusResponse(hosts: [
      "z.example.com": [.init(active: true, login: "zed")],
      "a.example.com": [.init(active: true, login: "ann")],
    ])

    let active = GithubAuthStatusParsing.activeAccount(in: response)

    #expect(active?.host == "a.example.com")
    #expect(active?.login == "ann")
  }

}
