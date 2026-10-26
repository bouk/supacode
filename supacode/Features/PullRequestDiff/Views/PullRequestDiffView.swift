import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Root of a pull-request diff window. Owns the window's store.
struct PullRequestDiffWindow: View {
  let terminalManager: WorktreeTerminalManager
  @State private var store: StoreOf<PullRequestDiffFeature>

  init(request: PullRequestDiffRequest, terminalManager: WorktreeTerminalManager) {
    self.terminalManager = terminalManager
    _store = State(
      initialValue: Store(initialState: PullRequestDiffFeature.State(request: request)) {
        PullRequestDiffFeature()
      }
    )
  }

  var body: some View {
    let _ = terminalManager.configGeneration
    PullRequestDiffView(store: store, palette: terminalManager.ghosttyRuntime.colorPalette())
  }
}

struct PullRequestDiffView: View {
  let store: StoreOf<PullRequestDiffFeature>
  var palette: TerminalColorPalette = .system
  @State private var textCommands = PullRequestDiffTextCommands()
  @Shared(.settingsFile) private var settingsFile
  @Environment(\.openURL) private var openURL

  var body: some View {
    let request = store.request
    let hasFiles = store.document?.files.isEmpty == false
    let goToFileShortcut = AppShortcuts.worktreeSwitcher.effective(from: settingsFile.global.shortcutOverrides)
    let textScale = settingsFile.global.chromeTextSize.scale
    NavigationSplitView {
      PullRequestDiffSidebar(store: store)
        .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 480)
    } detail: {
      PullRequestDiffDetail(
        store: store, fontSize: Self.pointSize(.body, scale: textScale), commands: textCommands, palette: palette)
    }
    .preferredColorScheme(palette.background.isLightColor ? .light : .dark)
    .tint(Color(nsColor: palette.color(4)))
    .navigationTitle(request.windowTitle)
    .navigationSubtitle(subtitle)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          store.send(.goToFile(.toggle))
        } label: {
          Label("Go to File", systemImage: "magnifyingglass")
        }
        .help("Go to File (\(goToFileShortcut?.display ?? "none"))")
        .disabled(!hasFiles)

        if store.isLoading, store.document != nil {
          ProgressView()
            .controlSize(.small)
            .help("Reloading diff")
        } else {
          Button {
            store.send(.reloadButtonTapped)
          } label: {
            Label("Reload", systemImage: "arrow.clockwise")
          }
          .keyboardShortcut("r")
          .help("Reload Diff (⌘R)")
          .disabled(store.isLoading)
        }

        if let url = URL(string: request.url) {
          Button {
            openURL(url)
          } label: {
            Label("Open in Browser", systemImage: "safari")
          }
          .help("Open in Browser")
        }
      }
    }
    .overlay {
      PullRequestDiffGoToFileOverlay(store: store, fontSize: Self.pointSize(.title3, scale: textScale))
    }
    .focusedSceneAction(\.goToDiffFileAction, enabled: hasFiles) {
      store.send(.goToFile(.toggle))
    }
    .focusedSceneAction(\.startSearchAction, enabled: hasFiles) {
      textCommands.perform(.showFindInterface)
    }
    .focusedSceneAction(\.navigateSearchNextAction, enabled: hasFiles) {
      textCommands.perform(.nextMatch)
    }
    .focusedSceneAction(\.navigateSearchPreviousAction, enabled: hasFiles) {
      textCommands.perform(.previousMatch)
    }
    .focusedSceneAction(\.searchSelectionAction, enabled: hasFiles) {
      textCommands.perform(.setSearchString)
    }
    .alert(
      "Couldn't Reload Diff",
      isPresented: Binding(
        get: { store.document != nil && store.errorMessage != nil },
        set: { if !$0 { store.send(.errorDismissed) } }
      )
    ) {
      Button("OK", role: .cancel) {}
        .keyboardShortcut(.defaultAction)
    } message: {
      Text(store.errorMessage ?? "")
    }
    .task {
      store.send(.task)
    }
  }

  private var subtitle: String {
    guard let document = store.document else {
      return store.isLoading ? "Loading…" : ""
    }
    let files = document.files.count == 1 ? "1 file" : "\(document.files.count.formatted()) files"
    return "\(files) changed, +\(document.additions.formatted()) −\(document.deletions.formatted())"
  }

  /// The semantic style's system size at the chrome text scale.
  static func pointSize(_ style: NSFont.TextStyle, scale: Double) -> CGFloat {
    (NSFont.preferredFont(forTextStyle: style).pointSize * scale).rounded()
  }
}

private struct PullRequestDiffDetail: View {
  let store: StoreOf<PullRequestDiffFeature>
  let fontSize: CGFloat
  let commands: PullRequestDiffTextCommands
  let palette: TerminalColorPalette
  @Environment(\.openURL) private var openURL

  var body: some View {
    if let document = store.document {
      if document.files.isEmpty {
        ContentUnavailableView(
          "No Changes",
          systemImage: "doc.text.magnifyingglass",
          description: Text("This pull request has no file changes.")
        )
      } else {
        VStack(spacing: 0) {
          if commands.isPresented { PullRequestDiffFindBar(commands: commands) }
          PullRequestDiffTextView(
            document: document,
            fontSize: fontSize,
            scrollRequest: store.scrollRequest,
            commands: commands,
            palette: palette,
            onVisibleFileChange: { store.send(.visibleFileChanged($0)) }
          )
        }
      }
    } else if let errorMessage = store.errorMessage {
      ContentUnavailableView {
        Label("Couldn't Load Diff", systemImage: "exclamationmark.triangle")
      } description: {
        Text(errorMessage)
      } actions: {
        Button("Try Again") {
          store.send(.reloadButtonTapped)
        }
        .help("Load the diff again (⌘R)")
        if let url = URL(string: store.request.url) {
          Button("Open in Browser") {
            openURL(url)
          }
          .help("Open the pull request in the browser")
        }
      }
    } else {
      ProgressView("Loading diff…")
    }
  }
}

// MARK: - Sidebar

private struct PullRequestDiffSidebar: View {
  let store: StoreOf<PullRequestDiffFeature>

  var body: some View {
    let files = store.document?.files ?? []
    ScrollViewReader { proxy in
      List(
        selection: Binding(
          get: { store.selectedFileID },
          set: { fileID in
            guard let fileID else { return }
            store.send(.fileSelected(fileID))
          }
        )
      ) {
        ForEach(files) { file in
          PullRequestDiffFileRow(file: file)
            .tag(file.id as PullRequestDiffFile.ID?)
        }
      }
      .onChange(of: store.selectedFileID) { _, fileID in
        guard let fileID else { return }
        proxy.scrollTo(fileID)
      }
    }
  }
}

private struct PullRequestDiffFileRow: View {
  let file: PullRequestDiffFile

  var body: some View {
    let style = PullRequestDiffFileStatusStyle(file.status)
    HStack(spacing: 6) {
      Image(systemName: style.symbolName)
        .foregroundStyle(style.color)
        .accessibilityLabel(style.label)
      VStack(alignment: .leading, spacing: 1) {
        Text(file.name)
          .appFont(.body)
          .lineLimit(1)
          .truncationMode(.middle)
        if !file.directory.isEmpty {
          Text(file.directory)
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
      Spacer(minLength: 4)
      PullRequestDiffLineStats(file: file)
    }
    .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
  }
}

private struct PullRequestDiffLineStats: View {
  let file: PullRequestDiffFile
  var isHighlighted = false

  var body: some View {
    Group {
      if file.isBinary {
        Text("Binary")
          .foregroundStyle(.secondary)
      } else {
        HStack(spacing: 4) {
          Text("+\(file.additions)")
            .foregroundStyle(isHighlighted ? AnyShapeStyle(.primary) : AnyShapeStyle(.green))
          Text("−\(file.deletions)")
            .foregroundStyle(isHighlighted ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
        }
      }
    }
    .appFont(.caption)
    .monospacedDigit()
  }
}

// MARK: - Go to File

private struct PullRequestDiffGoToFileOverlay: View {
  let store: StoreOf<PullRequestDiffFeature>
  let fontSize: CGFloat

  var body: some View {
    if let goToFile = store.goToFile, let files = store.document?.files {
      ZStack(alignment: .top) {
        // Clicking anywhere outside the panel dismisses it.
        Button {
          store.send(.goToFile(.dismiss))
        } label: {
          Color.clear
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityHidden(true)

        PullRequestDiffGoToFilePanel(
          query: goToFile.query,
          results: goToFile.results.map { files[$0] },
          highlightedIndex: goToFile.highlightedIndex,
          fontSize: fontSize,
          send: { store.send(.goToFile($0)) }
        )
        .padding(.top, 48)
        .padding(.horizontal, 16)
      }
    }
  }
}

private struct PullRequestDiffGoToFilePanel: View {
  static let maxListHeight: CGFloat = 360

  let query: String
  let results: [PullRequestDiffFile]
  let highlightedIndex: Int
  let fontSize: CGFloat
  let send: (PullRequestDiffFeature.GoToFileAction) -> Void
  @State private var listHeight: CGFloat = 0

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .appFont(.title3)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        PullRequestDiffGoToFileField(
          text: query,
          fontSize: fontSize,
          onTextChange: { send(.queryChanged($0)) },
          onCommand: { command in
            switch command {
            case .moveUp: send(.moveHighlight(-1))
            case .moveDown: send(.moveHighlight(1))
            case .submit: send(.submit)
            case .cancel: send(.dismiss)
            }
          }
        )
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)

      if !results.isEmpty {
        Divider()
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 2) {
              ForEach(Array(results.enumerated()), id: \.element.id) { index, file in
                Button {
                  send(.resultTapped(file.id))
                } label: {
                  PullRequestDiffGoToFileRow(file: file, isHighlighted: index == highlightedIndex)
                }
                .buttonStyle(.plain)
                .help(file.path)
                .id(file.id)
              }
            }
            .padding(6)
            .onGeometryChange(for: CGFloat.self) {
              $0.size.height
            } action: {
              listHeight = $0
            }
          }
          .frame(height: min(listHeight, Self.maxListHeight))
          .onChange(of: highlightedIndex) { _, index in
            guard results.indices.contains(index) else { return }
            proxy.scrollTo(results[index].id)
          }
        }
      } else if !query.isEmpty {
        Divider()
        Text("No Matching Files")
          .foregroundStyle(.secondary)
          .padding(14)
      }
    }
    .frame(maxWidth: 600)
    .glassEffect(.regular, in: .rect(cornerRadius: 16))
  }
}

private struct PullRequestDiffGoToFileRow: View {
  let file: PullRequestDiffFile
  let isHighlighted: Bool

  var body: some View {
    let style = PullRequestDiffFileStatusStyle(file.status)
    HStack(spacing: 8) {
      Image(systemName: style.symbolName)
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.primary) : AnyShapeStyle(style.color))
        .accessibilityLabel(style.label)
      Text(file.name)
        .appFont(.body, weight: .medium)
        .lineLimit(1)
        .layoutPriority(1)
      Text(file.directory)
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.head)
      Spacer(minLength: 8)
      PullRequestDiffLineStats(file: file, isHighlighted: isHighlighted)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .contentShape(.rect)
    // Selected-row text reads as light on the accent fill, like a menu.
    .transformEnvironment(\.colorScheme) { scheme in
      guard isHighlighted else { return }
      scheme = .dark
    }
    .background {
      if isHighlighted {
        RoundedRectangle(cornerRadius: 8)
          .fill(Color(nsColor: .selectedContentBackgroundColor))
      }
    }
  }
}

/// The Go to File query field. AppKit-backed so ↑/↓ (and ⌃P/⌃N), Return, and
/// Escape reach the panel through the field editor's standard commands.
private struct PullRequestDiffGoToFileField: NSViewRepresentable {
  enum Command {
    case moveUp
    case moveDown
    case submit
    case cancel
  }

  let text: String
  let fontSize: CGFloat
  let onTextChange: (String) -> Void
  let onCommand: (Command) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSTextField {
    let field = FocusingTextField()
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.isBezeled = false
    field.placeholderString = "Go to file"
    field.usesSingleLineMode = true
    field.lineBreakMode = .byTruncatingTail
    field.delegate = context.coordinator
    field.setAccessibilityLabel("Go to file")
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text {
      field.stringValue = text
    }
    if field.font?.pointSize != fontSize {
      field.font = .systemFont(ofSize: fontSize, weight: .light)
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    nonisolated deinit {}

    var parent: PullRequestDiffGoToFileField?

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent?.onTextChange(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      let command: Command? =
        switch selector {
        case #selector(NSResponder.moveUp(_:)): .moveUp
        case #selector(NSResponder.moveDown(_:)): .moveDown
        case #selector(NSResponder.insertNewline(_:)): .submit
        case #selector(NSResponder.cancelOperation(_:)): .cancel
        default: nil
        }
      guard let command else { return false }
      parent?.onCommand(command)
      return true
    }
  }

  /// Takes focus as soon as the panel appears, and hands it back to the
  /// previous responder (the sidebar or the diff) when the panel closes.
  private final class FocusingTextField: NSTextField {
    nonisolated deinit {}

    private weak var previousResponder: NSResponder?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      previousResponder = window.firstResponder
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        window.makeFirstResponder(self)
      }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow == nil, let window, (window.firstResponder as? NSText)?.delegate === self {
        window.makeFirstResponder(previousResponder)
      }
      super.viewWillMove(toWindow: newWindow)
    }
  }
}
