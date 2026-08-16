import Foundation

enum AutomatedPullBlockReason: Equatable, Sendable {
    case protectedDataUnavailable
    case repositoryNotCloned
    case externalStorageUnavailable

    func message(repositoryName: String? = nil) -> String {
        switch self {
        case .protectedDataUnavailable:
            return String(localized: "Unlock the device before running GitSync.md automation. No repository was changed.")
        case .repositoryNotCloned:
            if let repositoryName {
                return String(localized: "\(repositoryName) has not been cloned yet. Open GitSync.md and clone it first.")
            }
            return String(localized: "The repository has not been cloned yet. Open GitSync.md and clone it first.")
        case .externalStorageUnavailable:
            if let repositoryName {
                return String(localized: "\(repositoryName)'s external folder is unavailable. Open GitSync.md while the device is unlocked and grant folder access again.")
            }
            return String(localized: "The external repository folder is unavailable. Open GitSync.md while the device is unlocked and grant folder access again.")
        }
    }
}

enum AutomatedPullPolicy {
    static func shouldValidateCloneDirectory(
        requiresExternalStorage: Bool,
        hasExternalStorageAccess: Bool
    ) -> Bool {
        !requiresExternalStorage || hasExternalStorageAccess
    }

    static func blockReason(
        isProtectedDataAvailable: Bool,
        isCloned: Bool,
        requiresExternalStorage: Bool,
        hasExternalStorageAccess: Bool
    ) -> AutomatedPullBlockReason? {
        guard isProtectedDataAvailable else { return .protectedDataUnavailable }
        if requiresExternalStorage && !hasExternalStorageAccess {
            return .externalStorageUnavailable
        }
        guard isCloned else { return .repositoryNotCloned }
        return nil
    }
}
