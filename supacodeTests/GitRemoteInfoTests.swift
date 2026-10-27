import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct GitRemoteInfoTests {
  @Test func nativeRemoteDiscoveryMatchesGitAndAppliesURLRewrites() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "native-remotes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = root.path(percentEncoded: false)
    func git(_ arguments: [String]) async throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = arguments
      process.environment = ProcessInfo.processInfo.environment.merging([
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"
      ]) { _, value in value }
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try await process.runToExit()
      guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
    }
    try await git(["init", path])
    try await git(["-C", path, "remote", "add", "origin", "/tmp/local-repository"])
    try await git(["-C", path, "remote", "add", "alpha", "https://gitlab.com/group/project.git"])
    try await git(["-C", path, "remote", "add", "beta", "https://github.com/team/project.git"])
    let shell = ShellClient(
      run: { _, _, _ in
        Issue.record("Native remote discovery launched a subprocess")
        throw CocoaError(.fileReadUnknown)
      },
      runLoginImpl: { _, _, _, _ in
        Issue.record("Native remote discovery launched a login shell")
        throw CocoaError(.fileReadUnknown)
      }
    )
    let native = GitClient(shell: shell, nativeReferences: true)
    let gitClient = GitClient()
    #expect(await native.remote(for: root) == gitClient.remote(for: root))
    #expect(await native.remoteInfo(for: root) == gitClient.remoteInfo(for: root))
    #expect(await native.remote(for: root)?.host == "gitlab.com")
    #expect(await native.remoteInfo(for: root)?.host == "github.com")
    try await git(["-C", path, "remote", "set-url", "origin", "shortcut:team/repo.git"])
    try await git(["-C", path, "config", "url.https://github.com/.insteadOf", "shortcut:"])
    #expect(await native.remote(for: root) == gitClient.remote(for: root))
    #expect(await native.remoteInfo(for: root) == gitClient.remoteInfo(for: root))
    #expect(await native.remote(for: root)?.rawURL == "https://github.com/team/repo.git")
    try await git(["-C", path, "config", "--add", "remote.origin.url", "https://github.com/other/repo.git"])
    #expect(await native.remote(for: root) == gitClient.remote(for: root))
  }

  @Test func parseSSHRemote() {
    let info = GitClient.parseGithubRemoteInfo("git@github.com:octo/repo.git")
    #expect(info == GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parseSSHURLRemote() {
    let info = GitClient.parseGithubRemoteInfo("ssh://git@github.com/octo/repo.git")
    #expect(info == GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parseHTTPSRemote() {
    let info = GitClient.parseGithubRemoteInfo("https://github.com/octo/repo")
    #expect(info == GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parseEnterpriseRemote() {
    let info = GitClient.parseGithubRemoteInfo("git@github.acme.com:team/repo.git")
    #expect(info == GithubRemoteInfo(host: "github.acme.com", owner: "team", repo: "repo"))
  }

  @Test func rejectsNonGithubRemote() {
    let info = GitClient.parseGithubRemoteInfo("https://gitlab.com/group/repo.git")
    #expect(info == nil)
  }
}

struct GitRemoteParsingTests {
  @Test func parsesHTTPSWithAndWithoutGitSuffix() {
    #expect(GitRemote.parse("https://github.com/octo/repo.git")?.pathComponents == ["octo", "repo"])
    #expect(GitRemote.parse("https://github.com/octo/repo")?.pathComponents == ["octo", "repo"])
  }

  @Test func parsesHTTPSWithPortAndUser() {
    let remote = GitRemote.parse("https://user@git.acme.com:8443/group/repo.git")
    #expect(remote?.host == "git.acme.com")
    #expect(remote?.port == 8443)
    #expect(remote?.pathComponents == ["group", "repo"])
  }

  @Test func parsesSSHURLWithPort() {
    let remote = GitRemote.parse("ssh://git@git.acme.com:2222/group/sub/proj.git")
    #expect(remote?.host == "git.acme.com")
    #expect(remote?.port == 2222)
    #expect(remote?.pathComponents == ["group", "sub", "proj"])
  }

  @Test func parsesSCPStyle() {
    let remote = GitRemote.parse("git@github.com:octo/repo.git")
    #expect(remote?.host == "github.com")
    #expect(remote?.port == nil)
    #expect(remote?.pathComponents == ["octo", "repo"])
  }

  @Test func scpStylePreservesDeepNamespaces() {
    let remote = GitRemote.parse("git@gitlab.com:group/subgroup/team/proj.git")
    #expect(remote?.pathComponents == ["group", "subgroup", "team", "proj"])
  }

  @Test func normalizesUppercaseHost() {
    #expect(GitRemote.parse("https://GitHub.com/Octo/Repo")?.host == "github.com")
    #expect(GitRemote.parse("git@GitHub.com:Octo/Repo.git")?.host == "github.com")
  }

  @Test func preservesPathComponentCase() {
    #expect(GitRemote.parse("https://github.com/Octo/Repo")?.pathComponents == ["Octo", "Repo"])
  }

  @Test func parsesGitProtocol() {
    #expect(GitRemote.parse("git://github.com/octo/repo.git")?.pathComponents == ["octo", "repo"])
  }

  @Test func stripsTrailingSlash() {
    #expect(GitRemote.parse("https://github.com/octo/repo/")?.pathComponents == ["octo", "repo"])
  }

  @Test func rejectsLocalAndRelativePaths() {
    #expect(GitRemote.parse("/Users/dev/repo") == nil)
    #expect(GitRemote.parse("../other.git") == nil)
    #expect(GitRemote.parse("file:///Users/dev/repo") == nil)
  }

  @Test func rejectsEmptyAndHostlessInput() {
    #expect(GitRemote.parse("") == nil)
    #expect(GitRemote.parse("   ") == nil)
    #expect(GitRemote.parse("https:///octo/repo") == nil)
    #expect(GitRemote.parse("git@:octo/repo") == nil)
  }

  @Test func rejectsRemoteWithoutPath() {
    #expect(GitRemote.parse("https://github.com") == nil)
    #expect(GitRemote.parse("git@github.com:") == nil)
  }

  @Test func githubIdentityRequiresTwoComponents() {
    #expect(GitClient.parseGithubRemoteInfo("https://github.com/only-owner") == nil)
  }

  @Test func githubIdentityIgnoresHostsWithoutGithub() {
    #expect(GitRemote.parse("https://git.acme.com/group/repo") != nil)
    #expect(GitClient.parseGithubRemoteInfo("https://git.acme.com/group/repo") == nil)
  }
}
