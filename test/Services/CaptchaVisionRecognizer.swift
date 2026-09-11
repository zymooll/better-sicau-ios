import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit
import Vision

struct CaptchaRecognitionProbe: Sendable {
    var recognition: CaptchaRecognition
    var candidates: [String]
}

enum CaptchaVisionRecognizer {
    private struct ImageVariant {
        var name: String
        var image: CIImage
        var priority: Int
    }

    private struct Candidate {
        var text: String
        var confidence: Float
        var variant: String
        var priority: Int
    }

    private struct ForegroundMask {
        var width: Int
        var height: Int
        var pixels: [UInt8]

        func denseBounds(minimumPixels: Int, padding: Int) -> CGRect? {
            let columns = (0..<width).map { x in
                (0..<height).reduce(0) { count, y in
                    count + Int(pixels[y * width + x])
                }
            }
            let rows = (0..<height).map { y in
                (0..<width).reduce(0) { count, x in
                    count + Int(pixels[y * width + x])
                }
            }
            let xs = columns.indices.filter { columns[$0] >= minimumPixels }
            let ys = rows.indices.filter { rows[$0] >= minimumPixels }
            guard let firstX = xs.first, let lastX = xs.last,
                  let firstY = ys.first, let lastY = ys.last else {
                return nil
            }

            let minX = max(0, firstX - padding)
            let maxX = min(width - 1, lastX + padding)
            let minY = max(0, firstY - padding)
            let maxY = min(height - 1, lastY + padding)
            let rect = CGRect(
                x: minX,
                y: minY,
                width: maxX - minX + 1,
                height: maxY - minY + 1
            )
            return rect.width >= 40 && rect.height >= 20 ? rect : nil
        }

        func contentBounds(padding: Int) -> CGRect? {
            var minX = width
            var maxX = -1
            var minY = height
            var maxY = -1
            for y in 0..<height {
                for x in 0..<width where pixels[y * width + x] != 0 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            minX = max(0, minX - padding)
            maxX = min(width - 1, maxX + padding)
            minY = max(0, minY - padding)
            maxY = min(height - 1, maxY + padding)
            return CGRect(
                x: minX,
                y: minY,
                width: maxX - minX + 1,
                height: maxY - minY + 1
            )
        }

    }

    private static let expectedLength = 4
    private static let minimumConfidence: Float = 0.55
    private static let scale: CGFloat = 4

    static func recognize(_ imageData: Data) async throws -> CaptchaRecognition {
        try await probe(imageData).recognition
    }

    static func probe(_ imageData: Data) async throws -> CaptchaRecognitionProbe {
        guard !imageData.isEmpty else {
            Log.error(.academic, LogMessage("验证码识别失败：图片为空"))
            throw AppError.invalidResponse("验证码图片为空")
        }
        if Task.isCancelled { throw AppError.requestCancelled }

        let startedAt = Date()
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try recognizeSynchronously(imageData)
            }.value
            if Task.isCancelled { throw AppError.requestCancelled }
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            // 验证码文本与候选内容刻意不记录。
            Log.info(.academic, LogMessage("验证码识别完成：置信度 \(String(format: "%.2f", result.recognition.confidence))，候选 \(result.candidates.count) 组，耗时 \(elapsed) ms"))
            return result
        } catch is CancellationError {
            throw AppError.requestCancelled
        } catch let error as AppError {
            Log.error(.academic, LogMessage("验证码识别失败：\(error.errorDescription ?? "未知错误")"))
            throw error
        } catch {
            Log.error(.academic, LogMessage("验证码识别失败：无法识别"))
            throw AppError.unsupported("无法识别验证码，请手动输入")
        }
    }

    private static func recognizeSynchronously(_ data: Data) throws -> CaptchaRecognitionProbe {
        guard let input = CIImage(data: data),
              input.extent.width > 0,
              input.extent.height > 0 else {
            throw AppError.invalidResponse("验证码图片格式无效")
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let variants = imageVariants(input, context: context)
        var candidates: [Candidate] = []
        var highestObservedConfidence: Float = 0

        for variant in variants {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            request.customWords = Array("0123456789").map(String.init)
            request.minimumTextHeight = 0.03

            let handler = VNImageRequestHandler(ciImage: variant.image, options: [:])
            try handler.perform([request])
            let observations = request.results ?? []
            for observation in observations {
                for candidate in observation.topCandidates(5) {
                    highestObservedConfidence = max(highestObservedConfidence, candidate.confidence)
                    let normalized = normalizedCandidate(candidate.string)
                    guard normalized.count == expectedLength else { continue }
                    candidates.append(Candidate(
                        text: normalized,
                        confidence: candidate.confidence,
                        variant: variant.name,
                        priority: variant.priority
                    ))
                }
            }
        }

        guard let best = bestCandidate(in: candidates) else {
            return CaptchaRecognitionProbe(
                recognition: CaptchaRecognition(text: "", confidence: Double(highestObservedConfidence)),
                candidates: candidateDescriptions(candidates)
            )
        }
        return CaptchaRecognitionProbe(
            recognition: CaptchaRecognition(text: best.text, confidence: Double(best.confidence)),
            candidates: candidateDescriptions(candidates)
        )
    }

    private static func imageVariants(_ input: CIImage, context: CIContext) -> [ImageVariant] {
        let white = CIImage(color: CIColor.white).cropped(to: input.extent)
        let opaque = input.composited(over: white)
        var variants = [ImageVariant(name: "opaque", image: scaled(opaque), priority: 50)]

        guard let mask = foregroundMask(input, context: context) else { return variants }
        var seenBounds = Set<String>()
        for (minimumPixels, priority) in [(5, 40), (4, 30), (3, 20)] {
            guard let bounds = mask.denseBounds(minimumPixels: minimumPixels, padding: 6) else { continue }
            let key = "\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))"
            guard seenBounds.insert(key).inserted else { continue }
            variants.append(ImageVariant(
                name: "dense-\(minimumPixels)",
                image: scaled(crop(opaque, to: bounds, sourceExtent: input.extent)),
                priority: priority
            ))
        }
        if let binary = binaryImage(mask) {
            variants.append(ImageVariant(name: "binary", image: binary, priority: 10))
        }
        return variants
    }

    static func normalizedCandidate(_ source: String) -> String {
        var output = ""
        for character in source {
            guard let value = character.wholeNumberValue, (0...9).contains(value) else { continue }
            output.append(String(value))
        }
        return output
    }

    private static func bestCandidate(in candidates: [Candidate]) -> Candidate? {
        let accepted = candidates.filter { $0.confidence >= minimumConfidence }
        let groups = Dictionary(grouping: accepted, by: \.text)
            .map(\.value)
        let consensusGroups = groups
            .filter({ Set($0.map(\.variant)).count >= 2 })
            .sorted { consensusScore($0) > consensusScore($1) }

        if let consensus = consensusGroups.first {
            let votes = Set(consensus.map(\.variant)).count
            let nextVotes = consensusGroups.dropFirst().first.map { Set($0.map(\.variant)).count } ?? 0
            if votes > nextVotes {
                return strongestCandidate(consensus)
            }
        }

        let strongFallbacks = accepted.filter { $0.confidence >= 0.90 }
        if let dense = strongestCandidate(strongFallbacks.filter { $0.variant == "dense-5" }) {
            let alternatives = strongFallbacks.filter { $0.variant != "dense-5" }
            let alternativeConsensus = Dictionary(grouping: alternatives, by: \.text)
                .values
                .contains { Set($0.map(\.variant)).count >= 2 }
            if !alternativeConsensus { return dense }
        }

        if let binary = strongestCandidate(strongFallbacks.filter { $0.variant == "binary" }),
           strongFallbacks.allSatisfy({ $0.text == binary.text }) {
            return binary
        }
        return nil
    }

    private static func consensusScore(_ candidates: [Candidate]) -> (Int, Float, Int) {
        let variants = Set(candidates.map(\.variant)).count
        let average = candidates.map(\.confidence).reduce(0, +) / Float(candidates.count)
        let priority = candidates.map(\.priority).max() ?? 0
        return (variants, average, priority)
    }

    private static func strongestCandidate(_ candidates: [Candidate]) -> Candidate? {
        candidates.max { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
            return lhs.priority < rhs.priority
        }
    }

    private static func candidateDescriptions(_ candidates: [Candidate]) -> [String] {
        candidates
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.confidence > $1.confidence
            }
            .map { "\($0.variant)=\($0.text)@\(String(format: "%.2f", $0.confidence))" }
    }

    private static func scaled(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func crop(_ image: CIImage, to bounds: CGRect, sourceExtent: CGRect) -> CIImage {
        let sourceBounds = bounds.offsetBy(dx: sourceExtent.minX, dy: sourceExtent.minY)
        return image
            .cropped(to: sourceBounds)
            .transformed(by: CGAffineTransform(translationX: -sourceBounds.minX, y: -sourceBounds.minY))
    }

    private static func foregroundMask(_ image: CIImage, context: CIContext) -> ForegroundMask? {
        guard let source = context.createCGImage(image, from: image.extent) else { return nil }
        let width = source.width
        let height = source.height
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let bitmap = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            bitmap.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var foreground = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let red = Int(rgba[offset])
                let green = Int(rgba[offset + 1])
                let blue = Int(rgba[offset + 2])
                let alpha = Int(rgba[offset + 3])
                let maximum = max(red, max(green, blue))
                let minimum = min(red, min(green, blue))
                if alpha > 20, maximum > 20, maximum - minimum > 8 {
                    foreground[y * width + x] = 1
                }
            }
        }

        var filtered = [UInt8](repeating: 0, count: foreground.count)
        for y in 0..<height {
            for x in 0..<width where foreground[y * width + x] != 0 {
                var neighbors = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx
                        let yy = y + dy
                        guard xx >= 0, yy >= 0, xx < width, yy < height else { continue }
                        neighbors += Int(foreground[yy * width + xx])
                    }
                }
                if neighbors >= 5 { filtered[y * width + x] = 1 }
            }
        }
        return ForegroundMask(width: width, height: height, pixels: filtered)
    }

    private static func binaryImage(_ mask: ForegroundMask) -> CIImage? {
        guard let bounds = mask.contentBounds(padding: 4) else { return nil }
        let sourceWidth = Int(bounds.width)
        let sourceHeight = Int(bounds.height)
        let padding = 16
        let outputWidth = sourceWidth * Int(scale) + padding * 2
        let outputHeight = sourceHeight * Int(scale) + padding * 2
        let bytesPerRow = outputWidth * 4
        var output = [UInt8](repeating: 255, count: bytesPerRow * outputHeight)

        for y in 0..<sourceHeight {
            for x in 0..<sourceWidth {
                let sourceX = Int(bounds.minX) + x
                let sourceY = Int(bounds.minY) + y
                let value: UInt8 = mask.pixels[sourceY * mask.width + sourceX] == 0 ? 255 : 0
                for yy in 0..<Int(scale) {
                    for xx in 0..<Int(scale) {
                        let outputX = padding + x * Int(scale) + xx
                        let outputY = padding + y * Int(scale) + yy
                        let offset = outputY * bytesPerRow + outputX * 4
                        output[offset] = value
                        output[offset + 1] = value
                        output[offset + 2] = value
                        output[offset + 3] = 255
                    }
                }
            }
        }

        let cgImage = output.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let bitmap = CGContext(
                data: bytes.baseAddress,
                width: outputWidth,
                height: outputHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return bitmap.makeImage()
        }
        return cgImage.map(CIImage.init(cgImage:))
    }
}

enum QRCodeGenerator {
    static func pngData(for url: URL, dimension: Int = 512) -> Data? {
        guard dimension > 0 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(CGFloat(dimension) / extent.width, CGFloat(dimension) / extent.height)
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let image = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: image).pngData()
    }
}
