import AppKit

/// The picture behind the icons when someone opens the Hotch disk image.
///
/// This started as damage control for one dialog. macOS shows an unnotarized app
/// the same warning whatever the app is — "Apple could not verify that Hotch is
/// free of malware" — with **Move to Bin** as the highlighted button and **Done**
/// as the one that means "carry on". The honest reaction to that is to delete the
/// app you just downloaded, and that is what the first tester did. Gatekeeper draws
/// it before a single line of Hotch has run, so the app cannot reword or pre-empt
/// it; the only levers were notarizing and warning the user first, and this window
/// was the warning.
///
/// **Notarization landed, so the warning had to go.** A card describing a dialog
/// that no longer appears sends people looking for a prompt that is not there,
/// which is its own kind of confusing. The card now says where the app went and how
/// to reach it — the genuinely useful thing for an app with no Dock icon and no
/// window, which is the next thing people ask about.
///
/// Drawn in code for the same reason the app icon is: no binary assets to keep in
/// step with the copy, and the wording lives in version control next to the
/// behaviour it describes.
enum InstallerArt {
    /// Finder window content size, in points. The icon positions the Makefile
    /// hands to Finder are in this same space, measured from the top left, so
    /// the two have to agree.
    static let size = NSSize(width: 660, height: 462)

    /// Where Finder is told to put the two icons, from the top left.
    static let appIconCenter = CGPoint(x: 178, y: 214)
    static let applicationsIconCenter = CGPoint(x: 482, y: 214)

    // Light background with dark ink. Finder draws its own icon labels in a
    // colour that follows the viewer's appearance, and a light background is the
    // one that keeps *this* text readable in both — the labels themselves are
    // Finder's business and it is why there is generous room around the icons.
    private static let ink = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)
    private static let inkSoft = NSColor(calibratedRed: 0.32, green: 0.33, blue: 0.36, alpha: 1)
    private static let clay = NSColor(calibratedRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)

    // MARK: - Entry point

    /// A two-representation TIFF: 1x and 2x sharing one logical size, which is
    /// how a disk image background stays crisp on a Retina display.
    ///
    /// LZW rather than uncompressed. Both representations together are around
    /// 6 MB raw, which is four times the entire app and would dominate the
    /// download for a picture of some text; flat colour and text compress to a
    /// fraction of that with no loss.
    static func backgroundTIFF() -> Data? {
        guard let low = bitmap(scale: 1), let high = bitmap(scale: 2) else { return nil }
        let image = NSImage(size: size)
        image.addRepresentation(low)
        image.addRepresentation(high)
        return image.tiffRepresentation(using: .lzw, factor: 0)
    }

    private static func bitmap(scale: Int) -> NSBitmapImageRep? {
        let pixelsWide = Int(size.width) * scale
        let pixelsHigh = Int(size.height) * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: pixelsWide,
                                        pixelsHigh: pixelsHigh,
                                        bitsPerSample: 8,
                                        samplesPerPixel: 4,
                                        hasAlpha: true,
                                        isPlanar: false,
                                        colorSpaceName: .calibratedRGB,
                                        bytesPerRow: 0,
                                        bitsPerPixel: 0) else { return nil }
        // Declaring the logical size is what makes this a 2x representation
        // rather than a differently sized image.
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        // No manual scaling here: because `rep.size` was set in points while the
        // backing store is `scale` times larger in pixels, the context already
        // carries that transform. Applying it a second time drew the 2x pass at
        // 4x and pushed the header off the top of the canvas.
        draw(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()
        return rep
    }

    // MARK: - Composition

    /// Coordinates here are AppKit's: origin bottom left. Finder's icon
    /// positions are top left, so anything shared with the Makefile is converted
    /// through `flip`.
    private static func flip(_ y: CGFloat) -> CGFloat { size.height - y }

    static func draw(in rect: NSRect) {
        NSColor(calibratedRed: 0.955, green: 0.95, blue: 0.94, alpha: 1).setFill()
        rect.fill()

        drawHeader(in: rect)
        drawArrow()
        drawSteps(in: rect)
    }

    private static func drawHeader(in rect: NSRect) {
        // The app's own glyph, so the window is recognisably Hotch before
        // Finder has drawn anything.
        let badge = NSRect(x: 40, y: flip(78), width: 38, height: 38)
        HotchIcon.drawAppIcon(in: badge.insetBy(dx: -4, dy: -4))

        text("Hotch",
             font: .systemFont(ofSize: 24, weight: .bold),
             color: ink,
             at: NSRect(x: 92, y: flip(72), width: 420, height: 32))

        text("Claude, Codex and Gemini usage, in your notch.",
             font: .systemFont(ofSize: 12.5, weight: .regular),
             color: inkSoft,
             at: NSRect(x: 92, y: flip(94), width: 460, height: 20))
    }

    /// Drag direction, from the app to the Applications alias.
    private static func drawArrow() {
        let y = flip(appIconCenter.y)
        let from = appIconCenter.x + 62
        let to = applicationsIconCenter.x - 62
        let head: CGFloat = 13

        inkSoft.withAlphaComponent(0.55).setStroke()
        let shaft = NSBezierPath()
        shaft.move(to: CGPoint(x: from, y: y))
        shaft.line(to: CGPoint(x: to - head + 2, y: y))
        shaft.lineWidth = 2.5
        shaft.lineCapStyle = .round
        // Dashed, so it reads as a gesture to perform rather than a connector
        // between two things that are already related.
        shaft.setLineDash([9, 7], count: 2, phase: 0)
        shaft.stroke()

        inkSoft.withAlphaComponent(0.55).setFill()
        let tip = NSBezierPath()
        tip.move(to: CGPoint(x: to + 4, y: y))
        tip.line(to: CGPoint(x: to - head, y: y + head * 0.62))
        tip.line(to: CGPoint(x: to - head, y: y - head * 0.62))
        tip.close()
        tip.fill()

        text("drag",
             font: .systemFont(ofSize: 11, weight: .semibold),
             color: inkSoft.withAlphaComponent(0.7),
             at: NSRect(x: from, y: y + 8, width: to - from, height: 16),
             alignment: .center)
    }

    private static func drawSteps(in rect: NSRect) {
        let card = NSRect(x: 34, y: 26, width: rect.width - 68, height: 132)
        NSColor.white.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
        inkSoft.withAlphaComponent(0.16).setStroke()
        let border = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        border.lineWidth = 1
        border.stroke()

        text("AFTER YOU DRAG IT ACROSS",
             font: .systemFont(ofSize: 9.5, weight: .bold),
             color: clay,
             at: NSRect(x: card.minX + 18, y: card.maxY - 26, width: card.width - 36, height: 14),
             tracking: 1.2)

        // This card used to be a warning: the build was signed but not notarized,
        // macOS said it "cannot verify" the app, and the highlighted button in that
        // dialog was **Move to Bin** — which the first recipient duly clicked,
        // deleting the app instead of installing it. The build is notarized now, so
        // the dialog is gone and the warning would send people looking for a prompt
        // that never appears. What is left is what someone actually needs.
        let steps: [(String, String)] = [
            ("1", "Open **Hotch** from your Applications folder. It opens straight away."),
            ("2", "Look for the **notch icon in your menu bar** \u{2014} no Dock icon, no window."),
            ("3", "Settings opens once, to connect an account. **Hover the notch** any time."),
        ]

        var y = card.maxY - 52
        for (number, body) in steps {
            let bullet = NSRect(x: card.minX + 18, y: y - 1, width: 16, height: 15)
            clay.withAlphaComponent(0.14).setFill()
            NSBezierPath(ovalIn: bullet).fill()
            text(number,
                 font: .systemFont(ofSize: 9, weight: .bold),
                 color: clay,
                 at: NSRect(x: bullet.minX, y: bullet.minY + 1, width: bullet.width, height: 12),
                 alignment: .center)

            richText(body,
                     size: 11.5,
                     color: ink,
                     at: NSRect(x: card.minX + 42, y: y, width: card.width - 60, height: 16))
            y -= 25
        }

        text(HotchAbout.credit,
             font: .systemFont(ofSize: 9.5, weight: .regular),
             color: inkSoft.withAlphaComponent(0.75),
             at: NSRect(x: card.minX, y: 8, width: card.width, height: 12),
             alignment: .center)
    }

    // MARK: - Text helpers

    private static func text(_ string: String,
                             font: NSFont,
                             color: NSColor,
                             at rect: NSRect,
                             alignment: NSTextAlignment = .left,
                             tracking: CGFloat = 0) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        NSAttributedString(string: string, attributes: attributes).draw(in: rect)
    }

    /// Minimal `**bold**` support, so the one word that matters in each step can
    /// carry weight without hand-splitting every string at the call site.
    private static func richText(_ markup: String,
                                 size: CGFloat,
                                 color: NSColor,
                                 at rect: NSRect) {
        let result = NSMutableAttributedString()
        var bold = false
        for chunk in markup.components(separatedBy: "**") {
            if !chunk.isEmpty {
                result.append(NSAttributedString(string: chunk, attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular),
                    .foregroundColor: color
                ]))
            }
            bold.toggle()
        }
        result.draw(in: rect)
    }
}

// MARK: - CLI

enum InstallerArtCLI {
    static func runBlockingAndExit(path: String) -> Never {
        _ = NSApplication.shared

        guard let tiff = InstallerArt.backgroundTIFF() else {
            FileHandle.standardError.write(Data("render-dmg-background: render failed\n".utf8))
            exit(1)
        }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try tiff.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("render-dmg-background: \(error)\n".utf8))
            exit(1)
        }

        // The Makefile needs the same numbers to position icons in Finder, so
        // they are reported rather than duplicated in two places.
        let size = InstallerArt.size
        print("dmg background written to \(path)"
              + " (window \(Int(size.width))x\(Int(size.height)),"
              + " app at \(Int(InstallerArt.appIconCenter.x)),\(Int(InstallerArt.appIconCenter.y)),"
              + " applications at \(Int(InstallerArt.applicationsIconCenter.x)),\(Int(InstallerArt.applicationsIconCenter.y)))")
        exit(0)
    }
}
