// FineTuneTests/PopoverPlacementTests.swift
// Tests for where dropdown panels open relative to their trigger and the screen.

import Testing
import AppKit
@testable import FineTune

@Suite("PopoverPlacement.panelOrigin")
struct PopoverPlacementTests {
    // 1440×900 screen with a 25pt menu bar (AppKit: origin bottom-left)
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private let panel = NSSize(width: 210, height: 300)

    private func trigger(x: CGFloat, y: CGFloat) -> NSRect {
        NSRect(x: x, y: y, width: 28, height: 28)
    }

    @Test("Leading alignment lines the panel's left edge up with the trigger, below it")
    func leadingBelow() {
        let t = trigger(x: 400, y: 600)
        let origin = PopoverPlacement.panelOrigin(trigger: t, panelSize: panel, alignment: .leading, visibleFrame: screen)
        #expect(origin == NSPoint(x: 400, y: 600 - 4 - 300))
    }

    @Test("Trailing alignment lines the panel's right edge up with the trigger, so it opens leftward")
    func trailingBelow() {
        let t = trigger(x: 1000, y: 600)
        let origin = PopoverPlacement.panelOrigin(trigger: t, panelSize: panel, alignment: .trailing, visibleFrame: screen)
        #expect(origin.x == t.maxX - panel.width)
        #expect(origin.x + panel.width == t.maxX)
        #expect(origin.y == t.minY - 4 - panel.height)
    }

    @Test("A leading panel near the right screen edge is pulled back on screen")
    func clampRightEdge() {
        let t = trigger(x: 1400, y: 600)
        let origin = PopoverPlacement.panelOrigin(trigger: t, panelSize: panel, alignment: .leading, visibleFrame: screen)
        #expect(origin.x == screen.maxX - panel.width)
    }

    @Test("A trailing panel near the left screen edge is pulled back on screen")
    func clampLeftEdge() {
        let t = trigger(x: 10, y: 600)
        let origin = PopoverPlacement.panelOrigin(trigger: t, panelSize: panel, alignment: .trailing, visibleFrame: screen)
        #expect(origin.x == screen.minX)
    }

    @Test("With no room below, the panel flips above the trigger")
    func flipAbove() {
        let t = trigger(x: 400, y: 100)
        let origin = PopoverPlacement.panelOrigin(trigger: t, panelSize: panel, alignment: .leading, visibleFrame: screen)
        #expect(origin.y == t.maxY + 4)
    }

    @Test("With no room below or above, the panel is clamped to the bottom of the screen")
    func clampBottom() {
        let tall = NSSize(width: 210, height: 700)
        let t = trigger(x: 400, y: 400)
        let origin = PopoverPlacement.panelOrigin(trigger: t, panelSize: tall, alignment: .leading, visibleFrame: screen)
        #expect(origin.y == screen.minY)
        #expect(origin.y + tall.height <= screen.maxY)
    }

    @Test("A panel taller than the screen keeps its top inside the screen")
    func tallerThanScreen() {
        let huge = NSSize(width: 210, height: 2000)
        let t = trigger(x: 400, y: 400)
        let origin = PopoverPlacement.panelOrigin(trigger: t, panelSize: huge, alignment: .leading, visibleFrame: screen)
        #expect(origin.y == screen.minY)
        #expect(origin.x == 400)
    }

    @Test("Works on a secondary screen with a non-zero origin")
    func secondaryScreen() {
        let second = NSRect(x: 1440, y: -200, width: 1920, height: 1055)
        let t = trigger(x: second.maxX - 20, y: 500)
        let origin = PopoverPlacement.panelOrigin(trigger: t, panelSize: panel, alignment: .leading, visibleFrame: second)
        #expect(origin.x == second.maxX - panel.width)
        #expect(origin.x >= second.minX)
    }

    @Test("Without a known screen the panel keeps its unclamped position")
    func noScreen() {
        let t = trigger(x: 1400, y: 10)
        let origin = PopoverPlacement.panelOrigin(trigger: t, panelSize: panel, alignment: .leading, visibleFrame: nil)
        #expect(origin == NSPoint(x: 1400, y: 10 - 4 - 300))
    }
}
