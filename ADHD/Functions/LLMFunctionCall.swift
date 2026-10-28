import Foundation
import SwiftUI

/// 컨펌 모달에서 사용자가 직접 내용을 수정할 수 있도록 관리하기 위한 래퍼(Wrapper)
struct PendingLLMCall: Identifiable {
    let id = UUID()
    var call: LLMFunctionCall
    var urgency: Urgency
    /// nil은 아직 승인용 대상이 고정되지 않았다는 뜻이고, 빈 배열은 고정했지만 대상이 0개라는 뜻입니다.
    var targetSnapshots: [AppTaskSnapshot]? {
        didSet {
            if let targetSnapshots, !targetSnapshots.isEmpty {
                lastKnownTargets = targetSnapshots
            }
        }
    }
    /// 카드 편집으로 승인 대상이 무효화돼도 카드 표시와 편집 폼 초기값에 쓸 마지막 대상입니다.
    /// 실행 대상은 항상 targetSnapshots만 사용합니다.
    private(set) var lastKnownTargets: [AppTaskSnapshot] = []
    var executionIssue: LLMExecutionIssue?
    /// stale 감지 후 최신 미리보기를 다시 보여준 경우, 다음 확인 전에는 실행하지 않습니다.
    var requiresReconfirmation = false

    init(call: LLMFunctionCall) {
        self.call = call
        self.urgency = Self.defaultUrgency(for: call)
        self.targetSnapshots = call.requiresPreparedTargets ? nil : []
        self.executionIssue = nil
    }

    mutating func invalidatePreparedTargets() {
        guard call.requiresPreparedTargets else { return }
        targetSnapshots = nil
        executionIssue = nil
        requiresReconfirmation = true
    }

    /// 하이브리드 urgency 분류:
    /// 1) LLM이 판단한 urgency가 있으면 그대로 채택
    /// 2) 없거나 이상값이면 휴리스틱 — Appointment(일회성 약속)=strong, Routine(습관)=weak
    /// 3) 최종 오버라이드는 확인 카드의 bolt 토글 (사용자)
    static func defaultUrgency(for call: LLMFunctionCall) -> Urgency {
        guard case .addSingleTask(let params) = call else { return .strong }
        if let raw = params.urgency, let parsed = Urgency(rawValue: raw) {
            return parsed
        }
        return params.category == "Appointment" ? .strong : .weak
    }

    // UI Helpers pass-through to simplify views
    var uiAction: String { call.uiAction }
    var uiIcon: String { call.uiIcon }
    var uiActionLabel: String { call.uiActionLabel }
    var uiTaskName: String { call.uiTaskName }
    var uiTime: String? { call.uiTime }
    var uiDate: String? { call.uiDate }
    var uiSmartDateRaw: String { call.uiSmartDateRaw }
    var uiSmartDateTime: String { call.uiSmartDateTime }

    /// 수정·완료 카드는 분류를 바꾸지 않으면 실제 대상의 분류로 보여줍니다.
    var uiCategory: String {
        switch call {
        case .updateTask(let params) where params.new_category == nil:
            return lastKnownTargets.first?.category ?? call.uiCategory
        case .markTaskComplete:
            return lastKnownTargets.first?.category ?? call.uiCategory
        default:
            return call.uiCategory
        }
    }

    /// 승인 시 실제로 바뀔 기존 일정 이름입니다. 개수만으로는 무엇이 바뀌는지 알기 어렵기 때문입니다.
    var targetNamesSummary: String? {
        guard call.requiresPreparedTargets,
              let targets = targetSnapshots,
              !targets.isEmpty else { return nil }
        let names = targets.map(\.task)
        let shown = Array(names.prefix(3))
        return L.voice.targetNames(shown, more: names.count - shown.count)
    }

    /// 실패한 카드 아래에 보여줄 이유입니다. 다시 확인 안내가 이미 보이면 겹치지 않게 생략합니다.
    var inlineIssueMessage: String? {
        guard let executionIssue, !requiresReconfirmation else { return nil }
        switch executionIssue {
        case .noMatchingTarget:
            return L.voice.noMatchingTargetInline
        case .staleTarget, .previewRequired:
            return L.voice.reviewUpdatedPreview
        case .persistenceFailed, .notExecutedAfterStoreFailure, .storeUnavailable:
            return L.voice.saveFailedPreserved
        case .invalidCommand, .confirmationRequired, .unsupportedCommand:
            return L.voice.itemNotSaved
        }
    }
}

// MARK: - Confirmation Card Edit
/// 확인 카드 편집 폼의 값입니다. 명령 종류마다 고칠 수 있는 범위가 다릅니다.
struct PendingCallEditDraft: Equatable {
    enum Scope: Equatable {
        /// 추가·수정 카드: 이름, 분류, 날짜, 시간을 고칠 수 있습니다.
        case allFields
        /// 삭제·완료 카드: 찾을 대상 이름만 고칠 수 있습니다.
        case targetName
    }

    var scope: Scope
    var name: String
    /// "Routine" | "Appointment"
    var category: String
    /// 저장 형식 날짜("yyyy-MM-dd"). 루틴은 nil입니다.
    var date: String?
    /// 저장 형식 시간("hh:mm a"). nil이면 시간 없음입니다.
    var time: String?
}

extension PendingLLMCall {
    /// 편집 폼을 열 때 보여줄 값입니다.
    /// 수정 카드는 실제 대상 값 위에 이번 명령이 바꿀 값을 겹쳐 "저장 후 모습"을 보여줍니다.
    /// 날짜가 없는 플래너 일정은 오늘을 기본값으로 둡니다.
    func makeEditDraft(today: Date = Date()) -> PendingCallEditDraft? {
        let todayString = StoredTaskFormat.date.string(from: today)
        func plannerDate(_ value: String?, category: String) -> String? {
            guard category == "Appointment" else { return nil }
            guard let value, !value.isEmpty, value.lowercased() != "all" else { return todayString }
            return value
        }

        switch call {
        case .addSingleTask(let params):
            return PendingCallEditDraft(
                scope: .allFields,
                name: params.task_name,
                category: params.category,
                date: plannerDate(params.date, category: params.category),
                time: Self.normalizedTime(params.time)
            )

        case .updateTask(let params):
            let target = lastKnownTargets.first
            // 대상을 찾지 못한 카드에서는 이름 칸이 "찾을 이름"을 뜻합니다.
            let name = executionIssue == .noMatchingTarget
                ? params.target_task_name
                : (params.new_task_name ?? target?.task ?? params.target_task_name)
            let category = params.new_category ?? target?.category ?? "Routine"
            let currentDate = params.new_date
                ?? target?.date.map { StoredTaskFormat.date.string(from: $0) }
            let time: String? = params.new_time.map { Self.normalizedTime($0) }
                ?? Self.normalizedTime(target?.time)
            return PendingCallEditDraft(
                scope: .allFields,
                name: name,
                category: category,
                date: plannerDate(currentDate, category: category),
                time: time
            )

        case .deleteSpecificTask(let params):
            return PendingCallEditDraft(
                scope: .targetName,
                name: params.target_task_name,
                category: uiCategory,
                date: nil,
                time: nil
            )

        case .markTaskComplete(let params):
            return PendingCallEditDraft(
                scope: .targetName,
                name: params.target_task_name,
                category: uiCategory,
                date: nil,
                time: nil
            )

        case .clearAllTasks, .postponeAllTasks, .requestClarification, .handleOffTopicChat, .unknown:
            return nil
        }
    }

    /// 편집 폼 저장 결과를 명령에 반영합니다. 실제로 바뀐 내용이 있으면 true입니다.
    /// - 추가 카드: 폼에 보이는 값이 곧 저장될 값입니다.
    /// - 수정 카드: 사용자가 바꾼 항목만 반영합니다. 손대지 않은 항목은 원래 명령대로 둡니다.
    /// - 삭제·완료 카드: 찾을 대상 이름만 바꿉니다. 날짜·분류 범위는 넓히거나 좁히지 않습니다.
    @discardableResult
    mutating func applyEdit(_ edited: PendingCallEditDraft, from baseline: PendingCallEditDraft) -> Bool {
        let trimmedName = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameChanged = !trimmedName.isEmpty
            && trimmedName != baseline.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryChanged = edited.category != baseline.category
        let editedDate = edited.category == "Appointment" ? edited.date : nil
        let dateChanged = editedDate != baseline.date
        let timeChanged = !Self.isSameClock(edited.time, baseline.time)

        switch call {
        case .addSingleTask(var params):
            // 폼의 기본값(날짜 없는 플래너 일정의 오늘 등)도 그대로 저장해야 하므로
            // 편집 시작 값이 아니라 실제 명령 값과 비교합니다.
            let original = params
            if nameChanged { params.task_name = trimmedName }
            params.category = edited.category
            params.date = editedDate
            if timeChanged { params.time = edited.time }
            let changed = params.task_name != original.task_name
                || params.category != original.category
                || params.date != original.date
                || params.time != original.time
            if changed { call = .addSingleTask(params) }
            return changed

        case .updateTask(var params):
            var changed = false
            if nameChanged {
                if executionIssue == .noMatchingTarget {
                    params.target_task_name = trimmedName
                    lastKnownTargets = []
                } else {
                    params.new_task_name = trimmedName
                }
                changed = true
            }
            if categoryChanged {
                params.new_category = edited.category
                changed = true
            }
            if edited.category == "Appointment", dateChanged || categoryChanged {
                params.new_date = editedDate
                changed = true
            } else if edited.category == "Routine", categoryChanged {
                // 루틴은 날짜가 없으므로 앞서 정한 새 날짜도 버립니다.
                params.new_date = nil
            }
            if timeChanged {
                // 빈 문자열은 "시간 지우기"입니다. nil은 "바꾸지 않음"이라 구분합니다.
                params.new_time = edited.time ?? ""
                changed = true
            }
            if changed { call = .updateTask(params) }
            return changed

        case .deleteSpecificTask(var params):
            guard nameChanged else { return false }
            params.target_task_name = trimmedName
            call = .deleteSpecificTask(params)
            lastKnownTargets = []
            return true

        case .markTaskComplete(var params):
            guard nameChanged else { return false }
            params.target_task_name = trimmedName
            call = .markTaskComplete(params)
            lastKnownTargets = []
            return true

        case .clearAllTasks, .postponeAllTasks, .requestClarification, .handleOffTopicChat, .unknown:
            return false
        }
    }

    private static func normalizedTime(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    /// "03:00 PM"과 "15:00"처럼 표기만 다른 같은 시각은 바뀌지 않은 것으로 봅니다.
    private static func isSameClock(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            if let left = StoredTaskFormat.hourMinute(from: lhs),
               let right = StoredTaskFormat.hourMinute(from: rhs) {
                return left == right
            }
            return lhs == rhs
        default:
            return false
        }
    }
}

enum LLMExecutionIssue: Equatable {
    case invalidCommand
    case confirmationRequired
    case storeUnavailable
    case previewRequired
    case noMatchingTarget
    case staleTarget
    case persistenceFailed
    case notExecutedAfterStoreFailure
    case unsupportedCommand
}


// MARK: - Parameter Structs

struct AddSingleTaskParams: Codable {
    var task_name: String
    var time: String?
    var date: String?
    var category: String
    var recurrence: String?
    /// LLM이 판단한 알림 강도: "strong" | "weak" | nil (하이브리드 분류 1단계)
    var urgency: String?
}

struct UpdateTaskParams: Codable {
    var target_task_name: String
    var new_task_name: String?
    var new_time: String?
    var new_date: String?
    var new_category: String?
    var new_recurrence: String?
}

struct DeleteTaskParams: Codable {
    var target_task_name: String
    var target_category: String?
    var target_date: String?
}

struct ClearTasksParams: Codable {
    var target_category: String?
    var target_date: String
}

struct PostponeTasksParams: Codable {
    let from_date: String
    let to_date: String
}

struct MarkTaskCompleteParams: Codable {
    var target_task_name: String
}

struct ClarificationParams: Codable {
    let reason: String
}

/// OOV(Out-of-Domain) 응답 파라미터: 앱 목적과 무관한 입력에 대한 재치 있는 응답 메시지
struct OffTopicChatParams: Codable {
    let message: String
}

// MARK: - LLMFunctionCall Router Enum

enum LLMFunctionCall: Decodable {
    case addSingleTask(AddSingleTaskParams)
    case updateTask(UpdateTaskParams)
    case deleteSpecificTask(DeleteTaskParams)
    case clearAllTasks(ClearTasksParams)
    case postponeAllTasks(PostponeTasksParams)
    case markTaskComplete(MarkTaskCompleteParams)
    case requestClarification(ClarificationParams)
    case handleOffTopicChat(OffTopicChatParams) // OOV 예외 처리
    case unknown(String) // Fallback for unsupported functions

    enum CodingKeys: String, CodingKey {
        case function_name
        case parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let functionName = try container.decode(String.self, forKey: .function_name)

        switch functionName {
        case "add_single_task":
            var params = try container.decode(AddSingleTaskParams.self, forKey: .parameters)
            params.category = (params.category.lowercased() == "appointment") ? "Appointment" : "Routine"
            self = .addSingleTask(params)
        case "update_task":
            var params = try container.decode(UpdateTaskParams.self, forKey: .parameters)
            if let cat = params.new_category {
                params.new_category = (cat.lowercased() == "appointment") ? "Appointment" : "Routine"
            }
            self = .updateTask(params)
        case "delete_specific_task":
            var params = try container.decode(DeleteTaskParams.self, forKey: .parameters)
            if let cat = params.target_category {
                switch cat.lowercased() {
                case "appointment": params.target_category = "Appointment"
                case "routine": params.target_category = "Routine"
                case "all": params.target_category = "all"
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .parameters,
                        in: container,
                        debugDescription: "Invalid delete target category"
                    )
                }
            }
            self = .deleteSpecificTask(params)
        case "clear_all_tasks":
            var params = try container.decode(ClearTasksParams.self, forKey: .parameters)
            if let cat = params.target_category {
                switch cat.lowercased() {
                case "appointment": params.target_category = "Appointment"
                case "routine": params.target_category = "Routine"
                case "all": params.target_category = "all"
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .parameters,
                        in: container,
                        debugDescription: "Invalid clear target category"
                    )
                }
            }
            self = .clearAllTasks(params)
        case "postpone_all_tasks":
            let params = try container.decode(PostponeTasksParams.self, forKey: .parameters)
            self = .postponeAllTasks(params)
        case "mark_task_complete":
            let params = try container.decode(MarkTaskCompleteParams.self, forKey: .parameters)
            self = .markTaskComplete(params)
        case "request_clarification":
            let params = try container.decode(ClarificationParams.self, forKey: .parameters)
            self = .requestClarification(params)
        case "handle_off_topic_chat":
            let params = try container.decode(OffTopicChatParams.self, forKey: .parameters)
            self = .handleOffTopicChat(params)
        default:
            self = .unknown(functionName)
        }
    }

    /// 추가 명령의 내용을 통째로 바꿉니다.
    /// 수정·삭제·완료 명령은 바뀐 항목만 반영해야 하므로 PendingLLMCall.applyEdit을 사용합니다.
    mutating func updateFields(taskName: String, time: String?, date: String?, category: String) {
        guard case .addSingleTask(var p) = self else { return }
        p.task_name = taskName
        p.time = time
        // 루틴은 날짜 정보가 있으면 안 됨 (매일 반복이 기본이므로)
        p.date = category == "Routine" ? nil : date
        p.category = category
        self = .addSingleTask(p)
    }

    /// OOV 응답 여부
    var isOffTopic: Bool {
        if case .handleOffTopicChat = self { return true }
        return false
    }

    /// OOV 응답 메시지 추출
    var offTopicMessage: String? {
        if case .handleOffTopicChat(let p) = self { return p.message }
        return nil
    }

    /// 되묻기 응답 여부
    var isClarification: Bool {
        if case .requestClarification = self { return true }
        return false
    }

    /// 저장할 내용 없이 사용자에게 말만 건네는 응답(되묻기·잡담)입니다.
    /// 실행·성공 처리에서 빼고, 초안은 그대로 둡니다.
    var isFeedbackOnly: Bool {
        switch self {
        case .requestClarification, .handleOffTopicChat:
            return true
        default:
            return false
        }
    }

    /// 되묻기·잡담 응답의 안내 문장입니다.
    var feedbackMessage: String? {
        switch self {
        case .requestClarification(let params): return params.reason
        case .handleOffTopicChat(let params): return params.message
        default: return nil
        }
    }

    /// 사용자 설정과 무관하게 명시적 확인이 필요한 단일 명령입니다.
    var requiresExplicitConfirmation: Bool {
        switch self {
        case .deleteSpecificTask, .clearAllTasks, .postponeAllTasks:
            return true
        default:
            return false
        }
    }

    /// 기존 데이터를 바꾸는 명령은 승인 화면을 열 때 정확한 UUID/상태 스냅샷을 고정합니다.
    var requiresPreparedTargets: Bool {
        switch self {
        case .updateTask, .deleteSpecificTask, .clearAllTasks, .postponeAllTasks, .markTaskComplete:
            return true
        case .addSingleTask, .requestClarification, .handleOffTopicChat, .unknown:
            return false
        }
    }

    /// 한 응답에 여러 개가 포함되면 대량 변경으로 취급할 명령입니다.
    fileprivate var isMutableExistingTaskCommand: Bool {
        switch self {
        case .updateTask, .markTaskComplete:
            return true
        default:
            return false
        }
    }

    /// LLM이 범위를 누락하거나 잘못 보낸 명령은 넓은 범위로 보정하지 않고 실행을 차단합니다.
    var isExecutionPayloadValid: Bool {
        switch self {
        case .addSingleTask(let params):
            return !params.task_name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && Self.isValidCategory(params.category, allowsAll: false)
                && Self.isValidDate(params.date, allowsNil: true, allowsAll: false)
        case .updateTask(let params):
            return !params.target_task_name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && [
                    params.new_task_name,
                    params.new_time,
                    params.new_date,
                    params.new_category,
                    params.new_recurrence,
                ].contains(where: { $0 != nil })
                && Self.isValidCategory(params.new_category, allowsAll: false)
                && Self.isValidDate(params.new_date, allowsNil: true, allowsAll: false)
        case .deleteSpecificTask(let params):
            return params.target_task_name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
                && Self.isValidCategory(params.target_category, allowsAll: true)
                && Self.isValidDate(params.target_date, allowsNil: true, allowsAll: true)
        case .clearAllTasks(let params):
            return Self.isValidCategory(params.target_category, allowsAll: true)
                && Self.isValidDate(params.target_date, allowsNil: false, allowsAll: true)
        case .postponeAllTasks(let params):
            return Self.isValidDate(params.from_date, allowsNil: false, allowsAll: false)
                && Self.isValidDate(params.to_date, allowsNil: false, allowsAll: false)
        case .markTaskComplete(let params):
            return !params.target_task_name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .requestClarification(let params):
            return !params.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .handleOffTopicChat(let params):
            return !params.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .unknown:
            return false
        }
    }

    private static func isValidCategory(_ value: String?, allowsAll: Bool) -> Bool {
        guard let value else { return true }
        return value == "Routine" || value == "Appointment" || (allowsAll && value.lowercased() == "all")
    }

    private static func isValidDate(
        _ value: String?,
        allowsNil: Bool,
        allowsAll: Bool
    ) -> Bool {
        guard let value else { return allowsNil }
        if allowsAll && value.lowercased() == "all" { return true }

        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }

    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

enum LLMConfirmationPolicy {
    static func requiresExplicitConfirmation(for calls: [LLMFunctionCall]) -> Bool {
        if calls.contains(where: \.requiresExplicitConfirmation) {
            return true
        }

        return calls.filter(\.isMutableExistingTaskCommand).count > 1
    }
}

// MARK: - UI Helpers for Confirmation Card
extension LLMFunctionCall: Identifiable {
    var id: UUID { UUID() }
    
    var uiAction: String {
        switch self {
        case .deleteSpecificTask, .clearAllTasks: return "delete"
        case .addSingleTask: return "add"
        case .updateTask, .postponeAllTasks, .markTaskComplete: return "update"
        case .requestClarification, .handleOffTopicChat, .unknown: return "info"
        }
    }
    
    var uiIcon: String {
        switch uiAction {
        case "delete": return "trash.circle.fill"
        case "update": return "pencil.circle.fill"
        case "add":
            return CategoryIconResolver.resolveIcon(for: uiTaskName, category: uiCategory)
        default:
            return "plus.circle.fill"
        }
    }
    
    var uiActionLabel: String {
        switch uiAction {
        case "delete": return L.voice.confirmDelete
        case "update": return L.voice.confirmUpdate
        case "info": return L.voice.confirmClarify
        default:
            if uiCategory == "Appointment" {
                let todayString = StoredTaskFormat.date.string(from: Date())
                if uiDate == todayString {
                    return L.voice.confirmTask
                }
                return L.voice.confirmAppointment
            }
            return L.voice.confirmRoutine
        }
    }
    
    var uiTaskName: String {
        switch self {
        case .addSingleTask(let p): return p.task_name
        case .updateTask(let p): return p.new_task_name ?? p.target_task_name
        case .deleteSpecificTask(let p): return p.target_task_name
        case .clearAllTasks(let p):
            return p.target_date.lowercased() == "all"
                ? L.voice.actionClearAll
                : L.voice.actionClearDate(ConfirmCardDateFormat.displayDate(p.target_date))
        case .postponeAllTasks(let p):
            return L.voice.actionPostpone(
                from: ConfirmCardDateFormat.displayDate(p.from_date),
                to: ConfirmCardDateFormat.displayDate(p.to_date)
            )
        case .markTaskComplete(let p): return L.voice.actionComplete(p.target_task_name)
        case .requestClarification(let p): return p.reason
        case .handleOffTopicChat(let p): return p.message
        case .unknown(let s): return L.voice.actionUnknown(s)
        }
    }
    
    var uiTime: String? {
        switch self {
        case .addSingleTask(let p): return p.time
        case .updateTask(let p): return p.new_time
        default: return nil
        }
    }
    
    var uiDate: String? {
        switch self {
        case .addSingleTask(let p): return p.date
        case .updateTask(let p): return p.new_date
        case .deleteSpecificTask(let p): return p.target_date
        default: return nil
        }
    }
    
    var uiSmartDateRaw: String {
        uiDate ?? ""
    }
    
    var uiCategory: String {
        switch self {
        case .addSingleTask(let p): return p.category
        case .updateTask(let p):
            return p.new_category ?? "Appointment"
        case .deleteSpecificTask(let p):
            if p.target_category == "Routine" { return "Routine" }
            if p.target_category == "Appointment" { return "Appointment" }
            if let targetDate = p.target_date, targetDate.lowercased() != "all" { return "Appointment" }
            return "All"
        case .requestClarification, .handleOffTopicChat, .unknown:
            // 되묻기·잡담은 일정이 아니므로 루틴·플래너 어느 쪽으로도 표시하지 않습니다.
            return "None"
        default: return "Routine"
        }
    }
    
    // Smart Display for date and time UI
    /// 저장 형식 값을 앱 언어로 보여줍니다("오늘 오후 3:00", "Tomorrow 9:00 AM", "10月30日 15:00").
    var uiSmartDateTime: String {
        let timeString = uiTime.flatMap { $0.isEmpty ? nil : StoredTaskFormat.displayTime($0) } ?? ""
        guard uiCategory != "Routine",
              let dateString = uiDate,
              !dateString.isEmpty,
              dateString.lowercased() != "all" else { return timeString }

        let datePrefix = ConfirmCardDateFormat.displayDate(dateString)
        return timeString.isEmpty ? datePrefix : "\(datePrefix) \(timeString)"
    }
}

// MARK: - Confirmation Card Date Display
/// 확인 카드에서 저장 형식 날짜("2026-10-29")를 앱 언어로 보여줍니다.
/// 오늘·내일은 말로, 그 외는 월·일로 표시하고 올해가 아니면 연도를 붙입니다.
enum ConfirmCardDateFormat {
    static func displayDate(
        _ stored: String,
        now: Date = Date(),
        language: AppLanguage = LocalizationManager.shared.currentLanguage,
        calendar: Calendar = .current
    ) -> String {
        guard let date = StoredTaskFormat.date.date(from: stored) else { return stored }
        let strings = Strings(language: language).voice
        if calendar.isDate(date, inSameDayAs: now) { return strings.confirmToday }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return strings.confirmTomorrow
        }

        let locale = Locale(identifier: language.localeIdentifier)
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: calendar.timeZone)
            .month(.abbreviated)
            .day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        return date.formatted(style)
    }
}
