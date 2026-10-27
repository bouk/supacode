import CLibgit2
import Foundation

/// Fetch a configured remote with its fetch refspecs and credential helpers.
nonisolated enum GitNativeFetch {
  static func fetch(repository: OpaquePointer, name: String) -> Int32 {
    var remote: OpaquePointer?
    let lookup = git_remote_lookup(&remote, repository, name)
    guard lookup == 0, let remote else { return lookup }
    defer { git_remote_free(remote) }
    var config: OpaquePointer?
    let configResult = git_repository_config_snapshot(&config, repository)
    guard configResult == 0, let config else { return configResult }
    defer { git_config_free(config) }
    var iterator: OpaquePointer?
    let iteratorResult = git_config_multivar_iterator_new(&iterator, config, "remote.\(name).url", nil)
    guard iteratorResult == 0, let iterator else { return iteratorResult }
    defer { git_config_iterator_free(iterator) }
    var entry: UnsafeMutablePointer<git_config_entry>?
    let entryResult = git_config_next(&entry, iterator)
    guard entryResult == 0 else { return entryResult }
    guard let url = entry?.pointee.value else { return GIT_ERROR.rawValue }
    var rewritten: OpaquePointer?
    let rewriteResult = git_remote_create_anonymous(&rewritten, repository, url)
    guard rewriteResult == 0, let rewritten else { return rewriteResult }
    defer { git_remote_free(rewritten) }
    guard let fetchURL = git_remote_url(rewritten) else { return GIT_ERROR.rawValue }
    let urlResult = git_remote_set_instance_url(remote, fetchURL)
    guard urlResult == 0 else { return urlResult }
    var options = git_fetch_options()
    let optionsResult = git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
    guard optionsResult == 0 else { return optionsResult }
    let context = GitFetchCredentials.Context(repository: repository)
    options.callbacks.credentials = GitFetchCredentials.callback
    options.callbacks.payload = Unmanaged.passUnretained(context).toOpaque()
    let result = git_remote_fetch(remote, nil, &options, nil)
    GitFetchCredentials.finish(context, success: result == 0)
    return result
  }
}
