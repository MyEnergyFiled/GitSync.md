import SwiftUI

struct HugoSiteConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    let configuration: HugoSiteConfiguration

    var body: some View {
        NavigationStack {
            Group {
                if configuration.isDetected {
                    Form {
                        valuesSection("Configuration Files", values: configuration.configurationFiles)
                        valuesSection("Themes", values: configuration.themes)

                        Section("Languages") {
                            LabeledContent("Default Language", value: configuration.defaultContentLanguage ?? "—")
                            ForEach(configuration.languages, id: \.self) { language in
                                Text(language).font(.body.monospaced())
                            }
                        }

                        Section("Permalinks") {
                            if configuration.permalinks.isEmpty {
                                Text("—")
                            } else {
                                ForEach(configuration.permalinks.keys.sorted(), id: \.self) { key in
                                    LabeledContent(key, value: configuration.permalinks[key] ?? "")
                                }
                            }
                        }

                        valuesSection(
                            "Resource Directories",
                            values: configuration.previewResourceDirectories
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "No Hugo Configuration",
                        systemImage: "gearshape",
                        description: Text("No hugo.toml, hugo.yaml, or config directory was found.")
                    )
                }
            }
            .navigationTitle("Site Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func valuesSection(_ title: LocalizedStringKey, values: [String]) -> some View {
        Section(title) {
            if values.isEmpty {
                Text("—")
            } else {
                ForEach(values, id: \.self) { value in
                    Text(value).font(.body.monospaced())
                }
            }
        }
    }
}
