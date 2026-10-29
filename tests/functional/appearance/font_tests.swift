import AppKit
import CoreText
import Observation
import SwiftUI

private struct FontCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor private final class FontObservationProbe { var changed = false }

@main
private enum FontChecks {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw FontCheckFailure(description: message) }
    }

    private static func nameTable(_ records: [(Int, Int, Int, Int, [UInt8])], format: Int = 0) -> Data {
        func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }
        let storage = 6 + records.count * 12 + (format == 1 ? 2 : 0)
        var header = word(format) + word(records.count) + word(storage)
        var strings: [UInt8] = []
        for (platform, encoding, language, nameID, value) in records {
            header += word(platform) + word(encoding) + word(language) + word(nameID)
                + word(value.count) + word(strings.count)
            strings += value
        }
        if format == 1 { header += word(0) }
        return Data(header + strings)
    }

    private static func checkNameTables() throws {
        func unicode(_ value: String) -> [UInt8] { Array(value.data(using: .utf16BigEndian)!) }
        let values = ["测试字体😀", "測試字體😀 粗體", "Fixture-Regular", "Fixture Roman"]
        let records: [(Int, Int, Int, Int, [UInt8])] = [
            (0, 4, 0, 16, unicode(values[0])),
            (3, 10, 0x404, 4, unicode(values[1])),
            (3, 1, 0x409, 6, unicode(values[2])),
            (1, 0, 0, 1, Array(values[3].utf8)),
        ]
        let table = nameTable(records)
        for format in [0, 1] {
            try expect(FontNameTable.records(in: nameTable(records, format: format)).map(\.value) == values,
                       "Name table format \(format) lost Unicode, supplementary characters, or legacy Roman names")
        }
        for end in 0..<table.count {
            try expect(FontNameTable.records(in: Data(table.prefix(end))).isEmpty,
                       "Truncated name table at byte \(end) was accepted")
        }
        for (offset, value) in [(0, 2), (2, 0xFFFF), (4, 6), (4, 0xFFFF), (14, 0xFFFF), (16, 0xFFFF)] {
            var malformed = table
            malformed[offset] = UInt8(value >> 8)
            malformed[offset + 1] = UInt8(value & 255)
            try expect(FontNameTable.records(in: malformed).isEmpty,
                       "Malformed name table field at \(offset) was accepted")
        }
        let invalidNames: [[UInt8]] = [[0x00], [0xD8, 0x00], [0x00, 0x00]]
        for bytes in invalidNames {
            try expect(FontNameTable.records(in: nameTable([(3, 1, 0x804, 1, bytes)])).isEmpty,
                       "Invalid UTF-16 or NUL name was accepted")
        }
        var badLanguageHeader = nameTable(records, format: 1)
        let languageOffset = 6 + records.count * 12
        badLanguageHeader[languageOffset] = 0xFF
        badLanguageHeader[languageOffset + 1] = 0xFF
        try expect(FontNameTable.records(in: badLanguageHeader).isEmpty,
                   "Out-of-bounds format-1 language records were accepted")
        try expect(FontNameTable.records(in: nameTable([(3, 2, 0x804, 1, [0x81, 0x40])])).isEmpty,
                   "Unsupported legacy encoding was misinterpreted as Unicode")
    }

    @MainActor
    private static func checkLocalizedFonts() throws {
        let scale = TypeScale.shared
        let manager = NSFontManager.shared
        guard let regular = NSFont(name: "PingFangSC-Regular", size: 17),
              regular.fontName == "PingFangSC-Regular",
              let family = regular.familyName,
              let familyDefault = manager.font(withFamily: family, traits: [], weight: 5, size: 17) else {
            throw FontCheckFailure(description: "Required macOS PingFang SC metadata is unavailable")
        }
        let native = CTFontCreateWithName(regular.fontName as CFString, 17, nil)
        guard let data = CTFontCopyTable(native, CTFontTableTag(0x6E616D65), []) as Data? else {
            throw FontCheckFailure(description: "Required PingFang SC name table is unavailable")
        }
        let names = FontNameTable.records(in: data)
        let familyAliases = ["苹方-简", "蘋方-簡"]
        let fullAliases = ["苹方-简 常规体", "蘋方-簡 標準體"]
        let preferredFull = CTFontCopyLocalizedName(native, kCTFontFullNameKey, nil) as String?
        try expect(fullAliases.contains { $0 != preferredFull }, "Need a Chinese name outside the preferred locale")
        for alias in familyAliases {
            try expect(names.contains { [1, 16].contains($0.nameID) && $0.value == alias },
                       "Required macOS Chinese family metadata is missing: \(alias)")
            scale.monospacedFontName = " \n\(alias)\t "
            try expect(AppFont.monospaced(size: 11.5).fontName == familyDefault.fontName,
                       "Chinese family did not select the same default face as English: \(alias)")
            try expect(!manager.traits(of: AppFont.monospaced(size: 11.5)).contains(.boldFontMask),
                       "Shared Chinese family alias was overwritten by a bold face")
            let revision = AppFont.revision
            scale.monospacedFontName = family
            try expect(AppFont.revision == revision, "Equivalent monospaced family aliases changed the revision")
        }
        for alias in fullAliases {
            try expect(names.contains { $0.nameID == 4 && $0.value == alias },
                       "Required macOS Chinese full-name metadata is missing: \(alias)")
            scale.monospacedFontName = alias
            try expect(AppFont.monospaced(size: 11.5).fontName == regular.fontName,
                       "Chinese full name lost the exact face: \(alias)")
            let revision = AppFont.revision
            scale.monospacedFontName = CTFontCopyFullName(native) as String
            scale.monospacedFontName = regular.fontName
            try expect(AppFont.revision == revision, "Equivalent localized, English and PostScript face aliases changed the revision")
        }
        guard let bold = NSFont(name: "STSongti-SC-Bold", size: 17),
              bold.fontName == "STSongti-SC-Bold" else {
            throw FontCheckFailure(description: "Required macOS Songti SC bold face is unavailable")
        }
        for alias in ["宋体-简 粗体", "宋體-簡 粗體"] {
            scale.monospacedFontName = alias
            try expect(AppFont.monospaced(size: 11.5).fontName == bold.fontName,
                       "Localized specific-face alias was reset to the family default: \(alias)")
        }
        for alias in ["宋体-简", "宋體-簡"] {
            scale.monospacedFontName = alias
            try expect(AppFont.monospaced(size: 11.5).familyName == bold.familyName
                       && !manager.traits(of: AppFont.monospaced(size: 11.5)).contains(.boldFontMask),
                       "Localized shared family alias retained a specific bold face")
        }
    }

    private struct GlyphFont: Equatable {
        let name: String
        let size: CGFloat
    }

    private static func glyphFonts(_ text: String, font: NSFont) throws -> [Int: GlyphFont] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var fonts: [Int: GlyphFont] = [:]
        for value in CTLineGetGlyphRuns(line) as NSArray {
            let run = value as! CTRun
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetStringIndices(run, CFRange(), &indices)
            for (glyph, index) in zip(glyphs, indices) {
                try expect(glyph != 0, "CoreText produced a missing glyph for \(text) at \(index)")
                fonts[index] = GlyphFont(name: CTFontCopyPostScriptName(runFont) as String,
                                         size: CTFontGetSize(runFont))
            }
        }
        return fonts
    }

    @MainActor
    private static func checkMonospacedObservation() throws {
        let scale = TypeScale.shared
        let size: CGFloat = 13.5
        for mono in ["Menlo-Regular", "", "not-an-installed-font-91742"] {
            scale.monospacedFontName = mono
            var nativeFactories: [(String, @MainActor () -> NSFont)] = [
                ("monospaced", { AppFont.monospaced(size: size) }),
            ]
            if mono == "Menlo-Regular" {
                nativeFactories.append(("customMonospaced", { AppFont.customMonospaced(size: size)! }))
            }
            let swiftUIFactories: [(String, @MainActor () -> Font)] = [
                ("swiftUI", { AppFont.swiftUI(size: size, design: .monospaced) }),
                ("ui", { Font.ui(size: size, design: .monospaced) }),
            ]
            for (name, factory) in nativeFactories {
                scale.monospacedFontName = mono
                _ = factory()
                let observation = FontObservationProbe()
                let before = withObservationTracking { factory() } onChange: {
                    MainActor.assumeIsolated { observation.changed = true }
                }
                scale.monospacedFontName = "STSongti-SC-Bold"
                try expect(observation.changed,
                           "Warm \(name) consumer did not observe a monospaced change (mono: \(mono))")
                try expect(factory() != before, "Observed \(name) consumer retained its previous face")
                let glyphs = try glyphFonts("A中", font: AppFont.monospaced(size: size))
                try expect(glyphs[0] == GlyphFont(name: "STSongti-SC-Bold", size: size)
                           && glyphs[1] == GlyphFont(name: "STSongti-SC-Bold", size: size),
                           "Observed monospaced consumer did not shape every glyph with the new face")
            }
            for (name, factory) in swiftUIFactories {
                scale.monospacedFontName = mono
                _ = factory()
                let observation = FontObservationProbe()
                let before = withObservationTracking { factory() } onChange: {
                    MainActor.assumeIsolated { observation.changed = true }
                }
                scale.monospacedFontName = "STSongti-SC-Bold"
                try expect(observation.changed,
                           "Warm \(name) consumer did not observe a monospaced change (mono: \(mono))")
                try expect(factory() != before, "Observed SwiftUI consumer retained its previous font")
            }
        }
    }

    @MainActor
    static func main() throws {
        let scale = TypeScale.shared
        let originalMono = scale.monospacedFontName
        defer { scale.monospacedFontName = originalMono }
        scale.monospacedFontName = ""

        try checkNameTables()
        try checkLocalizedFonts()
        try checkMonospacedObservation()
        scale.monospacedFontName = ""
        let manager = NSFontManager.shared
        let families = manager.availableFontFamilies.sorted().compactMap { family -> NSFont? in
            guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: 17),
                  font.familyName != nil else { return nil }
            return font
        }
        guard let first = families.first,
              let second = families.first(where: { $0.familyName != first.familyName }) else {
            throw FontCheckFailure(description: "Need two installed font families")
        }
        let firstFamily = first.familyName!
        let secondFamily = second.familyName!

        if let courier = NSFont(name: "Courier", size: 17),
           courier.fontName.caseInsensitiveCompare("Courier") == .orderedSame {
            scale.monospacedFontName = " \nCoUrIeR\t "
            let selected = AppFont.monospaced(size: 17)
            try expect(selected.fontName == courier.fontName && selected.familyName == courier.familyName,
                       "An exact native-resolvable font must work even when font enumeration omits it")
        }

        scale.monospacedFontName = " \n\(firstFamily.uppercased())\t "
        try expect(AppFont.monospacedName == firstFamily, "Family lookup must ignore case and surrounding whitespace")
        let resolved = AppFont.monospaced(size: 17)
        try expect(resolved.familyName == firstFamily && resolved.pointSize == 17, "Family selection changed the requested size")
        let familyRevision = AppFont.revision
        scale.monospacedFontName = firstFamily.lowercased()
        try expect(AppFont.revision == familyRevision, "Equivalent family input invalidated the font revision")

        scale.monospacedFontName = " \(first.fontName.uppercased()) "
        try expect(AppFont.monospaced(size: 17).fontName == first.fontName, "PostScript lookup did not select the installed face")
        if let fullName = first.displayName {
            scale.monospacedFontName = fullName
            try expect(AppFont.monospaced(size: 17).fontName == first.fontName, "Full font name lookup did not select the installed face")
        }
        let faceRevision = AppFont.revision
        scale.monospacedFontName = first.fontName.lowercased()
        try expect(AppFont.revision == faceRevision, "Equivalent face aliases invalidated the revision")

        let beforeSwitch = AppFont.revision
        scale.monospacedFontName = secondFamily
        try expect(AppFont.revision == beforeSwitch + 1, "Changing the family at the same size did not invalidate the revision")
        try expect(AppFont.monospaced(size: 17).familyName == secondFamily, "Same-size family switch retained the old font")
        // The interface face is always the system font, whatever the monospaced selection is.
        try expect(AppFont.swiftUI(size: 15, weight: .medium) == .system(size: 15, weight: .medium, design: .default),
                   "Monospaced selection leaked into interface text")
        try expect(AppFont.swiftUI(size: 15, weight: .medium, design: .monospaced)
                   != .system(size: 15, weight: .medium, design: .monospaced),
                   "Monospaced selection did not reach monospaced text")

        guard let regular = families.first(where: {
            manager.traits(of: manager.convert($0, toHaveTrait: .boldFontMask)).contains(.boldFontMask)
                && manager.traits(of: manager.convert($0, toHaveTrait: .italicFontMask)).contains(.italicFontMask)
        }) else { throw FontCheckFailure(description: "Need an installed family with bold and italic faces") }
        let bold = manager.convert(regular, toHaveTrait: .boldFontMask)
        let italic = manager.convert(regular, toHaveTrait: .italicFontMask)
        scale.monospacedFontName = regular.fontName
        let weighted = AppFont.monospaced(size: 19.5, weight: .bold)
        try expect(weighted.pointSize == 19.5 && manager.traits(of: weighted).contains(.boldFontMask), "Requested weight or size was lost")
        scale.monospacedFontName = bold.fontName
        try expect(manager.traits(of: AppFont.monospaced(size: 14)).contains(.boldFontMask), "Named bold face was reset to regular")
        scale.monospacedFontName = italic.fontName
        try expect(manager.traits(of: AppFont.monospaced(size: 14)).contains(.italicFontMask), "Named italic face was reset to upright")
        try expect(manager.traits(of: AppFont.monospaced(size: 14, weight: .bold)).contains(.italicFontMask), "Adding weight lost the selected italic trait")

        scale.monospacedFontName = "not-an-installed-font-91742"
        try expect(AppFont.monospacedName == nil, "Unmatched names must resolve to defaults")
        scale.monospacedFontName = "不存在的字体-91742"
        try expect(AppFont.monospacedPostScriptName == nil,
                   "Unknown Chinese names must not accept native fallback fonts")
        let fallbackRevision = AppFont.revision
        scale.monospacedFontName = " \n\t "
        try expect(AppFont.revision == fallbackRevision, "Invalid-to-blank input changed the effective revision")
        try expect(AppFont.customMonospaced(size: 13) == nil, "Default monospaced selection must preserve terminal-specific fallback")
        try expect(AppFont.monospaced(size: 12) == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), "Monospaced fallback changed")
        for design in [Font.Design.default, .rounded, .serif, .monospaced] {
            try expect(AppFont.swiftUI(size: 15, weight: .medium, design: design) == .system(size: 15, weight: .medium, design: design), "Default SwiftUI design or weight changed")
        }
        print("Font behavior checks passed")
    }
}
