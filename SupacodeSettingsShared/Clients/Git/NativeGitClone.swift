import CLibgit2
import Foundation

nonisolated extension NativeGitRepository {
  private final class CloneContext {
    let cancelled: @Sendable () -> Bool
    let progress: @Sendable (String) -> Void
    var credentials: GitFetchCredentials.Context?
    init(cancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (String) -> Void) {
      self.cancelled = cancelled
      self.progress = progress
    }
  }

  public static func clone(
    url: String, destination: URL, branch: String?, depth: Int?,
    cancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (String) -> Void
  ) throws {
    if cancelled() { throw CancellationError() }
    try NativeGitFilters.ensureInstalled()
    try GitFilterProcess.withSession {
      guard git_libgit2_init() >= 0 else { throw failure() }
      defer { git_libgit2_shutdown() }
      let context = CloneContext(cancelled: cancelled, progress: progress)
      let payload = Unmanaged.passUnretained(context).toOpaque()
      var options = git_clone_options()
      guard git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION)) == 0 else { throw failure() }
      options.repository_cb_payload = payload
      options.repository_cb = { output, path, bare, payload in
        guard let output, let path, let payload else { return GIT_ERROR.rawValue }
        let result = git_repository_init(output, path, UInt32(bare))
        if result == 0, let repository = output.pointee {
          if let override = ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"], !override.isEmpty {
            var config: OpaquePointer?
            let configResult = git_repository_config(&config, repository)
            guard configResult == 0, let config else { return configResult }
            defer { git_config_free(config) }
            let addResult = git_config_add_file_ondisk(config, override, GIT_CONFIG_LEVEL_GLOBAL, repository, 1)
            guard addResult == 0 else { return addResult }
            var localLevel = GIT_CONFIG_LEVEL_LOCAL
            let orderResult = git_config_set_writeorder(config, &localLevel, 1)
            guard orderResult == 0 else { return orderResult }
          }
          Unmanaged<CloneContext>.fromOpaque(payload).takeUnretainedValue().credentials =
            GitFetchCredentials.Context(repository: repository)
        }
        return result
      }
      options.fetch_opts.callbacks.payload = payload
      options.fetch_opts.callbacks.credentials = { output, url, username, allowed, payload in
        guard let payload, let credentials = Unmanaged<CloneContext>.fromOpaque(payload).takeUnretainedValue().credentials
        else { return GIT_PASSTHROUGH.rawValue }
        return GitFetchCredentials.callback(output, url, username, allowed, Unmanaged.passUnretained(credentials).toOpaque())
      }
      options.fetch_opts.callbacks.transfer_progress = { stats, payload in
        guard let payload else { return GIT_ERROR.rawValue }
        let context = Unmanaged<CloneContext>.fromOpaque(payload).takeUnretainedValue()
        if context.cancelled() { return GIT_EUSER.rawValue }
        if let stats, stats.pointee.total_objects > 0 {
          context.progress("Receiving objects: \(stats.pointee.received_objects)/\(stats.pointee.total_objects)")
        }
        return 0
      }
      options.checkout_opts.progress_payload = payload
      options.checkout_opts.progress_cb = { _, completed, total, payload in
        guard let payload, total > 0 else { return }
        Unmanaged<CloneContext>.fromOpaque(payload).takeUnretainedValue().progress("Checking out files: \(completed)/\(total)")
      }
      options.checkout_opts.notify_payload = payload
      options.checkout_opts.notify_flags = UInt32(GIT_CHECKOUT_NOTIFY_ALL.rawValue)
      options.checkout_opts.notify_cb = { _, _, _, _, _, payload in
        guard let payload else { return GIT_ERROR.rawValue }
        return Unmanaged<CloneContext>.fromOpaque(payload).takeUnretainedValue().cancelled() ? GIT_EUSER.rawValue : 0
      }
      if let depth, depth > 0 { options.fetch_opts.depth = Int32(clamping: depth) }
      var repository: OpaquePointer?
      let perform: (UnsafePointer<CChar>?) -> Int32 = { branchPointer in
        options.checkout_branch = branchPointer
        return git_clone(&repository, url, destination.path(percentEncoded: false), &options)
      }
      let result = branch.flatMap { $0.isEmpty ? nil : $0 }.map { $0.withCString(perform) } ?? perform(nil)
      if let credentials = context.credentials { GitFetchCredentials.finish(credentials, success: result == 0) }
      if let repository { git_repository_free(repository) }
      guard result == 0 else { throw failure() }
    }
  }
}
