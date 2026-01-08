import Cocoa

/// Manages the status bar dropdown menu.
class StatusBarMenu: NSObject {
    var onSnip: (() -> Void)?
    var onGitHub: (() -> Void)?
    var onQuit: (() -> Void)?

    private let menu: NSMenu

    override init() {
        menu = NSMenu()
        super.init()
        buildMenu()
    }

    // MARK: - Menu Construction

    private func buildMenu() {
        // Version info
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let versionItem = NSMenuItem(title: "MathSnip v\(version)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(versionItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Snip action
        let snipItem = NSMenuItem(title: "Snip", action: #selector(snipClicked), keyEquivalent: "")
        snipItem.target = self
        menu.addItem(snipItem)

        menu.addItem(NSMenuItem.separator())

        // GitHub link
        let githubItem = NSMenuItem(title: "GitHub", action: #selector(githubClicked), keyEquivalent: "")
        githubItem.target = self
        menu.addItem(githubItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Menu Display

    func show(from statusItem: NSStatusItem) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Actions

    @objc private func snipClicked() {
        onSnip?()
    }

    @objc private func githubClicked() {
        onGitHub?()
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
