import SwiftUI

struct SharedThreadAccessBar: View {
    let isReadOnly: Bool
    let canRelease: Bool
    var edit: () -> Void
    var release: () -> Void

    var body: some View {
        ChromeRow(title: isReadOnly ? "Read-only · shared conversation" : "Shared conversation") {
            if isReadOnly {
                Button("Edit here", action: edit)
            } else {
                Button("Release editing", action: release).disabled(!canRelease)
            }
        }
    }
}
