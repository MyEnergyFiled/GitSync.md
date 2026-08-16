import Foundation

enum GitLongOperationKind: String, Equatable {
    case clone
    case pull
    case push
}

enum GitLongOperationStage: Equatable {
    case preparing
    case connecting
    case transferring
    case checkingRepository
    case applyingChanges
    case committing
    case uploading
    case finalizing
    case completed

    var fraction: Double {
        switch self {
        case .preparing: return 0.05
        case .connecting: return 0.15
        case .transferring: return 0.38
        case .checkingRepository: return 0.60
        case .committing: return 0.72
        case .applyingChanges: return 0.82
        case .uploading: return 0.86
        case .finalizing: return 0.94
        case .completed: return 1.0
        }
    }

    var allowsSafeCancellation: Bool {
        switch self {
        case .preparing, .connecting, .transferring, .checkingRepository:
            return true
        case .applyingChanges, .committing, .uploading, .finalizing, .completed:
            return false
        }
    }

    var title: String {
        switch self {
        case .preparing: return String(localized: "Preparing operation…")
        case .connecting: return String(localized: "Connecting to remote…")
        case .transferring: return String(localized: "Transferring Git objects…")
        case .checkingRepository: return String(localized: "Checking repository state…")
        case .applyingChanges: return String(localized: "Applying worktree changes…")
        case .committing: return String(localized: "Creating local commit…")
        case .uploading: return String(localized: "Uploading to remote…")
        case .finalizing: return String(localized: "Finalizing repository…")
        case .completed: return String(localized: "Operation complete")
        }
    }
}

struct GitLongOperationProgress: Equatable {
    let kind: GitLongOperationKind
    var stage: GitLongOperationStage
    var cancellationRequested = false

    var fraction: Double { stage.fraction }
    var canCancel: Bool { stage.allowsSafeCancellation && !cancellationRequested }
    var message: String {
        cancellationRequested ? String(localized: "Cancellation requested; waiting for a safe stopping point…") : stage.title
    }

    @discardableResult
    mutating func requestCancellationIfSafe() -> Bool {
        guard canCancel else { return false }
        cancellationRequested = true
        return true
    }
}

struct GitOperationCancelled: LocalizedError, Equatable {
    var errorDescription: String? { String(localized: "Git operation cancelled safely.") }
}
