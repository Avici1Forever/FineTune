// FineTuneTests/AppDevicePrioritySettingsTests.swift
// Tests for the per-app output device priority list persisted by SettingsManager.
// Uses temp directories — no real settings files affected.

import Testing
import Foundation
@testable import FineTune

@MainActor
private func makeManager(directory: URL? = nil) -> SettingsManager {
    let dir = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return SettingsManager(directory: dir)
}

// MARK: - Pure list helpers

@Suite("SettingsManager — per-app device priority list helpers")
struct AppDevicePriorityListHelperTests {

    @Test("promotingDevice inserts a new device at the front")
    func promoteNew() {
        #expect(SettingsManager.promotingDevice("c", in: ["a", "b"]) == ["c", "a", "b"])
    }

    @Test("promotingDevice moves an existing device to the front without duplicating it")
    func promoteExisting() {
        #expect(SettingsManager.promotingDevice("b", in: ["a", "b", "c"]) == ["b", "a", "c"])
    }

    @Test("promotingDevice on an empty list yields a single entry")
    func promoteIntoEmpty() {
        #expect(SettingsManager.promotingDevice("a", in: []) == ["a"])
    }

    @Test("movingDevice moves up and down by one")
    func moveByOne() {
        #expect(SettingsManager.movingDevice("b", by: -1, in: ["a", "b", "c"]) == ["b", "a", "c"])
        #expect(SettingsManager.movingDevice("b", by: 1, in: ["a", "b", "c"]) == ["a", "c", "b"])
    }

    @Test("movingDevice clamps at both ends")
    func moveClamps() {
        #expect(SettingsManager.movingDevice("a", by: -1, in: ["a", "b"]) == ["a", "b"])
        #expect(SettingsManager.movingDevice("b", by: 1, in: ["a", "b"]) == ["a", "b"])
        #expect(SettingsManager.movingDevice("a", by: 10, in: ["a", "b", "c"]) == ["b", "c", "a"])
    }

    @Test("movingDevice leaves the list unchanged for an unknown device")
    func moveUnknown() {
        #expect(SettingsManager.movingDevice("z", by: 1, in: ["a", "b"]) == ["a", "b"])
    }
}

// MARK: - SettingsManager API

@Suite("SettingsManager — per-app device priority")
@MainActor
struct AppDevicePrioritySettingsTests {
    let app = "com.test.spotify"

    @Test("An app with no routing has an empty priority list and follows default")
    func emptyByDefault() {
        let manager = makeManager()
        #expect(manager.getDevicePriority(for: app).isEmpty)
        #expect(manager.isFollowingDefault(for: app))
    }

    @Test("Each explicit selection moves the device to the top, keeping earlier choices")
    func selectionsBuildMostRecentFirstList() {
        let manager = makeManager()
        manager.setDeviceRouting(for: app, deviceUID: "monitor")
        manager.setDeviceRouting(for: app, deviceUID: "airpods")

        #expect(manager.getDevicePriority(for: app) == ["airpods", "monitor"])
        #expect(manager.getDeviceRouting(for: app) == "airpods")
        #expect(!manager.isFollowingDefault(for: app))

        manager.setDeviceRouting(for: app, deviceUID: "monitor")
        #expect(manager.getDevicePriority(for: app) == ["monitor", "airpods"])
        #expect(manager.getDeviceRouting(for: app) == "monitor")
    }

    @Test("The list is capped, dropping the least preferred devices")
    func listIsCapped() {
        let manager = makeManager()
        let limit = SettingsManager.maxAppDevicePriorityCount
        for i in 0..<(limit + 2) {
            manager.setDeviceRouting(for: app, deviceUID: "dev-\(i)")
        }
        let list = manager.getDevicePriority(for: app)
        #expect(list.count == limit)
        #expect(list.first == "dev-\(limit + 1)")
        #expect(!list.contains("dev-0"))
        #expect(!list.contains("dev-1"))
    }

    @Test("Following the system default clears the list")
    func followDefaultClears() {
        let manager = makeManager()
        manager.setDeviceRouting(for: app, deviceUID: "monitor")
        manager.setDeviceRouting(for: app, deviceUID: "airpods")

        manager.setFollowDefault(for: app)

        #expect(manager.getDevicePriority(for: app).isEmpty)
        #expect(manager.getDeviceRouting(for: app) == nil)
        #expect(manager.isFollowingDefault(for: app))

        // A later selection starts a fresh list rather than resurrecting old entries
        manager.setDeviceRouting(for: app, deviceUID: "speakers")
        #expect(manager.getDevicePriority(for: app) == ["speakers"])
    }

    @Test("setDevicePriority replaces the list and keeps routing in sync with its head")
    func manualReorder() {
        let manager = makeManager()
        manager.setDeviceRouting(for: app, deviceUID: "monitor")
        manager.setDeviceRouting(for: app, deviceUID: "airpods")

        manager.setDevicePriority(for: app, ["monitor", "airpods"])

        #expect(manager.getDevicePriority(for: app) == ["monitor", "airpods"])
        #expect(manager.getDeviceRouting(for: app) == "monitor")
    }

    @Test("setDevicePriority removes duplicates")
    func manualDeduplicates() {
        let manager = makeManager()
        manager.setDevicePriority(for: app, ["a", "b", "a"])
        #expect(manager.getDevicePriority(for: app) == ["a", "b"])
    }

    @Test("Setting an empty list makes the app follow the system default")
    func manualEmptyFollowsDefault() {
        let manager = makeManager()
        manager.setDeviceRouting(for: app, deviceUID: "monitor")
        manager.setDevicePriority(for: app, [])
        #expect(manager.isFollowingDefault(for: app))
        #expect(manager.getDevicePriority(for: app).isEmpty)
    }

    @Test("Lists are independent per app")
    func independentPerApp() {
        let manager = makeManager()
        manager.setDeviceRouting(for: app, deviceUID: "airpods")
        manager.setDeviceRouting(for: "com.test.zoom", deviceUID: "speakers")
        #expect(manager.getDevicePriority(for: app) == ["airpods"])
        #expect(manager.getDevicePriority(for: "com.test.zoom") == ["speakers"])
    }

    @Test("Routing written by an older version (no priority list) is treated as a one-entry list")
    func legacyRoutingOnly() throws {
        var legacy = SettingsManager.Settings()
        legacy.appDeviceRouting = [app: "monitor"]
        let data = try JSONEncoder().encode(legacy)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "appDevicePriority")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("settings.json"))

        let manager = makeManager(directory: dir)
        #expect(manager.getDevicePriority(for: app) == ["monitor"])
    }

    @Test("Routing changed by an older version wins over a stale list head")
    func routingAuthoritativeForHead() throws {
        var settings = SettingsManager.Settings()
        settings.appDeviceRouting = [app: "airpods"]
        settings.appDevicePriority = [app: ["monitor", "airpods", "speakers"]]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: dir.appendingPathComponent("settings.json"))

        let manager = makeManager(directory: dir)
        #expect(manager.getDevicePriority(for: app) == ["airpods", "monitor", "speakers"])
    }

    @Test("A stale list without routing (older version chose System Audio) reads as empty")
    func listWithoutRoutingIsEmpty() throws {
        var settings = SettingsManager.Settings()
        settings.appDevicePriority = [app: ["monitor"]]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: dir.appendingPathComponent("settings.json"))

        let manager = makeManager(directory: dir)
        #expect(manager.getDevicePriority(for: app).isEmpty)
        #expect(manager.isFollowingDefault(for: app))
    }

    @Test("The list persists across SettingsManager instances")
    func persistsToDisk() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = makeManager(directory: dir)
        first.setDeviceRouting(for: app, deviceUID: "monitor")
        first.setDeviceRouting(for: app, deviceUID: "airpods")
        first.flushSync()

        let second = makeManager(directory: dir)
        #expect(second.getDevicePriority(for: app) == ["airpods", "monitor"])
    }

    @Test("Ignoring an app clears its list")
    func ignoreClears() {
        let manager = makeManager()
        manager.setDeviceRouting(for: app, deviceUID: "airpods")
        manager.ignoreApp(app, info: IgnoredAppInfo(persistenceIdentifier: app, displayName: "Spotify", bundleID: app))
        #expect(manager.getDevicePriority(for: app).isEmpty)
    }

    @Test("resetAllSettings clears lists and remembered device names")
    func resetClears() {
        let manager = makeManager()
        manager.setDeviceRouting(for: app, deviceUID: "airpods")
        manager.rememberOutputDeviceName("AirPods Pro", for: "airpods")

        manager.resetAllSettings()

        #expect(manager.getDevicePriority(for: app).isEmpty)
        #expect(manager.outputDeviceName(for: "airpods") == nil)
    }

    @Test("Remembered device names are stored and updated")
    func rememberNames() {
        let manager = makeManager()
        #expect(manager.outputDeviceName(for: "airpods") == nil)
        manager.rememberOutputDeviceName("AirPods", for: "airpods")
        #expect(manager.outputDeviceName(for: "airpods") == "AirPods")
        manager.rememberOutputDeviceName("Karl's AirPods", for: "airpods")
        #expect(manager.outputDeviceName(for: "airpods") == "Karl's AirPods")
    }

    @Test("New fields round-trip through JSON")
    func jsonRoundTrip() throws {
        var original = SettingsManager.Settings()
        original.appDeviceRouting = [app: "airpods"]
        original.appDevicePriority = [app: ["airpods", "monitor"]]
        original.outputDeviceNames = ["airpods": "AirPods", "monitor": "Studio Display"]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        #expect(decoded.appDevicePriority == original.appDevicePriority)
        #expect(decoded.outputDeviceNames == original.outputDeviceNames)
    }
}
