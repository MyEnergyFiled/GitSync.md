import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var showContent = true

    var body: some View {
        Group {
            if !state.hasSeenOnboarding && state.repos.isEmpty {
                OnboardingView()
            } else if state.hasCompletedOnboarding || !state.repos.isEmpty {
                RepoListView()
            } else {
                SetupView()
            }
        }
        .opacity(showContent ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                showContent = true
            }
            state.scheduleInitialChangeDetectionIfNeeded()
        }
        .alert(
            state.pendingSSHHostKeyTrustRequest?.title ?? String(localized: "Trust SSH Host?"),
            isPresented: Binding(
                get: { state.pendingSSHHostKeyTrustRequest != nil },
                set: { _ in
                    // Do not clear the pending trust request from the alert's
                    // dismissal write-back. SwiftUI dismisses the alert before
                    // running the button action, so clearing here can make the
                    // “Trust Host” action a no-op. The explicit Cancel button
                    // handles rejection.
                }
            )
        ) {
            Button(String(localized: "Cancel"), role: .cancel) {
                state.cancelPendingSSHHostKeyTrust()
            }
            Button(state.pendingSSHHostKeyTrustRequest?.confirmButtonTitle ?? String(localized: "Trust Host")) {
                Task { await state.trustPendingSSHHostKeyAndRetry() }
            }
        } message: {
            Text(state.pendingSSHHostKeyTrustRequest?.message ?? "")
        }
    }

}

#Preview {
    ContentView()
        .environment(AppState())
}
