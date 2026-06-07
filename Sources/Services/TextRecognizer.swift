import Foundation
import Vision
import UIKit
import ImageIO

/// On-device OCR for scanning a territory card. Wraps Vision's text recognizer and a small
/// heuristic that flags which recognized lines look like street addresses (for pre-selection).
enum TextRecognizer {
    struct Line: Identifiable {
        let id = UUID()
        var text: String
        var looksLikeAddress: Bool
    }

    /// Recognizes text in an image, returning the lines top-to-bottom. Runs off the main actor.
    /// Encodes to `Data` (Sendable) before hopping threads so no non-Sendable Vision/CG types
    /// cross the boundary under Swift 6 strict concurrency.
    static func recognize(_ image: UIImage) async -> [String] {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return [] }
        return await Task.detached(priority: .userInitiated) {
            guard let reloaded = UIImage(data: data), let cg = reloaded.cgImage else { return [] }
            return recognizeSync(cg: cg, orientation: cgOrientation(reloaded.imageOrientation))
        }.value
    }

    /// Turns raw OCR lines into trimmed candidates, flagging the ones that look like real street
    /// addresses (begin with a house number and contain letters) so the UI can pre-select them.
    static func addressCandidates(from lines: [String]) -> [Line] {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
            .map { Line(text: $0, looksLikeAddress: looksLikeAddress($0)) }
    }

    // MARK: Internals

    private static func recognizeSync(cg: CGImage, orientation: CGImagePropertyOrientation) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results as? [VNRecognizedTextObservation])?
            .compactMap { $0.topCandidates(1).first?.string } ?? []
    }

    private static func looksLikeAddress(_ s: String) -> Bool {
        guard let first = s.first, first.isNumber else { return false }
        return s.contains { $0.isLetter }
    }

    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
