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
    static func validatedDirectoryURL(
        _ directoryURL: URL,
        repositoryRootURL: URL
    ) throws -> URL {
        let resolvedRoot = repositoryRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDirectory = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(resolvedDirectory, within: resolvedRoot) else {
            throw RepositoryFileDestinationError.outsideRepository
        }
        return resolvedDirectory
    }

    static func existingFileURL(
        _ fileURL: URL,
        in directoryURL: URL,
        repositoryRootURL: URL
    ) throws -> URL {
        let resolvedDirectory = try validatedDirectoryURL(
            directoryURL,
            repositoryRootURL: repositoryRootURL
        )
        let expectedURL = try destinationURL(
            for: fileURL.lastPathComponent,
            in: resolvedDirectory,
            repositoryRootURL: repositoryRootURL
        )
        let standardizedFile = fileURL.standardizedFileURL
        let resolvedFile = standardizedFile.resolvingSymlinksInPath()
        let values = try? standardizedFile.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard standardizedFile.deletingLastPathComponent().resolvingSymlinksInPath() == resolvedDirectory,
              resolvedFile == expectedURL,
              values?.isRegularFile == true,
              values?.isSymbolicLink != true else {
            throw RepositoryFileDestinationError.outsideRepository
        }
        return resolvedFile
    }

    static func destinationURL(
        forRenaming sourceURL: URL,
        to rawName: String,
        repositoryRootURL: URL
    ) throws -> URL {
        try destinationURL(
            for: rawName,
            in: sourceURL.deletingLastPathComponent(),
            repositoryRootURL: repositoryRootURL
        )
    }

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
        let resolvedDirectory = try validatedDirectoryURL(
            directoryURL,
            repositoryRootURL: repositoryRootURL
        )

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
