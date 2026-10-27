import SupacodeSettingsShared
import SwiftUI

struct WorktreeLoadingView: View {
  let info: WorktreeLoadingInfo

  var body: some View {
    let subtitle = subtitleText()
    VStack(spacing: 12) {
      if let progress = info.progress {
        if let fraction = progress.checkoutFraction {
          ProgressView(value: fraction) { Text("Checking out files") }
            .frame(maxWidth: 320)
        } else {
          ProgressView("Creating worktree")
            .progressViewStyle(.linear)
            .frame(maxWidth: 320)
        }
      } else {
        ProgressView()
          .controlSize(.large)
      }
      VStack(spacing: 4) {
        Text(info.name)
          .appFont(.title3)
        Text(subtitle)
          .appFont(.subheadline)
          .monospaced()
          .foregroundStyle(.tertiary)
          .lineLimit(5, reservesSpace: true)
          .truncationMode(.head)
          .contentTransition(.opacity)
          .animation(.easeInOut, value: subtitle)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func subtitleText() -> String {
    if let progress = info.progress {
      if progress.checkoutFraction != nil || !progress.statusLines.isEmpty {
        return progress.statusTitle ?? "Creating worktree"
      }
      if let text = progress.statusDetail ?? progress.statusTitle { return text }
    }
    let noun = info.isFolder ? "folder" : "worktree"
    // Folder repositories are their own root — the repository name
    // duplicates the folder name, so skip the "in <name>" suffix.
    if !info.isFolder, let repositoryName = info.repositoryName {
      return "\(info.actionLabel) \(noun) in \(repositoryName)"
    }
    return "\(info.actionLabel) \(noun)…"
  }
}

#Preview("Creating worktree") {
  WorktreeLoadingView(
    info: WorktreeLoadingInfo(
      name: "feature/example",
      repositoryName: "supacode",
      kind: .creating(
        WorktreeLoadingInfo.Progress(
          statusTitle: "Creating worktree",
          statusDetail: "Preparing checkout",
          statusCommand: nil,
          statusLines: []
        )
      )
    )
  )
  .frame(width: 600, height: 400)
}
