import ComposableArchitecture
import Darwin
import Foundation
import SupacodeSettingsShared

nonisolated struct GithubAuthStatus: Equatable, Sendable {
  let username: String
  let host: String
}

nonisolated struct GithubAuthStatusResponse: Sendable {
  let hosts: [String: [GithubAuthAccount]]

  nonisolated struct GithubAuthAccount: Sendable {
    let active: Bool
    let login: String
  }
}

extension GithubAuthStatusResponse: Decodable {
  private enum CodingKeys: String, CodingKey {
    case hosts
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.hosts = try container.decode([String: [GithubAuthAccount]].self, forKey: .hosts)
  }
}

extension GithubAuthStatusResponse.GithubAuthAccount: Decodable {
  private enum CodingKeys: String, CodingKey {
    case active
    case login
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.active = try container.decode(Bool.self, forKey: .active)
    self.login = try container.decode(String.self, forKey: .login)
  }
}

// A login shell sources `.zprofile` / `.zlogin` before `gh` runs, so a banner or version-manager
// line can prepend to captured stdout and corrupt the JSON.
enum GithubCLIOutput {
  // No JSON found at all: the likely cause is shell startup output polluting stdout.
  nonisolated static let noPayloadMessage =
    "Could not read GitHub CLI output. Your shell startup files may be printing extra output to stdout."

  // Valid JSON was found but failed to decode: the likely cause is an incompatible gh version.
  nonisolated static let undecodableMessage =
    "Could not parse GitHub CLI output. The installed GitHub CLI version may be incompatible."

  nonisolated fileprivate static let logger = SupaLogger("GithubCLI")

  // Every balanced top-level JSON value ({...} or [...]) in `output`, in source order. An opener that
  // never balances (a stray brace from shell noise) is skipped, so leading noise cannot swallow a real
  // payload that follows.
  nonisolated static func balancedJSONSpans(in output: String) -> [Substring] {
    var spans: [Substring] = []
    var searchStart = output.startIndex
    while let start = output[searchStart...].firstIndex(where: { $0 == "{" || $0 == "[" }) {
      let opener = output[start]
      let closer: Character = opener == "{" ? "}" : "]"
      var depth = 0
      var inString = false
      var escaped = false
      var matchedEnd: String.Index?
      var index = start
      scan: while index < output.endIndex {
        let character = output[index]
        switch character {
        case _ where inString && escaped:
          escaped = false
        case "\\" where inString:
          escaped = true
        case "\"" where inString:
          inString = false
        case _ where inString:
          break
        case "\"":
          inString = true
        case opener:
          depth += 1
        case closer:
          depth -= 1
          guard depth == 0 else { break }
          matchedEnd = output.index(after: index)
          break scan
        default:
          break
        }
        index = output.index(after: index)
      }
      guard let end = matchedEnd else {
        // Unbalanced opener (stray bracket in noise): skip it and keep scanning.
        searchStart = output.index(after: start)
        continue
      }
      spans.append(output[start..<end])
      searchStart = end
    }
    return spans
  }

  // Decodes the JSON payload from possibly noisy gh stdout, surfacing a readable error (with the raw
  // output logged) instead of an opaque DecodingError. Throws when no payload is found at all.
  nonisolated static func decode<T: Decodable>(
    _ type: T.Type,
    from output: String,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> T {
    guard let value = try decodeIfPresent(T.self, from: output, decoder: decoder) else {
      logDecodeFailure(output)
      throw GithubCLIError.commandFailed(noPayloadMessage)
    }
    return value
  }

  // Returns nil when `output` carries no JSON payload at all (e.g. `gh run list` with no runs), and
  // throws only when a payload is present but cannot be decoded. gh prints its JSON after any leading
  // shell noise, so the last decodable span wins.
  nonisolated static func decodeIfPresent<T: Decodable>(
    _ type: T.Type,
    from output: String,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> T? {
    let spans = balancedJSONSpans(in: output)
    guard !spans.isEmpty else {
      return nil
    }
    var lastDecodingError: Error?
    var sawValidJSON = false
    for span in spans.reversed() {
      let data = Data(span.utf8)
      do {
        return try decoder.decode(T.self, from: data)
      } catch {
        lastDecodingError = error
        if (try? JSONSerialization.jsonObject(with: data)) != nil {
          sawValidJSON = true
        }
      }
    }
    let detail = lastDecodingError.map { "\($0)" } ?? "unknown"
    logger.error("Failed to decode GitHub CLI JSON output: \(snapshot(of: output)) error=\(detail)")
    // Valid JSON that failed to decode points at gh schema drift; otherwise the brackets were noise.
    throw GithubCLIError.commandFailed(sawValidJSON ? undecodableMessage : noPayloadMessage)
  }

  // Logs a length-capped snapshot of the offending output so the user can retrieve it from the log
  // stream without flooding it with a large banner.
  nonisolated static func logDecodeFailure(_ output: String) {
    logger.error("Failed to read GitHub CLI JSON output: \(snapshot(of: output))")
  }

  // Caps the logged output so a large banner does not flood the log stream.
  nonisolated private static func snapshot(of output: String) -> String {
    let limit = 500
    let prefix = output.prefix(limit)
    return prefix.endIndex == output.endIndex ? String(prefix) : "\(prefix)… (truncated)"
  }
}

enum GithubAuthStatusParsing {
  // `hosts` is an unordered dictionary, so prefer github.com and otherwise sort the keys: the result
  // is deterministic even when more than one host has an active account.
  nonisolated static func activeAccount(
    in response: GithubAuthStatusResponse
  ) -> (host: String, login: String)? {
    let orderedHosts = response.hosts.keys.sorted { lhs, rhs in
      if lhs == "github.com" { return true }
      if rhs == "github.com" { return false }
      return lhs < rhs
    }
    for host in orderedHosts {
      if let active = response.hosts[host]?.first(where: { $0.active }) {
        return (host, active.login)
      }
    }
    return nil
  }
}
