import Foundation

public enum ScreenshotDraftBuilder {
    /// Recognition is only a proposal. Callers must show the original and require explicit confirmation.
    public static func make(text: String, now: Date, calendar: Calendar) throws -> CardDraft {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw ShiriError.validation("没有可识别的文字，可以手动输入内容") }
        guard source.count <= AppLimits.noteLength else { throw ShiriError.validation("识别文字超过 2,000 字，请先保留需要的部分") }
        let normalized = source.replacingOccurrences(of: #"(20[0-9]{2})[-/.]([0-9]{1,2})[-/.]([0-9]{1,2})"#, with: "$1年$2月$3日", options: .regularExpression)
        guard var draft = try ChineseCardParser(calendar: calendar).interpret(normalized, now: now).first else { throw ShiriError.validation("请先检查识别文字") }
        let lines = source.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let title = lines.first {
            draft.card.title = String(title.replacingOccurrences(of: #"^(事项|标题|预约项目|预约名称)[：:]\s*"#, with: "", options: .regularExpression).prefix(AppLimits.titleLength))
        }
        draft.card.note = source
        // Multiple detected dates require review; no arrival/expiry date is chosen silently.
        let pattern = try NSRegularExpression(pattern: #"(20[0-9]{2}年)?[0-9]{1,2}月[0-9]{1,2}[日号]?"#)
        if pattern.numberOfMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) > 1 {
            draft.questions = Array(Set(draft.questions + [.ambiguousDates])).sorted { $0.rawValue < $1.rawValue }
        }
        draft.originalText = source; draft.interpretedText = source
        return draft
    }
}
