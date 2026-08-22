import Foundation

/// Serializes mutating Git operations for each configured repository.
///
/// The shared instance is intentionally process-wide: the foreground app,
/// App Intents, and x-callback handlers may each create their own `AppState`,
/// but they must never mutate the same repository concurrently.
actor GitOperationCoordinator {
    static let shared = GitOperationCoordinator()

    private var activeRepositoryIDs: Set<UUID> = []
    private var waitersByRepositoryID: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func withOperation<Result: Sendable>(
        repoID: UUID,
        operation: @MainActor @Sendable () async -> Result
    ) async -> Result {
        await acquire(repoID: repoID)
        let result = await operation()
        release(repoID: repoID)
        return result
    }

    func withThrowingOperation<Result: Sendable>(
        repoID: UUID,
        operation: @MainActor @Sendable () async throws -> Result
    ) async throws -> Result {
        await acquire(repoID: repoID)
        do {
            let result = try await operation()
            release(repoID: repoID)
            return result
        } catch {
            release(repoID: repoID)
            throw error
        }
    }

    /// Acquires the per-repository queue without carrying an operation closure
    /// across the actor boundary. This is used for async Boolean operations to
    /// avoid a Swift 6.3 IRGen failure when reabstracting `@isolated(any)`
    /// closures that return `Bool`.
    func beginOperation(repoID: UUID) async {
        await acquire(repoID: repoID)
    }

    func endOperation(repoID: UUID) {
        release(repoID: repoID)
    }

    private func acquire(repoID: UUID) async {
        guard activeRepositoryIDs.contains(repoID) else {
            activeRepositoryIDs.insert(repoID)
            return
        }

        await withCheckedContinuation { continuation in
            waitersByRepositoryID[repoID, default: []].append(continuation)
        }
    }

    private func release(repoID: UUID) {
        guard var waiters = waitersByRepositoryID[repoID], !waiters.isEmpty else {
            waitersByRepositoryID.removeValue(forKey: repoID)
            activeRepositoryIDs.remove(repoID)
            return
        }

        let next = waiters.removeFirst()
        if waiters.isEmpty {
            waitersByRepositoryID.removeValue(forKey: repoID)
        } else {
            waitersByRepositoryID[repoID] = waiters
        }
        next.resume()
    }
}
