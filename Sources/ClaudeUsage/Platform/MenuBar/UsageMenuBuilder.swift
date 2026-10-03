import AppKit
import SwiftUI
import UsageCore

@MainActor
enum UsageMenuBuilder {
    struct Actions {
        var refresh: () -> Void
        var signInClaude: (() -> Void)?
        var signInCodex: (() -> Void)?
        var settings: (target: AnyObject, action: Selector)?
        var quit: (target: AnyObject, action: Selector)?
    }

    static func populate(_ menu: NSMenu, from store: UsageStore, actions: Actions) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        for (index, provider) in store.gaugeLayout.menuProviderOrder.enumerated() {
            appendSection(for: provider, to: menu, store: store, actions: actions, isFirst: index == 0)
            menu.addItem(.separator())
        }

        if let settings = actions.settings {
            menu.addItem(command("Settings…", key: ",", target: settings.target, action: settings.action))
        }
        if let quit = actions.quit {
            menu.addItem(command("Quit", key: "q", target: quit.target, action: quit.action))
        }
    }

    private static func appendSection(
        for provider: UsageProvider,
        to menu: NSMenu,
        store: UsageStore,
        actions: Actions,
        isFirst: Bool
    ) {
        let refresh = isFirst ? actions.refresh : nil

        switch provider {
        case .claude:
            appendProvider(
                to: menu,
                store: store,
                title: provider.displayName,
                buckets: store.buckets,
                visibleBuckets: store.buckets(from: provider, in: .menu),
                isStale: store.isStale,
                statusMessage: store.statusMessage,
                statusIcon: store.statusIcon,
                statusIsWarning: store.statusIsWarning,
                now: store.now,
                refresh: refresh,
                signIn: actions.signInClaude,
                isSigningIn: store.isSigningInClaude,
                authFailure: store.claudeAuthFeedback?.failure
            )
        case .codex:
            appendProvider(
                to: menu,
                store: store,
                title: provider.displayName,
                buckets: store.codexBuckets,
                visibleBuckets: store.buckets(from: provider, in: .menu),
                isStale: store.codexIsStale,
                statusMessage: store.codexStatusMessage,
                statusIcon: store.codexStatusIcon,
                statusIsWarning: store.codexStatusIsWarning,
                now: store.now,
                refresh: refresh,
                signIn: actions.signInCodex,
                isSigningIn: store.isSigningInCodex,
                authFailure: store.codexAuthFeedback?.failure
            )
        }
    }

    private static func appendProvider(
        to menu: NSMenu,
        store: UsageStore,
        title: String,
        buckets: [UsageBucket],
        visibleBuckets: [UsageBucket],
        isStale: Bool,
        statusMessage: String?,
        statusIcon: String,
        statusIsWarning: Bool,
        now: Date,
        refresh: (() -> Void)?,
        signIn: (() -> Void)?,
        isSigningIn: Bool,
        authFailure: String? = nil
    ) {
        menu.addItem(row(ProviderHeaderRow(title: title, store: store, refresh: refresh)))

        if buckets.isEmpty {
            if statusIsWarning, let statusMessage {
                menu.addItem(row(StatusMenuRow(message: statusMessage, systemImage: statusIcon)))
            } else if signIn != nil {
                menu.addItem(row(PlaceholderMenuRow(message: "Not signed in")))
            } else {
                menu.addItem(row(PlaceholderMenuRow(message: "No usage limits returned")))
            }

            if let authFailure {
                menu.addItem(
                    row(StatusMenuRow(message: authFailure, systemImage: "exclamationmark.triangle"))
                )
            }

            if let signIn {
                menu.addItem(row(SignInMenuRow(isSigningIn: isSigningIn, signIn: signIn)))
            }
        } else {
            if visibleBuckets.isEmpty {
                menu.addItem(row(PlaceholderMenuRow(message: "All limits hidden in Settings")))
            }

            for bucket in visibleBuckets {
                menu.addItem(row(BucketMenuRow(bucket: bucket, dimmed: isStale, now: now)))
            }

            if statusIsWarning, let statusMessage {
                menu.addItem(row(StatusMenuRow(message: statusMessage, systemImage: statusIcon)))
            }
        }
    }

    private static func row(_ content: some View) -> NSMenuItem {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        host.frame = NSRect(origin: .zero, size: host.fittingSize)

        let item = NSMenuItem()
        item.view = host
        item.isEnabled = false
        return item
    }

    private static func command(
        _ title: String,
        key: String,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        item.target = target
        item.isEnabled = true
        return item
    }
}
