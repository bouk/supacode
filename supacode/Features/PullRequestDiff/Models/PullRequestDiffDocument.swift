import Foundation

/// One changed file in a pull-request diff.
nonisolated struct PullRequestDiffFile: Identifiable, Equatable, Sendable {
  enum Status: Equatable, Sendable {
    case added
    case deleted
    case modified
    case renamed
    case copied
  }

  /// Position in `PullRequestDiffDocument.files`.
  let id: Int
  /// The new path, or the old path for a deleted file.
  let path: String
  /// The previous path when the file was renamed or copied.
  let oldPath: String?
  let status: Status
  let isBinary: Bool
  let additions: Int
  let deletions: Int
  /// Index of the file's header row in `PullRequestDiffDocument.rows`.
  let headerRow: Int
  /// Lowercased UTF-8 path, precomputed so Go to File ranks without allocating.
  let searchKey: [UInt8]

  init(
    id: Int,
    path: String,
    oldPath: String?,
    status: Status,
    isBinary: Bool,
    additions: Int,
    deletions: Int,
    headerRow: Int
  ) {
    self.id = id
    self.path = path
    self.oldPath = oldPath
    self.status = status
    self.isBinary = isBinary
    self.additions = additions
    self.deletions = deletions
    self.headerRow = headerRow
    self.searchKey = Array(path.lowercased().utf8)
  }

  var name: String {
    path.split(separator: "/").last.map(String.init) ?? path
  }

  /// The parent directory, empty for a file at the repository root.
  var directory: String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
  }
}

/// One rendered line of the diff. Kept small and flat so a large diff is one
/// contiguous array the table reads by index.
nonisolated struct PullRequestDiffRow: Equatable, Sendable {
  enum Kind: UInt8, Sendable {
    case fileHeader
    case hunkHeader
    case context
    case addition
    case deletion
    /// Out-of-band text, such as "\ No newline at end of file" or "Binary file".
    case note
  }

  let kind: Kind
  let fileIndex: Int32
  /// One-based line numbers, 0 when the side has no line.
  let oldLine: Int32
  let newLine: Int32
  /// Line content without the diff marker. Slices the raw diff, so rows add no
  /// per-line string storage.
  let text: Substring
}

/// A parsed, immutable diff. A reference type so reducer state compares by
/// identity and copies stay O(1) regardless of diff size.
nonisolated final class PullRequestDiffDocument: Equatable, Sendable {
  let files: [PullRequestDiffFile]
  let rows: [PullRequestDiffRow]
  /// Widest line in display columns (tabs expanded), for the horizontal extent.
  let maxColumns: Int
  /// Largest line number on either side, for the gutter width.
  let maxLineNumber: Int
  let additions: Int
  let deletions: Int
  let generatedFileAttributes: [String: Bool]

  init(
    files: [PullRequestDiffFile],
    rows: [PullRequestDiffRow],
    maxColumns: Int,
    maxLineNumber: Int,
    generatedFileAttributes: [String: Bool] = [:]
  ) {
    self.files = files
    self.generatedFileAttributes = generatedFileAttributes
    self.rows = rows
    self.maxColumns = maxColumns
    self.maxLineNumber = maxLineNumber
    self.additions = files.reduce(0) { $0 + $1.additions }
    self.deletions = files.reduce(0) { $0 + $1.deletions }
  }

  static func == (lhs: PullRequestDiffDocument, rhs: PullRequestDiffDocument) -> Bool {
    lhs === rhs
  }

  static let tabWidth = 4
}
