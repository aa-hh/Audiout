// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

extension SerializedSharedState {
    @Suite final class SpeakerLibraryTests: IsolatedSuite {
        private func library(persisted: Bool = true) -> SpeakerLibraryController {
            SpeakerLibraryController(store: SpeakerLibraryStore(directory: scratchDir),
                                     legacyHiddenStore: HiddenSpeakersStore(directory: scratchDir), loadPersisted: persisted)
        }

        private func speaker(_ id: String, name: String = "Speaker", kind: Device.Kind = .homePod,
                             available: Bool = true, connection: ConnectionState = .off) -> Device {
            Device(id: id, name: name, kind: kind, isAvailable: available, connectionState: connection)
        }

        // Remembering mere discovery, hiding, or recovery would retain an unused speaker after restart.
        @Test func onlySuccessfulUseSavedMembersAndAlwaysRememberIdentity() throws {
            let controller = library()
            let fleet = [speaker("used"), speaker("scene"), speaker("always"), speaker("hidden"), speaker("browsed")]
            let group = Group(id: "g", name: "Room", memberIDs: ["scene", "missing"], memberVolumes: [:])
            controller.update(liveDevices: fleet, groups: [group], confirmedUsedIDs: ["used"],
                              currentUse: SpeakerCurrentUse(recoveryIDs: ["browsed"]))
            controller.setVisibility(.always, for: "always")
            controller.setVisibility(.hideWhenNotInUse, for: "hidden")
            let reloaded = library()
            reloaded.update(liveDevices: [], groups: [group])
            #expect(Set(reloaded.records.map(\.id)) == ["used", "scene", "always", "missing"])
            #expect(reloaded.visibility(for: "hidden") == .hideWhenNotInUse)
            #expect(reloaded.record(for: "missing")?.metadataIsKnown == false)
            let stored = try #require(try SpeakerLibraryStore(directory: scratchDir).load())
            #expect(Set(stored.metadata.keys) == ["used", "scene", "always"])
            let json = try String(contentsOf: scratchDir.appendingPathComponent("speaker-library.json"), encoding: .utf8)
            #expect(!json.contains("connectionState") && !json.contains("volume") && !json.contains("isAvailable"))
        }

        // Reimporting legacy IDs would undo a visibility choice on the next launch.
        @Test func migrationIsOneTimeAndLeavesLegacyBytesUntouched() throws {
            let legacy = HiddenSpeakersStore(directory: scratchDir)
            try legacy.save(["old", "unknown"])
            let legacyURL = scratchDir.appendingPathComponent("hidden-speakers.json")
            let before = try Data(contentsOf: legacyURL)
            let controller = library()
            #expect(controller.visibility(for: "old") == .hideWhenNotInUse)
            #expect(controller.record(for: "unknown") == nil)
            controller.setVisibility(.whenAvailable, for: "old")
            let reloaded = library()
            #expect(reloaded.visibility(for: "old") == .whenAvailable)
            #expect(reloaded.visibility(for: "unknown") == .hideWhenNotInUse)
            #expect(try Data(contentsOf: legacyURL) == before)
            #expect(try SpeakerLibraryStore(directory: scratchDir).load()?.visibility["old"] == nil)
        }

        // Merging by name or retaining old live values would show another transport's identity and controls.
        @Test func exactIDRediscoveryReplacesLiveValuesAndRefreshesRememberedIdentity() throws {
            let controller = library()
            controller.update(liveDevices: [speaker("a", name: "Same"), speaker("b", name: "Same", kind: .bluetooth)],
                              groups: [], confirmedUsedIDs: ["a", "b"])
            #expect(controller.records.count == 2)
            var fresh = speaker("a", name: "Renamed", kind: .cast)
            fresh.volume = 73
            controller.update(liveDevices: [fresh], groups: [])
            #expect(controller.record(for: "a")?.liveDevice == fresh)
            #expect(controller.record(for: "b")?.kind == .bluetooth)
            let reloaded = library()
            #expect(reloaded.record(for: "a")?.displayName == "Renamed")
            #expect(reloaded.record(for: "a")?.kind == .cast)
            #expect(reloaded.record(for: "a")?.liveDevice == nil)
        }

        // Inferring transport or exposing synthetic routing state would misrepresent an unknown scene member.
        @Test func unknownSceneMembersRemainHonestAndRenderingNeverSelectsThem() throws {
            let controller = library(persisted: false)
            let id = "AA:BB:CC-bluetooth-looking-id"
            let group = Group(id: "g", name: "Legacy", memberIDs: [id], memberVolumes: [id: 88])
            controller.update(liveDevices: [], groups: [group])
            let record = try #require(controller.record(for: id))
            #expect(record.displayName == "Missing speaker")
            #expect(record.kind == nil)
            #expect(record.status == .missing)
            #expect(record.secondaryText == id && record.accessibilityIdentity.contains(id))
            #expect(!record.renderingDevice.isSelected && !record.renderingDevice.isAvailable)
            #expect(record.renderingDevice.connectionState == .off)
            #expect(record.renderingDevice.volume == 0 && !record.renderingDevice.supportsAirPlay2)
            #expect(!record.isVisibleInMixer)
        }

        // Checking absence before connection state would label a live undiscovered Cast session unavailable.
        @Test func transportStatusUsesLiveSessionBeforeDiscoveryAbsence() throws {
            let controller = library(persisted: false)
            let failure = ConnectionFailure(cause: .authRequired)
            let fleet = [speaker("live", kind: .cast, available: false, connection: .connected),
                         speaker("bt", kind: .bluetooth, available: false), speaker("network", available: false),
                         speaker("idle"), speaker("bt-on", kind: .bluetooth),
                         speaker("connecting", available: false, connection: .connecting),
                         speaker("reconnecting", available: false, connection: .reconnecting),
                         speaker("failed", available: false, connection: .failed(failure))]
            controller.update(liveDevices: fleet, groups: [])
            let expected: [String: SpeakerPresentationStatus] = ["live": .connected, "bt": .notConnected,
                "network": .unavailable, "idle": .available, "bt-on": .connected, "connecting": .connecting,
                "reconnecting": .reconnecting, "failed": .failed(failure)]
            for (id, status) in expected { #expect(controller.record(for: id)?.status == status) }
            #expect(controller.record(for: "live")?.isAvailable == true)
            #expect(controller.record(for: "failed")?.status.text == failure.headline)
        }

        // Treating saved membership as use, or ignoring absent app-scene intent, would hide the wrong rows.
        @Test func allThreeVisibilityChoicesRespectOnlyCurrentUseAndLocalMac() throws {
            let controller = library(persisted: false)
            let ids: Set<String> = ["main", "device-app", "group-app", "feed", "connecting", "recovery", "inactive"]
            var fleet = ids.map { speaker($0, available: false) }
            fleet.append(speaker("available"))
            fleet.append(speaker("physical-bt", kind: .bluetooth))
            fleet.append(Device(id: "local", name: "Mac", kind: .localMac, isAvailable: false, isLocalDevice: true))
            fleet[fleet.firstIndex(where: { $0.id == "connecting" })!].connectionState = .connecting
            let active = Group(id: "active", name: "App scene", memberIDs: ["group-app", "absent-app"], memberVolumes: [:])
            let inactive = Group(id: "inactive-scene", name: "Saved", memberIDs: ["inactive"], memberVolumes: [:])
            let use = SpeakerCurrentUse(mainAudioMemberIDs: ["main"], appRouteDestinations: [.device(id: "device-app"), .group(id: "active")],
                                        liveFeedIDs: ["feed"], recoveryIDs: ["recovery"])
            controller.update(liveDevices: fleet, groups: [active, inactive], currentUse: use)
            #expect(Set(controller.mixerRecords.map(\.id)) == ids.subtracting(["inactive"]).union(["local", "available", "physical-bt", "absent-app"]))
            controller.setVisibility(.always, for: "inactive")
            #expect(controller.record(for: "inactive")?.isVisibleInMixer == true)
            controller.setVisibility(.hideWhenNotInUse, for: ids.union(["available", "physical-bt", "absent-app", "local"]))
            #expect(controller.record(for: "available")?.isVisibleInMixer == false)
            #expect(controller.record(for: "physical-bt")?.status == .connected)
            #expect(controller.record(for: "physical-bt")?.isVisibleInMixer == false)
            #expect(controller.record(for: "inactive")?.isVisibleInMixer == false)
            #expect(controller.record(for: "local")?.visibility == .whenAvailable)
            #expect(controller.record(for: "absent-app")?.isVisibleInMixer == true)
        }

        // Publishing each bulk row or before disk success would desynchronize the two speaker screens.
        @Test func bulkPublishesOnceAfterSaveAndNoOpDoesNotPublish() throws {
            let controller = library()
            let fleet = [speaker("a"), speaker("b")]
            controller.update(liveDevices: fleet, groups: [])
            var publications = 0
            var diskWasReady = false
            controller.onChange = {
                publications += 1
                diskWasReady = (try? SpeakerLibraryStore(directory: self.scratchDir).load()?.visibility.count) == 2
            }
            #expect(controller.setVisibility(.always, for: ["a", "b"]))
            #expect(publications == 1 && diskWasReady)
            #expect(controller.setVisibility(.always, for: ["a", "b"]))
            controller.update(liveDevices: fleet, groups: [])
            #expect(publications == 1)
            let inMemory = library(persisted: false)
            inMemory.update(liveDevices: [speaker("memory")], groups: [])
            inMemory.setVisibility(.always, for: "memory")
            #expect(try SpeakerLibraryStore(directory: scratchDir).load()?.metadata["memory"] == nil)
        }

        // Keeping a failed preference write in memory would falsely report a saved visibility change.
        @Test func failedWriteDoesNotChangePreferenceOrPublish() throws {
            let directory = scratchDir.appendingPathComponent("blocked")
            let controller = SpeakerLibraryController(store: SpeakerLibraryStore(directory: directory),
                                                      legacyHiddenStore: HiddenSpeakersStore(directory: directory))
            controller.update(liveDevices: [speaker("a")], groups: [])
            try FileManager.default.removeItem(at: directory)
            try Data("not a directory".utf8).write(to: directory)
            var publications = 0
            controller.onChange = { publications += 1 }
            #expect(!controller.setVisibility(.always, for: "a"))
            #expect(controller.visibility(for: "a") == .whenAvailable)
            #expect(publications == 0)
        }

        // Passing presentation records into routing would add remembered members to the live fleet.
        @Test func visibilityAndRecoveryLeaveRoutingDevicesAndSelectionUntouched() throws {
            let backend = MockBackend(fleet: [], staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false)
            let groupController = GroupController(backend: backend, store: GroupStore(directory: scratchDir),
                                                   routingStore: RoutingStore(directory: scratchDir),
                                                   settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
            let live = [speaker("present")]
            groupController.updateDevices(live)
            let controller = library(persisted: false)
            let group = Group(id: "g", name: "Scene", memberIDs: ["absent"], memberVolumes: [:])
            controller.update(liveDevices: groupController.devices, groups: [group])
            controller.setVisibility(.always, for: "absent")
            let clock = RecoveryClock()
            let recovery = SpeakerRecoveryController(schedule: clock.schedule)
            recovery.lookForSpeaker(id: "absent")
            clock.fire(0)
            #expect(controller.records.count == 2)
            #expect(groupController.devices == live)
            #expect(groupController.selectedDeviceIDs.isEmpty)
            #expect(backend.devices.isEmpty)
        }

        // Overwriting a corrupt or newer library would erase evidence needed to recover saved identities.
        @Test(arguments: ["garbage", #"{"schemaVersion":99,"metadata":{},"visibility":{}}"#])
        func unreadableStoresAreQuarantined(_ contents: String) throws {
            let file = scratchDir.appendingPathComponent("speaker-library.json")
            try Data(contents.utf8).write(to: file)
            _ = try? SpeakerLibraryStore(directory: scratchDir).load()
            let names = try FileManager.default.contentsOfDirectory(atPath: scratchDir.path)
            #expect(!names.contains("speaker-library.json"))
            let quarantined = try #require(names.first { $0.hasPrefix("speaker-library.corrupt-") })
            #expect(try String(contentsOf: scratchDir.appendingPathComponent(quarantined), encoding: .utf8) == contents)
        }

        // Leaving no authoritative file after quarantine would reimport superseded legacy choices on relaunch.
        @Test func quarantineNeverReimportsLegacyChoicesOnLaterLaunch() throws {
            try HiddenSpeakersStore(directory: scratchDir).save(["old"])
            try SpeakerLibraryStore(directory: scratchDir).save(SpeakerLibraryState())
            let file = scratchDir.appendingPathComponent("speaker-library.json")
            try Data("corrupt".utf8).write(to: file)
            let first = library()
            #expect(first.visibility(for: "old") == .whenAvailable)
            #expect(SpeakerLibraryStore(directory: scratchDir).exists)
            let second = library()
            #expect(second.visibility(for: "old") == .whenAvailable)
            try FileManager.default.removeItem(at: file)
            let third = library()
            #expect(third.visibility(for: "old") == .whenAvailable)
            #expect(try String(contentsOf: scratchDir.appendingPathComponent("hidden-speakers.json"), encoding: .utf8).contains("old"))
        }

        // An unknown kind or visibility string throwing out of the envelope decode again quarantines the file and lets the controller write an empty library, or `load` dropping an entry without keeping a copy of the file, turns this test red.
        @Test func unknownEntriesDropAloneAndKeepACopy() throws {
            let file = scratchDir.appendingPathComponent("speaker-library.json")
            let json = #"""
            {"schemaVersion": 1,
             "metadata": {"ok": {"name": "Kitchen", "kind": "homePod"}, "weird": {"name": "Pod", "kind": "teleporter"}},
             "visibility": {"ok": "hideWhenNotInUse", "weird": "always", "odd": "sometimes"}}
            """#
            try Data(json.utf8).write(to: file)
            let alertedBefore = StoreRecovery.quarantinedFileNames.count
            let loaded = try #require(try SpeakerLibraryStore(directory: scratchDir).load())
            #expect(Set(loaded.metadata.keys) == ["ok"])
            #expect(loaded.visibility == ["ok": .hideWhenNotInUse, "weird": .always])
            #expect(StoreRecovery.quarantinedFileNames.count == alertedBefore)
            let names = try FileManager.default.contentsOfDirectory(atPath: scratchDir.path)
            let copy = try #require(names.first { $0.hasPrefix("speaker-library.corrupt-") })
            #expect(try String(contentsOf: scratchDir.appendingPathComponent(copy), encoding: .utf8) == json)
            #expect(library().visibility(for: "ok") == .hideWhenNotInUse)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }

        // The controller's init not saving the cleaned library after a load that dropped an entry turns it red: the
        // second launch drops the same entry again and keeps a second copy.
        @Test func aDroppedEntryIsCopiedOnceNotOnEveryLaunch() throws {
            let file = scratchDir.appendingPathComponent("speaker-library.json")
            try Data(#"""
            {"schemaVersion": 1, "visibility": {},
             "metadata": {"ok": {"name": "Kitchen", "kind": "homePod"}, "weird": {"name": "Pod", "kind": "teleporter"}}}
            """#.utf8).write(to: file)
            func copies() throws -> [String] {
                try FileManager.default.contentsOfDirectory(atPath: scratchDir.path)
                    .filter { $0.hasPrefix("speaker-library.corrupt-") }
            }
            _ = library()
            // A copy is named by the second it was made, so a second copy in the same second would land on the
            // first one's name and fail silently; moving the first aside lets every later copy show.
            let first = try #require(try copies().first)
            try FileManager.default.moveItem(at: scratchDir.appendingPathComponent(first),
                                             to: scratchDir.appendingPathComponent("speaker-library.corrupt-0.json"))
            #expect(library().record(for: "ok")?.displayName == "Kitchen")
            #expect(try copies() == ["speaker-library.corrupt-0.json"])
        }

        // The capture moving before the save, firing on a no-op gesture, or counting the local Mac turns it red.
        @Test func visibilityChangeCapturesOneEventAfterARealWrite() {
            let captured = CapturedEvents()
            Analytics.install(Analytics.Sink(capture: { name, props in captured.append(name, props) },
                                             captureError: { _, _ in }, consentChanged: { _ in }), consent: true)
            defer { Analytics.install(nil, consent: false) }
            let controller = library()
            controller.update(liveDevices: [speaker("a"), speaker("b"),
                                            Device(id: "mac", name: "Mac", kind: .localMac, isAvailable: true, isLocalDevice: true)],
                              groups: [])
            controller.setVisibility(.always, for: ["a", "b", "mac"])
            let events = captured.events()
            #expect(events.count == 1)
            #expect(events.first?.0 == "speaker:visibility_changed")
            #expect(events.first?.1 == ["visibility": "always", "count": "2"])
            controller.setVisibility(.always, for: "a")
            #expect(captured.events().count == 1)
        }

        private func sceneController(_ scenes: [Group]) throws -> GroupController {
            let controller = GroupController(backend: MockBackend(fleet: []), store: GroupStore(directory: scratchDir),
                                             routingStore: RoutingStore(directory: scratchDir),
                                             settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
            for scene in scenes { try controller.saveGroup(scene) }
            return controller
        }

        // Forget leaving the id in either the scene store or the library (metadata, visibility, record) turns it red.
        @Test func forgetRemovesTheSpeakerFromLibraryAndEveryScene() throws {
            let controller = library()
            let kitchen = Group(id: "k", name: "Kitchen", memberIDs: ["live", "gone"], memberVolumes: ["gone": 40])
            let den = Group(id: "d", name: "Den", memberIDs: ["gone", "live"], memberVolumes: [:])
            let scenes = try sceneController([kitchen, den])
            controller.update(liveDevices: [speaker("live")], groups: scenes.groups)
            controller.setVisibility(.always, for: "gone")
            #expect(controller.record(for: "gone")?.liveDevice == nil)
            #expect(try controller.forget(["gone"], scenes: scenes) == 2)
            #expect(controller.record(for: "gone") == nil)
            #expect(controller.visibility(for: "gone") == .whenAvailable)
            #expect(scenes.groups.allSatisfy { $0.memberIDs == ["live"] && $0.memberVolumes["gone"] == nil })
            #expect(try GroupStore(directory: scratchDir).load().allSatisfy { $0.memberIDs == ["live"] })
            let reloaded = library()
            reloaded.update(liveDevices: [], groups: [])
            #expect(reloaded.record(for: "gone") == nil)
        }

        // Forget acting on a speaker the Mac can still see turns it red.
        @Test func forgetIgnoresSpeakersWithALiveDevice() throws {
            let controller = library()
            let scenes = try sceneController([Group(id: "k", name: "Kitchen", memberIDs: ["live", "x"], memberVolumes: [:])])
            controller.update(liveDevices: [speaker("live")], groups: scenes.groups)
            #expect(try controller.forget(["live"], scenes: scenes) == 0)
            #expect(scenes.groups.first?.memberIDs == ["live", "x"])
            #expect(controller.record(for: "live") != nil)
        }

        // Forget dropping a lost speaker that Main Audio or an app route still names turns it red.
        @Test func forgetSkipsALostSpeakerStillInUse() throws {
            let controller = library()
            let scenes = try sceneController([Group(id: "k", name: "Kitchen",
                                                    memberIDs: ["live", "main", "routed", "gone"], memberVolumes: [:])])
            controller.update(liveDevices: [speaker("live")], groups: scenes.groups,
                              currentUse: SpeakerCurrentUse(mainAudioMemberIDs: ["main"],
                                                            appRouteDestinations: [.device(id: "routed")]))
            #expect(try controller.forget(["main", "routed", "gone"], scenes: scenes) == 1)
            #expect(scenes.groups.first?.memberIDs == ["live", "main", "routed"])
            #expect(controller.record(for: "main") != nil)
            #expect(controller.record(for: "routed") != nil)
            #expect(controller.record(for: "gone") == nil)
        }

        // Forget deleting or emptying a scene instead of refusing, or writing one store before the refusal, turns it red.
        @Test func forgetRefusesWhenASceneWouldBeEmptyAndWritesNothing() throws {
            let controller = library()
            let solo = Group(id: "s", name: "Solo", memberIDs: ["gone"], memberVolumes: [:])
            let other = Group(id: "o", name: "Other", memberIDs: ["live", "gone"], memberVolumes: [:])
            let scenes = try sceneController([other, solo])
            controller.update(liveDevices: [speaker("live")], groups: scenes.groups)
            controller.setVisibility(.always, for: "gone")
            #expect(throws: GroupController.GroupError.emptyMembership) { try controller.forget(["gone"], scenes: scenes) }
            #expect(scenes.groups.map(\.memberIDs) == [["live", "gone"], ["gone"]])
            #expect(try GroupStore(directory: scratchDir).load().map(\.memberIDs) == [["live", "gone"], ["gone"]])
            #expect(controller.record(for: "gone") != nil)
            #expect(controller.visibility(for: "gone") == .always)
        }

        // The capture firing before the writes, once per call instead of per speaker, or carrying a wrong scene count turns it red.
        @Test func forgetCapturesOneEventPerSpeakerWithItsSceneCount() throws {
            let captured = CapturedEvents()
            Analytics.install(Analytics.Sink(capture: { name, props in captured.append(name, props) },
                                             captureError: { _, _ in }, consentChanged: { _ in }), consent: true)
            defer { Analytics.install(nil, consent: false) }
            let controller = library()
            let scenes = try sceneController([
                Group(id: "a", name: "A", memberIDs: ["live", "one", "two"], memberVolumes: [:]),
                Group(id: "b", name: "B", memberIDs: ["live", "two"], memberVolumes: [:])])
            controller.update(liveDevices: [speaker("live")], groups: scenes.groups)
            _ = try controller.forget(["one", "two"], scenes: scenes)
            let events = captured.events().filter { $0.0 == "speaker:forgotten" }
            #expect(events.map { $0.1["scenes"] }.sorted { ($0 ?? "") < ($1 ?? "") } == ["1", "2"])
        }

        // A status gaining a button without a destination, or the action title drifting back to Title Case, turns red.
        @Test func bluetoothAccessTablePairsEveryButtonWithItsAction() {
            let asking = "Allow Bluetooth access to see paired speakers that are not connected."
            typealias Row = (String?, String?, SpeakerBluetoothAccessPresentation.Action)
            let expected: [(PermissionStatus, Bool, Row)] = [
                (.granted, false, (nil, nil, .openSettings(.bluetooth))),
                (.granted, true, (nil, nil, .openSettings(.bluetooth))),
                (.denied, false, ("Allow Bluetooth access in System Settings to see paired speakers that are not connected.",
                                  "Open Privacy Settings…", .openSettings(.bluetoothPrivacy))),
                (.denied, true, ("Allow Bluetooth access in System Settings to see paired speakers that are not connected.",
                                 "Open Privacy Settings…", .openSettings(.bluetoothPrivacy))),
                (.unsupported, false, ("Bluetooth access is unavailable on this Mac.", nil, .none)),
                (.unsupported, true, ("Bluetooth access is unavailable on this Mac.", nil, .none)),
                (.unknown, false, (asking, "Allow Bluetooth…", .prime)),
                (.unknown, true, (asking, nil, .none)),
                (.requested, false, (asking, "Allow Bluetooth…", .prime)),
                (.requested, true, (asking, nil, .none)),
            ]
            for (status, priming, row) in expected {
                let presentation = SpeakerBluetoothAccessPresentation(status: status, priming: priming)
                #expect(presentation.explanation == row.0, "\(status) priming \(priming)")
                #expect(presentation.actionTitle == row.1, "\(status) priming \(priming)")
                #expect(presentation.action == row.2, "\(status) priming \(priming)")
            }
        }

        // A connected scene member or a live feed no longer counting as current use, or an inactive scene's member (or an ignored selectedDeviceIDs under a group target) starting to count, turns red.
        @Test func routingStateDerivesCurrentUseAndRemembersUsedSpeakers() {
            let controller = library()
            let fleet = [speaker("a", connection: .connected), speaker("b", available: false), speaker("c"), speaker("d")]
            let scene = Group(id: "S", name: "Scene", memberIDs: ["a", "b"], memberVolumes: [:])
            let other = Group(id: "T", name: "Other", memberIDs: ["d"], memberVolumes: [:])
            controller.update(liveDevices: fleet, groups: [scene, other], mainOut: .group(id: "S"), selectedDeviceIDs: ["d"],
                              appRouteDestinations: [], routedAppNamesByDeviceID: ["c": ["Music"], "d": []], recoveryIDs: [])
            for (id, inUse) in ["a": true, "b": true, "c": true, "d": false] {
                #expect(controller.record(for: id)?.isInUse == inUse, "\(id)")
            }
            let reloaded = library()
            reloaded.update(liveDevices: [], groups: [])
            #expect(reloaded.record(for: "c")?.metadataIsKnown == true)
            #expect(reloaded.record(for: "a")?.metadataIsKnown == true)
        }

        // A same-name arrival or a second click resetting the timer would complete the wrong recovery attempt, so this test turns red.
        @Test func recoveryCoalescesAndCompletesOnlyOnExactFreshID() {
            let clock = RecoveryClock()
            var found: [String] = []
            let recovery = SpeakerRecoveryController(schedule: clock.schedule, onRediscovered: { found.append($0) })
            recovery.lookForSpeaker(id: "a")
            recovery.lookForSpeaker(id: "a")
            #expect(clock.delays == [10])
            recovery.update(liveDevices: [speaker("other", name: "Same")])
            #expect(recovery.state(for: "a") == .looking)
            #expect(recovery.state(for: "a")?.text == "Looking for speaker…")
            recovery.update(liveDevices: [speaker("a", available: false, connection: .connected)])
            #expect(recovery.state(for: "a") == .found && found == ["a"])
            #expect(clock.cancelled == [0])
            clock.fire(0)
            #expect(recovery.state(for: "a") == .found)
        }

        // Accepting a cancelled timer would timeout a newer lookup for the same speaker.
        @Test func timeoutCancellationAndStaleCallbacksDoNotFinishNewAttempt() {
            let clock = RecoveryClock()
            let recovery = SpeakerRecoveryController(schedule: clock.schedule)
            recovery.lookForSpeaker(id: "a")
            clock.fire(0)
            #expect(recovery.state(for: "a") == .notFound)
            #expect(recovery.state(for: "a")?.help == "Check that the speaker is on and on the same network.")
            recovery.lookForSpeaker(id: "a")
            recovery.cancel(id: "a")
            recovery.lookForSpeaker(id: "a")
            clock.fire(1)
            #expect(recovery.state(for: "a") == .looking)
            recovery.cancelAll()
            clock.fire(2)
            #expect(recovery.states.isEmpty && recovery.retainedDeviceIDs.isEmpty)
            #expect(clock.cancelled == [1, 2])
        }

        // Retaining a timer after controller disposal would leave work active after its surface closes, so this test turns red.
        @Test func disposalCancelsPendingRecovery() {
            let clock = RecoveryClock()
            var recovery: SpeakerRecoveryController? = SpeakerRecoveryController(schedule: clock.schedule)
            recovery?.lookForSpeaker(id: "a")
            recovery = nil
            #expect(clock.cancelled == [0])
            clock.fire(0)
        }
    }
}

private final class RecoveryClock {
    var delays: [TimeInterval] = []
    var actions: [() -> Void] = []
    var cancelled: [Int] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> SpeakerRecoveryController.Cancellation {
        let index = actions.count
        delays.append(delay)
        actions.append(action)
        return { self.cancelled.append(index) }
    }

    func fire(_ index: Int) { actions[index]() }
}

final class CapturedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, [String: String])] = []
    func append(_ name: String, _ props: [String: String]) { lock.withLock { items.append((name, props)) } }
    func events() -> [(String, [String: String])] { lock.withLock { items } }
}
