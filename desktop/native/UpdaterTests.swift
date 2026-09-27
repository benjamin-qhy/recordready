import Foundation
import AppKit
import Sparkle

@main struct UpdaterTests {
    @MainActor static func main() async throws {
        let recorder = Recorder.shared
        let driver = RecordReadyUpdater.shared
        for phase in ["preparing","countdown","starting","recording","paused","saving","unknown"] {
            recorder.phase = phase
            var installed = false
            driver.showReady { choice in installed = choice == .install }
            do { _ = try driver.action("install"); fatalError("Busy session accepted installation") }
            catch { precondition(!installed && !recorder.updateGate.reserved) }
        }
        recorder.phase = "idle"
        precondition(recorder.reserveUpdateInstallation())
        for action in ["start","prepare","configure","restore-session"] {
            do { _ = try await recorder.request(["action":action]); fatalError("Installation race accepted \(action)") }
            catch { precondition(recorder.phase == "idle") }
        }
        driver.fail(NSError(domain:"test",code:1))
        precondition(!recorder.updateGate.reserved && driver.phase == "error")
        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveExpectedContentLength(4000)
        driver.showDownloadDidReceiveData(ofLength: 2000)
        precondition(driver.received == 2000 && driver.total == 4000)
        driver.showDownloadInitiated(cancellation: {})
        precondition(driver.received == 0 && driver.total == 0, "Full package fallback must clear delta counters")
        var quitChoice: SPUUserUpdateChoice?
        driver.showReady { quitChoice = $0 }
        _ = try driver.action("before-quit")
        precondition(quitChoice == .skip, "Normal quit must cancel staged installation without consent")
        driver.downloadRequested = true
        _ = try driver.action("cancel")
        precondition(!driver.downloadRequested, "Cancellation must revoke download consent")
        driver.downloadRequested = true
        driver.showUpdateNotFoundWithError(NSError(domain:SUSparkleErrorDomain,code:Int(SUError.noUpdateError.rawValue)), acknowledgement: {})
        precondition(!driver.downloadRequested, "No-update result must revoke download consent")
        driver.showReady { _ in }
        driver.dismissUpdateInstallation()
        precondition(driver.install == nil && driver.phase != "ready", "Dismissal must tear down pending installation")
        print("Updater integration tests passed: busy phases, start race, failure recovery, fallback progress, quit consent")
    }
}
