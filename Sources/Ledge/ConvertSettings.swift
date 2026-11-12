import Foundation

enum OutputFormat: String, Codable, CaseIterable, Identifiable {
    /// WebP for everything, except WebP files, which become PNG.
    case auto, webp, png, jpeg, gif
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto (to WebP, WebP to PNG)"
        case .webp: return "WebP"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .gif: return "GIF (animated WebP stays animated)"
        }
    }

    var shortTitle: String {
        switch self {
        case .auto, .webp: return "WebP"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .gif: return "GIF"
        }
    }

    var fileExtension: String {
        switch self {
        case .auto, .webp: return "webp"
        case .png: return "png"
        case .jpeg: return "jpg"
        case .gif: return "gif"
        }
    }
}

enum Destination: String, Codable, CaseIterable, Identifiable {
    case shelf, sameFolder, folder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shelf: return "Shelf only (temporary files)"
        case .sameFolder: return "Next to the originals"
        case .folder: return "A folder I choose"
        }
    }
}

enum RenameMode: String, Codable, CaseIterable, Identifiable {
    case keep, prefix, suffix, replace, numbering
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keep: return "Keep names"
        case .prefix: return "Add prefix"
        case .suffix: return "Add suffix"
        case .replace: return "Find and replace"
        case .numbering: return "Numbering"
        }
    }
}

enum WatermarkKind: String, Codable, CaseIterable, Identifiable {
    case image, text
    var id: String { rawValue }
}

/// Where a watermark sits, as a 3x3 grid.
enum WatermarkPosition: Int, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var id: Int { rawValue }
    var title: String {
        ["Top left", "Top", "Top right", "Left", "Center", "Right", "Bottom left", "Bottom", "Bottom right"][rawValue]
    }
}

/// Everything a conversion run depends on. Saved as presets, so keep it Codable and tolerant of new keys.
struct ConvertSettings: Codable, Equatable {
    var format: OutputFormat = .auto

    // Encoder
    var quality: Double = 75
    var lossless = false
    /// 0 default, 1 picture, 2 photo, 3 drawing, 4 icon, 5 text (libwebp presets).
    var preset = 0
    /// 0 (fast) to 6 (smallest).
    var method = 4
    var sharpYUV = false
    var keepProfile = false

    // Size
    var resize = false
    var maxWidth = 1920
    var maxHeight = 1920

    // Metadata and files
    var keepMetadata = false
    var keepOriginalExtension = false
    var keepDates = false

    // Names
    var rename: RenameMode = .keep
    var renameText = ""
    var renameFind = ""
    var numberingStart = 1

    var destination: Destination = .shelf
    var folderPath = ""

    // Watermark
    var watermark = false
    var watermarkKind: WatermarkKind = .image
    var watermarkPath = ""
    var watermarkText = ""
    var watermarkPosition: WatermarkPosition = .bottomRight
    /// Percent of the image width.
    var watermarkScale = 20.0
    var watermarkOpacity = 70.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        var s = ConvertSettings()
        func read<T: Decodable>(_ key: Keys, _ keyPath: WritableKeyPath<ConvertSettings, T>) {
            if let value = try? c.decode(T.self, forKey: key) { s[keyPath: keyPath] = value }
        }
        read(.format, \.format); read(.quality, \.quality); read(.lossless, \.lossless)
        read(.preset, \.preset); read(.method, \.method); read(.sharpYUV, \.sharpYUV)
        read(.keepProfile, \.keepProfile); read(.resize, \.resize); read(.maxWidth, \.maxWidth)
        read(.maxHeight, \.maxHeight); read(.keepMetadata, \.keepMetadata)
        read(.keepOriginalExtension, \.keepOriginalExtension); read(.keepDates, \.keepDates)
        read(.rename, \.rename); read(.renameText, \.renameText); read(.renameFind, \.renameFind)
        read(.numberingStart, \.numberingStart); read(.destination, \.destination)
        read(.folderPath, \.folderPath); read(.watermark, \.watermark)
        read(.watermarkKind, \.watermarkKind); read(.watermarkPath, \.watermarkPath)
        read(.watermarkText, \.watermarkText); read(.watermarkPosition, \.watermarkPosition)
        read(.watermarkScale, \.watermarkScale); read(.watermarkOpacity, \.watermarkOpacity)
        self = s
    }

    enum Keys: String, CodingKey {
        case format, quality, lossless, preset, method, sharpYUV, keepProfile, resize, maxWidth, maxHeight
        case keepMetadata, keepOriginalExtension, keepDates, rename, renameText, renameFind, numberingStart
        case destination, folderPath, watermark, watermarkKind, watermarkPath, watermarkText
        case watermarkPosition, watermarkScale, watermarkOpacity
    }
}

struct ConvertPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: ConvertSettings
}

extension Prefs {
    /// The settings the converter window was last used with.
    static var convertSettings: ConvertSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: "convertSettings"),
                  let value = try? JSONDecoder().decode(ConvertSettings.self, from: data) else { return ConvertSettings() }
            return value
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "convertSettings") }
    }

    static var convertPresets: [ConvertPreset] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "convertPresets"),
                  let value = try? JSONDecoder().decode([ConvertPreset].self, from: data) else { return [] }
            return value
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "convertPresets") }
    }
}

extension Prefs {
    /// Settings for the one-click Quick Convert action on a shelf.
    static var quickSettings: ConvertSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: "quickSettings"),
                  let value = try? JSONDecoder().decode(ConvertSettings.self, from: data) else { return ConvertSettings() }
            return value
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "quickSettings") }
    }

    /// Quick Convert swaps converted files in for their sources on the shelf (otherwise it adds them next to them).
    static var quickReplacesSources: Bool {
        get { UserDefaults.standard.object(forKey: "quickReplacesSources") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "quickReplacesSources") }
    }
}
