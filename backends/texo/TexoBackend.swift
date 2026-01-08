import Cocoa

/// Manages the Texo Python backend - daemon lifecycle and inference.
class TexoBackend {
    private let backendDir: String
    private let socketPath = "/tmp/mathsnip_texo.sock"
    private let pidFile = "/tmp/mathsnip_texo.pid"

    private var daemonProcess: Process?
    private var daemonReady = false
    private var daemonStarting = false
    private let daemonReadyLock = NSLock()
    private let daemonReadyCondition = NSCondition()

    init(backendDir: String) {
        self.backendDir = backendDir
    }

    // MARK: - Setup

    func checkSetup() -> Bool {
        let venvPython = "\(backendDir)/venv/bin/python"
        let inferenceScript = "\(backendDir)/inference.py"
        let texoDir = "\(backendDir)/Texo"
        let modelDir = "\(backendDir)/model_cache/FormulaNet"
        return FileManager.default.fileExists(atPath: venvPython) &&
               FileManager.default.fileExists(atPath: inferenceScript) &&
               FileManager.default.fileExists(atPath: texoDir) &&
               FileManager.default.fileExists(atPath: modelDir)
    }

    func showSetupAlert() {
        let alert = NSAlert()
        alert.messageText = "Texo Backend Not Configured"
        alert.informativeText = """
            MathSnip's Texo backend requires setup. Please run:

            make BACKEND=texo setup

            Or from the MathSnip source directory:

            cd backends/texo && ./setup.sh
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Daemon Lifecycle

    func startDaemon() {
        daemonReadyLock.lock()
        defer { daemonReadyLock.unlock() }

        if daemonReady || daemonStarting {
            return
        }

        if isDaemonRunning() {
            print("Texo daemon already running")
            daemonReady = true
            return
        }

        daemonStarting = true

        // Clean up stale socket/pid files
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidFile)

        let pythonPath = "\(backendDir)/venv/bin/python"
        let scriptPath = "\(backendDir)/inference.py"

        guard FileManager.default.fileExists(atPath: pythonPath),
              FileManager.default.fileExists(atPath: scriptPath) else {
            print("Texo not properly set up, skipping daemon start")
            daemonStarting = false
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

        // Monitor stdout for READY signal (non-blocking)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), str.contains("READY") {
                self?.daemonReadyCondition.lock()
                self?.daemonReady = true
                self?.daemonStarting = false
                self?.daemonReadyCondition.broadcast()
                self?.daemonReadyCondition.unlock()
                print("Texo daemon ready")
                handle.readabilityHandler = nil
            }
        }

        do {
            try process.run()
            daemonProcess = process
            print("Texo daemon starting in background...")
        } catch {
            print("Failed to start Texo daemon: \(error)")
            daemonStarting = false
        }
    }

    func stopDaemon() {
        // Terminate our managed process if running
        if let process = daemonProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
            daemonProcess = nil
            print("Texo daemon stopped")
        }

        // Also check for orphaned daemon via PID file
        if let pidString = try? String(contentsOfFile: pidFile, encoding: .utf8),
           let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }

        // Clean up socket and PID files
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidFile)

        daemonReady = false
        daemonStarting = false
    }

    // MARK: - Inference

    func runInference(imagePath: String) -> String? {
        startDaemon()

        // Wait for daemon to be ready (blocks until ready or timeout)
        if !waitForDaemon(timeout: 120) {
            print("Daemon not ready, falling back to single-shot inference")
            return runFallback(imagePath)
        }

        // Try socket connection
        if let result = runViaSocket(imagePath) {
            return result
        }

        // Socket failed but daemon was "ready" - might have crashed
        print("Socket connection failed, restarting daemon...")
        stopDaemon()
        startDaemon()

        if waitForDaemon(timeout: 120) {
            if let result = runViaSocket(imagePath) {
                return result
            }
        }

        // Last resort: single-shot inference
        return runFallback(imagePath)
    }

    // MARK: - Private Helpers

    private func isDaemonRunning() -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return false
        }

        // Try to connect to verify it's actually running
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        return connectToSocket(fd: fd)
    }

    private func waitForDaemon(timeout: TimeInterval) -> Bool {
        daemonReadyCondition.lock()
        defer { daemonReadyCondition.unlock() }

        if daemonReady {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !daemonReady {
            if !daemonReadyCondition.wait(until: deadline) {
                print("Timeout waiting for Texo daemon")
                return false
            }
        }
        return true
    }

    private func runViaSocket(_ imagePath: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("Failed to create socket")
            return nil
        }
        defer { close(fd) }

        guard connectToSocket(fd: fd) else {
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

        if let response = response, response.hasPrefix("ERROR:") {
            print("Texo error: \(response)")
            return nil
        }

        return response
    }

    private func runFallback(_ imagePath: String) -> String? {
        print("Using single-shot inference (slow)")
        let pythonPath = "\(backendDir)/venv/bin/python"
        let scriptPath = "\(backendDir)/inference.py"

        guard FileManager.default.fileExists(atPath: pythonPath),
              FileManager.default.fileExists(atPath: scriptPath) else {
            print("Texo not properly set up")
            return nil
        }

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
                print("Texo error: \(stderr)")
                return nil
            }

            return output
        } catch {
            print("Failed to run Texo: \(error)")
            return nil
        }
    }

    /// Connect to the Unix socket. Returns true if successful.
    private func connectToSocket(fd: Int32) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
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
}
