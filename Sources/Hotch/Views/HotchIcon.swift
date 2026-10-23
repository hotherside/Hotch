import AppKit

/// A companion curve and a single warm signal. The same silhouette is drawn at
/// every size, including the monochrome menu bar glyph; no notch is implied.
enum HotchIcon {
    static func statusBarImage(pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            drawMark(in: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02),
                     foreground: .black, signal: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hotch"
        return image
    }

    static func appIconImage(pointSize: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            drawAppIcon(in: rect)
            return true
        }
    }

    static func appIconPNG(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawAppIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func drawAppIcon(in rect: NSRect) {
        let side = min(rect.width, rect.height)
        let content = rect.insetBy(dx: side * 0.10, dy: side * 0.10)
        let body = NSBezierPath(roundedRect: content, xRadius: content.width * 0.225,
                                yRadius: content.width * 0.225)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = side * 0.035
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
        shadow.set()
        NSColor(white: 0.10, alpha: 1).setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: NSColor(red: 0.075, green: 0.083, blue: 0.10, alpha: 1),
                   ending: NSColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 1))?
            .draw(in: body, angle: 90)
        let edge = NSBezierPath(roundedRect: content.insetBy(dx: side * 0.004, dy: side * 0.004),
                               xRadius: content.width * 0.22, yRadius: content.width * 0.22)
        edge.lineWidth = side * 0.008
        NSColor.white.withAlphaComponent(0.12).setStroke()
        edge.stroke()
        drawMark(in: content.insetBy(dx: content.width * 0.08, dy: content.height * 0.08),
                 foreground: NSColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1),
                 signal: NSColor(red: 1, green: 0.55, blue: 0.40, alpha: 1))
    }

    private static func drawMark(in rect: NSRect, foreground: NSColor, signal: NSColor) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        let curve = NSBezierPath()
        curve.move(to: point(0.60, 0.84))
        curve.curve(to: point(0.60, 0.16), controlPoint1: point(0.17, 0.79), controlPoint2: point(0.17, 0.21))
        curve.lineWidth = rect.width * 0.12
        curve.lineCapStyle = .round
        foreground.setStroke()
        curve.stroke()
        let diameter = rect.width * 0.20
        let center = point(0.65, 0.50)
        signal.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                   width: diameter, height: diameter)).fill()
    }
}

// MARK: - Iconset rendering CLI

/// `--render-icon <dir>` writes a complete .iconset directory that iconutil
/// can compile into AppIcon.icns. Wired into the Makefile's app target.
enum IconCLI {
    static let entries: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    static func runBlockingAndExit(directory: String) -> Never {
        _ = NSApplication.shared

        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for entry in entries {
                guard let png = HotchIcon.appIconPNG(pixels: entry.pixels) else {
                    FileHandle.standardError.write(Data("render-icon: render failed at \(entry.pixels)px\n".utf8))
                    exit(1)
                }
                try png.write(to: dir.appendingPathComponent("\(entry.name).png"))
            }
        } catch {
            FileHandle.standardError.write(Data("render-icon: \(error)\n".utf8))
            exit(1)
        }

        print("iconset written to \(directory) (\(entries.count) images)")
        exit(0)
    }
}
