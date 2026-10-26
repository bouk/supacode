import Foundation
import Testing

@testable import supacode

@MainActor
struct PullRequestDiffFileMatcherTests {
  private static func files(_ paths: String...) -> [PullRequestDiffFile] {
    paths.enumerated().map { index, path in
      PullRequestDiffFile(
        id: index,
        path: path,
        oldPath: nil,
        status: .modified,
        isBinary: false,
        additions: 0,
        deletions: 0,
        headerRow: index
      )
    }
  }

  @Test func emptyQueryKeepsDiffOrder() {
    let files = Self.files("b.swift", "a.swift", "c.swift")
    #expect(PullRequestDiffFileMatcher.rank(files, query: "  ") == [0, 1, 2])
  }

  @Test func fileNameMatchBeatsDirectoryMatch() {
    let files = Self.files("reducer/Other.swift", "views/Reducer.swift")
    #expect(PullRequestDiffFileMatcher.rank(files, query: "reducer") == [1, 0])
  }

  @Test func nameprefixBeatsNameSubstring() {
    let files = Self.files("a/AppFeatureTests.swift", "a/FeatureTests.swift")
    #expect(PullRequestDiffFileMatcher.rank(files, query: "feature").first == 1)
  }

  @Test func scatteredMatchIsFoundAndCaseInsensitive() {
    let files = Self.files("Sources/PullRequestDiffView.swift", "README.md")
    #expect(PullRequestDiffFileMatcher.rank(files, query: "PRDV") == [0])
  }

  @Test func nonMatchingFilesAreDropped() {
    let files = Self.files("a.swift", "b.swift")
    #expect(PullRequestDiffFileMatcher.rank(files, query: "zzz").isEmpty)
  }

  @Test func everyQueryWordMustMatch() {
    let files = Self.files("views/Sidebar.swift", "reducer/Sidebar.swift")
    #expect(PullRequestDiffFileMatcher.rank(files, query: "sidebar reducer") == [1])
  }
}
