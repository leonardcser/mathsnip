import Cocoa
import WebKit

class PreviewPanel: NSPanel, WKNavigationDelegate {
    private var webView: WKWebView!
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var tempDir: URL?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 210),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        let container = NSView(frame: contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        contentView = container

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 8
        webView.layer?.masksToBounds = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        container.addSubview(webView)
    }

    func showBelow(statusItem: NSStatusItem, latex: String) {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 210

        let x = screenRect.midX - panelWidth / 2
        let y = screenRect.minY - panelHeight - 4

        setContentSize(NSSize(width: panelWidth, height: panelHeight))
        setFrameOrigin(NSPoint(x: x, y: y))

        // Get bundle resource directory
        guard let resourceURL = Bundle.main.resourceURL else {
            print("No resource URL")
            return
        }

        // Read HTML template and replace placeholder
        let htmlURL = resourceURL.appendingPathComponent("preview.html")
        guard var htmlTemplate = try? String(contentsOf: htmlURL, encoding: .utf8) else {
            print("Failed to read: \(htmlURL.path)")
            return
        }

        // Escape LaTeX for safe insertion into JavaScript string
        let escapedLatex = latex
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        htmlTemplate = htmlTemplate.replacingOccurrences(of: "{{LATEX}}", with: escapedLatex)

        // Write modified HTML to cache directory
        let fm = FileManager.default
        let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let tmpBase = cacheDir.appendingPathComponent("com.mathsnip.preview")
        try? fm.removeItem(at: tmpBase)
        try? fm.createDirectory(at: tmpBase, withIntermediateDirectories: true)
        tempDir = tmpBase

        // Copy CSS to temp
        let cssSource = resourceURL.appendingPathComponent("katex.min.css")
        let cssDest = tmpBase.appendingPathComponent("katex.min.css")
        try? fm.copyItem(at: cssSource, to: cssDest)

        // Copy JS to temp
        let jsSource = resourceURL.appendingPathComponent("katex.min.js")
        let jsDest = tmpBase.appendingPathComponent("katex.min.js")
        try? fm.copyItem(at: jsSource, to: jsDest)

        // Copy fonts directory to temp
        let fontsSource = resourceURL.appendingPathComponent("fonts")
        let fontsDest = tmpBase.appendingPathComponent("fonts")
        try? fm.copyItem(at: fontsSource, to: fontsDest)

        // Write HTML to temp
        let htmlDest = tmpBase.appendingPathComponent("preview.html")
        try? htmlTemplate.write(to: htmlDest, atomically: true, encoding: .utf8)

        webView.loadFileURL(htmlDest, allowingReadAccessTo: tmpBase)
        orderFrontRegardless()
        setupDismissMonitors()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Content loaded
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("WebView failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("WebView provisional failed: \(error)")
    }

    private func setupDismissMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self = self, !self.frame.contains(NSEvent.mouseLocation) {
                self.dismiss()
                return nil
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        orderOut(nil)

        // Cleanup temp files
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
            tempDir = nil
        }
    }
}
