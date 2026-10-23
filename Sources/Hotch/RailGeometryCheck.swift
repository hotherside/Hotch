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
        check("three status targets have at least 40pt hit areas", RailGeometry.count == 3 && RailGeometry.slot >= 40)
        check("side targets fit across the rail", RailGeometry.width >= RailGeometry.slot)
        check("the side footprint reserves equal room around the targets",
              RailGeometry.height == RailGeometry.endInset * 2 + CGFloat(RailGeometry.count) * RailGeometry.slot)
        var policy = RailSlotPolicy()
        check("idle readouts are AI, Sessions and Mac", policy.targets == [.ai, .sessions, .mac])
        policy.update(focusActive: false, expanded: true)
        policy.update(focusActive: true, expanded: true)
        check("Focus starting cannot move an open Mac target", policy.targets == [.ai, .sessions, .mac])
        policy.update(focusActive: true, expanded: false)
        check("closing brings running Focus into the third slot", policy.targets == [.ai, .sessions, .focus])
        policy.update(focusActive: true, expanded: true)
        policy.update(focusActive: true, expanded: true)
        check("a paused active timer keeps its Focus target", policy.targets == [.ai, .sessions, .focus])
        policy.update(focusActive: false, expanded: true)
        check("a finishing timer cannot move an open Focus target", policy.targets == [.ai, .sessions, .focus])
        policy.update(focusActive: false, expanded: false)
        check("closing restores Mac after Focus finishes", policy.targets == [.ai, .sessions, .mac])
        policy.update(focusActive: true, expanded: true)
        check("opening snapshots the current Focus state", policy.targets == [.ai, .sessions, .focus])
        for bottom in [false, true] {
            let extent = bottom ? RailGeometry.bottomWidth : RailGeometry.height
            check("positions before the \(bottom ? "bar" : "rail") clamp to its first target",
                  RailGeometry.nearestSlot(to: -1000, bottom: bottom) == 0)
            check("positions after the \(bottom ? "bar" : "rail") clamp to its last target",
                  RailGeometry.nearestSlot(to: extent + 1000, bottom: bottom) == RailGeometry.count - 1)
            for index in 0..<RailGeometry.count {
                let center = RailGeometry.center(index, bottom: bottom)
                check("\(bottom ? "bottom" : "side") target \(index) resolves across its whole hit area",
                      [-RailGeometry.slot / 2 + 0.01, 0, RailGeometry.slot / 2 - 0.01].allSatisfy {
                          RailGeometry.nearestSlot(to: center + $0, bottom: bottom) == index
                      })
                check("target \(index) fits inside the \(bottom ? "bar" : "rail")",
                      center - RailGeometry.slot / 2 >= 0 && center + RailGeometry.slot / 2 <= extent)
            }
        }
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
