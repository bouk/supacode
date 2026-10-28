import Dependencies
import Foundation

/// The single transport seam for GitHub REST and GraphQL, including remote repositories.
nonisolated struct GithubHTTPClient: Sendable {
  var data: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  static func redirectedRequest(_ request: URLRequest, from original: URL?) -> URLRequest? {
    guard request.url?.scheme == "https" else { return nil }
    var request = request
    if request.url?.host != original?.host || request.url?.port != original?.port {
      request.setValue(nil, forHTTPHeaderField: "Authorization")
    }
    return request
  }
}

nonisolated extension GithubHTTPClient: DependencyKey {
  static let liveValue = Self { request in
    let (data, response) = try await GithubHTTPSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (data, response)
  }
  static let testValue = Self { _ in throw URLError(.unsupportedURL) }
}

private nonisolated enum GithubHTTPSession {
  static let shared: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(configuration: configuration, delegate: RedirectDelegate(), delegateQueue: nil)
  }()

  /// Job logs redirect to short-lived storage URLs. Never send the GitHub token there.
  private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(GithubHTTPClient.redirectedRequest(request, from: task.originalRequest?.url))
    }
  }
}
