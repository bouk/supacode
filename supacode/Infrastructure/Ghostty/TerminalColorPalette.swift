import AppKit
import GhosttyKit

/// Immutable colors from Ghostty's already-resolved configuration. Consumers
/// share the terminal's theme precedence and light/dark variant selection.
struct TerminalColorPalette: Equatable {
  let background: NSColor
  let foreground: NSColor
  let ansi: [NSColor]
  let selectionBackground: NSColor
  let selectionForeground: NSColor

  var muted: NSColor { color(8) }
  var separator: NSColor { foreground.withAlphaComponent(0.15) }

  func color(_ index: Int) -> NSColor {
    ansi.indices.contains(index) ? ansi[index] : foreground
  }

  init(config: ghostty_config_t) {
    let fallback = Self.system
    background = Self.readColor("background", config: config) ?? fallback.background
    foreground = Self.readColor("foreground", config: config) ?? fallback.foreground
    var palette = ghostty_config_palette_s()
    if ghostty_config_get(config, &palette, "palette", UInt("palette".utf8.count)) {
      ansi = withUnsafeBytes(of: &palette.colors) { bytes in
        bytes.bindMemory(to: ghostty_config_color_s.self).prefix(16).map { NSColor(ghostty: $0) }
      }
    } else {
      ansi = fallback.ansi
    }
    // GhosttyKit versions that don't export TerminalColor union values return
    // false for these keys. Derive a readable selection from the active palette.
    let accent = ansi[4]
    selectionBackground =
      Self.readColor("selection-background", config: config)
      ?? background.blended(withFraction: 0.35, of: accent) ?? accent
    selectionForeground = Self.readColor("selection-foreground", config: config) ?? foreground
  }

  init(
    background: NSColor, foreground: NSColor, ansi: [NSColor],
    selectionBackground: NSColor, selectionForeground: NSColor
  ) {
    self.background = background
    self.foreground = foreground
    self.ansi = ansi
    self.selectionBackground = selectionBackground
    self.selectionForeground = selectionForeground
  }

  private static func readColor(_ key: String, config: ghostty_config_t) -> NSColor? {
    var value = ghostty_config_color_s()
    guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
    return NSColor(ghostty: value)
  }

  static var system: Self {
    Self(
      background: .textBackgroundColor, foreground: .textColor,
      ansi: [
        .black, .systemRed, .systemGreen, .systemOrange, .systemBlue, .systemPurple, .systemTeal, .textColor,
        .secondaryLabelColor, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemCyan,
        .textColor,
      ],
      selectionBackground: .selectedTextBackgroundColor, selectionForeground: .selectedTextColor)
  }
}
