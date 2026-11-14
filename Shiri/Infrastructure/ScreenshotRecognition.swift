import Foundation
import Vision
import ShiriCore

struct ScreenshotRecognitionResult: Sendable {
    var text: String
    var uncertainLines: [String]
}

enum ScreenshotRecognition {
    static func recognize(_ data: Data) throws -> ScreenshotRecognitionResult {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let languages = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { languages.contains($0) }
        try VNImageRequestHandler(data: data, options: [:]).perform([request])
        try Task.checkCancellation()
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        guard !lines.isEmpty else { throw ShiriError.validation("没有识别到文字，请换一张清晰截图，或手动输入") }
        return ScreenshotRecognitionResult(text: lines.map(\.string).joined(separator: "\n"), uncertainLines: lines.filter { $0.confidence < 0.8 }.map(\.string))
    }
}
