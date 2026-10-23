import AppKit

/// Hotch's own identity: a display outline with the notch filled in, plus
/// two ring gauges on the app icon. Everything is drawn in code so the status
/// bar glyph and the app icon share one source of truth and no image assets
/// need to ship in the bundle.
enum HotchIcon {

    // MARK: - Status bar glyph (template)

    /// Small template glyph for the menu bar: a display outline with the notch
    /// hanging from its top edge. Template style, so it follows the menu bar
    /// tint and highlights correctly when the menu is open.
    static func statusBarImage(pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize),
                            flipped: false) { rect in
            drawStatusGlyph(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hotch"
        return image
    }


    private static func drawStatusGlyph(in rect: NSRect) {
        let u = min(rect.width, rect.height) / 18

        // Display outline.
        let screen = NSRect(x: rect.minX + 1.5 * u,
                            y: rect.midY - 5.5 * u,
                            width: 15 * u,
                            height: 11 * u)
        let outline = NSBezierPath(roundedRect: screen, xRadius: 3 * u, yRadius: 3 * u)
        outline.lineWidth = 1.4 * u
        NSColor.black.setStroke()
        outline.stroke()

        // Notch, descending from the inside of the top edge. Bottom corners
        // rounded, top flush against the stroke.
        NSColor.black.setFill()
        notchPath(width: 6 * u,
                  height: 3.1 * u,
                  cornerRadius: 1.1 * u,
                  topCenter: NSPoint(x: screen.midX, y: screen.maxY - 0.4 * u)).fill()
    }

    /// A tab shape hanging down from `topCenter`: square top corners, rounded
    /// bottom corners, matching how the physical notch meets the bezel.
    private static func notchPath(width: CGFloat,
                                  height: CGFloat,
                                  cornerRadius r: CGFloat,
                                  topCenter: NSPoint) -> NSBezierPath {
        let x0 = topCenter.x - width / 2
        let x1 = topCenter.x + width / 2
        let yTop = topCenter.y
        let yBot = topCenter.y - height

        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0, y: yTop))
        path.line(to: NSPoint(x: x1, y: yTop))
        path.line(to: NSPoint(x: x1, y: yBot + r))
        path.appendArc(withCenter: NSPoint(x: x1 - r, y: yBot + r),
                       radius: r, startAngle: 0, endAngle: -90, clockwise: true)
        path.line(to: NSPoint(x: x0 + r, y: yBot))
        path.appendArc(withCenter: NSPoint(x: x0 + r, y: yBot + r),
                       radius: r, startAngle: -90, endAngle: -180, clockwise: true)
        path.close()
        return path
    }

    // MARK: - App icon (full colour)

    private static let clay = NSColor(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
    private static let indigo = NSColor(red: 0x7A / 255, green: 0x7D / 255, blue: 0xFF / 255, alpha: 1)

    /// Runtime app icon (alerts, Cmd-Tab). Same artwork the .icns is built from.
    static func appIconImage(pointSize: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            drawAppIcon(in: rect)
            return true
        }
    }

    /// PNG at an exact pixel size, for `--render-icon` iconset output.
    static func appIconPNG(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixels,
                                         pixelsHigh: pixels,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        drawAppIcon(in: NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// Dark rounded square in the panel's own idiom, the display-with-notch
    /// glyph, and the two brand-coloured ring gauges beneath the notch.
    static func drawAppIcon(in rect: NSRect) {
        let side = min(rect.width, rect.height)
        // Standard macOS icon grid: artwork inset ~10% on every side.
        let content = rect.insetBy(dx: side * 0.10, dy: side * 0.10)
        let c = content.width

        // Body: near black, faint lift at the top like the panel surface.
        let body = NSBezierPath(roundedRect: content,
                                xRadius: c * 0.225, yRadius: c * 0.225)
        NSGradient(starting: NSColor(red: 0.045, green: 0.045, blue: 0.055, alpha: 1),
                   ending: NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1))?
            .draw(in: body, angle: 90)

        // Specular border, same treatment as the panel edge.
        let borderWidth = max(1, c * 0.008)
        let border = NSBezierPath(roundedRect: content.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                                  xRadius: c * 0.22, yRadius: c * 0.22)
        border.lineWidth = borderWidth
        NSColor.white.withAlphaComponent(0.08).setStroke()
        border.stroke()

        // Display outline with the notch, sitting in the upper half.
        let screen = NSRect(x: content.midX - c * 0.31,
                            y: content.midY - c * 0.14,
                            width: c * 0.62,
                            height: c * 0.44)
        let stroke = c * 0.038
        let outline = NSBezierPath(roundedRect: screen,
                                   xRadius: c * 0.075, yRadius: c * 0.075)
        outline.lineWidth = stroke
        NSColor.white.withAlphaComponent(0.92).setStroke()
        outline.stroke()

        NSColor.white.withAlphaComponent(0.92).setFill()
        notchPath(width: c * 0.21,
                  height: c * 0.075,
                  cornerRadius: c * 0.028,
                  topCenter: NSPoint(x: screen.midX, y: screen.maxY - stroke / 2)).fill()

        // Ring gauges below the notch. Too small to read under 64px, so the
        // tiny sizes keep just the display glyph.
        guard side >= 64 else { return }
        let ringY = screen.midY - c * 0.045
        drawRing(center: NSPoint(x: screen.midX - c * 0.135, y: ringY),
                 radius: c * 0.078, lineWidth: c * 0.034, fraction: 0.63, color: clay)
        drawRing(center: NSPoint(x: screen.midX + c * 0.135, y: ringY),
                 radius: c * 0.078, lineWidth: c * 0.034, fraction: 0.82, color: indigo)
    }

    /// Remaining-style arc: full faint track, brand arc drawn clockwise from 12
    /// o'clock, round caps, matching RingGauge.
    private static func drawRing(center: NSPoint,
                                 radius: CGFloat,
                                 lineWidth: CGFloat,
                                 fraction: Double,
                                 color: NSColor) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius,
                        startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(0.14).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
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
