import SwiftUI

struct HugoFrontMatterFieldsView: View {
    @Environment(\.dismiss) private var dismiss
    let root: URL
    let onSave: () -> Void

    @State private var fields: [HugoFrontMatterFieldConfiguration]
    @State private var errorMessage: String?

    init(root: URL, onSave: @escaping () -> Void) {
        self.root = root
        self.onSave = onSave
        _fields = State(initialValue: HugoContentService.loadConfiguration(from: root).frontMatterFields)
    }

    private var validationMessage: String? {
        let keys = fields.map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) }
        if keys.contains(where: { !HugoContentService.isValidFrontMatterFieldKey($0) }) {
            return String(localized: "Use a valid custom field key that does not replace a built-in field.")
        }
        if Set(keys.map { $0.lowercased() }).count != keys.count {
            return String(localized: "Custom field keys must be unique.")
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose the additional top-level Front Matter fields shown in the article editor. Unconfigured fields remain unchanged.")
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.brutalTextFaint)
                }

                ForEach($fields) { $field in
                    Section {
                        TextField("Field Key", text: $field.key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Display Name", text: $field.label)
                        Picker("Field Type", selection: $field.type) {
                            ForEach(HugoFrontMatterFieldType.allCases) { type in
                                Text(fieldTypeTitle(type)).tag(type)
                            }
                        }
                        Button("Remove Field", role: .destructive) {
                            fields.removeAll { $0.id == field.id }
                        }
                    }
                }

                Section {
                    Button {
                        fields.append(HugoFrontMatterFieldConfiguration(key: "", label: "", type: .text))
                    } label: {
                        Label("Add Field", systemImage: "plus")
                    }
                }

                if let message = validationMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(Color.brutalError)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Color.brutalError) }
                }
            }
            .navigationTitle("Front Matter Fields")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(validationMessage != nil)
                }
            }
        }
    }

    private func fieldTypeTitle(_ type: HugoFrontMatterFieldType) -> String {
        switch type {
        case .text: return String(localized: "Text")
        case .boolean: return String(localized: "Boolean")
        case .number: return String(localized: "Number")
        }
    }

    private func save() {
        var configuration = HugoContentService.loadConfiguration(from: root)
        configuration.frontMatterFields = fields.map { field in
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = field.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return HugoFrontMatterFieldConfiguration(
                key: key,
                label: label.isEmpty ? key : label,
                type: field.type
            )
        }
        do {
            try HugoContentService.saveConfiguration(configuration, to: root)
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
