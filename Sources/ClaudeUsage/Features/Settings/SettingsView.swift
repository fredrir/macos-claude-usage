import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginModel

    var body: some View {
        Form {
            Section("General") {
                Picker("Check every", selection: $store.pollInterval) {
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
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(store.claudeIsSignedIn ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(store.claudeIsSignedIn ? "Connected" : "Not Connected")
                                .font(.system(size: 13, weight: .medium))
                        }
                        Text(store.claudeIsSignedIn
                             ? "Using authenticated Anthropic OAuth session"
                             : "Sign in with your browser to track Claude usage limits")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if store.isSigningInClaude {
                        ProgressView()
                            .controlSize(.small)
                    } else if store.claudeIsSignedIn {
                        Button("Sign Out") {
                            store.signOutClaude()
                        }
                        .controlSize(.small)
                    } else {
                        Button("Sign In…") {
                            store.signInClaude()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            Section("Codex / ChatGPT Account") {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(store.codexIsSignedIn ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(store.codexIsSignedIn
                                 ? (store.codexEmail ?? "Connected")
                                 : "Not Connected")
                                .font(.system(size: 13, weight: .medium))
                        }
                        Text(store.codexIsSignedIn
                             ? "Using authenticated OpenAI OAuth session"
                             : "Sign in with your browser to track Codex / ChatGPT limits")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if store.isSigningInCodex {
                        ProgressView()
                            .controlSize(.small)
                    } else if store.codexIsSignedIn {
                        Button("Sign Out") {
                            store.signOutCodex()
                        }
                        .controlSize(.small)
                    } else {
                        Button("Sign In…") {
                            store.signInCodex()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            if let error = store.authErrorMessage {
                Section {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear {
            launchAtLogin.refresh()
            Task {
                await store.refreshAuthState()
            }
        }
    }
}
