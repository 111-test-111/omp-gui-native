import CoreServices
import Foundation

@main
private enum BrowserDownloadChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-browser-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("Isolated download fixture\n".utf8)

        func quarantine(_ file: URL) throws -> [String: Any]? {
            var observed = file
            observed.removeAllCachedResourceValues()
            return try observed.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        }

        func cleanFile(_ name: String) throws -> URL {
            var file = root.appendingPathComponent(name)
            try contents.write(to: file)
            var clean = URLResourceValues()
            clean.quarantineProperties = nil
            try file.setResourceValues(clean)
            let properties = try quarantine(file)
            expect(properties == nil || properties!.isEmpty, "The fixture must begin without inherited quarantine")
            return file
        }

        let file = try cleanFile("download.bin")
        let localOutput = try cleanFile("local-output.bin")
        try BrowserDownloadQuarantine.mark(file)
        let properties = try quarantine(file)!
        expect(properties[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String,
               "Completed browser downloads must retain persisted web-download quarantine")
        expect(try Data(contentsOf: file) == contents, "Quarantining must not alter the downloaded bytes")
        let localProperties = try quarantine(localOutput)
        expect(localProperties == nil || localProperties!.isEmpty,
               "Marking a browser download must not quarantine unrelated local outputs")

        let missing = root.appendingPathComponent("missing.bin")
        var failed = false
        do { try BrowserDownloadQuarantine.mark(missing) }
        catch { failed = true }
        expect(failed && !FileManager.default.fileExists(atPath: missing.path),
               "Missing download files must fail without creating a replacement")
        print("browser download quarantine: \(checks) checks passed")
    }
}
