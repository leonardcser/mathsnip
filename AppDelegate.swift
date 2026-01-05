import Cocoa
import ScreenCaptureKit
import ApplicationServices

// MARK: - LaTeX Conversion Backend

enum LaTeXBackend: String {
    case pix2tex
    case texo
}

// Set the active backend here
let activeBackend: LaTeXBackend = .pix2tex

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var overlayPanel: OverlayPanel?
    var previewPanel: PreviewPanel?
    var isProcessing = false
    var normalIcon: NSImage?
    var texoDaemonProcess: Process?

    let texoSocketPath = "/tmp/mathsnip_texo.sock"
    let texoPidFile = "/tmp/mathsnip_texo.pid"

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

        // Start Texo daemon if using Texo backend
        if activeBackend == .texo {
            startTexoDaemon()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopTexoDaemon()
    }

    // MARK: - Texo Daemon Management

    func startTexoDaemon() {
        // Check if daemon is already running
        if isTexoDaemonRunning() {
            print("Texo daemon already running")
            return
        }

        // Clean up stale socket/pid files
        try? FileManager.default.removeItem(atPath: texoSocketPath)
        try? FileManager.default.removeItem(atPath: texoPidFile)

        let dir = backendDir(.texo)
        let pythonPath = "\(dir)/venv/bin/python"
        let scriptPath = "\(dir)/inference_texo.py"

        guard FileManager.default.fileExists(atPath: pythonPath),
              FileManager.default.fileExists(atPath: scriptPath) else {
            print("Texo not properly set up, skipping daemon start")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath, "--server"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Log stderr to console for debugging
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                print("[Texo Daemon] \(str)", terminator: "")
            }
        }

        do {
            try process.run()
            texoDaemonProcess = process

            // Wait for READY signal (with timeout)
            let readySignal = DispatchSemaphore(value: 0)
            var gotReady = false

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), str.contains("READY") {
                    gotReady = true
                    readySignal.signal()
                }
            }

            let timeout = DispatchTime.now() + .seconds(60)  // Model loading can take a while
            if readySignal.wait(timeout: timeout) == .timedOut {
                print("Texo daemon startup timed out")
            } else if gotReady {
                print("Texo daemon started successfully")
            }

            // Clear the handler after startup
            stdoutPipe.fileHandleForReading.readabilityHandler = nil

        } catch {
            print("Failed to start Texo daemon: \(error)")
        }
    }

    func stopTexoDaemon() {
        // Terminate our managed process if running
        if let process = texoDaemonProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
            texoDaemonProcess = nil
            print("Texo daemon stopped")
        }

        // Also check for orphaned daemon via PID file
        if let pidString = try? String(contentsOfFile: texoPidFile, encoding: .utf8),
           let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }

        // Clean up socket and PID files
        try? FileManager.default.removeItem(atPath: texoSocketPath)
        try? FileManager.default.removeItem(atPath: texoPidFile)
    }

    func isTexoDaemonRunning() -> Bool {
        // Check if socket exists and is connectable
        guard FileManager.default.fileExists(atPath: texoSocketPath) else {
            return false
        }

        // Try to connect to verify it's actually running
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            texoSocketPath.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        return result == 0
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

    // MARK: - Backend Directories

    func backendDir(_ backend: LaTeXBackend) -> String {
        let cwdPath = "\(FileManager.default.currentDirectoryPath)/\(backend.rawValue)"
        let homePath = "\(NSHomeDirectory())/.mathsnip/\(backend.rawValue)"

        // Check current working directory first
        if FileManager.default.fileExists(atPath: cwdPath) {
            return cwdPath
        }

        // Fall back to home directory
        return homePath
    }

    // MARK: - Texo Backend

    func checkTexoSetup() -> Bool {
        let dir = backendDir(.texo)
        let venvPython = "\(dir)/venv/bin/python"
        let inferenceScript = "\(dir)/inference_texo.py"
        let texoDir = "\(dir)/Texo"
        let modelDir = "\(dir)/model_cache/FormulaNet"
        return FileManager.default.fileExists(atPath: venvPython) &&
               FileManager.default.fileExists(atPath: inferenceScript) &&
               FileManager.default.fileExists(atPath: texoDir) &&
               FileManager.default.fileExists(atPath: modelDir)
    }

    func showTexoNotSetupAlert() {
        let alert = NSAlert()
        alert.messageText = "Texo Backend Not Configured"
        alert.informativeText = "MathSnip's Texo backend requires setup. Please run the setup script:\n\ncd \(Bundle.main.bundlePath)/../scripts\n./setup_texo.sh\n\nOr from the MathSnip source directory:\n./scripts/setup_texo.sh"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func runTexo(_ imagePath: String) -> String? {
        // Try socket connection first (fast path)
        if let result = runTexoViaSocket(imagePath) {
            return result
        }

        // Fallback: try to start daemon and retry
        print("Socket connection failed, attempting to restart daemon...")
        startTexoDaemon()

        // Give daemon time to start, then retry
        Thread.sleep(forTimeInterval: 2.0)
        if let result = runTexoViaSocket(imagePath) {
            return result
        }

        // Last resort: run single-shot inference (slow)
        print("Daemon unavailable, falling back to single-shot inference")
        let dir = backendDir(.texo)
        let pythonPath = "\(dir)/venv/bin/python"
        let scriptPath = "\(dir)/inference_texo.py"

        guard FileManager.default.fileExists(atPath: pythonPath),
              FileManager.default.fileExists(atPath: scriptPath) else {
            print("Texo not properly set up")
            return nil
        }

        return runPythonInference(pythonPath: pythonPath, scriptPath: scriptPath, imagePath: imagePath, backendName: "Texo")
    }

    func runTexoViaSocket(_ imagePath: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("Failed to create socket")
            return nil
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            texoSocketPath.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            print("Failed to connect to Texo socket")
            return nil
        }

        // Send image path
        let pathData = imagePath.data(using: .utf8)!
        let sent = pathData.withUnsafeBytes { ptr in
            Darwin.send(fd, ptr.baseAddress, ptr.count, 0)
        }
        guard sent == pathData.count else {
            print("Failed to send image path")
            return nil
        }

        // Receive response
        var buffer = [UInt8](repeating: 0, count: 8192)
        let received = Darwin.recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else {
            print("Failed to receive response")
            return nil
        }

        let response = String(bytes: buffer[0..<received], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for error response
        if let response = response, response.hasPrefix("ERROR:") {
            print("Texo error: \(response)")
            return nil
        }

        return response
    }

    // MARK: - Common Python Runner

    func runPythonInference(pythonPath: String, scriptPath: String, imagePath: String, backendName: String) -> String? {
        let process = Process()

        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath, imagePath]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if process.terminationStatus != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                print("\(backendName) error: \(stderr)")
                return nil
            }

            return output
        } catch {
            print("Failed to run \(backendName): \(error)")
            return nil
        }
    }

    func startSnipping() {
        // Check backend is available
        switch activeBackend {
        case .pix2tex:
            if findPix2TexPath() == nil {
                showPix2TexNotFoundAlert()
                return
            }
        case .texo:
            if !checkTexoSetup() {
                showTexoNotSetupAlert()
                return
            }
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
                    let result: String?
                    switch activeBackend {
                    case .pix2tex:
                        result = runPix2Tex(path)
                    case .texo:
                        result = runTexo(path)
                    }

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
