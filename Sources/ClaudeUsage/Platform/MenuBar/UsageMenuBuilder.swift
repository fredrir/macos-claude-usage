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

        appendProvider(
            to: menu,
            title: "Claude",
            buckets: store.buckets,
            isStale: store.isStale,
            statusMessage: store.statusMessage,
            statusIcon: store.statusIcon,
            statusIsWarning: store.statusIsWarning,
            now: store.now,
            refresh: actions.refresh,
            signIn: actions.signInClaude,
            isSigningIn: store.isSigningInClaude,
            authFailure: store.claudeAuthFeedback?.failure
        )

        menu.addItem(.separator())

        appendProvider(
            to: menu,
            title: "Codex",
            buckets: store.codexBuckets,
            isStale: store.codexIsStale,
            statusMessage: store.codexStatusMessage,
            statusIcon: store.codexStatusIcon,
            statusIsWarning: store.codexStatusIsWarning,
            now: store.now,
            refresh: nil,
            signIn: actions.signInCodex,
            isSigningIn: store.isSigningInCodex,
            authFailure: store.codexAuthFeedback?.failure
        )

        menu.addItem(.separator())

        if let settings = actions.settings {
            menu.addItem(command("Settings…", key: ",", target: settings.target, action: settings.action))
        }
        if let quit = actions.quit {
            menu.addItem(command("Quit", key: "q", target: quit.target, action: quit.action))
        }
    }

    private static func appendProvider(
        to menu: NSMenu,
        title: String,
        buckets: [UsageBucket],
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
        menu.addItem(row(ProviderHeaderRow(title: title, refresh: refresh)))

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
            for bucket in buckets {
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
