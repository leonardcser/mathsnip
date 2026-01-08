import Cocoa

/// Manages the pix2tex external tool backend.
class Pix2TexBackend {
    private static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin/pix2tex",
        "/usr/local/bin/pix2tex",
        "/opt/homebrew/bin/pix2tex"
    ]

    private var executablePath: String?

    init() {
        executablePath = Self.findExecutable()
    }

    // MARK: - Setup

    func checkSetup() -> Bool {
        return executablePath != nil
    }

    func showSetupAlert() {
        let alert = NSAlert()
        alert.messageText = "pix2tex Not Found"
        alert.informativeText = """
            MathSnip requires pix2tex to convert equations to LaTeX. Please install it using:

            uv tool install pix2tex

            Then ensure it's available in one of these locations:
            \u{2022} ~/.local/bin/pix2tex
            \u{2022} /usr/local/bin/pix2tex
            \u{2022} /opt/homebrew/bin/pix2tex
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Inference

    func runInference(imagePath: String) -> String? {
        guard let execPath = executablePath else {
            print("pix2tex not found")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = [imagePath]

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

            // pix2tex output format is "filepath: latex_result"
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

    // MARK: - Private

    private static func findExecutable() -> String? {
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}
