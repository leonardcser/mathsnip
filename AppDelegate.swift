import Cocoa
import ScreenCaptureKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var overlayPanel: OverlayPanel?
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

    func startSnipping() {
        overlayPanel?.close()
        overlayPanel = OverlayPanel(appDelegate: self)
        overlayPanel?.makeKeyAndOrderFront(nil)
    }

    func handleSelection(_ rect: NSRect) {
        overlayPanel?.orderOut(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.captureAndProcess(rect)
        }
    }

    func captureAndProcess(_ rect: NSRect) {
        isProcessing = true
        setIconLoading()

        Task {
            do {
                let imagePath = try await captureScreenRegion(rect)

                if let path = imagePath {
                    let result = runPix2Tex(path)

                    if let latex = result, !latex.isEmpty {
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

            await MainActor.run {
                self.isProcessing = false
                self.setIconNormal()
                self.overlayPanel?.close()
                self.overlayPanel = nil
            }
        }
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

        // Try common paths for pix2tex
        let home = NSHomeDirectory()
        let possiblePaths = [
            "\(home)/.local/bin/pix2tex",
            "/usr/local/bin/pix2tex",
            "/opt/homebrew/bin/pix2tex"
        ]

        var pix2texPath: String?
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                pix2texPath = path
                break
            }
        }

        guard let execPath = pix2texPath else {
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

            return output
        } catch {
            print("Failed to run pix2tex: \(error)")
            return nil
        }
    }

    func cancelSnipping() {
        overlayPanel?.close()
        overlayPanel = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
