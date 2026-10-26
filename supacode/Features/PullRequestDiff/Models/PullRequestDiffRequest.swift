import Foundation
import SupacodeSettingsShared

/// The value a pull-request diff window opens for. One window per value, so
/// opening the same pull request again brings its window forward.
nonisolated struct PullRequestDiffRequest: Codable, Hashable, Sendable {
  let repositoryRootURL: URL
  let repositoryHost: RemoteHost?
  let number: Int
  let numberSigil: String
  let title: String
  let url: String

  var windowTitle: String {
    "\(numberSigil)\(number) \(title)"
  }

  // Identity is the pull request, not its display fields, so a retitled pull
  // request still finds its open window.
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.repositoryRootURL == rhs.repositoryRootURL && lhs.repositoryHost == rhs.repositoryHost
      && lhs.number == rhs.number
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(repositoryRootURL)
    hasher.combine(repositoryHost)
    hasher.combine(number)
  }
}

extension PullRequestDiffRequest {
  init(worktree: Worktree, pullRequest: ForgePullRequest) {
    self.init(
      repositoryRootURL: worktree.repositoryRootURL,
      repositoryHost: worktree.host,
      number: pullRequest.number,
      numberSigil: pullRequest.numberSigil,
      title: pullRequest.title,
      url: pullRequest.url
    )
  }
}
