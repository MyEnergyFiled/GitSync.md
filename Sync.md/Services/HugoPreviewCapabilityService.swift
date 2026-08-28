import Foundation

enum HugoPreviewCapabilityService {
    static func report(
        repositoryRoot: URL,
        selectedTheme: String?,
        configuration: HugoSiteConfiguration,
        runtime: HugoRuntimeVersion
    ) -> HugoCapabilityReport {
        let themes = HugoThemeDiscoveryService.discover(
            in: repositoryRoot,
            configuredThemes: configuration.themes,
            runtimeVersion: runtime.version
        )
        let descriptor = themes.first { $0.directoryName == selectedTheme }
        return HugoThemeCapabilityScanner.report(
            repositoryRoot: repositoryRoot,
            theme: descriptor,
            runtime: runtime
        )
    }
}
