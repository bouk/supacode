import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

/// The "Go to" slot after Edit's text-editing items. A focused pull-request
/// diff window turns the worktree switcher's shortcut (⌘P) into Go to File.
struct GoToCommands: Commands {
  let store: StoreOf<AppFeature>
  @FocusedValue(\.goToDiffFileAction) private var goToDiffFileAction

  var body: some Commands {
    let overrides = store.settings.shortcutOverrides
    let worktreeSwitcher = AppShortcuts.worktreeSwitcher.effective(from: overrides)
    let commandPalette = AppShortcuts.commandPalette.effective(from: overrides)
    CommandGroup(after: .textEditing) {
      if let goToDiffFileAction {
        Button("Go to File…") {
          guard NSApp.currentEvent?.isAutoRepeatKeyDown != true else { return }
          goToDiffFileAction()
        }
        .appKeyboardShortcut(worktreeSwitcher)
        .help("Jump to a file in the diff (\(worktreeSwitcher?.display ?? "none"))")
        .disabled(goToDiffFileAction.isEnabled != true)
      } else {
        Button("Go to Worktree") {
          guard NSApp.currentEvent?.isAutoRepeatKeyDown != true else { return }
          store.send(.commandPalette(.togglePresentInMode(.worktreeSwitcher)))
        }
        .appKeyboardShortcut(worktreeSwitcher)
        .help("Switch between worktrees, sorted by most recently used")
      }
      Button("Command Palette") {
        guard NSApp.currentEvent?.isAutoRepeatKeyDown != true else { return }
        store.send(.commandPalette(.togglePresentInMode(.commands)))
      }
      .appKeyboardShortcut(commandPalette)
      .help("Command Palette")
    }
  }
}

private struct GoToDiffFileActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var goToDiffFileAction: FocusedAction<Void>? {
    get { self[GoToDiffFileActionKey.self] }
    set { self[GoToDiffFileActionKey.self] = newValue }
  }
}
