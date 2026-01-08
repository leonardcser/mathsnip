// SPDX-License-Identifier: MIT
// TexoCoreMLInference.swift - CoreML-based equation recognition with beam search

import CoreML
import Foundation
import CoreGraphics

// MARK: - Constants

private let IMAGE_SIZE = 384
private let MEAN: Float = 0.7931
private let STD: Float = 0.1738
private let ENC_SEQ_LEN = 144  // (384/32)^2 after HGNetv2 downsampling

// MARK: - Beam Search Hypothesis

struct Hypothesis: Comparable {
    var tokens: [Int]
    var score: Float  // Log probability
    var isComplete: Bool

    static func < (lhs: Hypothesis, rhs: Hypothesis) -> Bool {
        // Higher normalized score is better
        return lhs.normalizedScore < rhs.normalizedScore
    }

    var normalizedScore: Float {
        // Length normalization to avoid favoring shorter sequences
        let lengthPenalty: Float = 1.0
        return score / pow(Float(tokens.count), lengthPenalty)
    }
}

// MARK: - CoreML Inference Engine

class TexoCoreMLInference {
    private var encoder: MLModel?
    private var decoder: MLModel?
    private let tokenizer: TexoCoreMLTokenizer

    // Beam search parameters
    let beamWidth: Int = 4
    let maxLength: Int = 512

    init() {
        self.tokenizer = TexoCoreMLTokenizer.formulaNet()
    }

    /// Load CoreML models from the app bundle.
    func loadModels() throws {
        guard let encoderURL = Bundle.main.url(forResource: "Encoder", withExtension: "mlpackage"),
              let decoderURL = Bundle.main.url(forResource: "Decoder", withExtension: "mlpackage") else {
            throw CoreMLError.modelsNotFound
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all  // Use ANE, GPU, CPU as available

        // Compile models (required for .mlpackage format)
        let compiledEncoderURL = try MLModel.compileModel(at: encoderURL)
        let compiledDecoderURL = try MLModel.compileModel(at: decoderURL)

        encoder = try MLModel(contentsOf: compiledEncoderURL, configuration: config)
        decoder = try MLModel(contentsOf: compiledDecoderURL, configuration: config)
    }

    /// Load models from a specific directory (for testing).
    func loadModels(from directory: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        let encoderURL = directory.appendingPathComponent("Encoder.mlpackage")
        let decoderURL = directory.appendingPathComponent("Decoder.mlpackage")

        // Compile models if needed
        let compiledEncoderURL = try MLModel.compileModel(at: encoderURL)
        let compiledDecoderURL = try MLModel.compileModel(at: decoderURL)

        encoder = try MLModel(contentsOf: compiledEncoderURL, configuration: config)
        decoder = try MLModel(contentsOf: compiledDecoderURL, configuration: config)
    }

    /// Run inference on an image and return LaTeX string.
    func predict(image: CGImage) async throws -> String {
        guard let encoder = encoder,
              let decoder = decoder else {
            throw CoreMLError.modelsNotLoaded
        }

        // 1. Preprocess image
        let pixelValues = try preprocessImage(image)

        // 2. Run encoder
        let encoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "pixel_values": MLFeatureValue(multiArray: pixelValues)
        ])
        let encoderOutput = try await encoder.prediction(from: encoderInput)
        guard let encoderHiddenStates = encoderOutput.featureValue(for: "encoder_output")?.multiArrayValue else {
            throw CoreMLError.invalidOutput
        }

        // 3. Beam search decoding
        let latex = try await beamSearchDecode(
            encoderHiddenStates: encoderHiddenStates,
            decoder: decoder
        )

        return latex
    }

    // MARK: - Image Preprocessing

    private func preprocessImage(_ image: CGImage) throws -> MLMultiArray {
        // 1. Convert to grayscale and get pixel data
        let width = image.width
        let height = image.height

        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else {
            throw CoreMLError.imageProcessingFailed
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let grayData = context.data else {
            throw CoreMLError.imageProcessingFailed
        }

        let grayPixels = grayData.bindMemory(to: UInt8.self, capacity: width * height)

        // 2. Crop margins (find bounding box of non-white pixels)
        let croppedRect = cropMargins(grayPixels: grayPixels, width: width, height: height)

        // 3. Create cropped image
        guard let croppedCGImage = image.cropping(to: croppedRect) else {
            throw CoreMLError.imageProcessingFailed
        }

        // 4. Resize to IMAGE_SIZE x IMAGE_SIZE preserving aspect ratio, pad with black
        let resizedData = try resizeWithPadding(image: croppedCGImage, targetSize: IMAGE_SIZE)

        // 5. Convert to MLMultiArray with normalization
        // Shape: (1, 3, IMAGE_SIZE, IMAGE_SIZE)
        let pixelValues = try MLMultiArray(shape: [1, 3, IMAGE_SIZE, IMAGE_SIZE] as [NSNumber], dataType: .float32)

        let ptr = pixelValues.dataPointer.bindMemory(to: Float.self, capacity: 3 * IMAGE_SIZE * IMAGE_SIZE)

        // Fill all 3 channels with the same grayscale value (normalized)
        for y in 0..<IMAGE_SIZE {
            for x in 0..<IMAGE_SIZE {
                let pixelIndex = y * IMAGE_SIZE + x
                let grayValue = Float(resizedData[pixelIndex]) / 255.0
                let normalized = (grayValue - MEAN) / STD

                // Channel-first format: (C, H, W)
                ptr[0 * IMAGE_SIZE * IMAGE_SIZE + pixelIndex] = normalized  // R
                ptr[1 * IMAGE_SIZE * IMAGE_SIZE + pixelIndex] = normalized  // G
                ptr[2 * IMAGE_SIZE * IMAGE_SIZE + pixelIndex] = normalized  // B
            }
        }

        return pixelValues
    }

    private func cropMargins(grayPixels: UnsafePointer<UInt8>, width: Int, height: Int) -> CGRect {
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0

        // Find min/max values for normalization
        var minVal: UInt8 = 255
        var maxVal: UInt8 = 0
        for i in 0..<(width * height) {
            minVal = min(minVal, grayPixels[i])
            maxVal = max(maxVal, grayPixels[i])
        }

        if minVal == maxVal {
            // Uniform image, return full rect
            return CGRect(x: 0, y: 0, width: width, height: height)
        }

        // Find bounding box of "text" pixels (threshold at 200 after normalization)
        let range = Float(maxVal - minVal)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = grayPixels[y * width + x]
                let normalized = (Float(pixel) - Float(minVal)) / range * 255.0
                if normalized < 200 {  // Text pixel
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        // Handle case where no text was found
        if minX > maxX || minY > maxY {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func resizeWithPadding(image: CGImage, targetSize: Int) throws -> [UInt8] {
        let srcWidth = image.width
        let srcHeight = image.height

        // Calculate scaling to fit within target size
        let scale = min(Float(targetSize) / Float(srcWidth), Float(targetSize) / Float(srcHeight))
        let newWidth = Int(Float(srcWidth) * scale)
        let newHeight = Int(Float(srcHeight) * scale)

        // Create grayscale context for resized image
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                  data: nil,
                  width: targetSize,
                  height: targetSize,
                  bitsPerComponent: 8,
                  bytesPerRow: targetSize,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else {
            throw CoreMLError.imageProcessingFailed
        }

        // Fill with black (padding)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: targetSize, height: targetSize))

        // Draw resized image centered
        let offsetX = (targetSize - newWidth) / 2
        let offsetY = (targetSize - newHeight) / 2
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: offsetX, y: offsetY, width: newWidth, height: newHeight))

        guard let data = context.data else {
            throw CoreMLError.imageProcessingFailed
        }

        // Copy to array
        let pixels = data.bindMemory(to: UInt8.self, capacity: targetSize * targetSize)
        return Array(UnsafeBufferPointer(start: pixels, count: targetSize * targetSize))
    }

    // MARK: - Beam Search Decoding

    private func beamSearchDecode(
        encoderHiddenStates: MLMultiArray,
        decoder: MLModel
    ) async throws -> String {
        // Initialize with BOS token
        var beams: [Hypothesis] = [
            Hypothesis(
                tokens: [TexoCoreMLTokenizer.bosTokenId],
                score: 0.0,
                isComplete: false
            )
        ]

        for _ in 0..<maxLength {
            // Check if all beams are complete
            if beams.allSatisfy({ $0.isComplete }) {
                break
            }

            var candidates: [Hypothesis] = []

            // Process each active beam
            for beam in beams {
                if beam.isComplete {
                    candidates.append(beam)
                    continue
                }

                // Run decoder with current sequence
                let inputIds = try createInputIds(beam.tokens)
                let decoderInput = try MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": MLFeatureValue(multiArray: inputIds),
                    "encoder_hidden_states": MLFeatureValue(multiArray: encoderHiddenStates)
                ])

                let decoderOutput = try await decoder.prediction(from: decoderInput)
                // Output name varies based on export method - try common names
                let logits: MLMultiArray
                if let l = decoderOutput.featureValue(for: "logits")?.multiArrayValue {
                    logits = l
                } else if let l = decoderOutput.featureValue(for: "linear_20")?.multiArrayValue {
                    logits = l
                } else {
                    // Try first available output
                    guard let firstFeature = decoderOutput.featureNames.first,
                          let l = decoderOutput.featureValue(for: firstFeature)?.multiArrayValue else {
                        throw CoreMLError.invalidOutput
                    }
                    logits = l
                }

                // Get logits for last position only
                let logProbs = logSoftmaxLastPosition(logits, seqLen: beam.tokens.count)
                let topK = topKIndices(logProbs, k: beamWidth)

                for (tokenId, logProb) in topK {
                    var newTokens = beam.tokens
                    newTokens.append(tokenId)

                    candidates.append(Hypothesis(
                        tokens: newTokens,
                        score: beam.score + logProb,
                        isComplete: tokenId == TexoCoreMLTokenizer.eosTokenId
                    ))
                }
            }

            // Select top beamWidth hypotheses
            candidates.sort(by: >)  // Higher normalized score first
            beams = Array(candidates.prefix(beamWidth))
        }

        // Return best completed hypothesis (or best incomplete if none complete)
        let completedBeams = beams.filter { $0.isComplete }
        let bestBeam = completedBeams.max() ?? beams.max()!

        return tokenizer.decode(bestBeam.tokens)
    }

    // MARK: - Helper Functions

    private func createInputIds(_ tokens: [Int]) throws -> MLMultiArray {
        let inputIds = try MLMultiArray(shape: [1, tokens.count as NSNumber], dataType: .int32)
        for (i, token) in tokens.enumerated() {
            inputIds[i] = NSNumber(value: Int32(token))
        }
        return inputIds
    }

    private func logSoftmaxLastPosition(_ logits: MLMultiArray, seqLen: Int) -> [Float] {
        // logits shape: (1, seq_len, vocab_size)
        let vocabSize = logits.shape[2].intValue
        let offset = (seqLen - 1) * vocabSize  // Get last position

        let ptr = logits.dataPointer.bindMemory(to: Float.self, capacity: seqLen * vocabSize)

        // Find max for numerical stability
        var maxVal: Float = -.greatestFiniteMagnitude
        for i in 0..<vocabSize {
            maxVal = max(maxVal, ptr[offset + i])
        }

        // Compute log-sum-exp
        var sumExp: Float = 0
        for i in 0..<vocabSize {
            sumExp += exp(ptr[offset + i] - maxVal)
        }
        let logSumExp = maxVal + log(sumExp)

        // Compute log-softmax
        var logProbs = [Float](repeating: 0, count: vocabSize)
        for i in 0..<vocabSize {
            logProbs[i] = ptr[offset + i] - logSumExp
        }

        return logProbs
    }

    private func topKIndices(_ logProbs: [Float], k: Int) -> [(Int, Float)] {
        // Get indices sorted by log probability
        let indexed = logProbs.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { $0.1 > $1.1 }
        return Array(sorted.prefix(k))
    }
}

// MARK: - Errors

enum CoreMLError: Error, LocalizedError {
    case modelsNotFound
    case modelsNotLoaded
    case imageProcessingFailed
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .modelsNotFound:
            return "CoreML models not found in app bundle"
        case .modelsNotLoaded:
            return "CoreML models have not been loaded"
        case .imageProcessingFailed:
            return "Failed to process image"
        case .invalidOutput:
            return "Invalid model output"
        }
    }
}
