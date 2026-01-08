import Cocoa
import CoreGraphics

/// Manages the Texo-CoreML backend - model loading and inference.
class TexoCoreMLBackend {
    private var inference: TexoCoreMLInference?
    private(set) var isReady = false

    init() {}

    // MARK: - Setup

    func checkSetup() -> Bool {
        return Bundle.main.url(forResource: "Encoder", withExtension: "mlpackage") != nil &&
               Bundle.main.url(forResource: "Decoder", withExtension: "mlpackage") != nil
    }

    func showSetupAlert() {
        let alert = NSAlert()
        alert.messageText = "CoreML Models Not Found"
        alert.informativeText = """
            MathSnip's CoreML backend requires the model files to be bundled in the app. Please run:

            make BACKEND=texo-coreml install

            Or from the MathSnip source directory:

            cd backends/texo-coreml && ./setup.sh
            make build
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Model Loading

    func loadModels() async -> Bool {
        let engine = TexoCoreMLInference()
        do {
            try engine.loadModels()
            inference = engine
            isReady = true
            print("CoreML models loaded successfully")
            return true
        } catch {
            print("Failed to load CoreML models: \(error)")
            return false
        }
    }

    // MARK: - Inference

    func runInference(image: CGImage) async -> String? {
        guard let inference else {
            print("CoreML models not loaded")
            return nil
        }

        do {
            return try await inference.predict(image: image)
        } catch {
            print("CoreML inference failed: \(error)")
            return nil
        }
    }
}
