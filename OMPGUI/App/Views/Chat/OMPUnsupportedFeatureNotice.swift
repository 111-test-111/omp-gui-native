import SwiftUI

struct OMPUnsupportedFeatureNotice: View {
    enum Feature { case sideQuestion, goal }
    let feature: Feature

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if feature == .sideQuestion {
                Text("Update OMP to use side questions.")
            } else {
                Text("Update OMP to use native goals.")
            }
            HStack(spacing: 10) {
                Link("Update OMP", destination: ProviderKind.omp.installURL).buttonStyle(.glass)
                Text("Restart the app after updating.")
                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
            }
        }
        .font(.ui(.callout)).fixedSize(horizontal: false, vertical: true)
    }
}
