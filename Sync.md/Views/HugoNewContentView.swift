import SwiftUI

struct HugoNewContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let repoID: UUID
    let initialDirectory: String
    let onCreated: (URL) -> Void

    @State private var title = ""
    @State private var filename = ""
    @State private var directory = ""
    @State private var archetype = ""
    @State private var directories: [String] = []
    @State private var archetypes: [String] = []
    @State private var errorMessage: String?
    @State private var terminalCommand = ""

    private var root: URL { state.vaultURL(for: repoID) }
    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !directory.isEmpty && !archetype.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Hugo command") {
                    HStack(spacing: 8) {
                        Text("$")
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.brutalAccent)
                        TextField("hugo new --kind moments content/moments/my-day.md", text: $terminalCommand)
                            .font(.system(size: 13, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { applyTerminalCommandAndCreate() }
                        Button { applyTerminalCommandAndCreate() } label: {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(Color.brutalAccent)
                        }
                        .buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        commandHelpRow(
                            code: "hugo new",
                            explanation: "Create a new content file from an archetype."
                        )
                        commandHelpRow(
                            code: "--kind moments",
                            explanation: "Use archetypes/moments.md. Change moments to default for archetypes/default.md."
                        )
                        commandHelpRow(
                            code: "content/moments/my-day.md",
                            explanation: "The directory and filename that will be created."
                        )
                        Divider()
                        Text("EXAMPLES")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(1.5)
                        Text("hugo new --kind default content/posts/hello.md")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Text("hugo new --kind moments content/moments/today.md")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Text("This is a safe simulation. GitSync.md parses the text and creates the file; no shell or Hugo binary is executed.")
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.brutalTextFaint)
                    }
                    .padding(.top, 4)
                }
                Section("Article") {
                    TextField("Title", text: $title)
                        .onChange(of: title) { _, value in
                            if filename.isEmpty || filename == ".md" {
                                filename = HugoContentService.slugify(value) + ".md"
                            }
                        }
                    TextField("filename.md", text: $filename)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Content directory") {
                    TextField("content/posts", text: $directory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: directory) { _, value in selectSuggestedTemplate(for: value) }
                    if !directories.isEmpty {
                        Picker("Detected directories", selection: $directory) {
                            ForEach(directories, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                Section("Archetype") {
                    if archetypes.isEmpty {
                        Text("No archetypes/*.md templates found")
                    } else {
                        Picker("Template", selection: $archetype) {
                            ForEach(archetypes, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Text("This mapping is saved in .gitsync-hugo.json and reused next time.")
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.brutalTextFaint)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Color.brutalError) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.brutalBg)
            .navigationTitle("New Hugo Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(!canCreate)
                }
            }
            .onAppear { loadOptions() }
        }
    }

    private func commandHelpRow(code: String, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(code)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalAccent)
            Text(explanation)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.brutalTextFaint)
        }
    }

    private func loadOptions() {
        directories = HugoContentService.contentDirectories(in: root)
        archetypes = HugoContentService.archetypes(in: root)
        let config = HugoContentService.loadConfiguration(from: root)
        directory = directories.contains(initialDirectory) ? initialDirectory : (directories.first ?? "")
        if let saved = config.contentMappings.first(where: { $0.directory == directory }),
           archetypes.contains(saved.archetype) {
            archetype = saved.archetype
        } else {
            selectSuggestedTemplate(for: directory)
        }
        terminalCommand = suggestedCommand()
    }

    private func selectSuggestedTemplate(for value: String) {
        let config = HugoContentService.loadConfiguration(from: root)
        archetype = config.contentMappings.first(where: { $0.directory == value })?.archetype
            ?? HugoContentService.suggestedArchetype(for: value, available: archetypes) ?? ""
    }


    private func suggestedCommand() -> String {
        let kind = URL(fileURLWithPath: archetype).deletingPathExtension().lastPathComponent
        let path = directory.isEmpty ? "content/new-post.md" : "\(directory)/new-post.md"
        return "hugo new --kind \(kind.isEmpty ? "default" : kind) \(path)"
    }

    private func applyTerminalCommandAndCreate() {
        let parts = terminalCommand.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count >= 3, parts[0] == "hugo", parts[1] == "new" else {
            errorMessage = "Use: hugo new --kind <template> content/<directory>/<file>.md"
            return
        }
        var kind: String?
        if let index = parts.firstIndex(of: "--kind"), parts.indices.contains(index + 1) {
            kind = parts[index + 1]
        } else if let value = parts.first(where: { $0.hasPrefix("--kind=") }) {
            kind = String(value.dropFirst("--kind=".count))
        }
        guard let path = parts.last, path.hasPrefix("content/"), !path.contains("..") else {
            errorMessage = "The destination must be a safe path below content/."
            return
        }
        let pathValue = path as NSString
        directory = pathValue.deletingLastPathComponent
        filename = pathValue.lastPathComponent
        if let kind {
            let candidate = "archetypes/\(kind).md"
            guard archetypes.contains(candidate) else {
                errorMessage = "Template \(candidate) was not found."
                return
            }
            archetype = candidate
        } else {
            selectSuggestedTemplate(for: directory)
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = (filename as NSString).deletingPathExtension
                .replacingOccurrences(of: "-", with: " ").capitalized
        }
        create()
    }

    private func create() {
        var safeName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if URL(fileURLWithPath: safeName).pathExtension.isEmpty { safeName += ".md" }
        guard !safeName.contains("/"), !safeName.contains("..") else {
            errorMessage = "Filename cannot contain a path."
            return
        }
        let safeDirectory = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard (safeDirectory == "content" || safeDirectory.hasPrefix("content/")),
              !safeDirectory.contains(".."), archetypes.contains(archetype) else {
            errorMessage = "Choose a safe content/ directory and an existing archetype."
            return
        }
        directory = safeDirectory
        let templateURL = root.appendingPathComponent(archetype)
        let destinationDirectory = root.appendingPathComponent(directory, isDirectory: true)
        let destination = destinationDirectory.appendingPathComponent(safeName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "A file with this name already exists."
            return
        }
        do {
            let template = try String(contentsOf: templateURL, encoding: .utf8)
            let section = URL(fileURLWithPath: directory).lastPathComponent
            let rendered = HugoContentService.render(
                template: template, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                filename: safeName, section: section
            )
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try rendered.write(to: destination, atomically: true, encoding: .utf8)
            var config = HugoContentService.loadConfiguration(from: root)
            config.contentMappings.removeAll { $0.directory == directory }
            config.contentMappings.append(HugoContentMapping(directory: directory, archetype: archetype))
            try HugoContentService.saveConfiguration(config, to: root)
            state.detectChanges(repoID: repoID)
            dismiss()
            onCreated(destination)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
