// Composes the README's boards and native tour GIF from the app's own renders.
//
//   swift tools/compose-media.swift <parts-light> <parts-dark> <output-directory>
//
// The parts come from `Hotch --snapshot-parts <dir>` (and `--snapshot-dark`).
// Writes four-tabs-{light,dark}.jpg (the card's four tabs side by side),
// homes-{light,dark}.jpg (the edge tab, the Dock bar, the pill and the orb
// where each lives on a screen) and native-tour.gif (each tab, the update
// button and an alert beside the tab). Nothing here draws Hotch: every
// element is a render of the real view, laid on a plain backdrop.

import AppKit
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("usage: swift tools/compose-media.swift <parts-light> <parts-dark> <output-directory>")
    exit(2)
}
let lightParts = URL(fileURLWithPath: arguments[1])
let darkParts = URL(fileURLWithPath: arguments[2])
let output = URL(fileURLWithPath: arguments[3])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func load(_ name: String, from directory: URL) -> CGImage {
    let url = directory.appendingPathComponent("\(name).png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("missing \(url.path)")
        exit(1)
    }
    return image
}

func canvas(_ width: Int, _ height: Int, dark: Bool) -> CGContext {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.interpolationQuality = .high
    let top = dark ? CGColor(srgbRed: 0.13, green: 0.14, blue: 0.18, alpha: 1)
                   : CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
    let bottom = dark ? CGColor(srgbRed: 0.08, green: 0.085, blue: 0.11, alpha: 1)
                      : CGColor(srgbRed: 0.86, green: 0.88, blue: 0.92, alpha: 1)
    let gradient = CGGradient(colorsSpace: sRGB, colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: Double(width) * 0.4, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    return context
}

/// Draws a render with the soft shadow a window would cast. `y` is from the
/// top, as the layouts below are written.
func place(_ image: CGImage, in context: CGContext, x: Double, top y: Double, scale: Double = 1, dark: Bool) {
    let w = Double(image.width) * scale, h = Double(image.height) * scale
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 48 * scale,
                      color: CGColor(gray: 0, alpha: dark ? 0.55 : 0.2))
    context.draw(image, in: CGRect(x: x, y: Double(context.height) - y - h, width: w, height: h))
    context.restoreGState()
}

func writeJPEG(_ context: CGContext, _ name: String) {
    let url = output.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!,
                               [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(destination)
    print("wrote \(url.path)")
}

// The four tabs, top-aligned as the card hangs from its tab.
for dark in [false, true] {
    let parts = dark ? darkParts : lightParts
    let cards = ["card-home", "card-ai", "card-mac", "card-desk"].map { load($0, from: parts) }
    let gap = 56.0, margin = 88.0
    let width = cards.reduce(0) { $0 + Double($1.width) } + gap * 3 + margin * 2
    let height = Double(cards.map(\.height).max()!) + margin * 2
    let context = canvas(Int(width), Int(height), dark: dark)
    var x = margin
    for card in cards {
        place(card, in: context, x: x, top: margin, dark: dark)
        x += Double(card.width) + gap
    }
    writeJPEG(context, "four-tabs-\(dark ? "dark" : "light").jpg")
}

// Where Hotch can live, each in its place on a small screen: the tab flush
// on the right edge, the bar along the bottom beside where the Dock sits,
// and the pill and orb floating on the desktop.
for dark in [false, true] {
    let parts = dark ? darkParts : lightParts
    let width = 1320.0, height = 700.0
    let context = canvas(Int(width), Int(height), dark: dark)
    let tab = load("tab", from: parts), bar = load("bottom", from: parts)
    let pill = load("pill", from: parts), orb = load("orb", from: parts)
    place(tab, in: context, x: width - Double(tab.width), top: (height - Double(tab.height)) / 2 - 36, dark: dark)
    place(bar, in: context, x: (width - Double(bar.width)) / 2 + 40, top: height - Double(bar.height) - 10, dark: dark)
    place(pill, in: context, x: 110, top: 120, dark: dark)
    place(orb, in: context, x: 560, top: 330, dark: dark)
    writeJPEG(context, "homes-\(dark ? "dark" : "light").jpg")
}

// One render a step, each held long enough to read, light appearance.
do {
    let names = ["card-home", "card-ai", "card-mac", "card-desk", "menubar-card-update", "tab-alert"]
    let frames = names.map { load($0, from: lightParts) }
    let scale = 0.75, margin = 48.0
    let width = Int((Double(frames.map(\.width).max()!) * scale + margin * 2).rounded())
    let height = Int((Double(frames.map(\.height).max()!) * scale + margin * 2).rounded())
    let url = output.appendingPathComponent("native-tour.gif")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
    CGImageDestinationSetProperties(destination,
                                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (index, frame) in frames.enumerated() {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.interpolationQuality = .high
        context.setFillColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let w = Double(frame.width) * scale
        // Cards hang from the top; the tab and its label sit mid-frame.
        let top = names[index] == "tab-alert" ? (Double(height) - Double(frame.height) * scale) / 2 : margin
        place(frame, in: context, x: (Double(width) - w) / 2, top: top, scale: scale, dark: false)
        let delay = index == frames.count - 1 ? 2.6 : 2.0
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
        ]] as CFDictionary)
    }
    CGImageDestinationFinalize(destination)
    print("wrote \(url.path)")
}
