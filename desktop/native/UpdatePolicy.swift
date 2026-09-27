import Foundation

struct UpdateInstallationGate {
    private(set) var reserved = false
    mutating func reserve(phase: String) -> Bool {
        guard !reserved, ["idle", "ready", "saved", "partial", "failed"].contains(phase) else { return false }
        reserved = true
        return true
    }
    mutating func release() { reserved = false }
}
