import Foundation

// MARK: - Errors

enum LocalGitError: LocalizedError {
    case notCloned
    case invalidRemoteURL
    case cloneFailed(String)
    case cloneDestinationNotEmpty(String)
    case fetchFailed(String)
    case pushFailed(String)
    case commitFailed(String)
    case noChanges
    case stashNothingToSave
    case stashNotFound(Int)
    case stashApplyConflict
    case pullBlockedByLocalChanges
    case pullDiverged
    case pullRemoteBranchMissing(String)
    case checkoutBlockedByLocalChanges
    case branchAlreadyExists(String)
    case branchNotFound(String)
    case branchIsCurrent(String)
    case mergeBlockedByLocalChanges
    case mergeConflictsDetected
    case rebaseConflictsDetected
    case revertBlockedByLocalChanges
    case noMergeInProgress
    case noRebaseInProgress
    case conflictPathNotFound(String)
    case tagAlreadyExists(String)
    case tagNotFound(String)
    case repositoryCorrupted(String)
    case lfsFailed(String)
    case invalidAuthorIdentity(String)
    case sshHostKeyTrustRequired(GitLFSSSHHostKeyTrustError)
    case libgit2(String)

    var errorDescription: String? {
        switch self {
        case .notCloned:
            return String(localized: "Repository not cloned yet. Clone it first.")
        case .invalidRemoteURL:
            return String(localized: "Invalid remote URL.")
        case .cloneFailed(let msg):
            return String(localized: "Clone failed: \(msg)")
        case .cloneDestinationNotEmpty(let path):
            return String(localized: "Clone stopped to protect existing files at \(path). Open that folder as an existing repository or choose another location.")
        case .fetchFailed(let msg):
            return String(localized: "Fetch failed: \(msg)")
        case .pushFailed(let msg):
            return String(localized: "Push failed: \(msg)")
        case .commitFailed(let msg):
            return String(localized: "Commit failed: \(msg)")
        case .noChanges:
            return String(localized: "No changes to commit.")
        case .stashNothingToSave:
            return String(localized: "No local changes to stash.")
        case .stashNotFound(let index):
            return String(localized: "Stash at index \(index) was not found.")
        case .stashApplyConflict:
            return String(localized: "Applying stash would overwrite local changes. Commit, stash, or discard local edits first.")
        case .pullBlockedByLocalChanges:
            return String(localized: "Pull blocked to protect local edits. Commit, stash, or discard local changes first.")
        case .pullDiverged:
            return String(localized: "Pull requires a merge because local and remote have diverged.")
        case .pullRemoteBranchMissing(let branch):
            return String(localized: "Remote branch '\(branch)' was not found on origin.")
        case .checkoutBlockedByLocalChanges:
            return String(localized: "Switching branches is blocked to protect local edits. Commit, stash, or discard changes first.")
        case .branchAlreadyExists(let name):
            return String(localized: "Branch '\(name)' already exists.")
        case .branchNotFound(let name):
            return String(localized: "Branch '\(name)' was not found.")
        case .branchIsCurrent(let name):
            return String(localized: "Cannot delete the currently checked out branch '\(name)'.")
        case .mergeBlockedByLocalChanges:
            return String(localized: "Merge is blocked to protect local edits. Commit, stash, or discard changes first.")
        case .mergeConflictsDetected:
            return String(localized: "Merge produced conflicts that require manual resolution.")
        case .rebaseConflictsDetected:
            return String(localized: "Rebase produced conflicts that require manual resolution.")
        case .revertBlockedByLocalChanges:
            return String(localized: "Revert is blocked to protect local edits. Commit, stash, or discard changes first.")
        case .noMergeInProgress:
            return String(localized: "No merge is currently in progress.")
        case .noRebaseInProgress:
            return String(localized: "No rebase is currently in progress.")
        case .conflictPathNotFound(let path):
            return String(localized: "No active conflict found for '\(path)'.")
        case .tagAlreadyExists(let name):
            return String(localized: "Tag '\(name)' already exists.")
        case .tagNotFound(let name):
            return String(localized: "Tag '\(name)' was not found.")
        case .repositoryCorrupted(let msg):
            return String(localized: "Repository corrupted: \(msg). Try removing and re-cloning.")
        case .lfsFailed(let msg):
            return String(localized: "Git LFS failed: \(msg)")
        case .invalidAuthorIdentity(let msg):
            return String(localized: "Git author identity is missing or invalid. \(msg) Open repository settings and set Author Name and Author Email.")
        case .sshHostKeyTrustRequired(let error):
            return error.localizedDescription
        case .libgit2(let msg):
            return String(localized: "Git error: \(msg)")
        }
    }
}

// MARK: - Result Types

struct LocalCloneResult: Sendable {
    let commitSHA: String
    let branch: String
    let fileCount: Int
    let lfsWarning: String?

    init(commitSHA: String, branch: String, fileCount: Int, lfsWarning: String? = nil) {
        self.commitSHA = commitSHA
        self.branch = branch
        self.fileCount = fileCount
        self.lfsWarning = lfsWarning
    }
}

struct LocalPullResult: Sendable {
    let updated: Bool
    let newCommitSHA: String
}

struct LocalPushResult: Sendable {
    let commitSHA: String
}

struct LocalRepoInfo: Sendable {
    let branch: String
    let commitSHA: String
    let changeCount: Int
    let syncState: RepoSyncState
    let statusEntries: [GitStatusEntry]

    init(
        branch: String,
        commitSHA: String,
        changeCount: Int,
        syncState: RepoSyncState = .unknown,
        statusEntries: [GitStatusEntry] = []
    ) {
        self.branch = branch
        self.commitSHA = commitSHA
        self.changeCount = changeCount
        self.syncState = syncState
        self.statusEntries = statusEntries
    }
}
