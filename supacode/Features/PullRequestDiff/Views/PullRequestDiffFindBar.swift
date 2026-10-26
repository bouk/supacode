import AppKit
import SwiftUI

/// Window-scoped search is independent of keyboard focus and includes folded
/// source. Only immutable strings cross to the background search task.
@MainActor
@Observable
final class PullRequestDiffTextCommands {
  nonisolated deinit {}

  @ObservationIgnored weak var textView: PullRequestDiffNSTextView?
  @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
  var isPresented = false
  private(set) var focusGeneration = 0
  var query = "" {
    didSet { if oldValue != query { refreshSearch() } }
  }
  private(set) var matches: [NSRange] = []
  private(set) var selectedIndex: Int?
  private(set) var isSearching = false

  var matchLabel: String {
    if isSearching { return "Searching…" }
    guard !query.isEmpty else { return "" }
    guard !matches.isEmpty else { return "No matches" }
    return "\(selectedIndex.map { $0 + 1 } ?? 0) of \(matches.count.formatted())"
  }

  func perform(_ action: NSTextFinder.Action) {
    switch action {
    case .showFindInterface:
      isPresented = true
      focusGeneration &+= 1
      if !query.isEmpty { refreshSearch() }
    case .hideFindInterface:
      isPresented = false
      textView?.searchRanges = []
      textView?.applySearchHighlights()
      textView?.window?.makeFirstResponder(textView)
    case .nextMatch: navigate(backward: false)
    case .previousMatch: navigate(backward: true)
    case .setSearchString:
      guard let textView else { return }
      let range = textView.selectedRange()
      if range.length > 0 { query = (textView.string as NSString).substring(with: range) }
    default: break
    }
  }

  func refreshSearch() {
    searchTask?.cancel()
    matches = []
    selectedIndex = nil
    textView?.searchRanges = []
    textView?.applySearchHighlights()
    guard !query.isEmpty, let textView, let full = textView.fullModel else {
      isSearching = false
      return
    }
    let query = query
    isSearching = true
    searchTask = Task { [weak self, weak textView] in
      let ranges = await PullRequestDiffTextDocument.search(full.text, for: query)
      guard !Task.isCancelled, let self, let textView, self.query == query,
        textView.fullModel?.document === full.document
      else { return }
      self.matches = ranges
      self.isSearching = false
      textView.searchRanges = self.isPresented ? ranges : []
      textView.applySearchHighlights()
      if self.isPresented, !ranges.isEmpty { self.select(0) }
    }
  }

  private func navigate(backward: Bool) {
    guard !matches.isEmpty else {
      if !isPresented { perform(.showFindInterface) }
      return
    }
    let index =
      selectedIndex.map { ($0 + (backward ? matches.count - 1 : 1)) % matches.count }
      ?? (backward ? matches.count - 1 : 0)
    select(index)
  }

  private func select(_ index: Int) {
    guard matches.indices.contains(index) else { return }
    selectedIndex = index
    textView?.revealSearchMatch(matches[index])
  }
}

struct PullRequestDiffFindBar: View {
  @Bindable var commands: PullRequestDiffTextCommands
  @FocusState private var fieldFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      TextField("Find in Diff", text: $commands.query)
        .textFieldStyle(.roundedBorder)
        .focused($fieldFocused)
        .onSubmit { commands.perform(.nextMatch) }
        .help("Find text in all files, including collapsed files (⌘F)")
      Text(commands.matchLabel)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityLabel(commands.matchLabel)
      Button {
        commands.perform(.previousMatch)
      } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(commands.matches.isEmpty)
      .help("Previous match (⇧⌘G)")
      Button {
        commands.perform(.nextMatch)
      } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(commands.matches.isEmpty)
      .help("Next match (⌘G)")
      Button("Done") { commands.perform(.hideFindInterface) }
        .keyboardShortcut(.cancelAction)
        .help("Close Find (Esc)")
    }
    .controlSize(.small)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
    .onAppear { fieldFocused = true }
    .onChange(of: commands.focusGeneration) { fieldFocused = true }
  }
}
