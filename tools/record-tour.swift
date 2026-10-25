#!/usr/bin/env swift
import AVFoundation
import AppKit
import ScreenCaptureKit

// Records `Hotch --demo-tour` with only Hotch's own windows, on transparency,
// as ProRes 4444 at the display's full resolution. Video time 0 is the tour's
// cue, and the tour's step and window-frame lines are written to <output>.log.
//
// Needs Screen Recording permission for the terminal that runs it. The pointer
// is parked at the left edge first; leave the mouse alone until it finishes.
//
// Usage: swift tools/record-tour.swift build/Hotch.app/Contents/MacOS/Hotch <output.mov> [--dark]

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: swift tools/record-tour.swift <Hotch binary> <output.mov> [--dark]\n", stderr)
    exit(2)
}
let binary = args[1]
let output = URL(fileURLWithPath: args[2])
let dark = args.contains("--dark")
let logURL = output.appendingPathExtension("log")

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "record-tour")
    private var cue: CMTime?
    private var lines: [String] = []
    private var frames = 0

    init(width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
    }

    func note(_ line: String) {
        queue.async { self.lines.append(line) }
    }

    /// Video time starts here, at the same moment the tour is cued.
    func markCue() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.sync {
            cue = now
            writer.startSession(atSourceTime: now)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        queue.sync {
            guard let cue, buffer.presentationTimeStamp >= cue, input.isReadyForMoreMediaData else { return }
            if frames == 0 {
                lines.append(String(format: "first-frame %.3f", (buffer.presentationTimeStamp - cue).seconds))
            }
            if input.append(buffer) { frames += 1 }
        }
    }

    func finish() async {
        let (lines, frames) = queue.sync { (self.lines, self.frames) }
        input.markAsFinished()
        await writer.finishWriting()
        let log = lines + ["frames-written \(frames)"]
        try? log.joined(separator: "\n").appending("\n").write(to: logURL, atomically: true, encoding: .utf8)
        print("recorded \(frames) frames to \(output.path); log at \(logURL.path)")
    }
}

let tour = Process()
tour.executableURL = URL(fileURLWithPath: binary)
tour.arguments = ["--demo-tour"] + (dark ? ["--snapshot-dark"] : [])
let toTour = Pipe(), fromTour = Pipe()
tour.standardInput = toTour
tour.standardOutput = fromTour

let ready = DispatchSemaphore(value: 0)
var recorder: Recorder?
var pending = ""
fromTour.fileHandleForReading.readabilityHandler = { handle in
    pending += String(decoding: handle.availableData, as: UTF8.self)
    while let newline = pending.firstIndex(of: "\n") {
        let line = String(pending[..<newline])
        pending.removeSubrange(...newline)
        if line == "ready" { ready.signal() } else { recorder?.note(line) }
        print(line)
    }
}
let finished = DispatchSemaphore(value: 0)
tour.terminationHandler = { _ in finished.signal() }

// Park the pointer away from every place Hotch can appear.
if let screen = NSScreen.main {
    CGWarpMouseCursorPosition(CGPoint(x: 160, y: screen.frame.height * 0.6))
}

try tour.run()
await withCheckedContinuation { (go: CheckedContinuation<Void, Never>) in
    DispatchQueue.global().async { ready.wait(); go.resume() }
}

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
guard let app = content.applications.first(where: { $0.processID == tour.processIdentifier }),
      let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
    fputs("record-tour: the tour or the main display is not shareable\n", stderr)
    tour.terminate()
    exit(1)
}
let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
let config = SCStreamConfiguration()
config.width = display.width * scale
config.height = display.height * scale
config.pixelFormat = kCVPixelFormatType_32BGRA
config.colorSpaceName = CGColorSpace.sRGB
config.backgroundColor = .clear
config.showsCursor = false
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
config.queueDepth = 8

// Every window the tour does not own is excluded, rather than the tour's app
// included: an app filter matches by bundle, which would also catch a copy of
// Hotch the person is running. Windows come and go, so the list is refreshed.
func othersFilter() async throws -> (SCContentFilter, Set<CGWindowID>) {
    let now = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    let others = now.windows.filter { $0.owningApplication?.processID != app.processID }
    return (SCContentFilter(display: display, excludingWindows: others), Set(others.map(\.windowID)))
}

let rec = try Recorder(width: config.width, height: config.height)
recorder = rec
var (filter, excluded) = try await othersFilter()
let stream = SCStream(filter: filter, configuration: config, delegate: nil)
try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
try await stream.startCapture()
let refresher = Task {
    while !Task.isCancelled {
        try await Task.sleep(nanoseconds: 250_000_000)
        let (next, ids) = try await othersFilter()
        if ids != excluded {
            excluded = ids
            try await stream.updateContentFilter(next)
        }
    }
}
try await Task.sleep(nanoseconds: 300_000_000)

rec.markCue()
toTour.fileHandleForWriting.write(Data("go\n".utf8))
await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
    DispatchQueue.global().async { finished.wait(); done.resume() }
}
try await Task.sleep(nanoseconds: 200_000_000)
refresher.cancel()
try await stream.stopCapture()
await rec.finish()
