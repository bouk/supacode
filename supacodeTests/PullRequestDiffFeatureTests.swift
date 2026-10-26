import AppKit
import ComposableArchitecture
import Foundation
import GhosttyKit
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct PullRequestDiffFeatureTests {
  private static let request = PullRequestDiffRequest(
    repositoryRootURL: URL(filePath: "/tmp/repo", directoryHint: .isDirectory),
    repositoryHost: nil,
    number: 42,
    numberSigil: "#",
    title: "Add diff window",
    url: "https://github.com/owner/repo/pull/42"
  )

  private nonisolated static let diff = """
    diff --git a/README.md b/README.md
    --- a/README.md
    +++ b/README.md
    @@ -1 +1 @@
    -old
    +new
    diff --git a/Sources/App.swift b/Sources/App.swift
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -1 +1,2 @@
     a
    +b

    """

  private nonisolated static let remote = GithubRemoteInfo(host: "github.com", owner: "owner", repo: "repo")

  private static func loadedState(_ diff: String = Self.diff) -> PullRequestDiffFeature.State {
    var state = PullRequestDiffFeature.State(request: request)
    let document = PullRequestDiffParser.parse(diff)
    state.document = document
    state.selectedFileID = document.files.first?.id
    return state
  }

  @Test func taskLoadsAndSelectsFirstFile() async {
    let requested = LockIsolated<[Int]>([])
    let store = TestStore(initialState: PullRequestDiffFeature.State(request: Self.request)) {
      PullRequestDiffFeature()
    } withDependencies: {
      $0.githubCLI.resolveRemoteInfo = { _ in Self.remote }
      $0.githubCLI.pullRequestDiff = { _, number in
        requested.withValue { $0.append(number) }
        return Self.diff
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.task) {
      $0.isLoading = true
    }
    await store.receive(\.diffResponse.success) {
      $0.isLoading = false
      $0.selectedFileID = 0
    }
    #expect(store.state.document?.files.map(\.path) == ["README.md", "Sources/App.swift"])
    #expect(requested.value == [42])

    // A second task (the window re-appearing) does not refetch.
    await store.send(.task)
  }

  @Test func failureShowsMessage() async {
    struct Failure: LocalizedError {
      var errorDescription: String? { "diff too large" }
    }
    let store = TestStore(initialState: PullRequestDiffFeature.State(request: Self.request)) {
      PullRequestDiffFeature()
    } withDependencies: {
      $0.githubCLI.resolveRemoteInfo = { _ in Self.remote }
      $0.githubCLI.pullRequestDiff = { _, _ in throw Failure() }
    }

    await store.send(.task) {
      $0.isLoading = true
    }
    await store.receive(\.diffResponse.failure) {
      $0.isLoading = false
      $0.errorMessage = "diff too large"
    }
    await store.send(.errorDismissed) {
      $0.errorMessage = nil
    }
  }

  @Test func missingCLIFails() async {
    let store = TestStore(initialState: PullRequestDiffFeature.State(request: Self.request)) {
      PullRequestDiffFeature()
    } withDependencies: {
      $0.githubCLI.isAvailable = { false }
    }

    await store.send(.task) {
      $0.isLoading = true
    }
    await store.receive(\.diffResponse.failure) {
      $0.isLoading = false
      $0.errorMessage = PullRequestDiffError.cliUnavailable("gh").errorDescription
    }
  }

  @Test func reloadKeepsSelectedFileByPath() async {
    var state = Self.loadedState()
    state.selectedFileID = 1
    let reloaded = """
      diff --git a/NEW.md b/NEW.md
      --- /dev/null
      +++ b/NEW.md
      @@ -0,0 +1 @@
      +hi
      """ + "\n" + Self.diff
    let store = TestStore(initialState: state) {
      PullRequestDiffFeature()
    } withDependencies: {
      $0.githubCLI.resolveRemoteInfo = { _ in Self.remote }
      $0.githubCLI.pullRequestDiff = { _, _ in reloaded }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.reloadButtonTapped) {
      $0.isLoading = true
    }
    await store.receive(\.diffResponse.success) {
      $0.isLoading = false
      // Sources/App.swift moved from index 1 to 2.
      $0.selectedFileID = 2
    }
  }

  @Test func selectingFileRequestsScroll() async {
    let store = TestStore(initialState: Self.loadedState()) {
      PullRequestDiffFeature()
    }

    await store.send(.fileSelected(1)) {
      $0.selectedFileID = 1
      $0.scrollRequest = .init(fileID: 1, generation: 1)
    }
    // The same file again scrolls again.
    await store.send(.fileSelected(1)) {
      $0.scrollRequest = .init(fileID: 1, generation: 2)
    }
    // Unknown ids are ignored.
    await store.send(.fileSelected(9))
  }

  @Test func scrollingUpdatesSelectionWithoutScrollRequest() async {
    let store = TestStore(initialState: Self.loadedState()) {
      PullRequestDiffFeature()
    }

    await store.send(.visibleFileChanged(1)) {
      $0.selectedFileID = 1
    }
    await store.send(.visibleFileChanged(1))
  }

  @Test func goToFileFiltersAndSubmits() async {
    let store = TestStore(initialState: Self.loadedState()) {
      PullRequestDiffFeature()
    }

    await store.send(.goToFile(.toggle)) {
      $0.goToFile = .init(results: [0, 1])
    }
    await store.send(.goToFile(.moveHighlight(1))) {
      $0.goToFile?.highlightedIndex = 1
    }
    // Clamped at the end.
    await store.send(.goToFile(.moveHighlight(1)))
    await store.send(.goToFile(.queryChanged("app"))) {
      $0.goToFile?.query = "app"
      $0.goToFile?.results = [1]
      $0.goToFile?.highlightedIndex = 0
    }
    await store.send(.goToFile(.submit)) {
      $0.goToFile = nil
      $0.selectedFileID = 1
      $0.scrollRequest = .init(fileID: 1, generation: 1, focusesDiff: true)
    }
  }

  @Test func goToFileToggleAndDismiss() async {
    let store = TestStore(initialState: Self.loadedState()) {
      PullRequestDiffFeature()
    }

    await store.send(.goToFile(.toggle)) {
      $0.goToFile = .init(results: [0, 1])
    }
    await store.send(.goToFile(.toggle)) {
      $0.goToFile = nil
    }
    await store.send(.goToFile(.toggle)) {
      $0.goToFile = .init(results: [0, 1])
    }
    await store.send(.goToFile(.dismiss)) {
      $0.goToFile = nil
    }
    await store.send(.goToFile(.toggle)) {
      $0.goToFile = .init(results: [0, 1])
    }
    await store.send(.goToFile(.resultTapped(0))) {
      $0.goToFile = nil
      $0.scrollRequest = .init(fileID: 0, generation: 1, focusesDiff: true)
    }
  }

  @Test func goToFileNeedsLoadedFiles() async {
    let store = TestStore(initialState: PullRequestDiffFeature.State(request: Self.request)) {
      PullRequestDiffFeature()
    }

    await store.send(.goToFile(.toggle))
    await store.send(.goToFile(.submit))
  }

  @Test func requestIdentityIgnoresTitle() {
    let retitled = PullRequestDiffRequest(
      repositoryRootURL: Self.request.repositoryRootURL,
      repositoryHost: nil,
      number: 42,
      numberSigil: "#",
      title: "New title",
      url: Self.request.url
    )
    #expect(retitled == Self.request)
    #expect(retitled.hashValue == Self.request.hashValue)
  }
}

@MainActor
struct PullRequestDiffTextTests {
  private static func document(path: String = "main.ts", source: String = "const answer = 42;")
    -> PullRequestDiffDocument
  {
    PullRequestDiffParser.parse(
      "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -1 +1 @@\n-old\n+\(source)\n")
  }

  private static func textView(document: PullRequestDiffDocument) -> (NSScrollView, PullRequestDiffNSTextView) {
    let scroll = PullRequestDiffTextView.makeScrollView()
    scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
    let text = scroll.documentView as! PullRequestDiffNSTextView
    text.fullModel = PullRequestDiffTextDocument(document: document)
    text.syntaxTokens = PullRequestDiffSyntaxHighlighter.tokens(in: text.fullModel!)
    text.seedCollapsedFiles()
    text.rebuildProjection()
    text.applyStyle(fontSize: NSFont.preferredFont(forTextStyle: .body).pointSize)
    (scroll.verticalRulerView as? PullRequestDiffRulerView)?.updateThickness()
    return (scroll, text)
  }

  private static func palette(config contents: String) throws -> TerminalColorPalette {
    let config = try #require(ghostty_config_new())
    defer { ghostty_config_free(config) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("diff-theme-\(UUID().uuidString).conf")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    url.path.withCString { ghostty_config_load_file(config, $0) }
    ghostty_config_finalize(config)
    return TerminalColorPalette(config: config)
  }

  @Test func syntaxColorsUseTheTerminalPaletteAndThemeUpdatesPreserveTheViewport() async throws {
    let palette = try Self.palette(
      config: """
        background = #102030
        foreground = #f0e0d0
        palette = 1=#d04050
        palette = 2=#40b060
        palette = 3=#e0b040
        palette = 4=#5080d0
        palette = 5=#b070d0
        palette = 6=#40b0c0
        palette = 8=#708090
        """)
    #expect(palette.background.matchesTint(NSColor(ghostty: .init(r: 0x10, g: 0x20, b: 0x30))))
    #expect(palette.foreground.matchesTint(NSColor(ghostty: .init(r: 0xf0, g: 0xe0, b: 0xd0))))
    #expect(palette.color(5).matchesTint(NSColor(ghostty: .init(r: 0xb0, g: 0x70, b: 0xd0))))
    let source = "const answer: number = greet(\"hello\") + 42; // note " + String(repeating: "x", count: 300)
    let diff =
      "diff --git a/main.ts b/main.ts\n--- a/main.ts\n+++ b/main.ts\n@@ -0,0 +1,201 @@\n+" + source + "\n"
      + (0..<200).map { "+const value\($0) = \($0);\n" }.joined()
    let document = PullRequestDiffParser.parse(diff)
    let (scroll, text) = Self.textView(document: document)
    let window = NSWindow(contentRect: scroll.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.contentView = nil }
    window.contentView?.layoutSubtreeIfNeeded()
    scroll.tile()
    let coordinator = PullRequestDiffTextView.Coordinator()
    coordinator.attach(textView: text, scrollView: scroll)
    defer { NotificationCenter.default.removeObserver(coordinator) }
    text.layoutManager?.ensureLayout(for: text.textContainer!)
    text.sizeToFit()
    scroll.contentView.scroll(to: NSPoint(x: 150, y: 250))
    scroll.reflectScrolledClipView(scroll.contentView)
    let selection = (text.string as NSString).range(of: "hello")
    text.setSelectedRange(selection)
    let oldBounds = scroll.contentView.bounds
    #expect(oldBounds.minX > 0 && oldBounds.minY > 0)
    coordinator.update(document: document, fontSize: text.font!.pointSize, palette: palette)
    await Task.yield()
    for (word, index) in [("const", 5), ("number", 6), ("greet", 4), ("hello", 1), ("42", 3), ("// note", 8)] {
      let range = (text.string as NSString).range(of: word)
      let color = text.textStorage!.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as! NSColor
      #expect(color.matchesTint(palette.color(index)))
    }
    #expect(text.backgroundColor.matchesTint(palette.background))
    #expect(scroll.backgroundColor.matchesTint(palette.background))
    #expect((text.selectedTextAttributes[.backgroundColor] as! NSColor).matchesTint(palette.selectionBackground))
    #expect(text.background(for: .addition) == palette.color(2).withAlphaComponent(0.13))
    #expect(scroll.contentView.bounds == oldBounds)
    #expect(text.selectedRange() == selection)

    let replacement = try Self.palette(config: "background = #ffffff\nforeground = #102030\npalette = 5=#603090")
    coordinator.update(document: document, fontSize: text.font!.pointSize, palette: replacement)
    await Task.yield()
    let keyword = (text.string as NSString).range(of: "const")
    let color = text.textStorage!.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as! NSColor
    #expect(color.matchesTint(replacement.color(5)))
    #expect(text.backgroundColor.matchesTint(replacement.background))
    #expect(scroll.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    #expect(scroll.contentView.bounds == oldBounds)
    #expect(text.selectedRange() == selection)
  }

  @Test func bundledSupacodeThemesProvideDistinctDiffPalettes() throws {
    let lightPath = try #require(Bundle.main.path(forResource: "Supacode Light", ofType: nil))
    let darkPath = try #require(Bundle.main.path(forResource: "Supacode Dark", ofType: nil))
    let light = try Self.palette(config: "theme = \(lightPath)")
    let dark = try Self.palette(config: "theme = \(darkPath)")
    #expect(light.background.isLightColor)
    #expect(!dark.background.isLightColor)
    #expect(!light.color(5).matchesTint(dark.color(5)))
    #expect(light.color(5).matchesTint(NSColor(ghostty: .init(r: 0xcb, g: 0x30, b: 0xe0))))
    #expect(dark.color(5).matchesTint(NSColor(ghostty: .init(r: 0xdb, g: 0x34, b: 0xf2))))
  }

  @Test func copyPreservesCharactersAndOmitsGutters() {
    let source = "\tconst café = \"👩🏽‍💻\";"
    let (scroll, text) = Self.textView(document: Self.document(source: source))
    let window = NSWindow(contentRect: scroll.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scroll
    window.makeFirstResponder(text)
    defer { window.contentView = nil }
    let range = (text.string as NSString).range(of: "café = \"👩🏽‍💻\"")
    text.setSelectedRange(range)
    #expect(range.location != NSNotFound)
    #expect(text.selectedRange() == range)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(text.writeSelection(to: pasteboard, types: [.string]))
    #expect(pasteboard.string(forType: .string) == "café = \"👩🏽‍💻\"")
    #expect(text.string.contains(source))
    let keyword = (text.string as NSString).range(of: "const")
    #expect(
      text.textStorage?.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? NSColor
        == .systemPurple)
    #expect(!text.isEditable)
    #expect(text.isSelectable)

  }

  @Test func longLinesAndUTF16RangesRemainIntact() {
    let source = "\t👩🏽‍💻" + String(repeating: "x", count: 5000)
    let model = PullRequestDiffTextDocument(document: Self.document(source: source))
    let row = model.document.rows.firstIndex { $0.kind == .addition }!
    #expect((model.text as NSString).substring(with: model.rowRanges[row]) == source + "\n")
    #expect(model.row(atUTF16Offset: model.rowRanges[row].location + 2) == row)
    #expect(model.row(atUTF16Offset: -1) == nil)
    #expect(model.row(atUTF16Offset: model.text.utf16.count) == nil)
  }

  @Test func headersToggleAndGeneratedDefaultsCanBeOverridden() {
    let document = Self.document(path: "package-lock.json")
    let (scroll, text) = Self.textView(document: document)
    let window = NSWindow(contentRect: scroll.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.contentView = nil }
    #expect(text.collapsedPaths == ["package-lock.json"])
    #expect(!text.string.contains("const answer"))
    #expect(text.string.contains("▸"))
    text.layoutManager?.ensureLayout(for: text.textContainer!)
    let point = text.convert(NSPoint(x: text.textContainerOrigin.x + 10, y: text.textContainerOrigin.y + 5), to: nil)
    let click = NSEvent.mouseEvent(
      with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    text.mouseDown(with: click)
    #expect(text.string.contains("const answer"))
    text.seedCollapsedFiles()
    #expect(text.collapsedPaths.isEmpty)
    text.toggleFile(0)
    #expect(!text.string.contains("const answer"))
    text.expandFile(0)
    #expect(text.string.contains("const answer"))
  }

  @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
  func fileNavigationOnlyScrollsVertically(collapsed: Bool, focusesDiff: Bool) async {
    let diff = (0..<3).map { file in
      "diff --git a/file\(file).ts b/file\(file).ts\n--- a/file\(file).ts\n+++ b/file\(file).ts\n@@ -0,0 +1,60 @@\n"
        + (0..<60).map { "+const value\($0) = \"" + String(repeating: "x", count: 300) + "\";\n" }.joined()
    }.joined()
    let document = PullRequestDiffParser.parse(diff)
    let (scroll, text) = Self.textView(document: document)
    let window = NSWindow(contentRect: scroll.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.contentView = nil }
    let coordinator = PullRequestDiffTextView.Coordinator()
    coordinator.attach(textView: text, scrollView: scroll)
    defer { NotificationCenter.default.removeObserver(coordinator) }
    let layout = text.layoutManager!
    let container = text.textContainer!
    layout.ensureLayout(for: container)
    text.sizeToFit()
    if collapsed { text.toggleFile(2) }
    scroll.contentView.scroll(to: NSPoint(x: 180, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    let oldX = scroll.contentView.bounds.minX
    #expect(oldX > 0)

    coordinator.scrollToFile(2, focusesDiff: focusesDiff)
    layout.ensureLayout(for: container)
    text.sizeToFit()
    await Task.yield()

    #expect(!text.collapsedPaths.contains("file2.ts"))
    #expect(abs(scroll.contentView.bounds.minX - oldX) < 1)
    let range = text.model!.rowRanges[document.files[2].headerRow]
    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
      .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    #expect(abs(scroll.contentView.bounds.minY + scroll.contentView.contentInsets.top - rect.minY) < 1)
  }

  @Test(arguments: [false, true])
  func foldingKeepsClickedHeaderAtTheSameScreenPosition(lastFile: Bool) async {
    let diff = (0..<3).map { file in
      "diff --git a/file\(file).ts b/file\(file).ts\n--- a/file\(file).ts\n+++ b/file\(file).ts\n@@ -0,0 +1,200 @@\n"
        + (0..<200).map { "+const value\($0) = \"file\(file)" + String(repeating: "x", count: 120) + "\";\n" }.joined()
    }.joined()
    let document = PullRequestDiffParser.parse(diff)
    let (scroll, text) = Self.textView(document: document)
    let window = NSWindow(contentRect: scroll.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.contentView = nil }
    let coordinator = PullRequestDiffTextView.Coordinator()
    coordinator.attach(textView: text, scrollView: scroll)
    defer { NotificationCenter.default.removeObserver(coordinator) }
    var reportedFiles: [Int] = []
    coordinator.onVisibleFileChange = { reportedFiles.append($0) }
    let layout = text.layoutManager!
    let container = text.textContainer!
    layout.ensureLayout(for: container)
    text.sizeToFit()
    let fileID = lastFile ? 2 : 1
    let headerRow = document.files[fileID].headerRow
    let headerRange = text.model!.rowRanges[headerRow]
    let glyphs = layout.glyphRange(forCharacterRange: headerRange, actualCharacterRange: nil)
    let originalRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
      .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    scroll.contentView.scroll(to: NSPoint(x: 25, y: originalRect.minY - 100))
    scroll.reflectScrolledClipView(scroll.contentView)
    let oldX = scroll.contentView.bounds.minX
    #expect(oldX > 0)
    let oldY = originalRect.minY - scroll.contentView.bounds.minY
    let selection = (text.string as NSString).range(of: "value199", options: .backwards)
    text.setSelectedRange(selection)

    let visibleFile = reportedFiles.last
    reportedFiles.removeAll()
    let point = text.convert(NSPoint(x: oldX + text.textContainerOrigin.x + 10, y: originalRect.minY + 5), to: nil)
    let click = NSEvent.mouseEvent(
      with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    text.mouseDown(with: click)
    layout.ensureLayout(for: container)
    text.sizeToFit()
    await Task.yield()
    let collapsedRange = text.model!.rowRanges[headerRow]
    let collapsedGlyphs = layout.glyphRange(forCharacterRange: collapsedRange, actualCharacterRange: nil)
    let collapsedRect = layout.boundingRect(forGlyphRange: collapsedGlyphs, in: container)
      .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    #expect(abs(collapsedRect.minY - scroll.contentView.bounds.minY - oldY) < 1)
    #expect(abs(scroll.contentView.bounds.minX - oldX) < 1)
    if let visibleFile { #expect(reportedFiles.allSatisfy { $0 == visibleFile }) }

    text.toggleFile(fileID)
    layout.ensureLayout(for: container)
    text.sizeToFit()
    await Task.yield()
    let expandedRange = text.model!.rowRanges[headerRow]
    let expandedGlyphs = layout.glyphRange(forCharacterRange: expandedRange, actualCharacterRange: nil)
    let expandedRect = layout.boundingRect(forGlyphRange: expandedGlyphs, in: container)
      .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    #expect(abs(expandedRect.minY - scroll.contentView.bounds.minY - oldY) < 1)
  }

  @Test func generatedAttributesOverrideFallbacksAndBannersAreRecognized() {
    let document = Self.document(path: "package-lock.json")
    let explicit = PullRequestDiffDocument(
      files: document.files, rows: document.rows, maxColumns: document.maxColumns,
      maxLineNumber: document.maxLineNumber, generatedFileAttributes: ["package-lock.json": false])
    #expect(!PullRequestDiffTextDocument.isGenerated(explicit.files[0], in: explicit))
    let banner = Self.document(path: "model.ts", source: "// Code generated by schema; DO NOT EDIT.")
    #expect(PullRequestDiffTextDocument.isGenerated(banner.files[0], in: banner))
    #expect(!PullRequestDiffTextDocument.isGenerated(Self.document().files[0], in: Self.document()))
  }

  @Test func findSearchesCollapsedFilesAndNavigatesMatches() async {
    let (scroll, text) = Self.textView(
      document: Self.document(path: "package-lock.json", source: "const hiddenNeedle = \"hiddenNeedle\";"))
    defer { _ = scroll }
    let commands = PullRequestDiffTextCommands()
    commands.textView = text
    text.searchCommands = commands
    commands.perform(.showFindInterface)
    #expect(commands.isPresented)
    let focus = commands.focusGeneration
    commands.perform(.showFindInterface)
    #expect(commands.focusGeneration > focus)
    commands.query = "hiddenneedle"
    await commands.searchTask?.value
    #expect(commands.matches.count == 2)
    #expect(text.collapsedPaths.isEmpty)
    #expect((text.string as NSString).substring(with: text.selectedRange()) == "hiddenNeedle")
    let first = text.selectedRange()
    commands.perform(.nextMatch)
    #expect(text.selectedRange() != first)
    commands.perform(.nextMatch)
    #expect(text.selectedRange() == first)
    commands.perform(.previousMatch)
    #expect(commands.selectedIndex == 1)
    commands.perform(.hideFindInterface)
    #expect(!commands.isPresented)
    #expect(text.searchRanges.isEmpty)
  }

  @Test func searchSupportsUnicodeAndClearingAndDocumentChanges() async {
    let (scroll, text) = Self.textView(document: Self.document(source: "const café = \"👩🏽‍💻\";"))
    defer { _ = scroll }
    let commands = PullRequestDiffTextCommands()
    commands.textView = text
    text.searchCommands = commands
    commands.perform(.showFindInterface)
    commands.query = "👩🏽‍💻"
    await commands.searchTask?.value
    #expect((text.string as NSString).substring(with: text.selectedRange()) == "👩🏽‍💻")
    commands.query = "café"
    commands.query = "const"
    await commands.searchTask?.value
    #expect(commands.matches.count == 1)
    #expect((text.string as NSString).substring(with: text.selectedRange()) == "const")
    commands.perform(.setSearchString)
    #expect(commands.query == "const")
    commands.query = ""
    #expect(commands.matches.isEmpty)
    #expect(text.searchRanges.isEmpty)
  }

  @Test func generatedAttributesAreLoadedWithTheDiff() async {
    let request = PullRequestDiffRequest(
      repositoryRootURL: URL(filePath: "/tmp/repo"), repositoryHost: nil,
      number: 42, numberSigil: "#", title: "Diff", url: "https://github.com/owner/repo/pull/42")
    let store = TestStore(initialState: PullRequestDiffFeature.State(request: request)) {
      PullRequestDiffFeature()
    } withDependencies: {
      $0.githubCLI.resolveRemoteInfo = { _ in GithubRemoteInfo(host: "github.com", owner: "owner", repo: "repo") }
      $0.githubCLI.pullRequestDiff = { _, _ in
        "diff --git a/model.ts b/model.ts\n--- a/model.ts\n+++ b/model.ts\n@@ -0,0 +1 @@\n+const answer = 42;\n"
      }
      $0.gitClient.generatedFileAttributes = { root, paths in
        #expect(root.path == "/tmp/repo")
        #expect(paths == ["model.ts"])
        return ["model.ts": true]
      }
    }
    store.exhaustivity = .off
    await store.send(.task)
    await store.receive(\.diffResponse.success)
    #expect(store.state.document?.generatedFileAttributes == ["model.ts": true])
  }

  @Test func gitGeneratedAttributesHandleUnusualPathsAndExplicitFalse() async {
    var shell = ShellClient.testValue
    shell.run = { _, arguments, _ in
      #expect(arguments.contains("check-attr"))
      #expect(arguments.suffix(3) == ["with\nnewline.ts", "package-lock.json", "normal.ts"])
      return ShellOutput(
        stdout:
          "with\nnewline.ts\0linguist-generated\0set\0package-lock.json\0linguist-generated\0false\0normal.ts\0linguist-generated\0unspecified\0",
        stderr: "", exitCode: 0)
    }
    let run = shell.run
    shell.runDataImpl = { executable, arguments, directory in
      Data((try await run(executable, arguments, directory)).stdout.utf8)
    }
    let attributes = await GitClient(shell: shell).generatedFileAttributes(
      at: URL(filePath: "/tmp/repo"), paths: ["with\nnewline.ts", "package-lock.json", "normal.ts"])
    #expect(attributes == ["with\nnewline.ts": true, "package-lock.json": false])
  }
}

nonisolated struct PullRequestDiffSyntaxTests {
  @Test(arguments: [
    ("main.ts", "interface Person { name: string }", "interface"),
    ("main.js", "const answer = 42;", "const"),
    ("main.rs", "pub fn main() {}", "pub"),
    ("flake.nix", "let answer = 42; in answer", "let"),
    ("main.py", "def greet(name): return name", "def"),
    ("index.html", "<div class=\"title\">hello</div>", "<div"),
    ("main.css", "body { color: red; }", "color"),
  ])
  func supportedLanguages(path: String, source: String, highlighted: String) {
    let tokens = PullRequestDiffSyntaxHighlighter.tokens(
      in: source, language: PullRequestDiffSyntaxHighlighter.Language(path: path)!)
    #expect(tokens.contains { (source as NSString).substring(with: $0.range) == highlighted })
    #expect(tokens.allSatisfy { NSMaxRange($0.range) <= source.utf16.count })
  }

  @Test func multilineStringsCommentsAndRustLifetimes() {
    let rust = "/* outer /* inner */ outer */ fn main<'a>(s: &'a str) { let x = r##\"raw \" string\"##; }"
    let tokens = PullRequestDiffSyntaxHighlighter.tokens(in: rust, language: .rust)
    #expect(tokens.contains { $0.kind == .keyword && (rust as NSString).substring(with: $0.range) == "fn" })
    #expect(
      tokens.contains { $0.kind == .string && (rust as NSString).substring(with: $0.range) == "r##\"raw \" string\"##" }
    )
    let python = "x = \"\"\"first\nsecond\"\"\"\ndef greet(): pass"
    let pythonTokens = PullRequestDiffSyntaxHighlighter.tokens(in: python, language: .python)
    #expect(
      pythonTokens.contains {
        $0.kind == .string && (python as NSString).substring(with: $0.range).contains("first\nsecond")
      })
    let nix = "let text = ''first\nsecond''; in text"
    #expect(
      PullRequestDiffSyntaxHighlighter.tokens(in: nix, language: .nix).contains {
        $0.kind == .string && (nix as NSString).substring(with: $0.range) == "''first\nsecond''"
      })
  }

  @Test func removedCommentsDoNotColorNewCodeAndHunksResetState() {
    let diff =
      "diff --git a/main.ts b/main.ts\n--- a/main.ts\n+++ b/main.ts\n@@ -1 +1 @@\n-/* removed comment\n+const answer = 42;\n@@ -20 +20 @@\n-old\n+let next = true;\n"
    let model = PullRequestDiffTextDocument(document: PullRequestDiffParser.parse(diff))
    let tokens = PullRequestDiffSyntaxHighlighter.tokens(in: model)
    let words = tokens.filter { $0.kind == .keyword }.map { (model.text as NSString).substring(with: $0.range) }
    #expect(words == ["const", "let"])
  }

  @Test func htmlHighlightsEmbeddedScriptsAndStyles() {
    let html = "<script>const x = 42;</script><style>body { color: red; }</style>"
    let tokens = PullRequestDiffSyntaxHighlighter.tokens(in: html, language: .html)
    #expect(tokens.contains { $0.kind == .keyword && (html as NSString).substring(with: $0.range) == "const" })
    #expect(tokens.contains { $0.kind == .property && (html as NSString).substring(with: $0.range) == "color" })
  }
}
