#!/usr/bin/env swift
// Packages the owner's existing PESH export without redrawing the artwork.
// swift Tools/GenerateIcon.swift Sources/Resources/PeshMark.png /tmp/Pesh.iconset
// iconutil -c icns /tmp/Pesh.iconset -o Sources/Pesh.icns
import AppKit
import ImageIO

guard CommandLine.arguments.count == 3,
      let source = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let artwork = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Provide the Pesh PNG and an output .iconset directory.")
}
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let variants = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                ("128x128", 128), ("128x128@2x", 256), ("256x256", 256),
                ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, pixels) in variants {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let file = output.appendingPathComponent("icon_\(name).png")
    let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(file.path)") }
}
print("Pesh iconset packaged.")
