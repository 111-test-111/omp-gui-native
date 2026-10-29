import AppKit
import Foundation

// Read-only image verification; shared across capture cases, no image editing.
guard CommandLine.arguments.count == 2,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let bitmap = NSBitmapImageRep(data: data) else { exit(2) }
let samples = [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)].map { point in
    let x = min(bitmap.pixelsWide - 1, Int(Double(bitmap.pixelsWide) * point.0))
    let y = min(bitmap.pixelsHigh - 1, Int(Double(bitmap.pixelsHigh) * point.1))
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { exit(3) }
    return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
}
let result: [String: Any] = ["width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "samples": samples]
let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
