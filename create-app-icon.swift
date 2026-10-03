import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: create-app-icon.swift artwork.png output.png")
}

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create icon drawing context.")
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

let iconBounds = CGRect(x: 38, y: 38, width: 948, height: 948)
let background = CGPath(roundedRect: iconBounds, cornerWidth: 205, cornerHeight: 205, transform: nil)
context.addPath(background)
context.clip()

context.setFillColor(color(0, 0, 0))
context.fill(iconBounds)

guard let artwork = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let artworkCGImage = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Could not load icon artwork: \(CommandLine.arguments[1])")
}
let artworkSize = CGSize(width: artworkCGImage.width, height: artworkCGImage.height)
let scale = min(iconBounds.width / artworkSize.width, iconBounds.height / artworkSize.height)
let fittedSize = CGSize(width: artworkSize.width * scale, height: artworkSize.height * scale)
let artworkRect = CGRect(
    x: iconBounds.midX - fittedSize.width / 2,
    y: iconBounds.midY - fittedSize.height / 2,
    width: fittedSize.width,
    height: fittedSize.height
)
context.interpolationQuality = .none
context.draw(artworkCGImage, in: artworkRect)

guard let image = context.makeImage() else {
    fatalError("Could not render icon image.")
}
let bitmap = NSBitmapImageRep(cgImage: image)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon PNG.")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
