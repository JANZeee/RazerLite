// Original vector monogram, drawn using AppKit. Build-time tool only.
import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: render-app-icon.swift WORK_DIRECTORY OUTPUT.icns")
}
let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = work.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (size, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
                     (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
                     (256, "icon_256x256"), (512, "icon_256x256@2x"),
                     (512, "icon_512x512"), (1024, "icon_512x512@2x")] {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Bitmap unavailable") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let path = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 20
    shadow.set()
    NSGradient(starting: NSColor(srgbRed: 0.51, green: 0.95, blue: 0.33, alpha: 1),
               ending: NSColor(srgbRed: 0.31, green: 0.77, blue: 0.17, alpha: 1))!.draw(in: path, angle: -90)
    NSShadow().set()
    let font = NSFont.systemFont(ofSize: 585, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.08, alpha: 1)]
    let letter = NSAttributedString(string: "R", attributes: attributes)
    let textSize = letter.size()
    letter.draw(at: NSPoint(x: (1024 - textSize.width) / 2, y: (1024 - textSize.height) / 2 + 15))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG unavailable") }
    try png.write(to: iconset.appendingPathComponent(name + ".png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", CommandLine.arguments[2]]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
