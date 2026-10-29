import SwiftUI

struct NewThreadDefaultsRows: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var settings = model.settings
        ChromeRow(title: "New chat location", detail: "Follow the recent project or task, or always start an independent task.") {
            Picker("New chat location", selection: $settings.newThreadLocation) {
                ForEach(NewThreadLocation.allCases, id: \.self) { location in
                    Text(verbatim: Chrome.localized(location.title)).tag(location)
                }
            }.labelsHidden()
        }
    }
}
