// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OMPGUICefPrototype",
    platforms: [.macOS(.v14)],
    // run.py prepares the exact upstream revision plus the reviewed dialog patch.
    dependencies: [.package(path: "../dependencies/CefSwift")],
    targets: [.executableTarget(name: "OMPGUICefPrototype",
        dependencies: [.product(name: "CefSwiftUI", package: "CefSwift")],
        path: "Sources")]
)
