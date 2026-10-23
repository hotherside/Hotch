#!/usr/bin/env swift
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Assemble unmodified native snapshots into a looping view tour.
// Run Hotch --snapshot-story first. This is a storyboard, not a screen recording.
let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("Usage: swift tools/render-demo.swift <story-directory> <output.gif>\n", stderr)
    exit(2)
}
let names = ["00-resting", "01-now", "02-ai", "03-sessions", "04-mac", "05-focus", "06-clipboard", "07-alert"]
let source = URL(fileURLWithPath: args[1], isDirectory: true)
let output = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString,
                                                       names.count, nil) else { exit(1) }
CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for name in names {
    let url = source.appendingPathComponent(name + ".png")
    guard let input = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(input, 0, nil) else {
        fputs("Missing frame: \(url.path)\n", stderr)
        exit(1)
    }
    let duration = name == "00-resting" ? 1.5 : 2.5
    CGImageDestinationAddImage(destination, image,
                              [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: duration]] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("Native view tour written to \(output.path)")
