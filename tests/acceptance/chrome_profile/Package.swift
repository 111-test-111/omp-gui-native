// swift-tools-version: 6.0
import PackageDescription

// The manual runner copies this package into build.noindex/chrome-profile/package.
let package = Package(name: "OMPChromeProfileProbe", platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../browser/dependencies/CefSwift")],
    targets: [.executableTarget(name: "OMPChromeProfileProbe", dependencies: [
        .product(name: "CefSwiftUI", package: "CefSwift")], path: "Sources")])
