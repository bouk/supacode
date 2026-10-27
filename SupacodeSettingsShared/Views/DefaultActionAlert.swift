import ComposableArchitecture
import SwiftUI

extension View {
  /// Presents a TCA alert with Return activating its first non-cancel action.
  /// A single cancel-role button (such as OK) is also the default action.
  public func defaultActionAlert<Action>(
    _ item: Binding<Store<AlertState<Action>, Action>?>
  ) -> some View {
    let alertStore = item.wrappedValue
    let alert = alertStore?.withState { $0 }
    return self.alert(
      alert.map { Text($0.title) } ?? Text(verbatim: ""),
      isPresented: Binding(item),
      presenting: alert
    ) { alert in
      let defaultButton = alert.buttons.first { $0.role != .cancel } ?? alert.buttons.first
      ForEach(alert.buttons) { button in
        let role: ButtonRole? = button.role == .cancel ? .cancel : (button.role == .destructive ? .destructive : nil)
        if button.id == defaultButton?.id {
          Button(role: role) {
            button.withAction { action in
              if let action { alertStore?.send(action) }
            }
          } label: {
            Text(button.label)
          }
          .keyboardShortcut(.defaultAction)
        } else {
          Button(role: role) {
            button.withAction { action in
              if let action { alertStore?.send(action) }
            }
          } label: {
            Text(button.label)
          }
        }
      }
    } message: { alert in
      alert.message.map(Text.init)
    }
  }
}
