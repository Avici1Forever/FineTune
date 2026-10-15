// FineTuneTests/DevicePriorityListTests.swift
// Tests for the device picker's fallback-order model.

import Testing
@testable import FineTune

@Suite("DevicePriorityList — picker model")
@MainActor
struct DevicePriorityListTests {
    private let airpods = DevicePriorityList.Entry(uid: "airpods", name: "AirPods Pro", isConnected: false)
    private let monitor = DevicePriorityList.Entry(uid: "monitor", name: "Studio Display", isConnected: true)
    private let speakers = DevicePriorityList.Entry(uid: "speakers", name: "MacBook Speakers", isConnected: true)

    @Test("moving reorders entries the same way the persisted list is reordered")
    func movingMatchesSettings() {
        let entries = [airpods, monitor, speakers]
        #expect(DevicePriorityList.moving("monitor", by: -1, in: entries) == [monitor, airpods, speakers])
        #expect(DevicePriorityList.moving("monitor", by: 1, in: entries) == [airpods, speakers, monitor])
    }

    @Test("moving keeps entry details such as connection state")
    func movingKeepsDetails() {
        let moved = DevicePriorityList.moving("airpods", by: 1, in: [airpods, monitor])
        #expect(moved.map(\.isConnected) == [true, false])
        #expect(moved.map(\.name) == ["Studio Display", "AirPods Pro"])
    }

    @Test("moving clamps at the ends and ignores unknown devices")
    func movingEdges() {
        let entries = [airpods, monitor]
        #expect(DevicePriorityList.moving("airpods", by: -1, in: entries) == entries)
        #expect(DevicePriorityList.moving("monitor", by: 1, in: entries) == entries)
        #expect(DevicePriorityList.moving("tv", by: 1, in: entries) == entries)
    }

    @Test("Section is shown only when there is a device to fall back to")
    func shouldShow() {
        #expect(DevicePriorityList.shouldShow([]) == false)
        #expect(DevicePriorityList.shouldShow([airpods]) == false)
        #expect(DevicePriorityList.shouldShow([airpods, monitor]) == true)
    }

    @Test("Callbacks receive the device and offset")
    func callbacksForwarded() {
        var moves: [(String, Int)] = []
        var removals: [String] = []
        let list = DevicePriorityList(
            entries: [airpods, monitor],
            onMove: { moves.append(($0, $1)) },
            onRemove: { removals.append($0) }
        )
        list.onMove("monitor", -1)
        list.onRemove("airpods")
        #expect(moves.count == 1 && moves[0].0 == "monitor" && moves[0].1 == -1)
        #expect(removals == ["airpods"])
    }
}
