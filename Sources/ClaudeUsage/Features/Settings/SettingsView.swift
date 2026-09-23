import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginModel

    var body: some View {
        Form {
            Section("General") {
                Picker("Check every", selection: $store.pollInterval) {
                    Text(" 5 minutes").tag(TimeInterval(5 * 60))
                    Text("10 minutes").tag(TimeInterval(10 * 60))
                    Text("15 minutes").tag(TimeInterval(15 * 60))
                    Text("30 minutes").tag(TimeInterval(30 * 60))
                    Text("60 minutes").tag(TimeInterval(60 * 60))
                }

                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )

                if let errorMessage = launchAtLogin.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Claude Account") {
                AccountRow(
                    isSignedIn: store.claudeIsSignedIn,
                    isSigningIn: store.isSigningInClaude,
                    isSigningOut: store.isSigningOutClaude,
                    connectedTitle: store.claudeEmail ?? "Connected",
                    disconnectedDetail: "Sign in with your browser to track Claude usage limits",
                    feedback: store.claudeAuthFeedback,
                    signIn: { store.signInClaude() },
                    signOut: { store.signOutClaude() },
                    cancelSignIn: { store.cancelClaudeSignIn() }
                )
            }

            Section("OpenAI Account") {
                AccountRow(
                    isSignedIn: store.codexIsSignedIn,
                    isSigningIn: store.isSigningInCodex,
                    isSigningOut: store.isSigningOutCodex,
                    connectedTitle: store.codexEmail ?? "Connected",
                    disconnectedDetail: "Sign in with your browser to track Codex / ChatGPT limits",
                    feedback: store.codexAuthFeedback,
                    signIn: { store.signInCodex() },
                    signOut: { store.signOutCodex() },
                    cancelSignIn: { store.cancelCodexSignIn() }
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear {
            launchAtLogin.refresh()
            Task { await store.refreshAuthState() }
        }
    }
}

private struct AccountRow: View {
    let isSignedIn: Bool
    let isSigningIn: Bool
    let isSigningOut: Bool
    let connectedTitle: String
    let disconnectedDetail: String
    let feedback: UsageStore.AuthFeedback?
    let signIn: () -> Void
    let signOut: () -> Void
    let cancelSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(indicatorColor)
                            .frame(width: 8, height: 8)
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                    }
                    if !isSignedIn {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                controls
            }

            if let feedback {
                Text(feedback.message)
                    .font(.callout)
                    .foregroundStyle(feedback.kind == .failure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if isSigningIn {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel", action: cancelSignIn)
                    .controlSize(.small)
            }
        } else if isSigningOut {
            ProgressView()
                .controlSize(.small)
        } else if isSignedIn {
            Button("Sign Out", action: signOut)
                .controlSize(.small)
        } else {
            Button("Sign In…", action: signIn)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private var title: String {
        if isSigningIn { return "Signing In…" }
        if isSigningOut { return "Signing Out…" }
        return isSignedIn ? connectedTitle : "Not Connected"
    }

    private var detail: String {
        if isSigningIn { return "Finish signing in in your browser, then return here." }
        if isSigningOut { return "Removing the saved sign-in…" }
        if !isSignedIn { return disconnectedDetail } else { return "" }
    }

    private var indicatorColor: Color {
        if isSigningIn || isSigningOut { return .orange }
        return isSignedIn ? .green : .secondary
    }
}
