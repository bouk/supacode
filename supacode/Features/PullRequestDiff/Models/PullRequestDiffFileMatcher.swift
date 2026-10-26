import Foundation

/// Ranks diff files for the Go to File panel, Open Quickly style: a hit on the
/// file name beats a hit on the directory, a contiguous hit beats a scattered
/// one, and matches on word boundaries rank higher.
nonisolated enum PullRequestDiffFileMatcher {
  private struct Match {
    let id: Int
    let score: Int
    let length: Int
  }

  /// Matching file ids, best first. An empty query keeps diff order.
  static func rank(_ files: [PullRequestDiffFile], query: String) -> [Int] {
    let pieces = query.lowercased().split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
    guard !pieces.isEmpty else { return files.map(\.id) }
    var scored: [Match] = []
    scored.reserveCapacity(files.count)
    for file in files {
      let path = file.searchKey
      let nameStart = (path.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
      var total = 0
      var matched = true
      for piece in pieces {
        guard let score = score(piece, path: path, nameStart: nameStart) else {
          matched = false
          break
        }
        total += score
      }
      if matched {
        scored.append(Match(id: file.id, score: total, length: path.count))
      }
    }
    scored.sort { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      if lhs.length != rhs.length { return lhs.length < rhs.length }
      return lhs.id < rhs.id
    }
    return scored.map(\.id)
  }

  /// Nil when `query` is not a subsequence of `path`.
  static func score(_ query: [UInt8], path: [UInt8], nameStart: Int) -> Int? {
    guard !query.isEmpty else { return 0 }
    // Most files miss; reject them with one linear scan before any ranking.
    var matchedCount = 0
    for byte in path where byte == query[matchedCount] {
      matchedCount += 1
      if matchedCount == query.count { break }
    }
    guard matchedCount == query.count else { return nil }
    let nameLength = path.count - nameStart
    if let start = firstIndex(of: query, in: path, from: nameStart) {
      // Name prefix, then any contiguous name hit.
      return start == nameStart ? 10_000 - nameLength : 8_000 - nameLength
    }
    if let start = firstIndex(of: query, in: path, from: 0) {
      return 6_000 + (isBoundary(path, start) ? 500 : 0) - path.count
    }
    // Scattered: prefer matching the name from the back, then fall back to the path.
    var score = 0
    var queryIndex = query.count - 1
    var previous: Int?
    var index = path.count - 1
    while index >= 0, queryIndex >= 0 {
      if path[index] == query[queryIndex] {
        score += index >= nameStart ? 30 : 10
        if isBoundary(path, index) { score += 20 }
        if let previous, previous == index + 1 { score += 15 }
        previous = index
        queryIndex -= 1
      }
      index -= 1
    }
    return min(score, 5_000)
  }

  private static func firstIndex(of query: [UInt8], in path: [UInt8], from start: Int) -> Int? {
    guard path.count - start >= query.count else { return nil }
    let first = query[0]
    for index in start...(path.count - query.count) where path[index] == first {
      var offset = 1
      while offset < query.count, path[index + offset] == query[offset] {
        offset += 1
      }
      if offset == query.count { return index }
    }
    return nil
  }

  private static func isBoundary(_ path: [UInt8], _ index: Int) -> Bool {
    guard index > 0 else { return true }
    switch path[index - 1] {
    case UInt8(ascii: "/"), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: " "):
      return true
    default:
      return false
    }
  }
}
