// FineTuneTests/AudioEngineDevicePriorityTests.swift
//
// Verifies per-app output device priority: when an app's routed device disappears
// it falls back down the app's own priority list, and when a higher-ranked device
// reappears the app moves back up to it.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

// MARK: - Fixture

@MainActor
private final class PriorityFixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let deviceMonitor: MockAudioDeviceMonitor
    let deviceVolume: MockDeviceVolumeProviding
    let processMonitor: StubProcessMonitor
    let app: AudioApp
    private let registry = TapRegistry()

    /// Device IDs reported as not alive by the injected isAlive check.
    var deadDeviceIDs: Set<AudioDeviceID> {
        get { registry.deadDeviceIDs }
        set { registry.deadDeviceIDs = newValue }
    }

    static let speakers = AudioDevice(id: AudioDeviceID(101), uid: "speakers", name: "MacBook Speakers", icon: nil, supportsAutoEQ: false)
    static let monitor = AudioDevice(id: AudioDeviceID(102), uid: "monitor", name: "Studio Display", icon: nil, supportsAutoEQ: false)
    static let airpods = AudioDevice(id: AudioDeviceID(103), uid: "airpods", name: "AirPods Pro", icon: nil, supportsAutoEQ: false)
    static let tv = AudioDevice(id: AudioDeviceID(104), uid: "tv", name: "Living Room TV", icon: nil, supportsAutoEQ: false)

    init(devices: [AudioDevice] = [speakers, monitor, airpods], defaultUID: String = "speakers") {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        settings = SettingsManager(directory: tempDir)
        var appSettings = settings.appSettings
        appSettings.showDeviceDisconnectAlerts = false
        settings.updateAppSettings(appSettings)

        deviceMonitor = MockAudioDeviceMonitor()
        for device in devices { deviceMonitor.addOutputDevice(device) }
        deviceVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        deviceVolume.defaultDeviceUID = defaultUID

        app = AudioApp(
            id: 31337,
            processObjectIDs: [],
            name: "Spotify",
            icon: NSImage(),
            bundleID: "com.spotify.client"
        )
        processMonitor = StubProcessMonitor()
        processMonitor.activeApps = [app]

        let permission = AudioRecordingPermission()
        permission.status = .authorized

        let box = registry
        engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: deviceMonitor,
            processMonitor: processMonitor,
            deviceVolumeMonitor: deviceVolume,
            tapFactory: { app, uids, _ in
                let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
                box.taps[app.id] = tap
                return tap
            },
            isAlive: { id in MainActor.assumeIsolated { !box.deadDeviceIDs.contains(id) } },
            startMonitorsAutomatically: false
        )
        engine.registerNewDevicesInPriority()
    }

    var tap: RecordingProcessTapController? { registry.taps[app.id] }
    var routedUID: String? { engine.getDeviceUID(for: app) }
    var followsDefault: Bool { engine.isFollowingDefault(for: app) }
    var persistedPriority: [String] { settings.getDevicePriority(for: app.persistenceIdentifier) }

    /// Starts the app on its persisted routing (like the app launching).
    func launch() {
        engine.applyPersistedSettings()
    }

    func disconnect(_ device: AudioDevice) {
        deviceMonitor.removeOutputDevice(uid: device.uid)
        deviceMonitor.onDeviceDisconnected?(device.uid, device.name)
    }

    func connect(_ device: AudioDevice) {
        deviceMonitor.addOutputDevice(device)
        deviceMonitor.onDeviceConnected?(device.uid, device.name)
    }

    /// Explicitly selects a device for the app (like picking it in the menu) and waits
    /// for the async tap switch so later device events see the tap on that device.
    func select(_ device: AudioDevice) async {
        engine.setDevice(for: app, deviceUID: device.uid)
        _ = await waitForTap([device.uid])
    }

    /// Waits for the engine's async tap switch to land on `uids`.
    func waitForTap(_ uids: [String]) async -> Bool {
        for _ in 0..<200 {
            if tap?.currentDeviceUIDs == uids { return true }
            await Task.yield()
        }
        return tap?.currentDeviceUIDs == uids
    }

    /// Gives pending engine tasks a chance to run (used when asserting nothing changed).
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }
}

@MainActor
private final class TapRegistry {
    var taps: [pid_t: RecordingProcessTapController] = [:]
    var deadDeviceIDs: Set<AudioDeviceID> = []
}

// MARK: - Suite

@Suite("AudioEngine — per-app device priority")
@MainActor
struct AudioEngineDevicePriorityTests {
    fileprivate typealias F = PriorityFixture

    // MARK: Disconnect

    @Test("Disconnecting the routed device falls back to the app's previous device, not the global top")
    func disconnectFallsBackToPreviousDevice() async {
        let fix = PriorityFixture()
        fix.launch()
        await fix.select(F.monitor)
        await fix.select(F.airpods)
        #expect(await fix.waitForTap([F.airpods.uid]))

        fix.disconnect(F.airpods)

        #expect(fix.routedUID == F.monitor.uid)
        #expect(fix.followsDefault == false)
        #expect(await fix.waitForTap([F.monitor.uid]))
    }

    @Test("Automatic fallback does not reorder the persisted list")
    func fallbackKeepsPersistedOrder() async {
        let fix = PriorityFixture()
        fix.launch()
        await fix.select(F.monitor)
        await fix.select(F.airpods)

        fix.disconnect(F.airpods)

        #expect(fix.persistedPriority == [F.airpods.uid, F.monitor.uid])
    }

    @Test("Fallback skips list entries that are connected but not alive")
    func fallbackSkipsDeadDevices() async {
        let fix = PriorityFixture(devices: [F.speakers, F.monitor, F.airpods, F.tv])
        fix.launch()
        await fix.select(F.tv)
        await fix.select(F.monitor)
        await fix.select(F.airpods)
        fix.deadDeviceIDs = [F.monitor.id]

        fix.disconnect(F.airpods)

        #expect(fix.routedUID == F.tv.uid)
        #expect(await fix.waitForTap([F.tv.uid]))
    }

    @Test("When no listed device is available the app follows the system default fallback")
    func noListedDeviceFallsBackToSystem() async {
        let fix = PriorityFixture()
        fix.launch()
        await fix.select(F.airpods)

        fix.disconnect(F.airpods)

        // Global output priority is registration order: speakers first
        #expect(fix.routedUID == F.speakers.uid)
        #expect(fix.followsDefault == true)
        #expect(await fix.waitForTap([F.speakers.uid]))
        // Preference is kept for reconnection
        #expect(fix.persistedPriority == [F.airpods.uid])
    }

    @Test("Apps following the system default keep the existing global fallback")
    func followDefaultAppUsesGlobalFallback() async {
        let fix = PriorityFixture(defaultUID: "airpods")
        fix.launch()
        #expect(fix.followsDefault == true)
        #expect(await fix.waitForTap([F.airpods.uid]))

        fix.disconnect(F.airpods)

        #expect(fix.routedUID == F.speakers.uid)
        #expect(fix.followsDefault == true)
        #expect(fix.persistedPriority.isEmpty)
    }

    @Test("Disconnecting a device the app isn't using changes nothing")
    func unrelatedDisconnect() async {
        let fix = PriorityFixture()
        fix.launch()
        await fix.select(F.monitor)
        #expect(await fix.waitForTap([F.monitor.uid]))

        fix.disconnect(F.airpods)
        await fix.settle()

        #expect(fix.routedUID == F.monitor.uid)
        #expect(fix.tap?.currentDeviceUIDs == [F.monitor.uid])
    }

    // MARK: Connect

    @Test("Reconnecting the top device moves the app back to it")
    func reconnectRestoresTopDevice() async {
        let fix = PriorityFixture()
        fix.launch()
        await fix.select(F.monitor)
        await fix.select(F.airpods)
        fix.disconnect(F.airpods)
        #expect(await fix.waitForTap([F.monitor.uid]))

        fix.connect(F.airpods)

        #expect(fix.routedUID == F.airpods.uid)
        #expect(fix.followsDefault == false)
        #expect(await fix.waitForTap([F.airpods.uid]))
    }

    @Test("Connecting a lower-ranked device does not steal the app")
    func lowerRankedConnectDoesNotSwitch() async {
        let fix = PriorityFixture(devices: [F.speakers, F.monitor])
        fix.settings.setDevicePriority(for: fix.app.persistenceIdentifier, [F.monitor.uid, F.airpods.uid])
        fix.launch()
        #expect(await fix.waitForTap([F.monitor.uid]))

        fix.connect(F.airpods)
        await fix.settle()

        #expect(fix.routedUID == F.monitor.uid)
        #expect(fix.tap?.currentDeviceUIDs == [F.monitor.uid])
    }

    @Test("Connecting a device that isn't in the app's list does not switch it")
    func unlistedConnectDoesNotSwitch() async {
        let fix = PriorityFixture(devices: [F.speakers, F.monitor])
        fix.launch()
        await fix.select(F.monitor)
        #expect(await fix.waitForTap([F.monitor.uid]))

        fix.connect(F.tv)
        await fix.settle()

        #expect(fix.routedUID == F.monitor.uid)
    }

    @Test("A connected but not-yet-alive device is not switched to until it becomes the best alive entry")
    func notAliveConnectWaits() async {
        let fix = PriorityFixture()
        fix.launch()
        await fix.select(F.monitor)
        await fix.select(F.airpods)
        fix.disconnect(F.airpods)
        #expect(await fix.waitForTap([F.monitor.uid]))

        fix.deadDeviceIDs = [F.airpods.id]
        fix.connect(F.airpods)
        await fix.settle()
        #expect(fix.routedUID == F.monitor.uid)

        // The alive watcher re-runs the connect handling once the device is alive
        fix.deadDeviceIDs = []
        fix.deviceMonitor.onDeviceConnected?(F.airpods.uid, F.airpods.name)
        #expect(fix.routedUID == F.airpods.uid)
        #expect(await fix.waitForTap([F.airpods.uid]))
    }

    @Test("Apps following the system default are not moved by a device connecting")
    func followDefaultAppIgnoresConnect() async {
        let fix = PriorityFixture(devices: [F.speakers, F.monitor])
        fix.launch()
        #expect(await fix.waitForTap([F.speakers.uid]))

        fix.connect(F.airpods)
        await fix.settle()

        #expect(fix.routedUID == F.speakers.uid)
        #expect(fix.followsDefault == true)
    }

    @Test("Multi-device apps are not collapsed to a single device on connect")
    func multiModeIgnoredByPriority() async {
        let fix = PriorityFixture()
        fix.launch()
        await fix.select(F.airpods)
        fix.engine.setDeviceSelectionMode(for: fix.app, to: .multi)
        fix.engine.setSelectedDeviceUIDs(for: fix.app, to: [F.speakers.uid, F.monitor.uid])
        #expect(await fix.waitForTap([F.monitor.uid, F.speakers.uid]))

        fix.disconnect(F.airpods)
        fix.connect(F.airpods)
        await fix.settle()

        #expect(fix.tap?.currentDeviceUIDs == [F.monitor.uid, F.speakers.uid])
    }

    // MARK: Full chain

    @Test("Three-device chain walks down on disconnect and back up on reconnect")
    func threeDeviceChain() async {
        let fix = PriorityFixture(devices: [F.speakers, F.monitor, F.airpods, F.tv])
        fix.launch()
        await fix.select(F.tv)
        await fix.select(F.monitor)
        await fix.select(F.airpods)
        #expect(await fix.waitForTap([F.airpods.uid]))

        fix.disconnect(F.airpods)
        #expect(await fix.waitForTap([F.monitor.uid]))

        fix.disconnect(F.monitor)
        #expect(await fix.waitForTap([F.tv.uid]))

        fix.connect(F.monitor)
        #expect(await fix.waitForTap([F.monitor.uid]))

        fix.connect(F.airpods)
        #expect(await fix.waitForTap([F.airpods.uid]))
        #expect(fix.persistedPriority == [F.airpods.uid, F.monitor.uid, F.tv.uid])
    }

    @Test("Manual selection while displaced re-ranks the list for future connects")
    func manualSelectionWhileDisplaced() async {
        let fix = PriorityFixture()
        fix.launch()
        await fix.select(F.monitor)
        await fix.select(F.airpods)
        fix.disconnect(F.airpods)

        await fix.select(F.speakers)
        #expect(fix.persistedPriority == [F.speakers.uid, F.airpods.uid, F.monitor.uid])

        fix.connect(F.airpods)
        await fix.settle()
        #expect(fix.routedUID == F.speakers.uid)
    }

    // MARK: Launch

    @Test("Launching picks the highest-ranked available device from the list")
    func launchUsesHighestAvailable() async {
        let fix = PriorityFixture(devices: [F.speakers, F.monitor])
        fix.settings.setDevicePriority(for: fix.app.persistenceIdentifier, [F.airpods.uid, F.monitor.uid])

        fix.launch()

        #expect(fix.routedUID == F.monitor.uid)
        #expect(fix.followsDefault == false)
        #expect(await fix.waitForTap([F.monitor.uid]))
    }

    @Test("Launching with no listed device available follows the default and keeps the list")
    func launchWithNothingAvailable() async {
        let fix = PriorityFixture(devices: [F.speakers])
        fix.settings.setDevicePriority(for: fix.app.persistenceIdentifier, [F.airpods.uid, F.monitor.uid])

        fix.launch()

        #expect(fix.routedUID == F.speakers.uid)
        #expect(fix.followsDefault == true)
        #expect(fix.persistedPriority == [F.airpods.uid, F.monitor.uid])

        fix.connect(F.monitor)
        #expect(fix.routedUID == F.monitor.uid)
        #expect(fix.followsDefault == false)
    }

    // MARK: Manual edits

    @Test("Moving a device above the current one switches the app to it")
    func moveUpSwitches() async {
        let fix = PriorityFixture()
        fix.launch()
        await fix.select(F.monitor)
        await fix.select(F.airpods)
        #expect(await fix.waitForTap([F.airpods.uid]))

        fix.engine.moveDeviceInPriority(F.monitor.uid, by: -1, forIdentifier: fix.app.persistenceIdentifier)

        #expect(fix.persistedPriority == [F.monitor.uid, F.airpods.uid])
        #expect(fix.routedUID == F.monitor.uid)
        #expect(await fix.waitForTap([F.monitor.uid]))
    }

    @Test("Moving a disconnected device to the top doesn't move the app")
    func moveDisconnectedDeviceUp() async {
        let fix = PriorityFixture(devices: [F.speakers, F.monitor])
        fix.settings.setDevicePriority(for: fix.app.persistenceIdentifier, [F.monitor.uid, F.airpods.uid])
        fix.launch()
        #expect(await fix.waitForTap([F.monitor.uid]))

        fix.engine.moveDeviceInPriority(F.airpods.uid, by: -1, forIdentifier: fix.app.persistenceIdentifier)
        await fix.settle()

        #expect(fix.persistedPriority == [F.airpods.uid, F.monitor.uid])
        #expect(fix.routedUID == F.monitor.uid)
    }

    @Test("Removing the current device moves the app to the next one")
    func removeCurrentDevice() async {
        let fix = PriorityFixture()
        fix.launch()
        await fix.select(F.monitor)
        await fix.select(F.airpods)

        fix.engine.removeDeviceFromPriority(F.airpods.uid, forIdentifier: fix.app.persistenceIdentifier)

        #expect(fix.persistedPriority == [F.monitor.uid])
        #expect(fix.routedUID == F.monitor.uid)
        #expect(await fix.waitForTap([F.monitor.uid]))
    }

    @Test("Removing the last device makes the app follow the system default")
    func removeLastDevice() async {
        let fix = PriorityFixture()
        fix.launch()
        await fix.select(F.airpods)
        #expect(await fix.waitForTap([F.airpods.uid]))

        fix.engine.removeDeviceFromPriority(F.airpods.uid, forIdentifier: fix.app.persistenceIdentifier)

        #expect(fix.persistedPriority.isEmpty)
        #expect(fix.settings.isFollowingDefault(for: fix.app.persistenceIdentifier))
        #expect(fix.followsDefault == true)
        #expect(fix.routedUID == F.speakers.uid)
        #expect(await fix.waitForTap([F.speakers.uid]))
    }

    @Test("Editing the list of an app that isn't running only updates settings")
    func editInactiveApp() {
        let fix = PriorityFixture()
        let id = "com.example.not-running"
        fix.settings.setDevicePriority(for: id, [F.airpods.uid, F.monitor.uid])

        fix.engine.moveDeviceInPriority(F.monitor.uid, by: -1, forIdentifier: id)

        #expect(fix.engine.devicePriority(forIdentifier: id) == [F.monitor.uid, F.airpods.uid])
        #expect(fix.tap == nil)
    }

    @Test("Selecting System Audio clears the list so disconnects use the global fallback")
    func systemAudioClearsList() async {
        let fix = PriorityFixture()
        fix.launch()
        await fix.select(F.monitor)
        fix.engine.setDevice(for: fix.app, deviceUID: nil)

        #expect(fix.persistedPriority.isEmpty)
        #expect(fix.followsDefault == true)
    }

    // MARK: Device names

    @Test("Device names are remembered so disconnected devices can be labelled")
    func namesRemembered() {
        let fix = PriorityFixture()
        #expect(fix.engine.outputDeviceName(for: F.airpods.uid) == F.airpods.name)

        fix.disconnect(F.airpods)
        #expect(fix.engine.outputDeviceName(for: F.airpods.uid) == F.airpods.name)

        let renamed = AudioDevice(id: F.tv.id, uid: F.tv.uid, name: "Bedroom TV", icon: nil, supportsAutoEQ: false)
        fix.connect(renamed)
        fix.disconnect(renamed)
        #expect(fix.engine.outputDeviceName(for: F.tv.uid) == "Bedroom TV")
        #expect(fix.engine.outputDeviceName(for: "never-seen") == nil)
    }
}
