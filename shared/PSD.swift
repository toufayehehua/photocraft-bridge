import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib

/// A standard layered PSD is the interchange file; only its saved composite is sent to XD.
struct PSDWorkFile {
    private enum Failure: Error { case invalidFile, unsupportedFormat, missingComposite, imageEncoding }
    private static let byteLimit = 512 * 1024 * 1024
    private static let pixelLimit = 100_000_000

    static func create(source: URL, destination: URL) throws {
        let file = try load(source)
        guard let decoder = CGImageSourceCreateWithData(file as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(decoder, 0, nil) else { throw Failure.invalidFile }
        let width = image.width, height = image.height
        try validate(width: width, height: height)
        let pixels = width * height
        guard pixels <= (byteLimit - 1024) / 8 else { throw Failure.invalidFile }
        var rgba = [UInt8](repeating: 0, count: pixels * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.imageEncoding }
        var planes = [UInt8](repeating: 0, count: pixels * 4)
        for i in 0..<pixels {
            let alpha = Int(rgba[i * 4 + 3])
            for c in 0..<3 {
                planes[c * pixels + i] = alpha == 0 ? 0 : UInt8(min(255, (Int(rgba[i * 4 + c]) * 255 + alpha / 2) / alpha))
            }
            planes[3 * pixels + i] = UInt8(alpha)
        }

        var layer = Data()
        layer.u32(0); layer.u32(0); layer.u32(height); layer.u32(width)
        layer.u16(4)
        for channel in [0, 1, 2, -1] { layer.u16(channel); layer.u32(pixels + 2) }
        layer.append(Data("8BIMnorm".utf8)); layer.append(contentsOf: [255, 0, 0, 0])
        var extra = Data()
        extra.u32(0); extra.u32(0)
        extra.append(contentsOf: [5] + Array("Image".utf8) + [0, 0])
        layer.u32(extra.count); layer.append(extra)
        var layers = Data()
        layers.u16(-1) // A negative layer count marks the merged fourth channel as transparency.
        layers.append(layer)
        for channel in 0..<4 {
            layers.u16(0)
            layers.append(contentsOf: planes[(channel * pixels)..<((channel + 1) * pixels)])
        }
        if layers.count % 2 != 0 { layers.append(0) }
        var mask = Data()
        mask.u32(layers.count); mask.append(layers); mask.u32(0)
        var output = Data("8BPS".utf8)
        output.u16(1); output.append(Data(repeating: 0, count: 6))
        output.u16(4); output.u32(height); output.u32(width); output.u16(8); output.u16(3)
        var resources = Data()
        if let profile = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData() {
            resources.append(Data("8BIM".utf8)); resources.u16(1039); resources.u16(0)
            resources.u32(CFDataGetLength(profile)); resources.append(profile as Data)
            if resources.count % 2 != 0 { resources.append(0) }
        }
        output.u32(0); output.u32(resources.count); output.append(resources)
        output.u32(mask.count); output.append(mask)
        output.u16(0)
        // PSD composite RGB is matted against white; layer channels above stay straight.
        for c in 0..<3 {
            for i in 0..<pixels {
                let alpha = Int(planes[3 * pixels + i])
                output.append(UInt8((Int(planes[c * pixels + i]) * alpha + 127) / 255 + 255 - alpha))
            }
        }
        output.append(contentsOf: planes[(3 * pixels)..<(4 * pixels)])
        try output.write(to: destination, options: .atomic)
    }

    static func render(source: URL, destination: URL) throws {
        var reader = Reader(data: try load(source))
        guard try reader.read(4) == Data("8BPS".utf8), try reader.u16() == 1 else { throw Failure.unsupportedFormat }
        try reader.skip(6)
        let channels = try reader.u16(), height = try reader.u32(), width = try reader.u32()
        let depth = try reader.u16(), mode = try reader.u16()
        try validate(width: width, height: height)
        guard mode == 3, [8, 16].contains(depth), (3...56).contains(channels) else { throw Failure.unsupportedFormat }
        let pixels = width * height, bytes = depth / 8
        let rowBytes = width * bytes, expected = pixels * channels * bytes
        guard expected <= byteLimit else { throw Failure.invalidFile }
        try reader.skipSection()
        let colorSpace = try checkResources(try reader.section())
        let alpha = try hasMergedAlpha(try reader.section())
        guard !alpha || channels >= 4 else { throw Failure.invalidFile }
        let compression = try reader.u16()
        var planes: [UInt8]
        switch compression {
        case 0:
            planes = Array(try reader.read(expected))
        case 1:
            var counts = [Int]()
            for _ in 0..<(height * channels) { counts.append(try reader.u16()) }
            planes = [UInt8](); planes.reserveCapacity(expected)
            for count in counts { try unpack(try reader.read(count), rowBytes: rowBytes, into: &planes) }
        case 2, 3:
            let packed = try reader.read(reader.remaining)
            guard !packed.isEmpty else { throw Failure.invalidFile }
            planes = [UInt8](repeating: 0, count: expected)
            var length = uLongf(expected)
            let status = planes.withUnsafeMutableBytes { output in
                packed.withUnsafeBytes { input in
                    uncompress(output.bindMemory(to: Bytef.self).baseAddress!, &length,
                        input.bindMemory(to: Bytef.self).baseAddress!, uLong(packed.count))
                }
            }
            guard status == Z_OK, length == expected else { throw Failure.invalidFile }
            if compression == 3 {
                for row in stride(from: 0, to: expected, by: rowBytes) {
                    for x in 1..<width {
                        let index = row + x * bytes
                        if bytes == 1 { planes[index] = planes[index] &+ planes[index - 1] }
                        else {
                            let sample = ((Int(planes[index]) << 8) | Int(planes[index + 1]))
                                + ((Int(planes[index - 2]) << 8) | Int(planes[index - 1]))
                            planes[index] = UInt8(truncatingIfNeeded: sample >> 8)
                            planes[index + 1] = UInt8(truncatingIfNeeded: sample)
                        }
                    }
                }
            }
        default: throw Failure.unsupportedFormat
        }
        func sample(_ channel: Int, _ pixel: Int) -> Double {
            let i = (channel * pixels + pixel) * bytes
            return bytes == 1 ? Double(planes[i]) / 255 : Double((Int(planes[i]) << 8) | Int(planes[i + 1])) / 65535
        }
        var rgba = [UInt8](repeating: 0, count: pixels * 4)
        for i in 0..<pixels {
            let a = alpha ? sample(3, i) : 1
            for c in 0..<3 {
                let color = a == 0 ? 0 : (sample(c, i) - (1 - a)) / a
                rgba[i * 4 + c] = UInt8((max(0, min(1, color)) * 255).rounded())
            }
            rgba[i * 4 + 3] = UInt8((a * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let encoder = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Failure.imageEncoding }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw Failure.imageEncoding }
    }

    private static func load(_ file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= byteLimit else { throw Failure.invalidFile }
        return try Data(contentsOf: file, options: .mappedIfSafe)
    }

    private static func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 30_000, height <= 30_000,
              width * height <= pixelLimit else { throw Failure.invalidFile }
    }

    private static func checkResources(_ data: Data) throws -> CGColorSpace {
        var reader = Reader(data: data)
        var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        while reader.remaining > 0 {
            guard try reader.read(4) == Data("8BIM".utf8) else { throw Failure.invalidFile }
            let id = try reader.u16(), name = try reader.byte()
            try reader.skip(name + ((name + 1) % 2))
            let resource = try reader.section()
            if id == 1057, resource.count >= 5, resource[4] == 0 { throw Failure.missingComposite }
            if id == 1039, let profile = CGColorSpace(iccData: resource as CFData), profile.model == .rgb { colorSpace = profile }
            if resource.count % 2 != 0 { try reader.skip(1) }
        }
        return colorSpace
    }

    private static func hasMergedAlpha(_ data: Data) throws -> Bool {
        guard !data.isEmpty else { return false }
        var reader = Reader(data: data)
        let layers = try reader.section()
        var alpha = layers.count >= 2 && (layers[0] & 0x80) != 0
        if reader.remaining == 0 { return alpha }
        try reader.skipSection() // Global layer mask.
        while reader.remaining >= 12 {
            let signature = try reader.read(4), key = try reader.read(4)
            guard signature == Data("8BIM".utf8) else { throw Failure.unsupportedFormat }
            let block = try reader.section()
            if ["Mtrn", "Mt16", "Mt32"].contains(String(data: key, encoding: .ascii) ?? "") { alpha = true }
            if ["Lr16", "Lr32", "Layr"].contains(String(data: key, encoding: .ascii) ?? ""), block.count >= 2,
                (block[0] & 0x80) != 0 { alpha = true }
            let padding = (4 - block.count % 4) % 4
            if padding > 0 { try reader.skip(padding) }
        }
        return alpha
    }

    private static func unpack(_ data: Data, rowBytes: Int, into output: inout [UInt8]) throws {
        var reader = Reader(data: data)
        let end = output.count + rowBytes
        while output.count < end {
            let code = Int(Int8(bitPattern: UInt8(try reader.byte())))
            if code >= 0 {
                guard code + 1 <= end - output.count else { throw Failure.invalidFile }
                output.append(contentsOf: try reader.read(code + 1))
            } else if code > -128 {
                guard 1 - code <= end - output.count else { throw Failure.invalidFile }
                output.append(contentsOf: repeatElement(UInt8(try reader.byte()), count: 1 - code))
            }
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0
        var remaining: Int { data.count - offset }
        mutating func byte() throws -> Int {
            guard remaining >= 1 else { throw Failure.invalidFile }
            defer { offset += 1 }
            return Int(data[offset])
        }
        mutating func u16() throws -> Int { (try byte() << 8) | (try byte()) }
        mutating func u32() throws -> Int { (try u16() << 16) | (try u16()) }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= remaining else { throw Failure.invalidFile }
            offset += count
        }
        mutating func read(_ count: Int) throws -> Data {
            let start = offset
            try skip(count)
            return data.subdata(in: start..<offset)
        }
        mutating func section() throws -> Data {
            let size = try u32()
            return try read(size)
        }
        mutating func skipSection() throws {
            let size = try u32()
            try skip(size)
        }
    }
}

private extension Data {
    mutating func u16(_ value: Int) {
        var bigEndian = UInt16(truncatingIfNeeded: value).bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
    mutating func u32(_ value: Int) {
        var bigEndian = UInt32(value).bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
