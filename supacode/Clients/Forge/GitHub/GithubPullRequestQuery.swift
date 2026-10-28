import Foundation

/// Batch-query selections older GitHub Enterprise Server may lack (`mergeQueueEntry` needs 3.8).
nonisolated enum GithubOptionalPullRequestField: String, CaseIterable, Hashable, Sendable {
  case mergeQueueEntry
  case latestOpinionatedReviews
  case autoMergeRequest
  case viewerCanEnableAutoMerge
  case viewerCanDisableAutoMerge
  case isMergeQueueEnabled
  case isInMergeQueue

  var selection: String {
    switch self {
    case .mergeQueueEntry: "mergeQueueEntry { position estimatedTimeToMerge state }"
    case .latestOpinionatedReviews: "latestOpinionatedReviews(first: 100, writersOnly: true) { nodes { state } }"
    case .autoMergeRequest: "autoMergeRequest { enabledAt }"
    case .viewerCanEnableAutoMerge: "viewerCanEnableAutoMerge"
    case .viewerCanDisableAutoMerge: "viewerCanDisableAutoMerge"
    case .isMergeQueueEnabled: "isMergeQueueEnabled"
    case .isInMergeQueue: "isInMergeQueue"
    }
  }

  /// Fields a GraphQL validation error rejects as unknown; an error merely echoing a name never matches.
  static func rejected(by error: Error) -> Set<Self> {
    guard case GithubCLIError.commandFailed(let message) = error else { return [] }
    let names = GraphQLFieldRejection.rejectedFields(allCases.map(\.rawValue), in: message)
    var rejected: Set<Self> = []
    for name in names {
      guard let field = Self(rawValue: name) else { continue }
      rejected.insert(field)
    }
    return rejected
  }
}

nonisolated enum GithubPullRequestQuery {
  static func batchQuery(
    branches: [String],
    optionalFields: Set<GithubOptionalPullRequestField>
  ) -> (query: String, aliasMap: [String: String]) {
    var optionalSelections: [String] = []
    for field in GithubOptionalPullRequestField.allCases where optionalFields.contains(field) {
      optionalSelections.append(field.selection)
    }
    let optionalSelection = optionalSelections.joined(separator: "\n")
    var aliasMap: [String: String] = [:]
    var selections: [String] = []
    for (index, branch) in branches.enumerated() {
      let alias = "branch\(index)"
      aliasMap[alias] = branch
      let escapedBranch = escapeGraphQLString(branch)
      let orderBy = "orderBy: {field: UPDATED_AT, direction: DESC}"
      let selection = """
        \(alias): pullRequests(first: 5, states: [OPEN, MERGED], headRefName: \"\(escapedBranch)\", \(orderBy)) {
          nodes {
            number
            title
            state
            additions
            deletions
            isDraft
            reviewDecision
            mergeable
            mergeStateStatus
            url
            updatedAt
            mergedAt
            headRefName
            baseRefName
            commits {
              totalCount
            }
            author {
              login
            }
            \(optionalSelection)
            headRepository {
              name
              owner { login }
            }
            statusCheckRollup {
              contexts(first: 100) {
                nodes {
                  ... on CheckRun {
                    name
                    status
                    conclusion
                    startedAt
                    completedAt
                    detailsUrl
                  }
                  ... on StatusContext {
                    context
                    state
                    targetUrl
                    createdAt
                  }
                }
              }
            }
          }
        }
        """
      selections.append(selection)
    }
    let selectionBlock = selections.joined(separator: "\n")
    let query = """
      query($owner: String!, $repo: String!) {
        repository(owner: $owner, name: $repo) {
      \(selectionBlock)
        }
      }
      """
    return (query, aliasMap)
  }

  private static func escapeGraphQLString(_ value: String) -> String {
    value
      .replacing("\\", with: "\\\\")
      .replacing("\"", with: "\\\"")
      .replacing("\n", with: "\\n")
      .replacing("\r", with: "\\r")
      .replacing("\t", with: "\\t")
  }

}
