import Cocoa
import WebKit

class PreviewPanel: NSPanel {
    private var webView: WKWebView!
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
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
        webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 8
        webView.layer?.masksToBounds = true
        webView.setValue(false, forKey: "drawsBackground")
        container.addSubview(webView)
    }

    func showBelow(statusItem: NSStatusItem, latex: String, html: String) {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 100

        let x = screenRect.midX - panelWidth / 2
        let y = screenRect.minY - panelHeight - 4

        setContentSize(NSSize(width: panelWidth, height: panelHeight))
        setFrameOrigin(NSPoint(x: x, y: y))

        let htmlContent = """
        <!DOCTYPE html>
        <html>
        <head>
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body {
                    width: 100%;
                    height: 100%;
                    background: white;
                    overflow: hidden;
                }
                body {
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    -webkit-user-select: all;
                    user-select: all;
                }
                .container {
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    transform-origin: center center;
                    opacity: 0;
                    transition: opacity 0.1s ease-in;
                }
                .katex-display {
                    margin: 0 !important;
                }
                .katex-display > .katex {
                    white-space: nowrap;
                }
                .katex {
                    font-family: 'New Computer Modern Math', 'New Computer Modern', 'Latin Modern Math', 'KaTeX_Main', serif !important;
                }
            </style>
            <script>
                function scaleToFit() {
                    const container = document.querySelector('.container');
                    if (!container) return;

                    const maxW = window.innerWidth - 24;
                    const maxH = window.innerHeight - 24;
                    const w = container.scrollWidth;
                    const h = container.scrollHeight;

                    if (w > 0 && h > 0) {
                        const scale = Math.min(1.2, maxW / w, maxH / h);
                        container.style.transform = 'scale(' + scale + ')';
                    }
                    container.style.opacity = '1';
                }
                document.fonts.ready.then(scaleToFit);
            </script>
        </head>
        <body>
            <div class="container">\(html)</div>
        </body>
        </html>
        """

        webView.loadHTMLString(htmlContent, baseURL: nil)
        orderFrontRegardless()

        setupDismissMonitors()
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
    }
}
