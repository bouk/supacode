import AppKit
import SwiftUI

/// Native text selection and accessibility with a source index for Find.
/// Gutters are drawn outside the text storage, so copying yields source code.
struct PullRequestDiffTextView: NSViewRepresentable {
  let document: PullRequestDiffDocument
  let fontSize: CGFloat
  let scrollRequest: PullRequestDiffFeature.ScrollRequest?
  let commands: PullRequestDiffTextCommands
  var palette: TerminalColorPalette = .system
  let onVisibleFileChange: (PullRequestDiffFile.ID) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = Self.makeScrollView()
    let textView = scrollView.documentView as! PullRequestDiffNSTextView
    commands.textView = textView
    textView.searchCommands = commands
    context.coordinator.attach(textView: textView, scrollView: scrollView)
    return scrollView
  }

  static func makeScrollView() -> NSScrollView {
    let textView = PullRequestDiffNSTextView(usingTextLayoutManager: false)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.importsGraphics = false
    textView.usesFontPanel = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.usesFindBar = false
    textView.isHorizontallyResizable = true
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainerInset = NSSize(width: 10, height: 8)
    textView.textContainer?.widthTracksTextView = false
    textView.layoutManager?.allowsNonContiguousLayout = true
    textView.backgroundColor = .textBackgroundColor
    textView.setAccessibilityLabel("Pull request diff")
    textView.toolTip =
      "Select and copy source text (⌘C). Click a file header to collapse or expand it. Find in the full diff (⌘F)."

    let scrollView = NSScrollView()
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.findBarPosition = .aboveContent
    scrollView.hasVerticalRuler = true
    let ruler = PullRequestDiffRulerView(scrollView: scrollView, orientation: .verticalRuler)
    ruler.clientView = textView
    scrollView.verticalRulerView = ruler
    scrollView.rulersVisible = true
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onVisibleFileChange = onVisibleFileChange
    coordinator.update(document: document, fontSize: fontSize, palette: palette)
    if let scrollRequest, scrollRequest != coordinator.handledScrollRequest {
      coordinator.handledScrollRequest = scrollRequest
      coordinator.scrollToFile(scrollRequest.fileID, focusesDiff: scrollRequest.focusesDiff)
    }
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    coordinator.highlightTask?.cancel()
    (scrollView.documentView as? PullRequestDiffNSTextView)?.searchCommands?.searchTask?.cancel()
    NotificationCenter.default.removeObserver(coordinator)
  }

  @MainActor
  final class Coordinator: NSObject {
    nonisolated deinit {}

    var onVisibleFileChange: (PullRequestDiffFile.ID) -> Void = { _ in }
    var handledScrollRequest: PullRequestDiffFeature.ScrollRequest?
    var highlightTask: Task<Void, Never>?
    private weak var textView: PullRequestDiffNSTextView?
    private weak var scrollView: NSScrollView?
    private var lastVisibleFileID: PullRequestDiffFile.ID?
    private var suppressesVisibleFileReports = false

    func attach(textView: PullRequestDiffNSTextView, scrollView: NSScrollView) {
      self.textView = textView
      self.scrollView = scrollView
      scrollView.contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(boundsChanged),
        name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    func update(document: PullRequestDiffDocument, fontSize: CGFloat, palette: TerminalColorPalette = .system) {
      guard let textView else { return }
      let documentChanged = textView.fullModel?.document !== document
      let fontChanged = textView.font?.pointSize != fontSize
      let paletteChanged = textView.palette != palette
      guard documentChanged || fontChanged || paletteChanged else { return }
      textView.palette = palette
      if paletteChanged, !documentChanged, !fontChanged {
        suppressesVisibleFileReports = true
        textView.applyTheme()
        suppressesVisibleFileReports = false
        return
      }
      let isFirstDocument = textView.model == nil
      suppressesVisibleFileReports = true
      if documentChanged {
        highlightTask?.cancel()
        let model = PullRequestDiffTextDocument(document: document)
        textView.fullModel = model
        textView.syntaxTokens = []
        textView.seedCollapsedFiles()
        textView.rebuildProjection()
        lastVisibleFileID = nil
        DispatchQueue.main.async { [weak commands = textView.searchCommands] in commands?.refreshSearch() }
        highlightTask = Task { [weak textView] in
          let tokens = await PullRequestDiffSyntaxHighlighter.highlight(model)
          guard !Task.isCancelled, let textView, textView.fullModel?.document === document else { return }
          textView.syntaxTokens = tokens
          textView.applySyntaxColors()
        }
      }
      textView.applyStyle(fontSize: fontSize)
      (scrollView?.verticalRulerView as? PullRequestDiffRulerView)?.updateThickness()
      suppressesVisibleFileReports = false
      if isFirstDocument {
        DispatchQueue.main.async { [weak textView] in
          guard let textView, let window = textView.window else { return }
          window.makeFirstResponder(textView)
        }
      }
    }

    func scrollToFile(_ fileID: PullRequestDiffFile.ID, focusesDiff: Bool) {
      guard let textView else { return }
      textView.expandFile(fileID)
      guard let model = textView.model, model.document.files.indices.contains(fileID),
        let layout = textView.layoutManager, let container = textView.textContainer, let scrollView
      else { return }
      let range = model.rowRanges[model.document.files[fileID].headerRow]
      let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(
        dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
      suppressesVisibleFileReports = true
      let clip = scrollView.contentView
      let maxY = max(0, textView.bounds.height - clip.bounds.height)
      clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(maxY, max(0, rect.minY - clip.contentInsets.top))))
      scrollView.reflectScrolledClipView(clip)
      suppressesVisibleFileReports = false
      lastVisibleFileID = fileID
      if focusesDiff { textView.window?.makeFirstResponder(textView) }
    }

    @objc private func boundsChanged() {
      scrollView?.verticalRulerView?.needsDisplay = true
      guard !suppressesVisibleFileReports, let textView, !textView.isRebuildingProjection, let model = textView.model,
        let layout = textView.layoutManager, let container = textView.textContainer,
        layout.numberOfGlyphs > 0
      else { return }
      let point = NSPoint(x: 0, y: max(0, textView.visibleRect.minY - textView.textContainerOrigin.y))
      let glyph = layout.glyphIndex(for: point, in: container)
      let offset = layout.characterIndexForGlyph(at: min(glyph, layout.numberOfGlyphs - 1))
      guard let row = model.row(atUTF16Offset: offset) else { return }
      let fileID = Int(model.document.rows[row].fileIndex)
      guard lastVisibleFileID != fileID else { return }
      lastVisibleFileID = fileID
      onVisibleFileChange(fileID)
    }
  }
}

final class PullRequestDiffNSTextView: NSTextView {
  nonisolated deinit {}

  var model: PullRequestDiffTextDocument?
  var fullModel: PullRequestDiffTextDocument?
  weak var searchCommands: PullRequestDiffTextCommands?
  private(set) var collapsedPaths: Set<String> = []
  private var seenPaths: Set<String> = []
  var searchRanges: [NSRange] = []
  var syntaxTokens: [PullRequestDiffSyntaxHighlighter.Token] = []
  var palette: TerminalColorPalette = .system
  private(set) var isRebuildingProjection = false

  private struct ScrollAnchor {
    let row: Int
    let screenY: CGFloat
    let x: CGFloat
  }

  override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

  override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    guard type == .string else { return false }
    let source = string as NSString
    let selected = selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= source.length }
    guard !selected.isEmpty else { return false }
    return pasteboard.setString(selected.map { source.substring(with: $0) }.joined(separator: "\n"), forType: .string)
  }

  override func performTextFinderAction(_ sender: Any?) {
    guard let item = sender as? NSMenuItem, let action = NSTextFinder.Action(rawValue: item.tag) else { return }
    searchCommands?.perform(action)
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(performTextFinderAction(_:)), let action = NSTextFinder.Action(rawValue: item.tag) {
      return searchCommands != nil && action != .showReplaceInterface
    }
    return super.validateUserInterfaceItem(item)
  }

  func seedCollapsedFiles() {
    guard let fullModel else { return }
    let paths = Set(fullModel.document.files.map(\.path))
    collapsedPaths.formIntersection(paths)
    for file in fullModel.document.files where !seenPaths.contains(file.path) {
      if PullRequestDiffTextDocument.isGenerated(file, in: fullModel.document) { collapsedPaths.insert(file.path) }
    }
    seenPaths = paths
  }

  func toggleFile(_ id: Int) {
    guard let fullModel, fullModel.document.files.indices.contains(id) else { return }
    let path = fullModel.document.files[id].path
    if collapsedPaths.remove(path) == nil { collapsedPaths.insert(path) }
    rebuildProjection(anchoredTo: fullModel.document.files[id].headerRow)
  }

  func expandFile(_ id: Int) {
    guard let fullModel, fullModel.document.files.indices.contains(id),
      collapsedPaths.remove(fullModel.document.files[id].path) != nil
    else { return }
    rebuildProjection(anchoredTo: fullModel.document.files[id].headerRow)
  }

  func rebuildProjection(anchoredTo row: Int? = nil) {
    guard let fullModel else { return }
    let collapsed = Set(fullModel.document.files.filter { collapsedPaths.contains($0.path) }.map(\.id))
    let origin = enclosingScrollView?.contentView.bounds.origin
    let anchor = row.flatMap { scrollAnchor(for: $0) }
    isRebuildingProjection = true
    defer { isRebuildingProjection = false }
    let previousSelection = fullRange(fromVisible: selectedRange())
    model = PullRequestDiffTextDocument(document: fullModel.document, collapsedFiles: collapsed)
    string = model?.text ?? ""
    applyStyle(fontSize: font?.pointSize ?? NSFont.preferredFont(forTextStyle: .body).pointSize)
    if let range = visibleRange(fromFull: previousSelection) { setSelectedRange(range) }
    if let anchor {
      restoreScrollAnchor(anchor)
    } else if let origin, let scroll = enclosingScrollView {
      scroll.contentView.scroll(to: origin)
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    enclosingScrollView?.verticalRulerView?.needsDisplay = true
    needsDisplay = true
  }

  private func scrollAnchor(for row: Int) -> ScrollAnchor? {
    guard let scroll = enclosingScrollView, let rect = rect(forRow: row) else { return nil }
    return ScrollAnchor(
      row: row, screenY: rect.minY - scroll.contentView.bounds.minY,
      x: scroll.contentView.bounds.minX)
  }

  private func rect(forRow row: Int) -> NSRect? {
    guard let model, model.rowRanges.indices.contains(row), model.rowRanges[row].length > 0,
      let layout = layoutManager, let container = textContainer
    else { return nil }
    let glyphs = layout.glyphRange(forCharacterRange: model.rowRanges[row], actualCharacterRange: nil)
    layout.ensureLayout(forGlyphRange: glyphs)
    return layout.boundingRect(forGlyphRange: glyphs, in: container)
      .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
  }

  private func restoreScrollAnchor(_ anchor: ScrollAnchor) {
    guard let scroll = enclosingScrollView, let layout = layoutManager, let container = textContainer else { return }
    // Replacing text invalidates TextKit's document height. Finish layout before
    // restoring the viewport, or its later resize clamps the old scroll offset.
    layout.ensureLayout(for: container)
    guard let rect = rect(forRow: anchor.row) else { return }
    let clip = scroll.contentView
    let targetY = max(-clip.contentInsets.top, rect.minY - anchor.screenY)
    let naturalHeight = layout.usedRect(for: container).maxY + textContainerInset.height * 2
    // Keep room below the last folded header so it can stay at the clicked
    // position. This minimum also survives NSTextView's subsequent sizeToFit.
    let minimumHeight = max(scroll.contentSize.height, targetY + clip.bounds.height - clip.contentInsets.bottom)
    minSize = NSSize(width: minSize.width, height: minimumHeight)
    setFrameSize(NSSize(width: frame.width, height: max(naturalHeight, minimumHeight)))
    clip.scroll(to: NSPoint(x: anchor.x, y: targetY))
    scroll.reflectScrolledClipView(clip)
  }

  func visibleRange(fromFull range: NSRange) -> NSRange? {
    guard let model, let fullModel, let first = fullModel.row(atUTF16Offset: range.location),
      let last = fullModel.row(atUTF16Offset: max(range.location, NSMaxRange(range) - 1)),
      model.rowRanges[first].length > 0, model.rowRanges[last].length > 0
    else { return nil }
    let start = model.rowRanges[first].location + range.location - fullModel.rowRanges[first].location
    let end = model.rowRanges[last].location + NSMaxRange(range) - fullModel.rowRanges[last].location
    return NSRange(location: start, length: max(0, end - start))
  }

  func fullRange(fromVisible range: NSRange) -> NSRange {
    guard let model, let fullModel, let first = model.row(atUTF16Offset: range.location),
      let last = model.row(atUTF16Offset: max(range.location, NSMaxRange(range) - 1))
    else {
      return NSRange(location: 0, length: 0)
    }
    let start = fullModel.rowRanges[first].location + range.location - model.rowRanges[first].location
    let end = fullModel.rowRanges[last].location + NSMaxRange(range) - model.rowRanges[last].location
    return NSRange(location: start, length: max(0, end - start))
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let offset = characterIndexForInsertion(at: point)
    if let model, let row = model.row(atUTF16Offset: offset), model.document.rows[row].kind == .fileHeader {
      window?.makeFirstResponder(self)
      toggleFile(Int(model.document.rows[row].fileIndex))
      return
    }
    super.mouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 49,
      let model, let row = model.row(atUTF16Offset: selectedRange().location),
      model.document.rows[row].kind == .fileHeader
    {
      toggleFile(Int(model.document.rows[row].fileIndex))
      return
    }
    if event.keyCode == 53, searchCommands?.isPresented == true {
      searchCommands?.perform(.hideFindInterface)
      window?.makeFirstResponder(self)
      return
    }
    super.keyDown(with: event)
  }

  func applyStyle(fontSize: CGFloat) {
    guard let model, let storage = textStorage else { return }
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    self.font = font
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = ceil(font.ascender - font.descender + font.leading) + 3
    paragraph.maximumLineHeight = paragraph.minimumLineHeight
    paragraph.tabStops = []
    paragraph.defaultTabInterval =
      (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(PullRequestDiffDocument.tabWidth)
    storage.beginEditing()
    storage.setAttributes(
      [.font: font, .foregroundColor: palette.foreground, .paragraphStyle: paragraph, .ligature: 0],
      range: NSRange(location: 0, length: storage.length))
    for (index, row) in model.document.rows.enumerated() {
      switch row.kind {
      case .fileHeader:
        storage.addAttributes(
          [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)], range: model.rowRanges[index])
      default: break
      }
    }
    storage.endEditing()
    // Preserve every source character, including minified lines. The container
    // does not wrap; double width leaves room for full-width Unicode glyphs.
    let characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
    let width = max(
      enclosingScrollView?.contentSize.width ?? 0, CGFloat(model.document.maxColumns) * characterWidth * 2 + 40)
    setFrameSize(NSSize(width: width, height: max(frame.height, enclosingScrollView?.contentSize.height ?? 0)))
    textContainer?.containerSize = NSSize(width: width - textContainerInset.width * 2, height: .greatestFiniteMagnitude)
    applyTheme()
    needsDisplay = true
  }

  func applyTheme() {
    let origin = enclosingScrollView?.contentView.bounds.origin
    backgroundColor = palette.background
    insertionPointColor = palette.foreground
    selectedTextAttributes = [
      .backgroundColor: palette.selectionBackground, .foregroundColor: palette.selectionForeground,
    ]
    enclosingScrollView?.backgroundColor = palette.background
    enclosingScrollView?.appearance = NSAppearance(named: palette.background.isLightColor ? .aqua : .darkAqua)
    if let model, let storage = textStorage {
      storage.beginEditing()
      storage.addAttribute(
        .foregroundColor, value: palette.foreground, range: NSRange(location: 0, length: storage.length))
      for (index, row) in model.document.rows.enumerated() where row.kind == .hunkHeader || row.kind == .note {
        storage.addAttribute(.foregroundColor, value: palette.muted, range: model.rowRanges[index])
      }
      storage.endEditing()
    }
    applySyntaxColors()
    // AppKit retiles rulers when appearance changes; preserve the user's viewport.
    if let origin, let scroll = enclosingScrollView {
      scroll.contentView.scroll(to: origin)
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    enclosingScrollView?.verticalRulerView?.needsDisplay = true
    needsDisplay = true
  }

  func applySyntaxColors() {
    guard let storage = textStorage else { return }
    storage.beginEditing()
    for token in syntaxTokens {
      guard let range = visibleRange(fromFull: token.range), NSMaxRange(range) <= storage.length else { continue }
      storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: range)
    }
    storage.endEditing()
    applySearchHighlights()
  }

  func applySearchHighlights() {
    guard let storage = textStorage else { return }
    storage.beginEditing()
    storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
    for match in searchRanges {
      guard let visible = visibleRange(fromFull: match), NSMaxRange(visible) <= storage.length else { continue }
      storage.addAttribute(
        .backgroundColor, value: palette.selectionBackground.withAlphaComponent(0.5), range: visible)
    }
    storage.endEditing()
  }

  func revealSearchMatch(_ range: NSRange) {
    guard let fullModel, let first = fullModel.row(atUTF16Offset: range.location),
      let last = fullModel.row(atUTF16Offset: max(range.location, NSMaxRange(range) - 1))
    else { return }
    for file in Set(fullModel.document.rows[first...last].map { Int($0.fileIndex) }) { expandFile(file) }
    guard let visible = visibleRange(fromFull: range) else { return }
    setSelectedRange(visible)
    scrollRangeToVisible(visible)
  }

  private func color(for kind: PullRequestDiffSyntaxHighlighter.Kind) -> NSColor {
    switch kind {
    case .keyword: palette.color(5)
    case .string: palette.color(1)
    case .comment: palette.muted
    case .number, .literal: palette.color(3)
    case .type, .tag: palette.color(6)
    case .function: palette.color(4)
    case .property, .attribute: palette.color(3)
    }
  }

  func background(for kind: PullRequestDiffRow.Kind) -> NSColor? {
    switch kind {
    case .addition: palette.color(2).withAlphaComponent(0.13)
    case .deletion: palette.color(1).withAlphaComponent(0.13)
    case .hunkHeader: palette.color(4).withAlphaComponent(0.08)
    case .fileHeader: palette.background
    default: nil
    }
  }

  override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    enumerateVisibleLines(in: rect) { model, row, lineRect in
      guard let color = self.background(for: model.document.rows[row].kind) else { return }
      color.setFill()
      NSRect(x: rect.minX, y: lineRect.minY, width: rect.width, height: lineRect.height).fill()
    }
  }

  func enumerateVisibleLines(in rect: NSRect, _ body: @escaping (PullRequestDiffTextDocument, Int, NSRect) -> Void) {
    guard let model, let layout = layoutManager, let container = textContainer else { return }
    let origin = textContainerOrigin
    let glyphs = layout.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
    layout.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, glyphRange, _ in
      let offset = layout.characterIndexForGlyph(at: glyphRange.location)
      guard let row = model.row(atUTF16Offset: offset) else { return }
      body(model, row, lineRect.offsetBy(dx: origin.x, dy: origin.y))
    }
  }
}

/// The line numbers and diff markers remain pinned while scrolling sideways.
final class PullRequestDiffRulerView: NSRulerView {
  nonisolated deinit {}

  override var isFlipped: Bool { true }

  func updateThickness() {
    guard let textView = clientView as? PullRequestDiffNSTextView,
      let font = textView.font, let model = textView.model
    else { return }
    let digits = max(3, String(model.document.maxLineNumber).count)
    let width = ("0" as NSString).size(withAttributes: [.font: font]).width
    ruleThickness = CGFloat(digits * 2 + 5) * width
    needsDisplay = true
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView = clientView as? PullRequestDiffNSTextView, let font = textView.font else { return }
    textView.palette.background.setFill()
    bounds.fill()
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textView.palette.muted]
    let numberWidth = (ruleThickness - 24) / 2
    textView.enumerateVisibleLines(in: textView.visibleRect) { model, index, lineRect in
      let row = model.document.rows[index]
      let rulerRect = self.convert(lineRect, from: textView)
      if let background = textView.background(for: row.kind) {
        background.setFill()
        NSRect(x: 0, y: rulerRect.minY, width: self.bounds.width, height: rulerRect.height).fill()
      }
      if row.oldLine > 0 { self.drawNumber(row.oldLine, right: numberWidth, y: rulerRect.minY, attributes: attributes) }
      if row.newLine > 0 {
        self.drawNumber(row.newLine, right: numberWidth * 2 + 8, y: rulerRect.minY, attributes: attributes)
      }
      if row.kind == .addition || row.kind == .deletion {
        let marker = row.kind == .addition ? "+" : "−"
        (marker as NSString).draw(
          at: NSPoint(x: self.ruleThickness - 12, y: rulerRect.minY),
          withAttributes: [
            .font: font,
            .foregroundColor: row.kind == .addition ? textView.palette.color(2) : textView.palette.color(1),
          ])
      }
    }
    textView.palette.separator.setFill()
    NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
  }

  private func drawNumber(_ number: Int32, right: CGFloat, y: CGFloat, attributes: [NSAttributedString.Key: Any]) {
    let text = String(number) as NSString
    text.draw(at: NSPoint(x: right - text.size(withAttributes: attributes).width, y: y), withAttributes: attributes)
  }
}

/// Symbol, color, and label for a file status, shared by the sidebar and the
/// diff's file headers.
struct PullRequestDiffFileStatusStyle {
  let symbolName: String
  let nsColor: NSColor
  let label: String

  var color: Color { Color(nsColor: nsColor) }

  init(_ status: PullRequestDiffFile.Status) {
    switch status {
    case .added:
      self.init(symbolName: "plus.square.fill", nsColor: .systemGreen, label: "Added")
    case .deleted:
      self.init(symbolName: "minus.square.fill", nsColor: .systemRed, label: "Deleted")
    case .modified:
      self.init(symbolName: "dot.square.fill", nsColor: .systemOrange, label: "Modified")
    case .renamed:
      self.init(symbolName: "arrow.right.square.fill", nsColor: .systemBlue, label: "Renamed")
    case .copied:
      self.init(symbolName: "plus.square.on.square.fill", nsColor: .systemBlue, label: "Copied")
    }
  }

  private init(symbolName: String, nsColor: NSColor, label: String) {
    self.symbolName = symbolName
    self.nsColor = nsColor
    self.label = label
  }
}
