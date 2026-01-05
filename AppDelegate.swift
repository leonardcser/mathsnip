import Cocoa
import ScreenCaptureKit
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var overlayPanel: OverlayPanel?
    var previewPanel: PreviewPanel?
    var isProcessing = false
    var normalIcon: NSImage?

    func setIconNormal() {
        if let icon = normalIcon {
            icon.isTemplate = true
            statusItem.button?.image = icon
            statusItem.button?.appearsDisabled = false
        }
    }

    func setIconLoading() {
        if let icon = normalIcon {
            icon.isTemplate = false  // Disable template to show custom color
            statusItem.button?.image = icon
            statusItem.button?.appearsDisabled = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Load icon from bundle resources
        let iconPath = Bundle.main.path(forResource: "icon", ofType: "png")!
        let icon = NSImage(contentsOfFile: iconPath)!
        icon.size = NSSize(width: 18, height: 18)
        normalIcon = icon
        setIconNormal()

        // Create menu for right-click
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Snip", action: #selector(snipMenuClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitMenuClicked), keyEquivalent: "q"))
        statusItem.menu = nil // We'll show it manually on right-click

        // Store menu reference
        self.statusMenu = menu
    }

    var statusMenu: NSMenu?

    @objc func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Show menu on right-click
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // Left click - start snipping
            if isProcessing { return }
            startSnipping()
        }
    }

    @objc func snipMenuClicked() {
        if isProcessing { return }
        startSnipping()
    }

    @objc func quitMenuClicked() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Permission Checks

    func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    func checkScreenCapturePermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    func showPermissionAlert(title: String, message: String, settingsAction: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            settingsAction()
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func findPix2TexPath() -> String? {
        let home = NSHomeDirectory()
        let possiblePaths = [
            "\(home)/.local/bin/pix2tex",
            "/usr/local/bin/pix2tex",
            "/opt/homebrew/bin/pix2tex"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }


    func showPix2TexNotFoundAlert() {
        let alert = NSAlert()
        alert.messageText = "pix2tex Not Found"
        alert.informativeText = "MathSnip requires pix2tex to convert equations to LaTeX. Please install it using:\n\npip install pix2tex\n\nThen ensure it's available in one of these locations:\n• ~/.local/bin/pix2tex\n• /usr/local/bin/pix2tex\n• /opt/homebrew/bin/pix2tex"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func startSnipping() {
        // Check pix2tex is installed first
        if findPix2TexPath() == nil {
            showPix2TexNotFoundAlert()
            return
        }

        // Check accessibility permission (required for event tap)
        if !checkAccessibilityPermission() {
            showPermissionAlert(
                title: "Accessibility Permission Required",
                message: "MathSnip needs Accessibility access to capture mouse and keyboard events for the snipping overlay. Please grant permission in System Settings.",
                settingsAction: openAccessibilitySettings
            )
            return
        }

        // Check screen capture permission
        if !checkScreenCapturePermission() {
            showPermissionAlert(
                title: "Screen Recording Permission Required",
                message: "MathSnip needs Screen Recording access to capture the selected area. Please grant permission in System Settings.",
                settingsAction: openScreenCaptureSettings
            )
            return
        }

        // All permissions granted, open the overlay
        overlayPanel?.close()
        overlayPanel = OverlayPanel(appDelegate: self)
        overlayPanel?.configureForOverlay()
        overlayPanel?.makeKeyAndOrderFront(nil)
    }

    func handleSelection(_ rect: NSRect) {
        // Immediately release the event tap so user can interact with computer
        overlayPanel?.cleanup()
        overlayPanel?.orderOut(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.captureAndProcess(rect)
        }
    }

    func captureAndProcess(_ rect: NSRect) {
        isProcessing = true
        setIconLoading()

        Task {
            var capturedLatex: String?

            do {
                let imagePath = try await captureScreenRegion(rect)

                if let path = imagePath {
                    let result = runPix2Tex(path)

                    if let latex = result, !latex.isEmpty {
                        capturedLatex = latex

                        await MainActor.run {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(latex, forType: .string)
                        }
                    }

                    try? FileManager.default.removeItem(atPath: path)
                }
            } catch {
                print("Error: \(error)")
            }

            let finalLatex = capturedLatex

            await MainActor.run {
                self.isProcessing = false
                self.setIconNormal()
                self.overlayPanel?.close()
                self.overlayPanel = nil

                if let latex = finalLatex {
                    self.showPreview(latex: latex)
                }
            }
        }
    }

    func showPreview(latex: String) {
        previewPanel?.dismiss()
        previewPanel = PreviewPanel()
        previewPanel?.showBelow(statusItem: statusItem, latex: latex)
    }

    func captureScreenRegion(_ rect: NSRect) async throws -> String? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first else {
            return nil
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = NSScreen.main?.backingScaleFactor ?? 1.0

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        // Crop to selection rect - convert from screen coords to image coords
        let screenHeight = NSScreen.main?.frame.height ?? CGFloat(display.height)

        let cropRect = CGRect(
            x: rect.origin.x * scale,
            y: (screenHeight - rect.origin.y - rect.height) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )

        guard let croppedImage = image.cropping(to: cropRect) else {
            return nil
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "mathsnip_\(Int(Date().timeIntervalSince1970)).png"
        let filePath = tempDir.appendingPathComponent(fileName)

        let bitmapRep = NSBitmapImageRep(cgImage: croppedImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            return nil
        }

        try pngData.write(to: filePath)
        return filePath.path
    }

    func runPix2Tex(_ imagePath: String) -> String? {
        let process = Process()

        guard let execPath = findPix2TexPath() else {
            print("pix2tex not found")
            return nil
        }

        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = [imagePath]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe  // Discard stderr (warnings)

        do {
            try process.run()
            process.waitUntilExit()

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // pix2tex output format is "filepath: latex_result"
            // Extract just the LaTeX part after the colon
            if let output = output, let colonRange = output.range(of: ": ") {
                let latex = String(output[colonRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return latex
            }
            print("pix2tex output: \(output ?? "nil")")

            return output
        } catch {
            print("Failed to run pix2tex: \(error)")
            return nil
        }
    }

    func cancelSnipping() {
        overlayPanel?.cleanup()
        overlayPanel?.close()
        overlayPanel = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
