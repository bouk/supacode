import Foundation

/// A native Swift lexer for read-only diff fragments. No runtime, executable,
/// grammar downloads, or HTML conversion are needed to display source text.
nonisolated enum PullRequestDiffSyntaxHighlighter {
  enum Language: Sendable {
    case typescript, javascript, rust, nix, python, html, css

    init?(path: String) {
      switch path.split(separator: ".").last?.lowercased() {
      case "ts", "tsx", "mts", "cts": self = .typescript
      case "js", "jsx", "mjs", "cjs": self = .javascript
      case "rs": self = .rust
      case "nix": self = .nix
      case "py", "pyw": self = .python
      case "html", "htm", "xhtml", "svg": self = .html
      case "css": self = .css
      default: return nil
      }
    }

    var keywords: Set<String> {
      switch self {
      case .typescript, .javascript:
        [
          "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
          "declare", "default", "delete", "do", "else", "enum", "export", "extends", "finally", "for", "from",
          "function", "get", "if", "implements", "import", "in", "infer", "instanceof", "interface", "is", "keyof",
          "let", "namespace", "new", "of", "override", "private", "protected", "public", "readonly", "return",
          "satisfies", "set", "static", "super", "switch", "this", "throw", "try", "type", "typeof", "var", "void",
          "while", "with", "yield",
        ]
      case .rust:
        [
          "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn",
          "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
          "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while",
        ]
      case .nix:
        ["assert", "else", "if", "in", "inherit", "let", "or", "rec", "then", "with"]
      case .python:
        [
          "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else",
          "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "nonlocal",
          "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
        ]
      case .html, .css: []
      }
    }
  }

  enum Kind: Equatable, Sendable {
    case keyword, string, comment, number, type, function, property, tag, attribute, literal
  }

  struct Token: Equatable, Sendable {
    let range: NSRange
    let kind: Kind
  }

  @concurrent
  static func highlight(_ text: PullRequestDiffTextDocument) async -> [Token] {
    tokens(in: text)
  }

  /// Reset at hunk boundaries: omitted lines may close an earlier lexical
  /// construct. Within a hunk, old/new sources retain independent syntax state.
  static func tokens(in text: PullRequestDiffTextDocument) -> [Token] {
    let rows = text.document.rows
    var result: [Token] = []
    var start = 0
    while start < rows.count {
      if Task.isCancelled { return [] }
      guard let language = Language(path: text.document.files[Int(rows[start].fileIndex)].path) else {
        start += 1
        continue
      }
      if rows[start].kind == .fileHeader || rows[start].kind == .hunkHeader || rows[start].kind == .note {
        start += 1
        continue
      }
      var end = start
      while end < rows.count, rows[end].fileIndex == rows[start].fileIndex,
        rows[end].kind != .fileHeader, rows[end].kind != .hunkHeader, rows[end].kind != .note
      { end += 1 }
      for oldSide in [true, false] {
        var source = ""
        var mapped: [(source: NSRange, row: Int)] = []
        var offset = 0
        for rowIndex in start..<end {
          let row = rows[rowIndex]
          if oldSide ? row.kind == .addition : row.kind == .deletion { continue }
          let length = row.text.utf16.count + 1
          mapped.append((NSRange(location: offset, length: length), rowIndex))
          source += row.text + "\n"
          offset += length
        }
        var lineIndex = 0
        for token in tokens(in: source, language: language) {
          while lineIndex < mapped.count, NSMaxRange(mapped[lineIndex].source) <= token.range.location {
            lineIndex += 1
          }
          var index = lineIndex
          while index < mapped.count, mapped[index].source.location < NSMaxRange(token.range) {
            let line = mapped[index]
            if !oldSide || rows[line.row].kind == .deletion {
              let intersection = NSIntersectionRange(token.range, line.source)
              if intersection.length > 0 {
                result.append(
                  Token(
                    range: NSRange(
                      location: text.rowRanges[line.row].location + intersection.location - line.source.location,
                      length: intersection.length), kind: token.kind))
              }
            }
            index += 1
          }
        }
      }
      start = end
    }
    return result
  }

  static func tokens(in source: String, language: Language) -> [Token] {
    var lexer = Lexer(source: source, language: language)
    return lexer.scan()
  }

  private struct Lexer {
    let units: [UInt16]
    let language: Language
    let keywords: Set<String>
    var index = 0
    var result: [Token] = []

    init(source: String, language: Language) {
      units = Array(source.utf16)
      self.language = language
      keywords = language.keywords
    }

    mutating func scan() -> [Token] {
      while index < units.count {
        if index % 4096 == 0, Task.isCancelled { return [] }
        let start = index
        if matches("<!--"), language == .html {
          consumeThrough("-->")
          emit(.comment, from: start)
        } else if language == .html, matches("<"), markup() {
          continue
        } else if language == .html {
          index += 1
        } else if matches("/*"), language != .python {
          consumeBlockComment(nested: language == .rust || language == .nix)
          emit(.comment, from: start)
        } else if matches("//"), language == .rust || language == .typescript || language == .javascript {
          consumeLine()
          emit(.comment, from: start)
        } else if matches("#"), language == .python || language == .nix {
          consumeLine()
          emit(.comment, from: start)
        } else if language == .rust, rawRustString() {
          emit(.string, from: start)
        } else if language == .nix, matches("''") {
          consumeNixString()
          emit(.string, from: start)
        } else if units[index] == 34 || units[index] == 39
          || (units[index] == 96 && (language == .javascript || language == .typescript))
        {
          if language == .rust, units[index] == 39, !isRustCharacter() {
            index += 1
          } else {
            let quote = units[index]
            let triple = language == .python && matches(String(repeating: String(UnicodeScalar(quote)!), count: 3))
            consumeString(
              delimiter: Array(repeating: quote, count: triple ? 3 : 1),
              multiline: triple || quote == 96 || language == .nix)
            emit(.string, from: start)
          }
        } else if Self.isDigit(units[index]) {
          index += 1
          while index < units.count, Self.isIdentifier(units[index]) || units[index] == 46 { index += 1 }
          emit(.number, from: start)
        } else if Self.isIdentifierStart(units[index]) {
          index += 1
          while index < units.count,
            Self.isIdentifier(units[index]) || (language == .nix && (units[index] == 45 || units[index] == 39))
          { index += 1 }
          let word = String(decoding: units[start..<index], as: UTF16.self)
          if keywords.contains(word) {
            emit(.keyword, from: start)
          } else if ["true", "false", "null", "undefined", "None", "True", "False"].contains(word) {
            emit(.literal, from: start)
          } else if [
            "string", "number", "boolean", "any", "unknown", "never", "bool", "str", "int", "float", "usize", "isize",
            "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "f32", "f64",
          ].contains(word) || (65...90).contains(units[start]) {
            emit(.type, from: start)
          } else if nextNonspace() == 40 || (language == .rust && nextNonspace() == 33) {
            emit(.function, from: start)
          } else if nextNonspace() == 58 || (language == .css && word.hasPrefix("--")) {
            emit(.property, from: start)
          }
        } else {
          index += 1
        }
      }
      return result
    }

    mutating func emit(_ kind: Kind, from start: Int) {
      result.append(Token(range: NSRange(location: start, length: index - start), kind: kind))
    }

    func matches(_ text: String) -> Bool { matches(Array(text.utf16)) }
    func matches(_ text: [UInt16]) -> Bool {
      index + text.count <= units.count && units[index..<(index + text.count)].elementsEqual(text)
    }

    mutating func consumeLine() {
      while index < units.count, units[index] != 10 { index += 1 }
    }

    mutating func consumeThrough(_ delimiter: String) {
      let end = Array(delimiter.utf16)
      index += 1
      while index < units.count, !matches(end) { index += 1 }
      index = min(index + end.count, units.count)
    }

    mutating func consumeBlockComment(nested: Bool) {
      index += 2
      var depth = 1
      while index < units.count {
        if matches("*/") {
          index += 2
          depth -= 1
          if depth == 0 { return }
        } else if nested, matches("/*") {
          depth += 1
          index += 2
        } else {
          index += 1
        }
      }
    }

    mutating func consumeString(delimiter: [UInt16], multiline: Bool) {
      index += delimiter.count
      while index < units.count {
        if matches(delimiter) {
          index += delimiter.count
          return
        }
        if units[index] == 92 {
          index = min(index + 2, units.count)
        } else if !multiline, units[index] == 10 {
          return
        } else {
          index += 1
        }
      }
    }

    mutating func consumeNixString() {
      index += 2
      while index < units.count {
        if matches("'''") || matches("''$") || matches("''\\") {
          index += 3
        } else if matches("''") {
          index += 2
          return
        } else {
          index += 1
        }
      }
    }

    mutating func rawRustString() -> Bool {
      let start = index
      if matches("br") { index += 1 }
      guard matches("r") else {
        index = start
        return false
      }
      index += 1
      let hashesStart = index
      while index < units.count, units[index] == 35 { index += 1 }
      let hashes = index - hashesStart
      guard index < units.count, units[index] == 34 else {
        index = start
        return false
      }
      let delimiter = [UInt16(34)] + Array(repeating: UInt16(35), count: hashes)
      index += 1
      while index < units.count, !matches(delimiter) { index += 1 }
      index = min(index + delimiter.count, units.count)
      return true
    }

    func isRustCharacter() -> Bool {
      guard index + 2 < units.count else { return false }
      if units[index + 1] == 92 { return true }
      // A Unicode scalar can be a surrogate pair; lifetimes have no closing quote.
      return units[index + 2] == 39 || (index + 3 < units.count && units[index + 3] == 39)
    }

    mutating func markup() -> Bool {
      let start = index
      index += 1
      if index < units.count, units[index] == 47 || units[index] == 33 || units[index] == 63 { index += 1 }
      guard index < units.count, Self.isIdentifierStart(units[index]) else {
        index = start + 1
        return false
      }
      let tagStart = index
      while index < units.count, Self.isIdentifier(units[index]) || units[index] == 45 || units[index] == 58 {
        index += 1
      }
      let tag = String(decoding: units[tagStart..<index], as: UTF16.self).lowercased()
      emit(.tag, from: start)
      while index < units.count, units[index] != 62 {
        if units[index] == 34 || units[index] == 39 {
          let quoteStart = index
          consumeString(delimiter: [units[index]], multiline: true)
          emit(.string, from: quoteStart)
        } else if Self.isIdentifierStart(units[index]) {
          let attributeStart = index
          while index < units.count, Self.isIdentifier(units[index]) || units[index] == 45 || units[index] == 58 {
            index += 1
          }
          emit(.attribute, from: attributeStart)
        } else {
          index += 1
        }
      }
      if index < units.count { index += 1 }
      if units[start + 1] != 47, tag == "script" || tag == "style" {
        let contentStart = index
        while index < units.count, !matches("</" + tag) { index += 1 }
        let content = String(decoding: units[contentStart..<index], as: UTF16.self)
        result += PullRequestDiffSyntaxHighlighter.tokens(in: content, language: tag == "style" ? .css : .javascript)
          .map {
            Token(range: NSRange(location: contentStart + $0.range.location, length: $0.range.length), kind: $0.kind)
          }
      }
      return true
    }

    func nextNonspace() -> UInt16? {
      var next = index
      while next < units.count, units[next] == 32 || units[next] == 9 { next += 1 }
      return next < units.count ? units[next] : nil
    }

    static func isDigit(_ value: UInt16) -> Bool { (48...57).contains(value) }
    static func isIdentifierStart(_ value: UInt16) -> Bool {
      (65...90).contains(value) || (97...122).contains(value) || value == 95 || value == 36 || value > 127
    }
    static func isIdentifier(_ value: UInt16) -> Bool { isIdentifierStart(value) || isDigit(value) }
  }
}
