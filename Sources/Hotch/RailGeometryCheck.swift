import Foundation
import CoreGraphics

/// `--check-rail`: verifies the boundary cases behind jumping targets and
/// cards, without opening windows or changing the user's saved rail position.
enum RailGeometryCheck {
    static func runBlockingAndExit() -> Never {
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            if passed { print("  ok    \(name)") }
            else { print("  FAIL  \(name)"); failures += 1 }
        }
        let displays = [
            CGRect(x: 0, y: 38, width: 1440, height: 838),
            CGRect(x: -1920, y: 25, width: 1920, height: 1030),
            CGRect(x: 1440, y: -640, width: 1024, height: 730),
        ]
        let heights: [CGFloat] = [196, 324, CardMetrics.maxHeight]
        check("every readout has at least a 40pt slot", RailGeometry.slot >= 40)
        check("side readouts fit across the rail", RailGeometry.width >= RailGeometry.slot)

        let claude = RailSlotPolicy.Target.provider("claude")
        let codex = RailSlotPolicy.Target.provider("codex")
        let chosen: [RailSlotPolicy.Target] = [claude, codex, .sessions, .memory]
        var policy = RailSlotPolicy()
        check("before any choice the tab shows Claude, Sessions and Memory",
              policy.targets == [claude, .sessions, .memory])
        policy.update(chosen: chosen, focusClock: true, focusActive: false, expanded: false)
        check("readouts follow Settings' choice and order", policy.targets == chosen)
        policy.update(chosen: [], focusClock: true, focusActive: false, expanded: false)
        check("choosing nothing still leaves Sessions", policy.targets == [.sessions])
        policy.update(chosen: chosen + [.cpu, .provider("grok")], focusClock: true, focusActive: false, expanded: false)
        check("the tab never grows past five readouts", policy.targets.count == RailGeometry.maxCount)
        policy.update(chosen: chosen, focusClock: true, focusActive: false, expanded: false)
        policy.update(chosen: chosen, focusClock: true, focusActive: false, expanded: true)
        policy.update(chosen: chosen, focusClock: true, focusActive: true, expanded: true)
        check("Focus starting cannot move an open readout", policy.targets == chosen)
        policy.update(chosen: chosen, focusClock: true, focusActive: true, expanded: false)
        check("closing brings running Focus into the last slot",
              policy.targets == [claude, codex, .sessions, .focus])
        policy.update(chosen: chosen, focusClock: true, focusActive: true, expanded: true)
        policy.update(chosen: chosen, focusClock: true, focusActive: false, expanded: true)
        check("a finishing timer cannot move an open Focus readout",
              policy.targets == [claude, codex, .sessions, .focus])
        policy.update(chosen: chosen, focusClock: true, focusActive: false, expanded: false)
        check("closing restores the last readout after Focus finishes", policy.targets == chosen)
        policy.update(chosen: chosen, focusClock: false, focusActive: true, expanded: false)
        check("with the Focus clock off a timer leaves the readouts alone", policy.targets == chosen)
        policy.update(chosen: chosen, focusClock: true, focusActive: false, expanded: true)
        policy.update(chosen: [claude, .sessions], focusClock: true, focusActive: false, expanded: true)
        check("a new choice waits until the card closes", policy.targets == chosen)
        policy.update(chosen: [claude, .sessions], focusClock: true, focusActive: false, expanded: false)
        check("closing applies the new choice", policy.targets == [claude, .sessions])

        let saved = RailGeometry.count
        defer { RailGeometry.count = saved }
        for count in 1...RailGeometry.maxCount {
            RailGeometry.count = count
            check("\(count) readouts: the side footprint keeps equal room around them",
                  RailGeometry.height == RailGeometry.endInset * 2 + CGFloat(count) * RailGeometry.slot)
            for bottom in [false, true] {
                let extent = bottom ? RailGeometry.bottomWidth : RailGeometry.height
                for index in 0..<count {
                    let center = RailGeometry.center(index, bottom: bottom)
                    check("\(count) readouts: \(bottom ? "bottom" : "side") slot \(index) fits inside",
                          center - RailGeometry.slot / 2 >= 0 && center + RailGeometry.slot / 2 <= extent)
                }
            }
        }
        RailGeometry.count = chosen.count
        for (displayIndex, visible) in displays.enumerated() {
            for side in RailGeometry.Side.allCases {
                for fraction: CGFloat in [0, 0.5, 1] {
                    let y = visible.minY + 6 + (visible.height - RailGeometry.height - 12) * fraction
                    let rail: CGRect
                    switch side {
                    case .left: rail = CGRect(x: visible.minX, y: y, width: RailGeometry.width, height: RailGeometry.height)
                    case .right: rail = CGRect(x: visible.maxX - RailGeometry.width, y: y, width: RailGeometry.width, height: RailGeometry.height)
                    case .bottom: rail = CGRect(x: visible.minX + 6 + (visible.width - RailGeometry.bottomWidth - 12) * fraction,
                                               y: visible.minY - 34,
                                               width: RailGeometry.bottomWidth, height: 44)
                    }
                    let attachment = RailGeometry.cardAttachment(rail: rail, visible: visible, side: side, maximumHeight: CardMetrics.maxHeight)
                    let frames = heights.map { RailGeometry.cardFrame(size: CGSize(width: CardMetrics.width, height: $0), rail: rail,
                                                                      visible: visible, side: side, attachment: attachment) }
                    let label = "display \(displayIndex), \(side), position \(fraction)"
                    check("cards remain inside the display: \(label)", frames.allSatisfy { visible.contains($0) })
                    check("changing page keeps its attachment: \(label)", frames.allSatisfy {
                        abs((side == .bottom ? $0.minY : $0.maxY) - attachment) < 0.01
                    })
                    check("diagonal trips from all rail targets retain hover: \(label)", frames.allSatisfy { card in
                        (0..<RailGeometry.count).allSatisfy { slot in
                            let start = side == .bottom
                                ? CGPoint(x: rail.minX + RailGeometry.center(slot, bottom: true), y: rail.midY)
                                : CGPoint(x: rail.midX, y: rail.maxY - RailGeometry.center(slot))
                            let destination = CGPoint(x: card.midX, y: card.midY)
                            return (0...10).allSatisfy { step in
                                let share = CGFloat(step) / 10
                                let point = CGPoint(x: start.x + (destination.x - start.x) * share,
                                                    y: start.y + (destination.y - start.y) * share)
                                return RailGeometry.hoverBridgeContains(point, rail: rail, card: card)
                            }
                        }
                    })
                    check("the rail/card gap retains hover: \(label)", frames.allSatisfy { card in
                        let crossing: CGPoint
                        switch side {
                        case .left: crossing = CGPoint(x: (rail.maxX + card.minX) / 2, y: rail.midY)
                        case .right: crossing = CGPoint(x: (card.maxX + rail.minX) / 2, y: rail.midY)
                        case .bottom: crossing = CGPoint(x: rail.midX, y: (rail.maxY + card.minY) / 2)
                        }
                        return RailGeometry.hoverBridgeContains(crossing, rail: rail, card: card)
                    })
                }
            }
        }
        print(failures == 0 ? "Rail geometry checks passed." : "\(failures) rail geometry checks failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
