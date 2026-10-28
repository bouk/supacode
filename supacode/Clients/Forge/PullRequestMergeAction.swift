import Foundation

nonisolated enum PullRequestMergeAction: Equatable, Sendable {
  case merge
  case enableAutoMerge
  case enqueue
  case disableAutoMerge

  func title(noun: String, usesQueue: Bool = false) -> String {
    switch self {
    case .merge: "Merge \(noun)"
    case .enableAutoMerge: usesQueue ? "Merge When Ready" : "Enable Auto-Merge"
    case .enqueue: "Add to Merge Queue"
    case .disableAutoMerge: "Disable Auto-Merge"
    }
  }
}

nonisolated enum PullRequestMergeOutcome: Equatable, Sendable {
  case merged
  case autoMergeEnabled
  case queued
  case autoMergeDisabled

  var message: String {
    switch self {
    case .merged: "Pull request merged"
    case .autoMergeEnabled: "Auto-merge enabled"
    case .queued: "Pull request added to merge queue"
    case .autoMergeDisabled: "Auto-merge disabled"
    }
  }
}

/// Optional on older servers and non-GitHub forges. These are viewer permissions,
/// rather than guesses based on pending checks or a repository-wide setting.
nonisolated struct PullRequestMergeAutomation: Equatable, Hashable, Sendable {
  var isEnabled = false
  var canEnable = false
  var canDisable = false
  var usesQueue = false
  var isQueued = false
}

nonisolated extension ForgePullRequest {
  var mergeAction: PullRequestMergeAction? {
    guard state == .open, !isDraft else { return nil }
    if let automation = mergeAutomation {
      if automation.isEnabled { return automation.canDisable ? .disableAutoMerge : nil }
      if automation.isQueued || mergeQueueEntry != nil { return nil }
      guard !PullRequestMergeReadiness(pullRequest: self).isConflicting else { return nil }
      let immediate = ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(mergeStateStatus?.uppercased() ?? "")
      if !immediate, automation.canEnable || automation.usesQueue { return .enableAutoMerge }
      // GitHub can permit merging with failed optional checks (UNSTABLE).
      // Its policy result takes precedence over the aggregate check badge.
      if immediate { return automation.usesQueue ? .enqueue : .merge }
      if mergeStateStatus == "BLOCKED" || mergeStateStatus == "BEHIND" { return nil }
    }
    guard mergeQueueEntry == nil, PullRequestMergeReadiness(pullRequest: self).blockingReason == nil else { return nil }
    return .merge
  }

  func mergeActionTitle(noun: String) -> String? {
    mergeAction?.title(noun: noun, usesQueue: mergeAutomation?.usesQueue == true)
  }
}
