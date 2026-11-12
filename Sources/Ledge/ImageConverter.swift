import AppKit
import CWebP
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ConvertError: LocalizedError {
    case unreadable, encodeFailed(String), writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Can’t read this image"
        case .encodeFailed(let why): return String(format: "Encoding failed (%@)", why)
        case .writeFailed: return "Can’t write the output file"
        }
    }
}

/// One decoded image, possibly animated.
struct DecodedImage {
    struct Frame { var image: CGImage; var delay: TimeInterval }
    var frames: [Frame]
    var properties: [CFString: Any]
    var loopCount: Int
    var isAnimated: Bool { frames.count > 1 }
}

/// A rendered frame: resized, watermarked, in a known color space with premultiplied alpha.
struct Bitmap {
    let context: CGContext
    var width: Int { context.width }
    var height: Int { context.height }
    var colorSpace: CGColorSpace { context.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)! }
    var image: CGImage? { context.makeImage() }

    /// Straight (non-premultiplied) RGBA, which is what libwebp imports.
    func straightRGBA() -> [UInt8] {
        let w = width, h = height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        guard let base = context.data else { return out }
        let rowBytes = context.bytesPerRow
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let i = x * 4, o = (y * w + x) * 4
                let a = Int(row[i + 3])
                if a == 255 || a == 0 {
                    out[o] = row[i]; out[o + 1] = row[i + 1]; out[o + 2] = row[i + 2]
                } else {
                    out[o] = UInt8(min(255, (Int(row[i]) * 255 + a / 2) / a))
                    out[o + 1] = UInt8(min(255, (Int(row[i + 1]) * 255 + a / 2) / a))
                    out[o + 2] = UInt8(min(255, (Int(row[i + 2]) * 255 + a / 2) / a))
                }
                out[o + 3] = UInt8(a)
            }
        }
        return out
    }
}

struct EncodedImage {
    var data: Data
    var fileExtension: String
    var width: Int
    var height: Int
}

/// Reads almost any image and writes WebP, PNG, JPEG or GIF. Everything is synchronous; call it off the main thread.
enum ImageConverter {

    // MARK: Which files we accept

    static func canRead(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    /// Expands folders (recursively) into the image files inside them and drops everything else.
    static func imageFiles(in urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
                let found = (walker?.allObjects as? [URL]) ?? []
                result += found.filter { canRead($0) }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if canRead(url) {
                result.append(url)
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func isWebP(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .webP) == true
            || url.pathExtension.lowercased() == "webp"
    }

    static func resolvedFormat(_ settings: ConvertSettings, for url: URL) -> OutputFormat {
        settings.format == .auto ? (isWebP(url) ? .png : .webp) : settings.format
    }

    // MARK: Decoding

    static func decode(_ url: URL) throws -> DecodedImage {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if type?.conforms(to: .pdf) == true { return try decodePDF(url) }
        if type?.conforms(to: .svg) == true { return try decodeSVG(url) }
        if isWebP(url), let animated = try? decodeAnimatedWebP(url), animated.isAnimated { return animated }
        if let decoded = decodeWithImageIO(url) { return decoded }
        if isWebP(url), let decoded = try? decodeAnimatedWebP(url) { return decoded }
        throw ConvertError.unreadable
    }

    private static func decodeWithImageIO(_ url: URL) -> DecodedImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

        if count > 1 {
            var frames: [DecodedImage.Frame] = []
            for i in 0..<count {
                guard let image = CGImageSourceCreateImageAtIndex(source, i, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { continue }
                frames.append(.init(image: image, delay: frameDelay(source, index: i)))
            }
            // Multi-image TIFFs and HEIC bursts are pages, not animation: take the first image only.
            let type = CGImageSourceGetType(source) as String? ?? ""
            let animatedTypes: Set<String> = [UTType.gif.identifier, UTType.png.identifier, UTType.webP.identifier, "public.heics"]
            if animatedTypes.contains(type), frames.count > 1 {
                return DecodedImage(frames: frames, properties: props, loopCount: loopCount(props))
            }
            if let first = frames.first { return DecodedImage(frames: [first], properties: props, loopCount: 0) }
            return nil
        }

        // Thumbnail decoding applies the EXIF orientation, which plain image creation does not.
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 16),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        guard let image else { return nil }
        return DecodedImage(frames: [.init(image: image, delay: 0)], properties: props, loopCount: 0)
    }

    private static func frameDelay(_ source: CGImageSource, index: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (dict, unclamped, clamped) in dicts {
            guard let d = props[dict] as? [CFString: Any] else { continue }
            let value = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0
            if value > 0 { return max(value, 0.02) }
        }
        return 0.1
    }

    private static func loopCount(_ props: [CFString: Any]) -> Int {
        (props[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
            ?? (props[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyAPNGLoopCount] as? Int
            ?? 0
    }

    /// WebP decoding through libwebp, so animation works on every supported macOS.
    private static func decodeAnimatedWebP(_ url: URL) throws -> DecodedImage {
        let file = try Data(contentsOf: url)
        return try file.withUnsafeBytes { raw -> DecodedImage in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw ConvertError.unreadable }
            var webp = WebPData(bytes: base, size: file.count)
            var options = WebPAnimDecoderOptions()
            guard WebPAnimDecoderOptionsInit(&options) != 0 else { throw ConvertError.unreadable }
            options.color_mode = MODE_rgbA // premultiplied, which is what CGContext wants
            options.use_threads = 1
            guard let decoder = WebPAnimDecoderNew(&webp, &options) else { throw ConvertError.unreadable }
            defer { WebPAnimDecoderDelete(decoder) }
            var info = WebPAnimInfo()
            guard WebPAnimDecoderGetInfo(decoder, &info) != 0 else { throw ConvertError.unreadable }
            let w = Int(info.canvas_width), h = Int(info.canvas_height)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!

            var frames: [DecodedImage.Frame] = []
            var previous: Int32 = 0
            while WebPAnimDecoderHasMoreFrames(decoder) != 0 {
                var pixels: UnsafeMutablePointer<UInt8>?
                var timestamp: Int32 = 0
                guard WebPAnimDecoderGetNext(decoder, &pixels, &timestamp) != 0, let pixels else { break }
                let copy = Data(bytes: pixels, count: w * h * 4)
                guard let provider = CGDataProvider(data: copy as CFData),
                      let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { throw ConvertError.unreadable }
                let delay = max(Double(timestamp - previous) / 1000, 0.02)
                previous = timestamp
                frames.append(.init(image: image, delay: delay))
            }
            guard !frames.isEmpty else { throw ConvertError.unreadable }
            return DecodedImage(frames: frames, properties: [:], loopCount: Int(info.loop_count))
        }
    }

    private static func decodePDF(_ url: URL) throws -> DecodedImage {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { throw ConvertError.unreadable }
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let pageW = rotated ? box.height : box.width, pageH = rotated ? box.width : box.height
        let scale = min(2.0, 4096 / max(pageW, pageH, 1))
        let w = max(1, Int(pageW * scale)), h = max(1, Int(pageH * scale))
        guard let ctx = makeContext(width: w, height: h, space: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw ConvertError.unreadable }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw ConvertError.unreadable }
        return DecodedImage(frames: [.init(image: image, delay: 0)], properties: [:], loopCount: 0)
    }

    private static func decodeSVG(_ url: URL) throws -> DecodedImage {
        guard let svg = NSImage(contentsOf: url), svg.size.width > 0, svg.size.height > 0 else { throw ConvertError.unreadable }
        // Vector art has no pixel size of its own, so render it large enough to stay sharp.
        let scale = min(4096 / max(svg.size.width, svg.size.height), max(1, 1024 / max(svg.size.width, svg.size.height)))
        let w = max(1, Int(svg.size.width * scale)), h = max(1, Int(svg.size.height * scale))
        guard let ctx = makeContext(width: w, height: h, space: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw ConvertError.unreadable }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        svg.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.current = previous
        guard let image = ctx.makeImage() else { throw ConvertError.unreadable }
        return DecodedImage(frames: [.init(image: image, delay: 0)], properties: [:], loopCount: 0)
    }

    // MARK: Rendering (resize + watermark)

    static func makeContext(width: Int, height: Int, space: CGColorSpace) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func targetSize(width: Int, height: Int, settings: ConvertSettings) -> (Int, Int) {
        guard settings.resize else { return (width, height) }
        let maxW = settings.maxWidth > 0 ? Double(settings.maxWidth) : .infinity
        let maxH = settings.maxHeight > 0 ? Double(settings.maxHeight) : .infinity
        let scale = min(1, maxW / Double(width), maxH / Double(height)) // never enlarge
        if scale >= 1 { return (width, height) }
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// Loaded once per run.
    struct WatermarkAsset {
        var image: CGImage?
        var text: String?
    }

    static func loadWatermark(_ settings: ConvertSettings) -> WatermarkAsset? {
        guard settings.watermark else { return nil }
        switch settings.watermarkKind {
        case .image:
            guard !settings.watermarkPath.isEmpty, let decoded = try? decode(URL(fileURLWithPath: settings.watermarkPath)) else { return nil }
            return WatermarkAsset(image: decoded.frames[0].image, text: nil)
        case .text:
            let text = settings.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : WatermarkAsset(image: nil, text: text)
        }
    }

    static func render(_ image: CGImage, size: (Int, Int), settings: ConvertSettings, watermark: WatermarkAsset?, opaque: Bool) -> Bitmap? {
        var space = CGColorSpace(name: CGColorSpace.sRGB)!
        if settings.keepProfile, let own = image.colorSpace, own.model == .rgb { space = own }
        guard let ctx = makeContext(width: size.0, height: size.1, space: space)
            ?? makeContext(width: size.0, height: size.1, space: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: size.0, height: size.1)
        if opaque {
            ctx.setFillColor(.white)
            ctx.fill(rect)
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        if let watermark { drawWatermark(watermark, in: ctx, settings: settings) }
        return Bitmap(context: ctx)
    }

    private static func drawWatermark(_ mark: WatermarkAsset, in ctx: CGContext, settings: ConvertSettings) {
        let canvas = CGSize(width: ctx.width, height: ctx.height)
        let margin = canvas.width * 0.03
        let width = max(8, canvas.width * settings.watermarkScale / 100)
        let alpha = CGFloat(settings.watermarkOpacity / 100)

        var markSize: CGSize
        var draw: (CGRect) -> Void
        if let image = mark.image {
            markSize = CGSize(width: width, height: width * CGFloat(image.height) / CGFloat(max(image.width, 1)))
            draw = { rect in ctx.draw(image, in: rect) }
        } else if let text = mark.text {
            let font = NSFont.systemFont(ofSize: max(8, width / CGFloat(max(text.count, 4)) * 1.7), weight: .semibold)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = font.pointSize / 10
            shadow.shadowOffset = NSSize(width: 0, height: -font.pointSize / 20)
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white, .shadow: shadow])
            markSize = string.size()
            draw = { rect in
                let previous = NSGraphicsContext.current
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                string.draw(at: rect.origin)
                NSGraphicsContext.current = previous
            }
        } else { return }

        let col = settings.watermarkPosition.rawValue % 3, row = settings.watermarkPosition.rawValue / 3
        let x: CGFloat = [margin, (canvas.width - markSize.width) / 2, canvas.width - markSize.width - margin][col]
        // Rows count from the top; Core Graphics counts from the bottom.
        let y: CGFloat = [canvas.height - markSize.height - margin, (canvas.height - markSize.height) / 2, margin][row]
        ctx.saveGState()
        ctx.setAlpha(alpha)
        draw(CGRect(origin: CGPoint(x: x, y: y), size: markSize))
        ctx.restoreGState()
    }

    // MARK: Encoding

    /// Decodes, renders and encodes one file, without touching the disk.
    static func encode(_ url: URL, settings: ConvertSettings, watermark: WatermarkAsset?) throws -> EncodedImage {
        let decoded = try decode(url)
        let format = resolvedFormat(settings, for: url)
        let opaque = format == .jpeg
        let first = decoded.frames[0].image
        let size = targetSize(width: first.width, height: first.height, settings: settings)
        let animated = decoded.isAnimated && (format == .webp || format == .gif)
        let sources = animated ? decoded.frames : [decoded.frames[0]]

        let rendered: [(Bitmap, TimeInterval)] = try sources.map { frame in
            guard let bitmap = render(frame.image, size: size, settings: settings, watermark: watermark, opaque: opaque) else {
                throw ConvertError.encodeFailed("out of memory")
            }
            return (bitmap, frame.delay)
        }

        switch format {
        case .webp, .auto:
            let data = try encodeWebP(rendered, loopCount: decoded.loopCount, settings: settings, properties: decoded.properties, size: size)
            return EncodedImage(data: data, fileExtension: "webp", width: size.0, height: size.1)
        case .png, .jpeg, .gif:
            let data = try encodeWithImageIO(rendered, format: format, loopCount: decoded.loopCount, settings: settings, properties: decoded.properties, size: size)
            return EncodedImage(data: data, fileExtension: format.fileExtension, width: size.0, height: size.1)
        }
    }

    private static func encodeWithImageIO(_ frames: [(Bitmap, TimeInterval)], format: OutputFormat, loopCount: Int,
                                          settings: ConvertSettings, properties: [CFString: Any], size: (Int, Int)) throws -> Data {
        let type: UTType = format == .png ? .png : format == .jpeg ? .jpeg : .gif
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, frames.count, nil) else {
            throw ConvertError.encodeFailed("no encoder")
        }
        if format == .gif {
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary)
        }
        for (bitmap, delay) in frames {
            guard let image = bitmap.image else { throw ConvertError.encodeFailed("render") }
            var props: [CFString: Any] = settings.keepMetadata ? metadataProperties(properties, size: size) : [:]
            if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = settings.quality / 100 }
            if format == .gif { props[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: delay] }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.encodeFailed("finalize") }
        return out as Data
    }

    private static func webPConfig(_ settings: ConvertSettings) throws -> WebPConfig {
        var config = WebPConfig()
        let preset = WebPPreset(rawValue: UInt32(min(max(settings.preset, 0), 5)))
        guard WebPConfigPreset(&config, preset, Float(settings.quality)) != 0 else { throw ConvertError.encodeFailed("config") }
        config.lossless = settings.lossless ? 1 : 0
        config.quality = Float(settings.quality) // in lossless mode this is the effort/size trade-off
        config.method = Int32(min(max(settings.method, 0), 6))
        config.use_sharp_yuv = settings.sharpYUV ? 1 : 0
        if settings.lossless { config.exact = 1 }
        guard WebPValidateConfig(&config) != 0 else { throw ConvertError.encodeFailed("invalid settings") }
        return config
    }

    private static func makePicture(_ bitmap: Bitmap, lossless: Bool) throws -> WebPPicture {
        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw ConvertError.encodeFailed("picture") }
        picture.width = Int32(bitmap.width)
        picture.height = Int32(bitmap.height)
        picture.use_argb = lossless ? 1 : 0
        let rgba = bitmap.straightRGBA()
        let ok = rgba.withUnsafeBufferPointer { WebPPictureImportRGBA(&picture, $0.baseAddress, Int32(bitmap.width * 4)) }
        guard ok != 0 else { WebPPictureFree(&picture); throw ConvertError.encodeFailed("import") }
        return picture
    }

    private static func encodeWebP(_ frames: [(Bitmap, TimeInterval)], loopCount: Int, settings: ConvertSettings,
                                   properties: [CFString: Any], size: (Int, Int)) throws -> Data {
        var config = try webPConfig(settings)
        var encoded: Data

        if frames.count > 1 {
            var options = WebPAnimEncoderOptions()
            guard WebPAnimEncoderOptionsInit(&options) != 0 else { throw ConvertError.encodeFailed("animation") }
            options.anim_params.loop_count = Int32(loopCount)
            guard let encoder = WebPAnimEncoderNew(Int32(size.0), Int32(size.1), &options) else { throw ConvertError.encodeFailed("animation") }
            defer { WebPAnimEncoderDelete(encoder) }
            var timestamp: Int32 = 0
            for (bitmap, delay) in frames {
                var picture = try makePicture(bitmap, lossless: settings.lossless)
                defer { WebPPictureFree(&picture) }
                guard WebPAnimEncoderAdd(encoder, &picture, timestamp, &config) != 0 else { throw ConvertError.encodeFailed("frame") }
                timestamp += Int32(delay * 1000)
            }
            guard WebPAnimEncoderAdd(encoder, nil, timestamp, nil) != 0 else { throw ConvertError.encodeFailed("finish") }
            var assembled = WebPData()
            WebPDataInit(&assembled)
            defer { WebPDataClear(&assembled) }
            guard WebPAnimEncoderAssemble(encoder, &assembled) != 0, let bytes = assembled.bytes else { throw ConvertError.encodeFailed("assemble") }
            encoded = Data(bytes: bytes, count: assembled.size)
        } else {
            var picture = try makePicture(frames[0].0, lossless: settings.lossless)
            defer { WebPPictureFree(&picture) }
            var writer = WebPMemoryWriter()
            WebPMemoryWriterInit(&writer)
            defer { WebPMemoryWriterClear(&writer) }
            let ok: Int32 = withUnsafeMutablePointer(to: &writer) { pointer in
                picture.writer = WebPMemoryWrite
                picture.custom_ptr = UnsafeMutableRawPointer(pointer)
                return WebPEncode(&config, &picture)
            }
            guard ok != 0, let bytes = writer.mem else {
                throw ConvertError.encodeFailed("code \(picture.error_code.rawValue)")
            }
            encoded = Data(bytes: bytes, count: writer.size)
        }

        var icc: Data?
        if settings.keepProfile { icc = frames[0].0.colorSpace.copyICCData() as Data? }
        let exif = settings.keepMetadata ? exifBlob(from: properties, size: size) : nil
        if icc != nil || exif != nil { encoded = try addChunks(to: encoded, icc: icc, exif: exif) }
        return encoded
    }

    /// Adds the ICC profile and EXIF block to a finished WebP file.
    private static func addChunks(to webp: Data, icc: Data?, exif: Data?) throws -> Data {
        try webp.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw ConvertError.encodeFailed("mux") }
            var input = WebPData(bytes: base, size: webp.count)
            guard let mux = WebPMuxCreate(&input, 1) else { throw ConvertError.encodeFailed("mux") }
            defer { WebPMuxDelete(mux) }
            for (fourCC, payload) in [("ICCP", icc), ("EXIF", exif)] {
                guard let payload else { continue }
                let status = payload.withUnsafeBytes { bytes -> WebPMuxError in
                    var chunk = WebPData(bytes: bytes.bindMemory(to: UInt8.self).baseAddress, size: payload.count)
                    return WebPMuxSetChunk(mux, fourCC, &chunk, 1)
                }
                guard status == WEBP_MUX_OK else { throw ConvertError.encodeFailed("metadata") }
            }
            var output = WebPData()
            WebPDataInit(&output)
            defer { WebPDataClear(&output) }
            guard WebPMuxAssemble(mux, &output) == WEBP_MUX_OK, let bytes = output.bytes else { throw ConvertError.encodeFailed("mux") }
            return Data(bytes: bytes, count: output.size)
        }
    }

    // MARK: Metadata

    /// EXIF, TIFF, GPS and IPTC from the source, minus the orientation (the pixels are already upright).
    private static func metadataProperties(_ source: [CFString: Any], size: (Int, Int)) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        if var exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = size.0
            exif[kCGImagePropertyExifPixelYDimension] = size.1
            out[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = source[key] { out[key] = value }
        }
        return out
    }

    /// Raw EXIF bytes for a WebP `EXIF` chunk: write a 1x1 JPEG carrying the metadata and lift out its APP1 segment.
    private static func exifBlob(from source: [CFString: Any], size: (Int, Int)) -> Data? {
        let props = metadataProperties(source, size: size)
        guard !props.isEmpty,
              let ctx = makeContext(width: 1, height: 1, space: CGColorSpace(name: CGColorSpace.sRGB)!),
              let pixel = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, pixel, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let bytes = [UInt8](out as Data)
        var i = 2
        while i + 4 <= bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1]
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if marker == 0xE1, length > 8, i + 2 + length <= bytes.count,
               bytes[(i + 4)..<(i + 10)].elementsEqual([0x45, 0x78, 0x69, 0x66, 0, 0]) { // "Exif\0\0"
                return Data(bytes[(i + 10)..<(i + 2 + length)])
            }
            if marker == 0xDA { break }
            i += 2 + length
        }
        return nil
    }

    // MARK: Naming and writing

    /// The file name each input will get. Plain function so the whole batch can be planned up front.
    static func outputName(for url: URL, index: Int, settings: ConvertSettings) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        var name: String
        switch settings.rename {
        case .keep: name = base
        case .prefix: name = settings.renameText + base
        case .suffix: name = base + settings.renameText
        case .replace: name = settings.renameFind.isEmpty ? base : base.replacingOccurrences(of: settings.renameFind, with: settings.renameText)
        case .numbering:
            let number = String(format: "%03d", settings.numberingStart + index)
            name = settings.renameText.isEmpty ? number : "\(settings.renameText)\(number)"
        }
        if name.isEmpty { name = base }
        if settings.keepOriginalExtension, !url.pathExtension.isEmpty { name += ".\(url.pathExtension)" }
        return name.replacingOccurrences(of: "/", with: "-")
    }

    /// A path for each input, unique within the batch and on disk.
    static func plan(_ urls: [URL], settings: ConvertSettings, stagingFolder: URL) -> [URL] {
        var used = Set<String>()
        let fm = FileManager.default
        return urls.enumerated().map { index, url in
            let folder: URL
            switch settings.destination {
            case .shelf: folder = stagingFolder
            case .sameFolder: folder = url.deletingLastPathComponent()
            case .folder: folder = settings.folderPath.isEmpty ? url.deletingLastPathComponent() : URL(fileURLWithPath: settings.folderPath, isDirectory: true)
            }
            let ext = resolvedFormat(settings, for: url).fileExtension
            let name = outputName(for: url, index: index, settings: settings)
            var candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
            var n = 2
            while used.contains(candidate.path) || fm.fileExists(atPath: candidate.path) {
                candidate = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
                n += 1
            }
            used.insert(candidate.path)
            return candidate
        }
    }

    /// Converts one file and writes it to `destination`.
    static func convert(_ url: URL, to destination: URL, settings: ConvertSettings, watermark: WatermarkAsset?) throws -> Int64 {
        let encoded = try encode(url, settings: settings, watermark: watermark)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded.data.write(to: destination, options: .atomic)
        } catch { throw ConvertError.writeFailed }
        if settings.keepDates,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            var copy: [FileAttributeKey: Any] = [:]
            if let created = attrs[.creationDate] { copy[.creationDate] = created }
            if let modified = attrs[.modificationDate] { copy[.modificationDate] = modified }
            try? FileManager.default.setAttributes(copy, ofItemAtPath: destination.path)
        }
        return Int64(encoded.data.count)
    }
}
