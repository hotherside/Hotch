import AVFoundation
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `--render-tour <directory>`: films the real edge tab and card on the demo
/// fixture for the README, without putting anything on the screen.
///
/// The windows are the app's own, laid out and animated as usual but unseen
/// (`NotchPanel.unseen`), and a scripted pointer drives them through the real
/// hover and click logic: the tab tints and opens, the card's four tabs are
/// clicked in turn, the pointer leaves and the card closes, then an alert
/// speaks beside the tab. Each frame draws what those windows show onto a
/// plain backdrop, with a soft shadow and the arrow cursor, where the screen
/// recording this replaces needed the person's screen and mouse for a minute.
///
/// Writes `hotch-tour.mp4` (1520 x 1200, 30 fps: a dark take, then a light
/// one) and `hotch-tour.gif` (the dark take, 960 px wide, 15 fps), plus a
/// PNG still of each take with the AI tab open.
@MainActor
enum TourFilm {
    private final class Pointer {
        var point = CGPoint(x: -10_000, y: -10_000)
        var pressedUntil: TimeInterval = -1
    }

    /// What one take does, in seconds from its start.
    private enum Step {
        case glide(to: () -> CGPoint, over: TimeInterval)
        case click(PanelPage)
        case alert
        case still(String)
    }

    /// The screen region filmed, in points: the right edge of the screen
    /// with the tab and the tallest card, and room to the left for the
    /// pointer to come from. The movie draws it at the screen's own 2x.
    private static let regionSize = CGSize(width: 760, height: 600)
    private static let movieSize = CGSize(width: 1520, height: 1200)
    private static let gifSize = CGSize(width: 960, height: 758)
    private static let fps: Int32 = 30
    private static let gifEvery = 2

    static func runAndExit(directory: String) -> Never {
        NotchPanel.unseen = true
        SnapshotRendering.everywhere = true
        Haptics.muted = true
        let suite = "com.hojaejung.hotch.tour-film"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        HotchPrefs.defaultsOverride = UserDefaults(suiteName: suite)
        let history = UsageHistoryStore(persists: false)
        Snapshot.seedDemoHistory(into: history)
        UsageHistoryStore.sharedOverride = history
        AppSettings.displayModeOverride = .used
        AppSettings.enabledProvidersOverride = ["claude", "codex"]

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        app.finishLaunching()

        let prefs = HotchPrefs.shared
        prefs.edgeSide = .right
        prefs.edgeOffset = 0.32
        let deps = CardMotionCheck.demoDeps()
        let card = CardPanelController(deps: deps)
        let rail = RailController(card: card)
        let pointer = Pointer()
        rail.pointer = PointerSource(location: { pointer.point }, buttons: { 0 }, watchClicks: { _ in nil })
        rail.start()
        guard let screen = rail.screen else {
            print("no display to lay the tab out on")
            exit(1)
        }
        spin(0.4)
        print("tab readouts: \(rail.state.readouts)")

        // Frame the tab and the tallest card: open it once to see where it
        // lands, then centre the region on the two.
        deps.pages.select(.ai)
        rail.expand(pinned: true)
        spin(0.8)
        let reach = rail.panel.frame.union(card.frame)
        rail.collapse()
        spin(0.6)
        deps.pages.select(.home)
        spin(0.4)
        let region = CGRect(x: screen.frame.maxX - regionSize.width,
                            y: min(max(reach.midY - regionSize.height / 2, screen.frame.minY),
                                   screen.frame.maxY - regionSize.height),
                            width: regionSize.width, height: regionSize.height)

        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let movieURL = url.appendingPathComponent("hotch-tour.mp4")
        let gifURL = url.appendingPathComponent("hotch-tour.gif")
        try? FileManager.default.removeItem(at: movieURL)
        try? FileManager.default.removeItem(at: gifURL)

        guard let writer = try? AVAssetWriter(outputURL: movieURL, fileType: .mp4) else {
            print("cannot write \(movieURL.path)")
            exit(1)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(movieSize.width),
            AVVideoHeightKey: Int(movieSize.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 9_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
            ],
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(movieSize.width),
            kCVPixelBufferHeightKey as String: Int(movieSize.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        guard let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, 400, nil) else {
            print("cannot write \(gifURL.path)")
            exit(1)
        }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

        var frameOffset: Int64 = 0
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            deps.pages.select(.home)
            pointer.point = CGPoint(x: region.minX + 120, y: region.midY - 150)
            spin(0.8)
            let frames = take(rail: rail, card: card, pages: deps.pages, pointer: pointer, region: region,
                              dark: dark, adaptor: adaptor, input: input, frameOffset: frameOffset,
                              gif: dark ? gif : nil, stills: url)
            frameOffset += frames
            spin(0.6)
        }

        input.markAsFinished()
        var finished = false
        writer.finishWriting { finished = true }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let gifDone = CGImageDestinationFinalize(gif)
        rail.stop()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        print(writer.status == .completed ? "wrote \(movieURL.path) (\(frameOffset) frames)" : "movie failed: \(String(describing: writer.error))")
        print(gifDone ? "wrote \(gifURL.path)" : "gif failed")
        exit(writer.status == .completed && gifDone ? 0 : 1)
    }

    // MARK: A take

    /// Plays the script once, writing a frame whenever one is due. Returns
    /// how many frames of time it covered.
    private static func take(rail: RailController, card: CardPanelController, pages: PopoverPageModel,
                             pointer: Pointer, region: CGRect, dark: Bool,
                             adaptor: AVAssetWriterInputPixelBufferAdaptor, input: AVAssetWriterInput,
                             frameOffset: Int64, gif: CGImageDestination?, stills: URL) -> Int64 {
        let tab = rail.restingFrame
        let face = CGPoint(x: tab.midX, y: tab.midY)
        let rest = pointer.point
        // The four tab symbols, from the card's top right corner.
        func symbol(_ page: PanelPage) -> CGPoint {
            let across: [CGFloat] = [223, 258.5, 294.5, 330]
            return CGPoint(x: card.frame.minX + across[page.rawValue], y: card.frame.maxY - 30)
        }
        var alert = LiveActivity(icon: .brand("codex"), leading: "Refactor upload\u{2026}", trailing: "needs approval",
                                 tint: .white, trailingTint: HP.amber, dot: true, key: "need-tour")
        alert.hold = 2.6

        let script: [(TimeInterval, Step)] = [
            (0.6, .glide(to: { face }, over: 0.6)),
            (2.3, .glide(to: { symbol(.ai) }, over: 0.55)),
            (3.0, .click(.ai)),
            (4.6, .still(dark ? "tour-ai-dark" : "tour-ai-light")),
            (5.4, .glide(to: { symbol(.mac) }, over: 0.4)),
            (6.0, .click(.mac)),
            (7.6, .glide(to: { symbol(.desk) }, over: 0.35)),
            (8.2, .click(.desk)),
            (9.8, .glide(to: { symbol(.home) }, over: 0.45)),
            (10.4, .click(.home)),
            (11.9, .glide(to: { rest }, over: 0.6)),
            (13.4, .alert),
        ]
        let length: TimeInterval = 16.6

        var next = 0
        var glide: (from: CGPoint, to: CGPoint, start: TimeInterval, length: TimeInterval)?
        var lastFrame: Int64 = -1
        let start = Date()
        while true {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
            let t = Date().timeIntervalSince(start)
            if t >= length { break }
            while next < script.count, script[next].0 <= t {
                switch script[next].1 {
                case .glide(let to, let over):
                    glide = (pointer.point, to(), t, over)
                case .click(let page):
                    pointer.pressedUntil = t + 0.12
                    pages.select(page)
                case .alert:
                    rail.present(alert) {}
                case .still(let name):
                    if let image = compose(region: region, size: movieSize, dark: dark, flat: false, pointer: pointer,
                                           t: t) {
                        write(png: image, to: stills.appendingPathComponent("\(name).png"))
                    }
                }
                next += 1
            }
            if let g = glide {
                let p = min(1, (t - g.start) / g.length)
                let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
                pointer.point = CGPoint(x: g.from.x + (g.to.x - g.from.x) * e, y: g.from.y + (g.to.y - g.from.y) * e)
                if p >= 1 { glide = nil }
            }

            let frame = Int64(t * Double(fps))
            guard frame > lastFrame, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { continue }
            lastFrame = frame
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            let captured = capture(region: region)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(movieSize.width),
                                       height: Int(movieSize.height), bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                           | CGBitmapInfo.byteOrder32Little.rawValue) {
                draw(captured, into: context, region: region, size: movieSize, dark: dark, flat: false,
                     pointer: pointer, t: t)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: frameOffset + frame, timescale: fps))

            if let gif, frame % Int64(gifEvery) == 0,
               let image = render(captured, region: region, size: gifSize, dark: dark, flat: true, pointer: pointer, t: t) {
                // GIF delays are whole hundredths: alternate them so the
                // loop keeps the take's own length instead of drifting.
                let shown = Double(frame) / Double(fps)
                let delay = (((shown + Double(gifEvery) / Double(fps)) * 100).rounded() - (shown * 100).rounded()) / 100
                CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]] as CFDictionary)
            }
        }
        return Int64(length * Double(fps))
    }

    // MARK: Drawing

    /// What each of Hotch's windows over the region shows, back to front.
    private static func capture(region: CGRect) -> [(CGRect, CGImage)] {
        // Unseen windows are left out of `orderedWindows`; level, then the
        // stacking within it, puts them back in the order they are drawn.
        NSApp.windows.sorted { ($0.level.rawValue, -$0.orderedIndex) < ($1.level.rawValue, -$1.orderedIndex) }
            .compactMap { window in
            guard window is NotchPanel, window.isVisible, window.frame.intersects(region),
                  let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.cgImage.map { (window.frame, $0) }
        }
    }

    private static func compose(region: CGRect, size: CGSize, dark: Bool, flat: Bool, pointer: Pointer,
                                t: TimeInterval) -> CGImage? {
        render(capture(region: region), region: region, size: size, dark: dark, flat: flat, pointer: pointer, t: t)
    }

    private static func render(_ windows: [(CGRect, CGImage)], region: CGRect, size: CGSize, dark: Bool, flat: Bool,
                               pointer: Pointer, t: TimeInterval) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        draw(windows, into: context, region: region, size: size, dark: dark, flat: flat, pointer: pointer, t: t)
        return context.makeImage()
    }

    private static func draw(_ windows: [(CGRect, CGImage)], into context: CGContext, region: CGRect, size: CGSize,
                             dark: Bool, flat: Bool, pointer: Pointer, t: TimeInterval) {
        let scale = size.width / region.width
        let bounds = CGRect(origin: .zero, size: size)
        context.interpolationQuality = .high
        // A quiet desktop: one tone for the GIF, which compresses flat colour
        // far better, and a soft fall of light for the movie.
        let top = dark ? CGColor(srgbRed: 0.13, green: 0.14, blue: 0.18, alpha: 1)
                       : CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        let bottom = dark ? CGColor(srgbRed: 0.08, green: 0.085, blue: 0.11, alpha: 1)
                          : CGColor(srgbRed: 0.86, green: 0.88, blue: 0.92, alpha: 1)
        if flat {
            context.setFillColor(top)
            context.fill(bounds)
        } else if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width * 0.4, y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        for (frame, image) in windows {
            let rect = CGRect(x: (frame.minX - region.minX) * scale, y: (frame.minY - region.minY) * scale,
                              width: frame.width * scale, height: frame.height * scale)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 28 * scale,
                              color: CGColor(gray: 0, alpha: dark ? 0.55 : 0.2))
            context.draw(image, in: rect)
            context.restoreGState()
        }
        // The arrow, a touch smaller for a moment on each click.
        let cursor = NSCursor.arrow
        var proposed = CGRect(origin: .zero, size: cursor.image.size)
        if let arrow = cursor.image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            let press: CGFloat = t < pointer.pressedUntil ? 0.86 : 1
            let w = cursor.image.size.width * scale * press, h = cursor.image.size.height * scale * press
            let hot = CGPoint(x: cursor.hotSpot.x * scale * press, y: cursor.hotSpot.y * scale * press)
            let x = (pointer.point.x - region.minX) * scale - hot.x
            let y = (pointer.point.y - region.minY) * scale - (h - hot.y)
            context.draw(arrow, in: CGRect(x: x, y: y, width: w, height: h))
        }
    }

    private static func write(png image: CGImage, to url: URL) {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// Turns the run loop without filming.
    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
