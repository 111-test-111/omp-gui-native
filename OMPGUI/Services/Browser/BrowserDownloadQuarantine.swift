import CoreServices
import Foundation

/// Completed browser downloads remain quarantined without marking local tool outputs.
enum BrowserDownloadQuarantine {
    static func mark(_ file: URL) throws {
        let properties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "OMP GUI",
            kLSQuarantineAgentBundleIdentifierKey as String: Bundle.main.bundleIdentifier ?? "dev.ompgui.mac",
            kLSQuarantineTimeStampKey as String: Date()
        ]
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = file
        try target.setResourceValues(values)
    }
}
