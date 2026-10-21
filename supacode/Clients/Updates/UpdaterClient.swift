import ComposableArchitecture
import SupacodeSettingsShared

nonisolated struct UpdaterClient: Sendable {
  var configure: @MainActor @Sendable (_ checks: Bool, _ downloads: Bool, _ checkInBackground: Bool) -> Void
  var setUpdateChannel: @MainActor @Sendable (UpdateChannel) -> Void
  var checkForUpdates: @MainActor @Sendable () -> Void
}

nonisolated extension UpdaterClient: DependencyKey {
  // Fork: no update feed. Sparkle is never started, so upstream releases are
  // never offered or installed over this build.
  static let liveValue = UpdaterClient(
    configure: { _, _, _ in },
    setUpdateChannel: { _ in },
    checkForUpdates: {}
  )

  static let testValue = UpdaterClient(
    configure: { _, _, _ in },
    setUpdateChannel: { _ in },
    checkForUpdates: {}
  )
}

nonisolated extension DependencyValues {
  var updaterClient: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}
