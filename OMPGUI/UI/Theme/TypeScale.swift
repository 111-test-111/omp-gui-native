import AppKit
import CoreText
import SwiftUI

/// Interface, Content and Code base sizes. A stock setting is today's type;
/// any other setting adds the same point offset to every size in that category.
///
/// Isolated to the main actor, which is where SwiftUI bodies and the AppKit
/// attributed-string builders run. The read stays synchronous under Swift 6,
/// and Observation re-renders a body that read a size.
@MainActor @Observable
final class TypeScale {
    static let shared = TypeScale()

    static let stockUI = 13
    static let defaultUI = 14
    static let stockContent = 13 // Rendering baseline; keep existing sizes and range anchored here.
    static let defaultContent = 15
    static let stockCode = 12
    static let defaultCode = 13

    /// One point under the stock size through five over it.
    static let uiRange = (stockUI - 1)...(stockUI + 5)
    static let contentRange = (stockContent - 1)...(stockContent + 5)
    static let codeRange = (stockCode - 1)...(stockCode + 5)

    var ui = defaultUI
    var content = defaultContent
    var code = defaultCode

    var monospacedFontName = "" {
        didSet {
            let resolved = AppFont.resolve(monospacedFontName)
            guard monospacedFont != resolved else { return }
            monospacedFont = resolved
            AppFont.invalidateInstances()
            fontRevision += 1
        }
    }
    private(set) var fontRevision = 0
    fileprivate private(set) var monospacedFont: String?

    private init() {}

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The macOS point size of a text style at the Large content size.
    static func stockPointSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }

    func ui(_ stock: CGFloat) -> CGFloat { stock + CGFloat(ui - Self.stockUI) }
    func content(_ stock: CGFloat) -> CGFloat { stock + CGFloat(content - Self.stockContent) }
    func code(_ stock: CGFloat) -> CGFloat { stock + CGFloat(code - Self.stockCode) }
}

enum FontNameTable {
    struct Record {
        let platform: Int
        let encoding: Int
        let language: Int
        let nameID: Int
        let value: String
    }

    static func records(in data: Data) -> [Record] {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= 6 else { return [] }
            func word(_ offset: Int) -> Int {
                Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            }
            let format = word(0)
            let count = word(2)
            let storage = word(4)
            guard format <= 1, count <= (bytes.count - 6) / 12 else { return [] }
            var headerEnd = 6 + count * 12
            if format == 1 {
                guard bytes.count - headerEnd >= 2 else { return [] }
                let languageCount = word(headerEnd)
                headerEnd += 2
                guard languageCount <= (bytes.count - headerEnd) / 4 else { return [] }
                for index in 0..<languageCount {
                    let entry = headerEnd + index * 4
                    let length = word(entry)
                    let offset = word(entry + 2)
                    guard storage <= bytes.count, offset <= bytes.count - storage,
                          length <= bytes.count - storage - offset, length.isMultiple(of: 2) else { return [] }
                }
                headerEnd += languageCount * 4
            }
            guard storage >= headerEnd, storage <= bytes.count else { return [] }
            var records: [Record] = []
            for index in 0..<count {
                let entry = 6 + index * 12
                let platform = word(entry)
                let encoding = word(entry + 2)
                let language = word(entry + 4)
                let nameID = word(entry + 6)
                let length = word(entry + 8)
                let offset = word(entry + 10)
                guard offset <= bytes.count - storage,
                      length <= bytes.count - storage - offset else { return [] }
                switch nameID {
                case 1, 4, 6, 16, 21: break
                default: continue
                }
                let stringEncoding: String.Encoding
                switch (platform, encoding) {
                case (0, _), (3, 0), (3, 1), (3, 10):
                    guard length.isMultiple(of: 2) else { return [] }
                    stringEncoding = .utf16BigEndian
                case (1, 0...32):
                    let macEncoding = CFStringEncoding(encoding)
                    guard CFStringIsEncodingAvailable(macEncoding) else { continue }
                    stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(macEncoding))
                default:
                    continue
                }
                let start = storage + offset
                guard let value = String(bytes: bytes[start..<(start + length)], encoding: stringEncoding),
                      !value.isEmpty, !value.contains("\0") else { continue }
                records.append(Record(platform: platform, encoding: encoding, language: language,
                                      nameID: nameID, value: value))
            }
            return records
        }
    }
}

/// Resolves installed font names once, then shares sized faces across native and SwiftUI text.
@MainActor
enum AppFont {
    private struct NativeKey: Hashable {
        let name: String?
        let size: CGFloat
        let weight: CGFloat
        let monospaced: Bool
    }

    private struct SwiftUIKey: Hashable {
        let name: String?
        let size: CGFloat
        let weight: Font.Weight
        let design: Font.Design
    }

    private static var nativeFonts: [NativeKey: NSFont] = [:]
    private static var swiftUIFonts: [SwiftUIKey: Font] = [:]

    fileprivate static func invalidateInstances() {
        nativeFonts.removeAll(keepingCapacity: true)
        swiftUIFonts.removeAll(keepingCapacity: true)
    }

    private struct Aliases {
        var families: Set<String> = []
        var faces: Set<String> = []
        var postScript: Set<String> = []
    }

    private static func aliases(for font: NSFont) -> Aliases {
        let native = CTFontCreateWithName(font.fontName as CFString, 13, nil)
        var aliases = Aliases()
        if let family = font.familyName { aliases.families.insert(normalized(family)) }
        if let full = font.displayName { aliases.faces.insert(normalized(full)) }
        aliases.faces.insert(normalized(CTFontCopyFullName(native) as String))
        aliases.postScript.insert(normalized(font.fontName))
        for (key, isFamily) in [(kCTFontFamilyNameKey, true), (kCTFontFullNameKey, false)] {
            if let localized = CTFontCopyLocalizedName(native, key, nil) as String? {
                if isFamily {
                    aliases.families.insert(normalized(localized))
                } else {
                    aliases.faces.insert(normalized(localized))
                }
            }
        }
        // The localized API exposes only the preferred language, not every installed alias.
        if let data = CTFontCopyTable(native, CTFontTableTag(0x6E616D65), []) as Data? {
            let records = FontNameTable.records(in: data)
            for record in records {
                let key = normalized(record.value)
                switch record.nameID {
                case 1:
                    // Legacy families such as “Family Light” identify a face when name 16
                    // groups it under the wider typographic family.
                    let typographic = records.first {
                        $0.nameID == 16 && $0.platform == record.platform
                            && $0.encoding == record.encoding && $0.language == record.language
                    }
                    if let typographic, normalized(typographic.value) != key {
                        aliases.faces.insert(key)
                    } else {
                        aliases.families.insert(key)
                    }
                case 16, 21: aliases.families.insert(key)
                case 4: aliases.faces.insert(key)
                case 6: aliases.postScript.insert(key)
                default: break
                }
            }
        }
        return aliases
    }

    private static var installedNames: [String: String] = {
        let manager = NSFontManager.shared
        var families: [String: String] = [:]
        var faces: [String: String] = [:]
        var postScript: [String: String] = [:]
        var defaults: [String: String] = [:]
        for family in manager.availableFontFamilies.sorted() {
            if let font = manager.font(withFamily: family, traits: [], weight: 5, size: 13) {
                defaults[family] = font.fontName
                families[normalized(family)] = font.fontName
            }
        }
        for name in manager.availableFonts.sorted() {
            guard let font = NSFont(name: name, size: 13) else { continue }
            let aliases = aliases(for: font)
            if let family = font.familyName {
                let regular = defaults[family]
                    ?? manager.font(withFamily: family, traits: [], weight: 5, size: 13)?.fontName
                if let regular {
                    defaults[family] = regular
                    for alias in aliases.families where families[alias] == nil { families[alias] = regular }
                }
            }
            for alias in aliases.faces where faces[alias] == nil { faces[alias] = font.fontName }
            for alias in aliases.postScript where postScript[alias] == nil { postScript[alias] = font.fontName }
        }
        // A full name can equal a shared family name; family input must remain regular.
        // Exact PostScript names still identify their specific face.
        faces.merge(families) { _, family in family }
        faces.merge(postScript) { _, face in face }
        return faces
    }()

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    fileprivate static func resolve(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()
        guard !key.isEmpty else { return nil }
        if let installed = installedNames[key] { return installed }
        guard let font = NSFont(name: trimmed, size: 13) else { return nil }
        let aliases = aliases(for: font)
        let resolved: String
        if aliases.postScript.contains(key) {
            resolved = font.fontName
        } else if aliases.families.contains(key), let family = font.familyName {
            resolved = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?.fontName
                ?? font.fontName
        } else if aliases.faces.contains(key) {
            resolved = font.fontName
        } else {
            return nil
        }
        installedNames[key] = resolved
        return resolved
    }

    static var revision: Int { TypeScale.shared.fontRevision }
    static var monospacedPostScriptName: String? { TypeScale.shared.monospacedFont }
    static var monospacedName: String? {
        TypeScale.shared.monospacedFont.flatMap { native(name: $0, size: 13, weight: .regular, monospaced: true).familyName }
    }

    static func monospaced(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        native(name: TypeScale.shared.monospacedFont, size: size, weight: weight, monospaced: true)
    }

    static func customMonospaced(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont? {
        guard let name = TypeScale.shared.monospacedFont else { return nil }
        return native(name: name, size: size, weight: weight, monospaced: true)
    }

    private static func native(name: String?, size: CGFloat, weight: NSFont.Weight, monospaced: Bool) -> NSFont {
        let key = NativeKey(name: name, size: size, weight: weight.rawValue, monospaced: monospaced)
        if let cached = nativeFonts[key] { return cached }
        let font: NSFont
        if let name, let selected = NSFont(name: name, size: size) {
            if weight == .regular {
                // A named bold or italic face remains that face when no extra weight is requested.
                font = selected
            } else {
                var traits = selected.fontDescriptor.symbolicTraits
                traits.remove(.bold)
                let descriptor = NSFontDescriptor(fontAttributes: [
                    .family: selected.familyName ?? name,
                    .traits: [
                        NSFontDescriptor.TraitKey.symbolic: traits.rawValue,
                        NSFontDescriptor.TraitKey.weight: weight.rawValue,
                    ],
                ])
                font = NSFont(descriptor: descriptor, size: size) ?? selected
            }
        } else {
            font = monospaced
                ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
        }
        nativeFonts[key] = font
        return font
    }

    static func swiftUI(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let name = design == .monospaced ? TypeScale.shared.monospacedFont : nil
        let key = SwiftUIKey(name: name, size: size, weight: weight, design: design)
        if let cached = swiftUIFonts[key] { return cached }
        let font: Font
        if let name {
            font = Font(native(name: name, size: size, weight: nativeWeight(weight), monospaced: true))
        } else {
            font = .system(size: size, weight: weight, design: design)
        }
        swiftUIFonts[key] = font
        return font
    }

    private static func nativeWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

extension Font {
    /// Interface text. At the stock Interface size this matches `Font.system` for the style.
    /// `Font` itself is nonisolated, so the factories are marked to match `TypeScale`.
    @MainActor static func ui(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        typeScaled(size: TypeScale.shared.ui(TypeScale.stockPointSize(style)), style: style, weight: weight, design: design)
    }

    @MainActor static func ui(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        AppFont.swiftUI(size: TypeScale.shared.ui(size), weight: weight, design: design)
    }

    /// Headline stays semibold unless the caller passes a weight, matching `Font.system`.
    @MainActor static func typeScaled(size: CGFloat, style: Font.TextStyle, weight: Font.Weight?, design: Font.Design) -> Font {
        AppFont.swiftUI(size: size, weight: weight ?? (style == .headline ? .semibold : .regular), design: design)
    }

    /// SF Symbols keep the system face while following the interface size setting.
    @MainActor static func symbol(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        let font = Font.system(size: TypeScale.shared.ui(TypeScale.stockPointSize(style)), design: design)
        return (weight ?? (style == .headline ? .semibold : nil)).map { font.weight($0) } ?? font
    }

    @MainActor static func symbol(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: TypeScale.shared.ui(size), weight: weight, design: design)
    }
}
