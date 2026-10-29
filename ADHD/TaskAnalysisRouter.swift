import Foundation

/// One immutable clock, locale and account generation for a user's analysis tap and every retry.
struct TaskAnalysisContext {
    let requestID: UUID
    let now: Date
    let timeZone: TimeZone
    let language: String
    let accountScope: String
    let accountGeneration: String

    init(requestID: UUID = UUID(), now: Date = .now, timeZone: TimeZone = .current,
         language: String, accountScope: String, accountGeneration: String) {
        self.requestID = requestID
        self.now = now
        self.timeZone = timeZone
        self.language = language
        self.accountScope = accountScope
        self.accountGeneration = accountGeneration
    }

    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone
        return value
    }

    var isCurrentAccount: Bool {
        AccountPreferences.activeScope == accountScope
            && AccountPreferences.sessionGeneration() == accountGeneration
    }
}

enum TaskAnalysisSource { case localRules, cloud }

struct TaskAnalysisResult {
    let calls: [LLMFunctionCall]
    let source: TaskAnalysisSource
    let quota: ServerAIQuotaSnapshot?
    var requiresPreview: Bool { source == .localRules }
}

enum TaskAnalysisError: Error { case offline }

enum TaskAnalysisRollout {
    /// Release activation requires the physical-iPhone and held-out checks in the canonical ADR.
    /// This is an engineering gate, never an AI setting exposed to the user.
    static var localRulesEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

/// Local interpretation never asks the cloud permission/quota gate and never consumes its quota.
/// Apple generation stays absent from the production route until a device/OS/language cohort
/// passes the canonical semantic and physical-device gates. Availability alone is not approval.
@MainActor
enum TaskAnalysisRouter {
    static func analyze(
        text: String,
        context: TaskAnalysisContext,
        localRulesEnabled: Bool = true,
        isCurrent: () -> Bool,
        authorizeCloud: () throws -> Void,
        cloud: (String, TaskAnalysisContext) async throws -> TaskAnalysisResult
    ) async throws -> TaskAnalysisResult {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 1_000 else { throw CloudLLMError.requestRejected }

        if localRulesEnabled, let proposal = LocalTaskParser.parse(text, context: context) {
            guard LLMFunctionCall.isValidAnalysis([proposal.call]) else { throw CloudLLMError.invalidResponse }
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return TaskAnalysisResult(calls: [proposal.call], source: .localRules, quota: nil)
        }

        // Only an explicit analysis action can reach this branch. There is no upload queue.
        try authorizeCloud()
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let result = try await cloud(text, context)
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        guard result.source == .cloud, LLMFunctionCall.isValidAnalysis(result.calls),
              let quota = result.quota, quota.isValid else { throw CloudLLMError.invalidResponse }
        return result
    }
}

struct LocalTaskProposal {
    let call: LLMFunctionCall
    /// UTF-16 spans in the exact submitted string; no normalized or reconstructed title.
    let titleRange: NSRange
    let temporalRange: NSRange
}

/// Deliberately closed grammar: one appointment, an explicit AM/PM and today/tomorrow/date.
/// Titles are a reviewed noun vocabulary, not arbitrary trailing text. An open-ended capture
/// would accept negation, corrections or extra commands as a title. Anything else falls through.
enum LocalTaskParser {
    private static let titles: [String: Set<String>] = [
        "ko": ["치과", "병원", "회의", "팀 미팅", "점심", "저녁", "운동", "산책", "장보기", "약속", "미용실", "수업"],
        "en": ["dentist", "doctor", "meeting", "team meeting", "lunch", "dinner", "workout", "walk", "groceries", "appointment", "haircut", "class"],
        "ja": ["歯医者", "病院", "会議", "チーム会議", "昼食", "夕食", "運動", "散歩", "買い物", "約束", "美容院", "授業"],
    ]

    static func parse(_ text: String, context: TaskAnalysisContext) -> LocalTaskProposal? {
        guard text.utf16.count <= 1_000, let vocabulary = titles[context.language] else { return nil }
        // Named captures allow each locale to retain its natural word order without dropping text.
        let date = #"[0-9]{4}-[0-9]{2}-[0-9]{2}"#
        let pattern: String
        switch context.language {
        case "ko":
            pattern = #"\A *(?<when>(?<day>오늘|내일|"# + date + #") +(?<period>오전|오후) *(?<hour>[0-9]{1,2})시(?: *(?<minute>[0-9]{1,2})분)?)(?:에)? +(?<title>[가-힣 ]+?)(?: *(?:추가해줘|추가해 줘|추가))? *[.!]? *\z"#
        case "en":
            pattern = #"\A *(?:Add +)?(?<title>[A-Za-z ]+?) +(?<when>(?<day>today|tomorrow|"# + date + #") +at +(?<hour>[0-9]{1,2})(?::(?<minute>[0-9]{2}))? *(?<period>AM|PM)) *[.!]? *\z"#
        case "ja":
            pattern = #"\A *(?<when>(?<day>今日|明日|"# + date + #") *(?<period>午前|午後) *(?<hour>[0-9]{1,2})時(?: *(?<minute>[0-9]{1,2})分)?)(?:に)? *(?<title>[一-龯ぁ-んァ-ヶー]+?)(?:を追加して|を追加)? *[。！]? *\z"#
        default: return nil
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range == NSRange(text.startIndex..., in: text) else { return nil }
        func capture(_ name: String) -> String? {
            guard let range = Range(match.range(withName: name), in: text) else { return nil }
            return String(text[range])
        }
        guard let title = capture("title"), vocabulary.contains(title.lowercased()),
              let day = capture("day"), let period = capture("period"),
              let hourText = capture("hour"), let hour = Int(hourText), (1...12).contains(hour) else { return nil }
        let minute = Int(capture("minute") ?? "0") ?? -1
        guard (0...59).contains(minute) else { return nil }
        let hour24 = hour % 12 + (["pm", "오후", "午後"].contains(period.lowercased()) ? 12 : 0)
        let calendar = context.calendar
        let targetDay: Date
        if ["today", "오늘", "今日", "tomorrow", "내일", "明日"].contains(day.lowercased()) {
            let offset = ["tomorrow", "내일", "明日"].contains(day.lowercased()) ? 1 : 0
            guard let resolved = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: context.now)) else { return nil }
            targetDay = resolved
        } else {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = context.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let resolved = formatter.date(from: day), formatter.string(from: resolved) == day else { return nil }
            targetDay = resolved
        }

        // Reject gaps AND overlaps instead of silently choosing a DST interpretation.
        var components = calendar.dateComponents([.year, .month, .day], from: targetDay)
        components.hour = hour24
        components.minute = minute
        components.second = 0
        let start = calendar.startOfDay(for: targetDay).addingTimeInterval(-1)
        guard let first = calendar.nextDate(after: start, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first),
              let last = calendar.nextDate(after: start, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .last),
              first == last, calendar.isDate(first, inSameDayAs: targetDay), first > context.now else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = context.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let call = LLMFunctionCall.addSingleTask(AddSingleTaskParams(
            task_name: title,
            time: String(format: "%02d:%02d %@", hour, minute, hour24 < 12 ? "AM" : "PM"),
            date: formatter.string(from: targetDay), category: "Appointment", recurrence: nil, urgency: "strong"
        ))
        guard call.isExecutionPayloadValid else { return nil }
        return LocalTaskProposal(call: call, titleRange: match.range(withName: "title"), temporalRange: match.range(withName: "when"))
    }
}
