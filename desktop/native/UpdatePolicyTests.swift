import Foundation

@main struct UpdatePolicyTests {
    static func main() {
        for phase in ["preparing", "countdown", "starting", "recording", "paused", "saving", "", "future-state"] {
            var gate = UpdateInstallationGate()
            precondition(!gate.reserve(phase: phase), "Must block \(phase)")
            precondition(!gate.reserved)
        }
        for phase in ["idle", "ready", "saved", "partial", "failed"] {
            var gate = UpdateInstallationGate()
            precondition(gate.reserve(phase: phase), "Must allow idle phase \(phase)")
            precondition(gate.reserved)
            precondition(!gate.reserve(phase: phase), "Cannot reserve twice")
            gate.release()
            precondition(!gate.reserved)
            precondition(gate.reserve(phase: phase), "Must recover after canceled installation")
        }
        print("Update installation policy passed: active/unknown phases blocked, idle phases accepted, reservation exclusive and recoverable")
    }
}
