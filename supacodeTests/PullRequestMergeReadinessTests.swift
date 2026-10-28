import Testing

@testable import supacode

@MainActor
struct PullRequestMergeReadinessTests {
  @Test func protectedPullRequestOffersAutoMergeInsteadOfMerge() {
    var pullRequest = makePullRequest(mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED")
    pullRequest.mergeAutomation = PullRequestMergeAutomation(canEnable: true)
    #expect(pullRequest.mergeAction == .enableAutoMerge)
    #expect(pullRequest.mergeActionTitle(noun: "Pull Request") == "Enable Auto-Merge")
    pullRequest.mergeAutomation?.isEnabled = true
    pullRequest.mergeAutomation?.canDisable = true
    #expect(pullRequest.mergeAction == .disableAutoMerge)
    #expect(pullRequest.mergeActionTitle(noun: "Pull Request") == "Disable Auto-Merge")
  }

  @Test func queueAndUnavailableAutoMergeHaveDifferentActions() {
    var blocked = makePullRequest(mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED")
    blocked.mergeAutomation = PullRequestMergeAutomation()
    #expect(blocked.mergeAction == nil)
    blocked.mergeAutomation?.usesQueue = true
    #expect(blocked.mergeAction == .enableAutoMerge)
    #expect(blocked.mergeActionTitle(noun: "Pull Request") == "Merge When Ready")
    var ready = makePullRequest(mergeable: "MERGEABLE", mergeStateStatus: "CLEAN")
    ready.mergeAutomation = PullRequestMergeAutomation(usesQueue: true)
    #expect(ready.mergeAction == .enqueue)
    ready.mergeAutomation?.isQueued = true
    #expect(ready.mergeAction == nil)
  }

  @Test func conflictCannotOfferAutoMergeButCanDisableIt() {
    var pullRequest = makePullRequest(mergeable: "CONFLICTING", mergeStateStatus: "DIRTY")
    pullRequest.mergeAutomation = PullRequestMergeAutomation(canEnable: true)
    #expect(pullRequest.mergeAction == nil)
    pullRequest.mergeAutomation = PullRequestMergeAutomation(isEnabled: true, canDisable: true)
    #expect(pullRequest.mergeAction == .disableAutoMerge)
  }

  @Test func optionalCheckFailureDoesNotOverrideGitHubsMergePolicy() {
    var pullRequest = makePullRequest(mergeable: "MERGEABLE", mergeStateStatus: "UNSTABLE", checks: [
      ForgePullRequestStatusCheck(status: "COMPLETED", conclusion: "FAILURE", state: nil)
    ])
    pullRequest.mergeAutomation = PullRequestMergeAutomation()
    #expect(pullRequest.mergeAction == .merge)
  }

  @Test func mergeReadinessUsesConflictReasonFirst() {
    let pullRequest = makePullRequest(
      reviewDecision: "CHANGES_REQUESTED",
      mergeable: "CONFLICTING",
      mergeStateStatus: "DIRTY"
    )

    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)

    #expect(readiness.blockingReason == .mergeConflicts)
    #expect(readiness.label == "Merge conflicts")
    #expect(readiness.isConflicting)
  }

  @Test func mergeReadinessUsesChangesRequestedWhenNoConflict() {
    let pullRequest = makePullRequest(
      reviewDecision: "CHANGES_REQUESTED",
      mergeable: "MERGEABLE",
      mergeStateStatus: "CLEAN"
    )

    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)

    #expect(readiness.blockingReason == .changesRequested)
    #expect(readiness.label == "Changes requested")
  }

  @Test func mergeReadinessUsesFailedChecksCountWhenPresent() {
    let pullRequest = makePullRequest(
      mergeable: "MERGEABLE",
      mergeStateStatus: "CLEAN",
      checks: [
        ForgePullRequestStatusCheck(status: "COMPLETED", conclusion: "FAILURE", state: nil),
        ForgePullRequestStatusCheck(status: "COMPLETED", conclusion: "FAILURE", state: nil),
      ]
    )

    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)

    #expect(readiness.blockingReason == .checksFailed(2))
    #expect(readiness.label == "2 checks failed")
  }

  @Test func mergeReadinessIsMergeableWhenMergeable() {
    let pullRequest = makePullRequest(
      mergeable: "MERGEABLE",
      mergeStateStatus: "BEHIND"
    )

    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)

    #expect(readiness.blockingReason == nil)
    #expect(readiness.assessment == .mergeable)
    #expect(readiness.label == "Mergeable")
  }

  @Test func mergeReadinessIsCheckingWhileMergeabilityIsUnknown() {
    let pullRequest = makePullRequest(
      mergeable: "UNKNOWN",
      mergeStateStatus: "BEHIND"
    )

    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)

    #expect(readiness.assessment == .checking)
    #expect(readiness.blockingReason == nil)
    #expect(readiness.label == "Checking")
  }

  @Test func mergeReadinessIsCheckingWhenMergeabilityIsMissing() {
    let pullRequest = makePullRequest(
      mergeable: nil,
      mergeStateStatus: nil
    )

    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)

    #expect(readiness.assessment == .checking)
  }
}

private func makePullRequest(
  reviewDecision: String? = nil,
  mergeable: String? = nil,
  mergeStateStatus: String? = nil,
  checks: [ForgePullRequestStatusCheck] = [],
  mergeQueueEntry: ForgeMergeQueueEntry? = nil
) -> ForgePullRequest {
  ForgePullRequest(
    number: 1,
    title: "PR",
    state: .open,
    additions: 0,
    deletions: 0,
    isDraft: false,
    reviewDecision: reviewDecision,
    mergeable: mergeable,
    mergeStateStatus: mergeStateStatus,
    updatedAt: nil,
    mergedAt: nil,
    url: "https://example.com/pull/1",
    headRefName: "feature",
    baseRefName: "main",
    commitsCount: 1,
    authorLogin: "khoi",
    statusCheckRollup: checks.isEmpty ? nil : ForgePullRequestStatusCheckRollup(checks: checks),
    mergeQueueEntry: mergeQueueEntry
  )
}
