import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated enum PullRequestDiffError: LocalizedError, Equatable {
  case noForge
  case cliUnavailable(String)
  case noProject

  var errorDescription: String? {
    switch self {
    case .noForge:
      "Supacode could not resolve a git forge for this repository."
    case .cliUnavailable(let cliName):
      "Install `\(cliName)` to view pull request diffs."
    case .noProject:
      "Supacode could not resolve the forge project for this repository."
    }
  }
}

/// One pull-request diff window: loads the forge's diff, tracks the selected
/// file, and drives the Go to File panel.
@Reducer
struct PullRequestDiffFeature {
  @ObservableState
  struct State: Equatable {
    let request: PullRequestDiffRequest
    var document: PullRequestDiffDocument?
    var isLoading = false
    var errorMessage: String?
    /// The sidebar selection: the clicked file, or the file at the top of the diff.
    var selectedFileID: PullRequestDiffFile.ID?
    /// A request for the diff to scroll a file to the top. The generation makes
    /// selecting the same file twice scroll twice.
    var scrollRequest: ScrollRequest?
    var goToFile: GoToFile?

    init(request: PullRequestDiffRequest) {
      self.request = request
    }
  }

  struct ScrollRequest: Equatable {
    let fileID: PullRequestDiffFile.ID
    let generation: Int
    /// Moves keyboard focus to the diff. Off for sidebar picks, which keep the
    /// sidebar focused for arrow-key browsing.
    var focusesDiff = false
  }

  struct GoToFile: Equatable {
    var query = ""
    /// Matching file ids, best first.
    var results: [PullRequestDiffFile.ID]
    var highlightedIndex = 0
  }

  enum Action {
    case task
    case reloadButtonTapped
    case diffResponse(Result<PullRequestDiffDocument, any Error>)
    case errorDismissed
    case fileSelected(PullRequestDiffFile.ID)
    case visibleFileChanged(PullRequestDiffFile.ID)
    case goToFile(GoToFileAction)
  }

  enum GoToFileAction: Equatable {
    case toggle
    case dismiss
    case queryChanged(String)
    case moveHighlight(Int)
    case submit
    case resultTapped(PullRequestDiffFile.ID)
  }

  /// The Go to File panel lists at most this many matches.
  static let goToFileResultLimit = 100

  static func goToFileResults(_ files: [PullRequestDiffFile], query: String) -> [PullRequestDiffFile.ID] {
    Array(PullRequestDiffFileMatcher.rank(files, query: query).prefix(goToFileResultLimit))
  }

  private nonisolated enum CancelID: Hashable, Sendable {
    case load
  }

  @Dependency(ForgeRegistry.self) private var forgeRegistry

  // `Reducer<State, Action>`, not `ReducerOf<Self>`: other files use this
  // reducer's nested types, which makes `Self` resolution circular.
  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        guard state.document == nil, !state.isLoading else { return .none }
        return load(&state)

      case .reloadButtonTapped:
        return load(&state)

      case .diffResponse(.success(let document)):
        apply(document, to: &state)
        return .none

      case .diffResponse(.failure(let error)):
        state.isLoading = false
        state.errorMessage = error.localizedDescription
        return .none

      case .errorDismissed:
        state.errorMessage = nil
        return .none

      case .fileSelected(let fileID):
        select(fileID, in: &state)
        return .none

      case .visibleFileChanged(let fileID):
        guard state.selectedFileID != fileID else { return .none }
        state.selectedFileID = fileID
        return .none

      case .goToFile(let action):
        reduceGoToFile(action, state: &state)
        return .none
      }
    }
  }

  private func load(_ state: inout State) -> Effect<Action> {
    state.isLoading = true
    let request = state.request
    let forgeRegistry = forgeRegistry
    return .run { send in
      do {
        let document = try await Self.fetchDocument(request: request, registry: forgeRegistry)
        await send(.diffResponse(.success(document)))
      } catch is CancellationError {
        return
      } catch {
        await send(.diffResponse(.failure(error)))
      }
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }

  private static func fetchDocument(
    request: PullRequestDiffRequest,
    registry: ForgeRegistry
  ) async throws -> PullRequestDiffDocument {
    let registry = registry.forHost(request.repositoryHost)
    let rootURL = request.repositoryRootURL
    guard
      let forgeID = await registry.resolveForgeID(rootURL, request.repositoryHost),
      let forge = registry.client(forgeID)
    else {
      throw PullRequestDiffError.noForge
    }
    guard await forge.isAvailable() else {
      throw PullRequestDiffError.cliUnavailable(registry.capabilities(forgeID)?.vocabulary.cliName ?? forgeID.rawValue)
    }
    guard let project = await forge.resolveProject(rootURL) else {
      throw PullRequestDiffError.noProject
    }
    let diff = try await forge.pullRequestDiff(project, request.number)
    let document = await PullRequestDiffParser.parseInBackground(diff)
    @Dependency(GitClientDependency.self) var gitClient
    @Dependency(ShellClient.self) var shellClient
    let git = request.repositoryHost.map { GitClientDependency.ssh(host: $0, base: shellClient) } ?? gitClient
    let attributes = await git.generatedFileAttributes(rootURL, document.files.map(\.path))
    return PullRequestDiffDocument(
      files: document.files, rows: document.rows, maxColumns: document.maxColumns,
      maxLineNumber: document.maxLineNumber, generatedFileAttributes: attributes)
  }

  private func apply(_ document: PullRequestDiffDocument, to state: inout State) {
    state.isLoading = false
    state.errorMessage = nil
    // Keep the selected file across a reload when it is still in the diff.
    var selectedFileID = document.files.first?.id
    if let previous = state.selectedFileID, let files = state.document?.files, files.indices.contains(previous) {
      let path = files[previous].path
      if let match = document.files.first(where: { $0.path == path }) {
        selectedFileID = match.id
      }
    }
    state.document = document
    state.selectedFileID = selectedFileID
    if let query = state.goToFile?.query {
      state.goToFile?.results = Self.goToFileResults(document.files, query: query)
      state.goToFile?.highlightedIndex = 0
    }
  }

  private func select(_ fileID: PullRequestDiffFile.ID, focusesDiff: Bool = false, in state: inout State) {
    guard state.document?.files.indices.contains(fileID) == true else { return }
    state.selectedFileID = fileID
    state.scrollRequest = ScrollRequest(
      fileID: fileID,
      generation: (state.scrollRequest?.generation ?? 0) + 1,
      focusesDiff: focusesDiff
    )
  }

  private func reduceGoToFile(_ action: GoToFileAction, state: inout State) {
    switch action {
    case .toggle:
      if state.goToFile != nil {
        state.goToFile = nil
      } else if let document = state.document, !document.files.isEmpty {
        state.goToFile = GoToFile(results: Self.goToFileResults(document.files, query: ""))
      }

    case .dismiss:
      state.goToFile = nil

    case .queryChanged(let query):
      guard let document = state.document, state.goToFile != nil else { return }
      state.goToFile?.query = query
      state.goToFile?.results = Self.goToFileResults(document.files, query: query)
      state.goToFile?.highlightedIndex = 0

    case .moveHighlight(let offset):
      guard let goToFile = state.goToFile, !goToFile.results.isEmpty else { return }
      state.goToFile?.highlightedIndex = min(max(goToFile.highlightedIndex + offset, 0), goToFile.results.count - 1)

    case .submit:
      guard let goToFile = state.goToFile, goToFile.results.indices.contains(goToFile.highlightedIndex) else { return }
      state.goToFile = nil
      select(goToFile.results[goToFile.highlightedIndex], focusesDiff: true, in: &state)

    case .resultTapped(let fileID):
      state.goToFile = nil
      select(fileID, focusesDiff: true, in: &state)
    }
  }
}
