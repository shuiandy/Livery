// Builds the Livery app icon from the approved flat source artwork.
// Usage: swift Scripts/make-icon.swift Resources/AppIcon.icns [source.png]
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fputs("usage: swift Scripts/make-icon.swift <output.icns> [source.png]\n", stderr)
    exit(64)
}

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: #filePath)
let repositoryRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let defaultSource = repositoryRoot
    .appendingPathComponent("Design")
    .appendingPathComponent("Livery-AppIcon-concept-v3-flat.png")
let sourceURL = arguments.count >= 3
    ? URL(fileURLWithPath: arguments[2])
    : defaultSource

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fputs("could not load source image: \(sourceURL.path)\n", stderr)
    exit(66)
}

func render(size: Int) throws -> Data {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    sourceImage.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .copy,
        fraction: 1
    )

    guard let png = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

let outputURL = URL(fileURLWithPath: arguments[1])
let iconsetURL = outputURL.deletingPathExtension().appendingPathExtension("iconset")
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconsetURL) }

let representations = [
    ("16x16", 16),
    ("16x16@2x", 32),
    ("32x32", 32),
    ("32x32@2x", 64),
    ("128x128", 128),
    ("128x128@2x", 256),
    ("256x256", 256),
    ("256x256@2x", 512),
    ("512x512", 512),
    ("512x512@2x", 1024),
]

for (name, size) in representations {
    let destination = iconsetURL.appendingPathComponent("icon_\(name).png")
    try render(size: size).write(to: destination)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("iconutil failed with status \(iconutil.terminationStatus)\n", stderr)
    exit(iconutil.terminationStatus)
}

print("wrote \(outputURL.path) from \(sourceURL.path)")
