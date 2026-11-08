import AppKit
import CoreGraphics
import Foundation

enum IconError: Error, CustomStringConvertible {
    case invalidArguments
    case unreadableImage(String)
    case cannotCreateContext
    case cannotWriteImage(String)
    case cannotCreateICNS(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return "Uso: IconProcessor <app-source.png> <menu-source.png> <output-directory>"
        case .unreadableImage(let path):
            return "No se pudo leer la imagen: \(path)"
        case .cannotCreateContext:
            return "No se pudo crear el contexto gráfico"
        case .cannotWriteImage(let path):
            return "No se pudo escribir la imagen: \(path)"
        case .cannotCreateICNS(let path):
            return "No se pudo crear el archivo ICNS: \(path)"
        }
    }
}

func bigEndianUInt32(_ value: UInt32) -> Data {
    var number = value.bigEndian
    return Data(bytes: &number, count: MemoryLayout<UInt32>.size)
}

func createICNS(iconsetDirectory: String, outputPath: String) throws {
    // Modern ICNS files can contain PNG-compressed representations directly.
    // Keeping this tiny packer local also makes icon generation reproducible on
    // macOS releases where iconutil rejects otherwise valid iconsets.
    let representations: [(String, String)] = [
        ("icp4", "icon_16x16.png"),
        ("icp5", "icon_32x32.png"),
        ("icp6", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"),
        ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png")
    ]

    var body = Data()
    for (type, filename) in representations {
        let url = URL(fileURLWithPath: iconsetDirectory).appendingPathComponent(filename)
        let png = try Data(contentsOf: url)
        guard let typeData = type.data(using: .ascii), typeData.count == 4 else {
            throw IconError.cannotCreateICNS(outputPath)
        }
        body.append(typeData)
        body.append(bigEndianUInt32(UInt32(png.count + 8)))
        body.append(png)
    }

    var result = Data("icns".utf8)
    result.append(bigEndianUInt32(UInt32(body.count + 8)))
    result.append(body)
    try result.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
}

func loadCGImage(_ path: String) throws -> CGImage {
    guard
        let image = NSImage(contentsOfFile: path),
        let data = image.tiffRepresentation,
        let representation = NSBitmapImageRep(data: data),
        let cgImage = representation.cgImage
    else {
        throw IconError.unreadableImage(path)
    }
    return cgImage
}

func makeRGBAContext(width: Int, height: Int) throws -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.cannotCreateContext
    }
    return context
}

func writePNG(_ image: CGImage, to path: String) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw IconError.cannotWriteImage(path)
    }
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

func createAppIcon(source: CGImage, outputPath: String) throws {
    // ImageGen returns a preview checkerboard around the rendered tile. Crop to
    // the actual tile, then apply a real alpha mask for native macOS corners.
    let side = min(source.width, source.height)
    let margin = Int(Double(side) * 0.062)
    let cropSide = side - (margin * 2)
    let cropRect = CGRect(x: margin, y: margin, width: cropSide, height: cropSide)
    guard let cropped = source.cropping(to: cropRect) else {
        throw IconError.unreadableImage(outputPath)
    }

    let outputSize = 1024
    let context = try makeRGBAContext(width: outputSize, height: outputSize)
    context.clear(CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
    context.interpolationQuality = .high
    context.addPath(
        CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: outputSize, height: outputSize),
            cornerWidth: 230,
            cornerHeight: 230,
            transform: nil
        )
    )
    context.clip()
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))

    guard let result = context.makeImage() else { throw IconError.cannotCreateContext }
    try writePNG(result, to: outputPath)
}

func createMenuBarIcon(source: CGImage, outputPath: String) throws {
    let size = 128
    let context = try makeRGBAContext(width: size, height: size)
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))

    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
        throw IconError.cannotCreateContext
    }

    for y in 0..<size {
        for x in 0..<size {
            let index = ((y * size) + x) * 4
            let red = Double(pixels[index])
            let green = Double(pixels[index + 1])
            let blue = Double(pixels[index + 2])
            let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
            // Keep the dark glyph and remove the light preview checkerboard.
            let opacity = max(0, min(1, (195 - luminance) / 80))
            pixels[index] = 0
            pixels[index + 1] = 0
            pixels[index + 2] = 0
            pixels[index + 3] = UInt8(opacity * 255)
        }
    }

    guard let result = context.makeImage() else { throw IconError.cannotCreateContext }
    try writePNG(result, to: outputPath)
}

do {
    guard CommandLine.arguments.count == 4 else { throw IconError.invalidArguments }
    if CommandLine.arguments[1] == "--icns" {
        try createICNS(
            iconsetDirectory: CommandLine.arguments[2],
            outputPath: CommandLine.arguments[3]
        )
        exit(0)
    }
    let appSource = try loadCGImage(CommandLine.arguments[1])
    let menuSource = try loadCGImage(CommandLine.arguments[2])
    let outputDirectory = CommandLine.arguments[3]
    try FileManager.default.createDirectory(
        atPath: outputDirectory,
        withIntermediateDirectories: true
    )
    try createAppIcon(
        source: appSource,
        outputPath: "\(outputDirectory)/AppIcon.png"
    )
    try createMenuBarIcon(
        source: menuSource,
        outputPath: "\(outputDirectory)/MenuBarIconTemplate.png"
    )
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
