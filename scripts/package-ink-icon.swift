// Package the approved artwork without regenerating it.
// Run from any directory: swift /path/to/eimerrail/scripts/package-ink-icon.swift
import AppKit
import ImageIO

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let artwork = root.appendingPathComponent("design/icon/astra/eimerrail-ink.png")
let preview = root.appendingPathComponent("design/icon/astra/AppIcon-ink.png")
let output = root.appendingPathComponent("resources/AppIcon.icns")
let files = FileManager.default
let temporary = files.temporaryDirectory.appendingPathComponent("eimerrail-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? files.removeItem(at: temporary) }

func context(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
              bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "EimerrailIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "EimerrailIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG export failed: \(url.path)"])
    }
}

guard let source = CGImageSourceCreateWithURL(artwork as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot read \(artwork.path)")
}

// Match the project's macOS icon grid: 824px body within a 1024px canvas.
let canvas = context(1024)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let outline = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -6), blur: 12,
                 color: CGColor(gray: 0, alpha: 0.28))
canvas.addPath(outline)
canvas.setFillColor(CGColor(gray: 0, alpha: 1))
canvas.fillPath()
canvas.restoreGState()
canvas.addPath(outline)
canvas.clip()
canvas.interpolationQuality = .high
canvas.draw(image, in: body)
let master = canvas.makeImage()!
try writePNG(master, to: preview)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let resized = context(pixels)
        resized.interpolationQuality = .high
        resized.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let suffix = scale == 2 ? "@2x" : ""
        try writePNG(resized.makeImage()!, to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Packaged \(output.path) with all 10 macOS icon representations.")
print("Preview: \(preview.path)")
