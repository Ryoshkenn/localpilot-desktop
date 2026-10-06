import Foundation
import Testing
@testable import LocalPilotDesktop

struct SettingsStoreTests {
    private func tempStore() -> SettingsStore {
        SettingsStore(fileURL: URL.temporaryDirectory.appending(path: "localpilot-settings-\(UUID().uuidString).json"))
    }

    @Test
    func settingsRoundTripPersistsLocalServerSelection() throws {
        let store = tempStore()
        var settings = AppSettings.defaultValue
        settings.modelProviderMode = .localServer
        settings.serverBaseURL = "http://127.0.0.1:11434/v1"
        settings.plannerModel = "qwen3.5-4b"
        settings.dryRunExecutionOnly = false

        try store.save(settings)
        let loaded = try store.load()

        #expect(loaded == settings)
        #expect(loaded.serverURL?.port == 11434)
        #expect(loaded.activeModelLabel == "qwen3.5-4b")
    }

    @Test
    func oldSettingsFilesStillLoad() throws {
        let store = tempStore()
        // Shape written by earlier versions, including the removed managed runtime.
        let legacy = #"{"modelProviderMode":"managed_runtime","useGuardModel":true,"runtimePort":49191,"plannerModel":"planner.gguf","temperature":0.3}"#
        try Data(legacy.utf8).write(to: store.fileURL)

        let loaded = try store.load()

        #expect(loaded.modelProviderMode == .builtIn)
        #expect(loaded.temperature == 0.3)
        #expect(loaded.serverBaseURL == AppSettings.defaultServerURL)
    }

    @Test
    func invalidServerAddressHasNoURL() {
        var settings = AppSettings.defaultValue
        settings.serverBaseURL = "not a url"
        #expect(settings.serverURL == nil)
        settings.serverBaseURL = "ftp://127.0.0.1/v1"
        #expect(settings.serverURL == nil)
    }
}
