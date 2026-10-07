import SwiftUI

/// The colour each shortcut section wears in Settings; kept with the theme so the
/// shortcut model stays free of chrome colours.
extension AppShortcut.Section {
    var tint: Color {
        switch self {
        case .threads: Chrome.blue
        case .window: Color(red: 0.686, green: 0.322, blue: 0.871)
        }
    }
}
