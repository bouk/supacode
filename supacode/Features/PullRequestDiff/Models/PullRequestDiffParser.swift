import Foundation

/// Parses `git diff`-format unified diffs (the output of `gh pr diff` and
/// `glab mr diff`) into a flat row list. Works on UTF-8 bytes and slices the
/// input instead of copying lines, so multi-megabyte diffs parse quickly.
nonisolated enum PullRequestDiffParser {
  /// Parses off the caller's actor; a large diff must never parse on main.
  @concurrent
  static func parseInBackground(_ diff: String) async -> PullRequestDiffDocument {
    parse(diff)
  }

  static func parse(_ diff: String) -> PullRequestDiffDocument {
    var diff = diff
    diff.makeContiguousUTF8()
    var builder = Builder()
    let utf8 = diff.utf8
    var lineStart = utf8.startIndex
    while lineStart < utf8.endIndex {
      let lineEnd = utf8[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? utf8.endIndex
      var contentEnd = lineEnd
      if contentEnd > lineStart, utf8[utf8.index(before: contentEnd)] == UInt8(ascii: "\r") {
        contentEnd = utf8.index(before: contentEnd)
      }
      builder.consume(diff[lineStart..<contentEnd])
      lineStart = lineEnd == utf8.endIndex ? lineEnd : utf8.index(after: lineEnd)
    }
    return builder.finish()
  }

  private enum Section {
    /// Before the first file.
    case preamble
    /// Extended header lines between `diff --git` and the first hunk.
    case header
    case hunk
  }

  private struct PendingFile {
    var oldPath: String?
    var newPath: String?
    var status: PullRequestDiffFile.Status = .modified
    var isBinary = false
    var additions = 0
    var deletions = 0
    let headerRow: Int
  }

  private struct Builder {
    var files: [PullRequestDiffFile] = []
    var rows: [PullRequestDiffRow] = []
    var section = Section.preamble
    var pending: PendingFile?
    var oldLine: Int32 = 0
    var newLine: Int32 = 0
    var maxColumns = 0
    var maxLineNumber: Int32 = 0

    var fileIndex: Int32 { Int32(files.count) }

    mutating func consume(_ line: Substring) {
      if line.hasPrefix("diff --git ") {
        startFile()
        let (oldPath, newPath) = PullRequestDiffParser.gitHeaderPaths(line.dropFirst("diff --git ".count))
        pending?.oldPath = oldPath
        pending?.newPath = newPath
        return
      }
      switch section {
      case .preamble:
        // A plain unified diff without `diff --git` headers.
        if line.hasPrefix("--- ") {
          startFile()
          consumeHeader(line)
        }
      case .header:
        consumeHeader(line)
      case .hunk:
        consumeHunk(line)
      }
    }

    private mutating func consumeHeader(_ line: Substring) {
      if line.hasPrefix("@@") {
        startHunk(line)
      } else if line.hasPrefix("--- ") {
        let path = PullRequestDiffParser.markerPath(line.dropFirst(4), prefix: "a/")
        pending?.oldPath = path
        if path == nil { pending?.status = .added }
      } else if line.hasPrefix("+++ ") {
        let path = PullRequestDiffParser.markerPath(line.dropFirst(4), prefix: "b/")
        pending?.newPath = path
        if path == nil { pending?.status = .deleted }
      } else if line.hasPrefix("new file mode") {
        pending?.status = .added
      } else if line.hasPrefix("deleted file mode") {
        pending?.status = .deleted
      } else if line.hasPrefix("rename from ") {
        pending?.status = .renamed
        pending?.oldPath = PullRequestDiffParser.unquote(line.dropFirst("rename from ".count))
      } else if line.hasPrefix("rename to ") {
        pending?.status = .renamed
        pending?.newPath = PullRequestDiffParser.unquote(line.dropFirst("rename to ".count))
      } else if line.hasPrefix("copy from ") {
        pending?.status = .copied
        pending?.oldPath = PullRequestDiffParser.unquote(line.dropFirst("copy from ".count))
      } else if line.hasPrefix("copy to ") {
        pending?.status = .copied
        pending?.newPath = PullRequestDiffParser.unquote(line.dropFirst("copy to ".count))
      } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
        guard pending?.isBinary == false else { return }
        pending?.isBinary = true
        appendRow(.note, text: "Binary file not shown")
      }
    }

    private mutating func consumeHunk(_ line: Substring) {
      guard let marker = line.utf8.first else {
        // Some tools strip the space marker from blank context lines.
        appendRow(.context, text: line, old: oldLine, new: newLine)
        oldLine += 1
        newLine += 1
        return
      }
      let text = line.dropFirst()
      switch marker {
      case UInt8(ascii: " "):
        appendRow(.context, text: text, old: oldLine, new: newLine)
        oldLine += 1
        newLine += 1
      case UInt8(ascii: "+"):
        appendRow(.addition, text: text, new: newLine)
        newLine += 1
        pending?.additions += 1
      case UInt8(ascii: "-"):
        appendRow(.deletion, text: text, old: oldLine)
        oldLine += 1
        pending?.deletions += 1
      case UInt8(ascii: "@"):
        if line.hasPrefix("@@") { startHunk(line) }
      case UInt8(ascii: "\\"):
        appendRow(.note, text: text.drop { $0 == " " })
      default:
        // Anything else ends the hunk; a following plain-diff header starts a file.
        section = .preamble
        consume(line)
      }
    }

    private mutating func startFile() {
      finishFile()
      pending = PendingFile(headerRow: rows.count)
      rows.append(PullRequestDiffRow(kind: .fileHeader, fileIndex: fileIndex, oldLine: 0, newLine: 0, text: ""))
      section = .header
    }

    private mutating func startHunk(_ line: Substring) {
      let (old, new) = PullRequestDiffParser.hunkStarts(line)
      oldLine = old
      newLine = new
      appendRow(.hunkHeader, text: line)
      section = .hunk
    }

    private mutating func appendRow(
      _ kind: PullRequestDiffRow.Kind,
      text: Substring,
      old: Int32 = 0,
      new: Int32 = 0
    ) {
      guard pending != nil else { return }
      maxColumns = max(maxColumns, PullRequestDiffParser.displayColumns(text))
      maxLineNumber = max(maxLineNumber, old, new)
      rows.append(PullRequestDiffRow(kind: kind, fileIndex: fileIndex, oldLine: old, newLine: new, text: text))
    }

    private mutating func finishFile() {
      guard let file = pending else { return }
      if rows.count == file.headerRow + 1 {
        let note: Substring =
          switch file.status {
          case .renamed: "File renamed without changes"
          case .copied: "File copied without changes"
          default: "No content changes"
          }
        appendRow(.note, text: note)
      }
      let path = file.newPath ?? file.oldPath ?? "Unknown file"
      let showsOldPath = (file.status == .renamed || file.status == .copied) && file.oldPath != path
      files.append(
        PullRequestDiffFile(
          id: files.count,
          path: path,
          oldPath: showsOldPath ? file.oldPath : nil,
          status: file.status,
          isBinary: file.isBinary,
          additions: file.additions,
          deletions: file.deletions,
          headerRow: file.headerRow
        )
      )
      pending = nil
    }

    mutating func finish() -> PullRequestDiffDocument {
      finishFile()
      return PullRequestDiffDocument(
        files: files,
        rows: rows,
        maxColumns: maxColumns,
        maxLineNumber: Int(maxLineNumber)
      )
    }
  }

  // MARK: - Line helpers

  /// Old and new start lines from `@@ -a,b +c,d @@`.
  static func hunkStarts(_ line: Substring) -> (old: Int32, new: Int32) {
    var old: Int32 = 0
    var new: Int32 = 0
    // 0 reads digits into `old`, 1 into `new`, nil ignores them.
    var slot: Int?
    var sawOld = false
    for byte in line.utf8.dropFirst(2) {
      switch byte {
      case UInt8(ascii: "@") where sawOld:
        return (old, new)
      case UInt8(ascii: "-") where !sawOld:
        slot = 0
        sawOld = true
      case UInt8(ascii: "+") where sawOld:
        slot = 1
      case UInt8(ascii: "0")...UInt8(ascii: "9"):
        let digit = Int32(byte - UInt8(ascii: "0"))
        if slot == 0 { old = old &* 10 &+ digit }
        if slot == 1 { new = new &* 10 &+ digit }
      default:
        slot = nil
      }
    }
    return (old, new)
  }

  /// Display width with tabs expanded and multi-byte scalars counted once.
  static func displayColumns(_ text: Substring) -> Int {
    var columns = 0
    for byte in text.utf8 {
      if byte == UInt8(ascii: "\t") {
        columns += PullRequestDiffDocument.tabWidth - columns % PullRequestDiffDocument.tabWidth
      } else if byte & 0xC0 != 0x80 {
        columns += 1
      }
    }
    return columns
  }

  /// The path from a `---`/`+++` line, nil for `/dev/null`.
  static func markerPath(_ value: Substring, prefix: String) -> String? {
    var value = value
    // Plain diffs may append a tab and a timestamp.
    if !value.hasPrefix("\""), let tab = value.firstIndex(of: "\t") {
      value = value[..<tab]
    }
    let path = unquote(value)
    if path == "/dev/null" { return nil }
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
  }

  /// Paths from the `a/<old> b/<new>` tail of a `diff --git` line. Ambiguous
  /// when unquoted paths contain " b/"; equal paths, the common case, resolve
  /// exactly, and the `---`/`+++` lines override this guess when present.
  static func gitHeaderPaths(_ rest: Substring) -> (String?, String?) {
    if rest.hasPrefix("\"") {
      guard let (old, remainder) = quotedToken(rest) else { return (nil, nil) }
      let new = remainder.drop { $0 == " " }
      return (strip(old, prefix: "a/"), strip(unquote(new), prefix: "b/"))
    }
    let count = rest.utf8.count
    if count >= 5, (count - 5) % 2 == 0 {
      let length = (count - 5) / 2
      let utf8 = rest.utf8
      let oldStart = utf8.index(utf8.startIndex, offsetBy: 2)
      let oldEnd = utf8.index(oldStart, offsetBy: length)
      let newStart = utf8.index(oldEnd, offsetBy: 3)
      if rest[rest.startIndex..<oldStart] == "a/", rest[oldEnd..<newStart] == " b/",
        rest[oldStart..<oldEnd] == rest[newStart...]
      {
        let path = String(rest[oldStart..<oldEnd])
        return (path, path)
      }
    }
    guard let separator = rest.range(of: " b/") else { return (nil, nil) }
    return (
      strip(String(rest[..<separator.lowerBound]), prefix: "a/"),
      String(rest[separator.upperBound...])
    )
  }

  private static func strip(_ path: String, prefix: String) -> String {
    path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
  }

  /// Decodes git's C-style quoting (`"a/caf\303\251"`); unquoted input passes through.
  static func unquote(_ value: Substring) -> String {
    guard value.hasPrefix("\"") else { return String(value) }
    return quotedToken(value)?.token ?? String(value)
  }

  private static func quotedToken(_ value: Substring) -> (token: String, remainder: Substring)? {
    var bytes: [UInt8] = []
    let utf8 = value.utf8
    var index = utf8.index(after: utf8.startIndex)
    while index < utf8.endIndex {
      let byte = utf8[index]
      if byte == UInt8(ascii: "\"") {
        guard let token = String(bytes: bytes, encoding: .utf8) else { return nil }
        return (token, value[utf8.index(after: index)...])
      }
      guard byte == UInt8(ascii: "\\") else {
        bytes.append(byte)
        index = utf8.index(after: index)
        continue
      }
      index = utf8.index(after: index)
      guard index < utf8.endIndex else { break }
      let escaped = utf8[index]
      switch escaped {
      case UInt8(ascii: "n"): bytes.append(UInt8(ascii: "\n"))
      case UInt8(ascii: "t"): bytes.append(UInt8(ascii: "\t"))
      case UInt8(ascii: "0")...UInt8(ascii: "7"):
        var octal = 0
        var digits = 0
        while digits < 3, index < utf8.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(utf8[index]) {
          octal = octal * 8 + Int(utf8[index] - UInt8(ascii: "0"))
          index = utf8.index(after: index)
          digits += 1
        }
        bytes.append(UInt8(truncatingIfNeeded: octal))
        continue
      default: bytes.append(escaped)
      }
      index = utf8.index(after: index)
    }
    return nil
  }
}
