import Foundation

enum RepositoryFileDestinationError: LocalizedError, Equatable {
    case invalidName
    case outsideRepository

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return String(localized: "Enter a file name without folders, '.', '..', or '.git'.")
        case .outsideRepository:
            return String(localized: "Files must stay inside the repository.")
        }
    }
}

enum RepositoryFileDestinationValidator {
    static func destinationURL(
        for rawName: String,
        in directoryURL: URL,
        repositoryRootURL: URL
    ) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.lowercased() != ".git",
              !name.contains("/"),
              !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw RepositoryFileDestinationError.invalidName
        }

        let resolvedRoot = repositoryRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDirectory = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(resolvedDirectory, within: resolvedRoot) else {
            throw RepositoryFileDestinationError.outsideRepository
        }

        let destination = resolvedDirectory.appendingPathComponent(name).standardizedFileURL
        guard destination.deletingLastPathComponent() == resolvedDirectory,
              contains(destination, within: resolvedRoot) else {
            throw RepositoryFileDestinationError.outsideRepository
        }
        return destination
    }

    private static func contains(_ candidate: URL, within root: URL) -> Bool {
        let rootPath = root.path
        return candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/")
    }
}
