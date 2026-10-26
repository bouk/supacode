import Foundation
import Testing

@testable import supacode

@MainActor
struct PullRequestDiffParserTests {
  private static func lines(_ lines: String...) -> String {
    lines.joined(separator: "\n") + "\n"
  }

  @Test func emptyDiffHasNoFiles() {
    let document = PullRequestDiffParser.parse("")
    #expect(document.files.isEmpty)
    #expect(document.rows.isEmpty)
  }

  @Test func modifiedFileTracksLineNumbersAndCounts() {
    let document = PullRequestDiffParser.parse(
      Self.lines(
        "diff --git a/Sources/App.swift b/Sources/App.swift",
        "index 1111111..2222222 100644",
        "--- a/Sources/App.swift",
        "+++ b/Sources/App.swift",
        "@@ -10,3 +10,4 @@ struct App {",
        " let a = 1",
        "-let b = 2",
        "+let b = 3",
        "+let c = 4",
        " let d = 5"
      )
    )
    #expect(document.files.count == 1)
    let file = document.files[0]
    #expect(file.path == "Sources/App.swift")
    #expect(file.name == "App.swift")
    #expect(file.directory == "Sources")
    #expect(file.status == .modified)
    #expect(file.additions == 2)
    #expect(file.deletions == 1)
    #expect(file.headerRow == 0)
    #expect(
      document.rows.map(\.kind) == [.fileHeader, .hunkHeader, .context, .deletion, .addition, .addition, .context]
    )
    #expect(document.rows[2].oldLine == 10)
    #expect(document.rows[2].newLine == 10)
    #expect(document.rows[2].text == "let a = 1")
    #expect(document.rows[3].oldLine == 11)
    #expect(document.rows[3].newLine == 0)
    #expect(document.rows[4].oldLine == 0)
    #expect(document.rows[4].newLine == 11)
    #expect(document.rows[5].newLine == 12)
    #expect(document.rows[6].oldLine == 12)
    #expect(document.rows[6].newLine == 13)
    #expect(document.maxLineNumber == 13)
    #expect(document.additions == 2)
    #expect(document.deletions == 1)
  }

  @Test func multipleFilesAndHunks() {
    let document = PullRequestDiffParser.parse(
      Self.lines(
        "diff --git a/a.txt b/a.txt",
        "--- a/a.txt",
        "+++ b/a.txt",
        "@@ -1 +1 @@",
        "-old",
        "+new",
        "@@ -20,2 +20,2 @@",
        " same",
        "-x",
        "+y",
        "diff --git a/b.txt b/b.txt",
        "--- a/b.txt",
        "+++ b/b.txt",
        "@@ -5,1 +5,2 @@",
        " five",
        "+six"
      )
    )
    #expect(document.files.map(\.path) == ["a.txt", "b.txt"])
    #expect(document.files[1].headerRow == 8)
    #expect(document.rows[8].kind == .fileHeader)
    #expect(document.rows[8].fileIndex == 1)
    #expect(document.rows[6].oldLine == 21)
    #expect(document.rows[7].newLine == 21)
    #expect(document.files[1].additions == 1)
  }

  @Test func addedAndDeletedFiles() {
    let document = PullRequestDiffParser.parse(
      Self.lines(
        "diff --git a/new.txt b/new.txt",
        "new file mode 100644",
        "index 0000000..1111111",
        "--- /dev/null",
        "+++ b/new.txt",
        "@@ -0,0 +1,2 @@",
        "+one",
        "+two",
        "diff --git a/old.txt b/old.txt",
        "deleted file mode 100644",
        "--- a/old.txt",
        "+++ /dev/null",
        "@@ -1 +0,0 @@",
        "-gone"
      )
    )
    #expect(document.files[0].status == .added)
    #expect(document.files[0].path == "new.txt")
    #expect(document.files[0].oldPath == nil)
    #expect(document.files[1].status == .deleted)
    #expect(document.files[1].path == "old.txt")
    #expect(document.files[1].deletions == 1)
  }

  @Test func pureRenameGetsNote() {
    let document = PullRequestDiffParser.parse(
      Self.lines(
        "diff --git a/old name.txt b/new name.txt",
        "similarity index 100%",
        "rename from old name.txt",
        "rename to new name.txt"
      )
    )
    let file = document.files[0]
    #expect(file.status == .renamed)
    #expect(file.path == "new name.txt")
    #expect(file.oldPath == "old name.txt")
    #expect(document.rows.map(\.kind) == [.fileHeader, .note])
    #expect(document.rows[1].text == "File renamed without changes")
  }

  @Test func binaryFile() {
    let document = PullRequestDiffParser.parse(
      Self.lines(
        "diff --git a/logo.png b/logo.png",
        "index 1111111..2222222 100644",
        "Binary files a/logo.png and b/logo.png differ"
      )
    )
    #expect(document.files[0].isBinary)
    #expect(document.rows.map(\.kind) == [.fileHeader, .note])
  }

  @Test func noNewlineMarkerIsANote() {
    let document = PullRequestDiffParser.parse(
      Self.lines(
        "diff --git a/a b/a",
        "--- a/a",
        "+++ b/a",
        "@@ -1 +1 @@",
        "-x",
        "\\ No newline at end of file",
        "+y"
      )
    )
    #expect(document.rows.map(\.kind) == [.fileHeader, .hunkHeader, .deletion, .note, .addition])
    #expect(document.rows[3].text == "No newline at end of file")
    #expect(document.rows[4].newLine == 1)
  }

  @Test func hunkLinesThatLookLikeHeaders() {
    // A removed "-- x" line reads "--- x"; inside a hunk it is content.
    let document = PullRequestDiffParser.parse(
      Self.lines(
        "diff --git a/a.sql b/a.sql",
        "--- a/a.sql",
        "+++ b/a.sql",
        "@@ -1,2 +1,2 @@",
        "--- comment",
        "+++ comment",
        " select 1"
      )
    )
    #expect(document.rows.map(\.kind) == [.fileHeader, .hunkHeader, .deletion, .addition, .context])
    #expect(document.rows[2].text == "-- comment")
    #expect(document.files[0].additions == 1)
    #expect(document.files[0].deletions == 1)
  }

  @Test func crlfLinesAreTrimmed() {
    let diff = "diff --git a/a b/a\r\n--- a/a\r\n+++ b/a\r\n@@ -1 +1 @@\r\n-x\r\n+y\r\n"
    let document = PullRequestDiffParser.parse(diff)
    #expect(document.rows.map(\.text) == ["", "@@ -1 +1 @@", "x", "y"])
  }

  @Test func quotedPathsAreDecoded() {
    let document = PullRequestDiffParser.parse(
      Self.lines(
        #"diff --git "a/caf\303\251.txt" "b/caf\303\251.txt""#,
        #"--- "a/caf\303\251.txt""#,
        #"+++ "b/caf\303\251.txt""#,
        "@@ -1 +1 @@",
        "-a",
        "+b"
      )
    )
    #expect(document.files[0].path == "café.txt")
  }

  @Test func gitHeaderPathsWithSpaces() {
    let (old, new) = PullRequestDiffParser.gitHeaderPaths("a/my file.txt b/my file.txt")
    #expect(old == "my file.txt")
    #expect(new == "my file.txt")
  }

  @Test func plainUnifiedDiffWithoutGitHeader() {
    let document = PullRequestDiffParser.parse(
      Self.lines(
        "--- a/x.txt\t2026-01-01",
        "+++ b/x.txt\t2026-01-02",
        "@@ -1 +1 @@",
        "-a",
        "+b"
      )
    )
    #expect(document.files.map(\.path) == ["x.txt"])
    #expect(document.files[0].additions == 1)
  }

  @Test func hunkStartsParsesBothSides() {
    #expect(PullRequestDiffParser.hunkStarts("@@ -12,7 +34,9 @@ func x() {") == (12, 34))
    #expect(PullRequestDiffParser.hunkStarts("@@ -1 +1 @@") == (1, 1))
    #expect(PullRequestDiffParser.hunkStarts("@@ -0,0 +1,3 @@") == (0, 1))
  }

  @Test func displayColumnsExpandTabsAndCountScalars() {
    #expect(PullRequestDiffParser.displayColumns("abc") == 3)
    #expect(PullRequestDiffParser.displayColumns("\tx") == PullRequestDiffDocument.tabWidth + 1)
    #expect(PullRequestDiffParser.displayColumns("ab\tx") == PullRequestDiffDocument.tabWidth + 1)
    #expect(PullRequestDiffParser.displayColumns("café") == 4)
  }
}
