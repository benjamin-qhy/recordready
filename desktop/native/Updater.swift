import AppKit
#if canImport(Sparkle)
import Sparkle

/// All callbacks, recording state and the installation reservation share MainActor.
@MainActor final class RecordReadyUpdater: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    static let shared = RecordReadyUpdater()
    var updater: SPUUpdater?
    var phase = "unavailable"
    var availableVersion = ""
    var message = ""
    var received: UInt64 = 0
    var total: UInt64 = 0
    var choice: ((SPUUserUpdateChoice) -> Void)?
    var install: ((SPUUserUpdateChoice) -> Void)?
    var cancel: (() -> Void)?
    var downloadRequested = false
    var timer: Timer?
    var authorizeExit: (@convention(c) (Int32) -> Void)?
    var menuItem: NSMenuItem?
    var zh: Bool { Recorder.shared.language == "zh-CN" }

    func start(_ authorize: @escaping @convention(c) (Int32) -> Void) {
        guard updater == nil else { return }
        authorizeExit = authorize
        let item = NSMenuItem(title: "检查更新… / Check for Updates…", action: #selector(menuCheck), keyEquivalent: "")
        item.target = self
        NSApplication.shared.mainMenu?.items.first?.submenu?.insertItem(item, at: 1)
        menuItem = item
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        let instance = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        updater = instance
        do {
            try instance.start()
            phase = "idle"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.check(background: true) }
            timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.check(background: true) }
            }
        } catch { fail(error) }
    }
    @objc func menuCheck() {
        Recorder.shared.uiCallback?("updates")
        check(background: false)
    }
    func check(background: Bool) {
        guard let updater, updater.canCheckForUpdates else { return }
        guard !["available", "downloading", "preparing", "ready", "installing"].contains(phase) else { return }
        phase = "checking"; message = ""
        if background { updater.checkForUpdateInformation() } else { updater.checkForUpdates() }
    }
    func snapshot() -> [String: Any] {
        ["phase": phase, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
         "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", "availableVersion": availableVersion,
         "received": received, "total": total, "message": message]
    }
    func action(_ action: String) throws -> [String: Any] {
        switch action {
        case "status": break
        case "check": check(background: false)
        case "download":
            guard phase == "available" else { break }
            message = ""
            if let reply = choice { choice = nil; phase = "downloading"; reply(.install) }
            else { downloadRequested = true; updater?.checkForUpdates() }
        case "cancel":
            downloadRequested = false
            let callback = cancel; cancel = nil; callback?(); phase = "idle"
        case "before-quit":
            let pendingInstall = install; install = nil; pendingInstall?(.skip)
            let pendingChoice = choice; choice = nil; pendingChoice?(.dismiss)
            cancel?(); cancel = nil
        case "later": Recorder.shared.uiCallback?("appearance")
        case "install":
            guard phase == "ready", install != nil else { break }
            // Never open a modal confirmation over an active recording.
            guard Recorder.shared.reserveUpdateInstallation() else { throw ProbeError.message("session_busy") }
            let alert = NSAlert()
            alert.messageText = zh ? "重启安装 RecordReady 更新？" : "Restart to install the RecordReady update?"
            alert.informativeText = zh ? "已保存的视频和设置将保留。" : "Saved recordings and settings will be preserved."
            alert.addButton(withTitle: zh ? "稍后" : "Later")
            alert.addButton(withTitle: zh ? "重启安装" : "Restart and Install")
            guard alert.runModal() == .alertSecondButtonReturn else { Recorder.shared.releaseUpdateInstallation(); break }
            guard Recorder.shared.updateInstallationStillSafe else {
                Recorder.shared.releaseUpdateInstallation(); throw ProbeError.message("session_busy")
            }
            Recorder.shared.persistConfiguration(); Recorder.shared.persistLayout()
            authorizeExit?(1)
            allowQuit()
            phase = "installing"
            let reply = install; install = nil; reply?(.install)
        default: throw ProbeError.message("unknown_update_action")
        }
        return snapshot()
    }
    func fail(_ error: Error) {
        phase = "error"; message = error.localizedDescription
        choice = nil; install = nil; cancel = nil; downloadRequested = false
        Recorder.shared.releaseUpdateInstallation()
        revokeUpdateQuit(); authorizeExit?(0)
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { phase = "checking"; cancel = cancellation }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        availableVersion = appcastItem.displayVersionString
        guard !appcastItem.isInformationOnlyUpdate else { phase = "error"; message = zh ? "此版本需要手动下载安装。" : "This version requires a manual download."; reply(.dismiss); return }
        if state.stage == .installing { install = reply; phase = "ready" }
        else if downloadRequested { downloadRequested = false; phase = "downloading"; reply(.install) }
        else { choice = reply; phase = "available" }
        cancel = nil
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        downloadRequested = false; phase = "current"; message = error.localizedDescription; cancel = nil; acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { fail(error); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        phase = "downloading"; received = 0; total = 0; cancel = cancellation
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { total = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) { received += length }
    func showDownloadDidStartExtractingUpdate() { phase = "preparing"; cancel = nil }
    func showExtractionReceivedProgress(_ progress: Double) { phase = "preparing" }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        phase = "ready"; install = reply; cancel = nil
        // Keep the reply pending for Later; no install consent is inferred from an idle session.
        Recorder.shared.uiCallback?("updates")
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { phase = "installing" }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        choice = nil; install = nil; cancel = nil; downloadRequested = false
        if phase != "installing" {
            Recorder.shared.releaseUpdateInstallation(); revokeUpdateQuit(); authorizeExit?(0)
            if !["error", "current", "unavailable"].contains(phase) { phase = "idle" }
        }
    }
    func showUpdateInFocus() { Recorder.shared.uiCallback?("updates") }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        if phase == "checking" { phase = "available" }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error, !((error as NSError).domain == SUSparkleErrorDomain && (error as NSError).code == SUError.noUpdateError.rawValue) { fail(error) }
        else if phase == "checking" { phase = "current"; downloadRequested = false }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if (error as NSError).domain == SUSparkleErrorDomain && (error as NSError).code == SUError.noUpdateError.rawValue {
            phase = "current"; downloadRequested = false
        } else { fail(error) }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // A final native check; reservation prevents a new recording between confirmation and quit.
        !Recorder.shared.updateInstallationStillSafe
    }
}

@_cdecl("rr_start_updater")
@MainActor public func startUpdater(_ callback: @escaping @convention(c) (Int32) -> Void) { RecordReadyUpdater.shared.start(callback) }

@MainActor func updateRequest(_ action: String) throws -> [String: Any] { try RecordReadyUpdater.shared.action(action) }
#else
@MainActor func updateRequest(_ action: String) throws -> [String: Any] { ["phase": "unavailable", "version": "development"] }
#endif
