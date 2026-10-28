import AppKit
import Sparkle
import VakenCore

/// Sparkle owns scheduling, preferences, network traffic and signature validation.
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var configured = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var status = "Updates are not configured in this build."
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private weak var model: AppModel?

    init(previewConfigured: Bool = false) {
        super.init()
        if previewConfigured {
            configured = true; canCheck = true; automaticChecks = true
            status = "Updates are checked with Sparkle. Installation requires normal sleep."
        }
    }

    func start(model: AppModel) {
        self.model = model
        do {
            guard try UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) != nil else { return }
        } catch { status = "Update configuration is invalid. Reinstall a trusted build."; return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                DispatchQueue.main.async { self?.canCheck = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                DispatchQueue.main.async { self?.automaticChecks = updater.automaticallyChecksForUpdates }
            },
        ]
        configured = true
        status = "Updates are checked with Sparkle. Installation requires normal sleep."
        controller.startUpdater()
    }

    func check() { controller?.checkForUpdates(nil) }
    func setAutomaticChecks(_ value: Bool) {
        controller?.updater.automaticallyChecksForUpdates = value
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard model?.beginUpdateInteraction() == true else {
            let message = "End the Keep awake session and wait for pending actions to finish, then check for updates again."
            status = message
            throw NSError(domain: "no.ogard.vaken.updates", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        status = "Finish or dismiss the update before starting Keep awake."
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        model?.endUpdateInteraction()
        if let error { status = error.localizedDescription }
        else { status = "Update check finished." }
    }

    // Resumed downloads can skip shouldProceedWithUpdate. Recheck at installation too.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        guard model?.beginUpdateInteraction() == true else {
            status = "End Keep awake before installing the update."
            return false
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        model?.endUpdateInteraction()
        status = error.localizedDescription
    }
}
