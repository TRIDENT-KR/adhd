import Foundation
import SwiftData
import SwiftUI

// MARK: - TaskManager Function Calling Extension
extension TaskManager {
    
    /// 메인 라우터: CloudLLMManager에서 파싱된 함수 호출들을 순차적으로 실행합니다.
    func execute(llmCalls: [LLMFunctionCall]) {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🤖 [AI Function Calling 라우터 작동 시작]")
        print("수신된 명령어 개수: \(llmCalls.count)개")
        
        for (index, call) in llmCalls.enumerated() {
            print("----------------------------------------")
            
            switch call {
            case .addSingleTask(let params):
                print("▶️ [명령 \(index + 1)] 호출 함수: add_single_task")
                print("   ↳ 파라미터: 이름='\(params.task_name)', 시간='\(params.time ?? "nil")', 날짜='\(params.date ?? "nil")', 카테고리='\(params.category)', 반복='\(params.recurrence ?? "nil")'")
                addSingleTask(params: params)
                
            case .updateTask(let params):
                print("▶️ [명령 \(index + 1)] 호출 함수: update_task")
                print("   ↳ 파라미터(수정대상): '\(params.target_task_name)'")
                print("   ↳ 파라미터(변경값): 반환된 새 이름='\(params.new_task_name ?? "nil")', 시간='\(params.new_time ?? "nil")', 날짜='\(params.new_date ?? "nil")', 카테고리='\(params.new_category ?? "nil")', 반복='\(params.new_recurrence ?? "nil")'")
                updateTask(params: params)
                
            case .deleteSpecificTask(let params):
                print("▶️ [명령 \(index + 1)] 호출 함수: delete_specific_task")
                print("   ↳ 파라미터(삭제대상): '\(params.target_task_name)'")
                deleteSpecificTask(params: params)
                
            case .clearAllTasks(let params):
                print("▶️ [명령 \(index + 1)] 호출 함수: clear_all_tasks")
                print("   ↳ 파라미터(삭제일자): '\(params.target_date)'")
                clearAllTasks(params: params)
                
            case .postponeAllTasks(let params):
                print("▶️ [명령 \(index + 1)] 호출 함수: postpone_all_tasks")
                print("   ↳ 파라미터(연기경로): '\(params.from_date)' -> '\(params.to_date)'")
                postponeAllTasks(params: params)
                
            case .markTaskComplete(let params):
                print("▶️ [명령 \(index + 1)] 호출 함수: mark_task_complete")
                print("   ↳ 파라미터(완료대상): '\(params.target_task_name)'")
                markTaskComplete(params: params)
                
            case .requestClarification(let params):
                print("▶️ [명령 \(index + 1)] 호출 함수: request_clarification")
                print("   ↳ 파라미터(분류불가 사유): '\(params.reason)'")
                requestClarification(params: params)
                
            case .unknown(let funcName):
                print("▶️ [명령 \(index + 1)] 호출 함수: (알 수 없음)")
                print("⚠️ [TaskManager] 에러: 지원하지 않는 함수 호출: \(funcName)")
            }
        }
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        // 일괄 변경 내역 한 번에 저장
        safeSave()
    }
    
    // MARK: - 1. Add Single Task
    private func addSingleTask(params: AddSingleTaskParams) {
        // 일정이 시간 없이 추가되면 '허전함'을 방지하기 위해 기본값(오전 09:00) 부여
        let defaultTime = (params.category == "Appointment") ? "오전 09:00" : nil
        let finalTime = (params.time == nil || params.time!.isEmpty) ? defaultTime : params.time

        let task = AppTask(
            task: params.task_name,
            time: finalTime,
            date: date(from: params.date) ?? (params.category == "Routine" ? nil : Date()),
            category: params.category,
            recurrenceRule: params.recurrence
        )
        insertBatch(task)
        NotificationManager.shared.scheduleNotification(for: task)
        setUndoAction(.added([task]), message: L.voice.undoAdded(1))
    }
    
    // MARK: - 2. Update Task
    private func updateTask(params: UpdateTaskParams) {
        guard let matchingTask = findBestMatch(name: params.target_task_name) else {
            print("❌ [updateTask] 일치하는 일정을 찾을 수 없음: \(params.target_task_name)")
            return
        }
        
        let previousState = (task: matchingTask.task, time: matchingTask.time, date: matchingTask.date, category: matchingTask.category, recurrenceRule: matchingTask.recurrenceRule)
        
        // 기존 알림 취소 (시간/날짜 등이 변경될 수 있으므로)
        NotificationManager.shared.cancelNotification(for: matchingTask)
        
        // 파라미터가 들어온 것만 선별적으로 업데이트 (nil인 경우 기존 값 유지)
        if let newName = params.new_task_name { matchingTask.task = newName }
        if let newTime = params.new_time { matchingTask.time = newTime }
        
        if let newCategory = params.new_category { 
            matchingTask.category = newCategory 
            // 만약 루틴으로 변경된 경우, 특정 날짜 정보를 제거하여 매일 반복되도록 처리
            if newCategory == "Routine" {
                matchingTask.date = nil
            }
        }
        
        // 날짜가 명시적으로 들어왔다면 (Appointment 등) 업데이트
        if let newDateString = params.new_date, let newDate = date(from: newDateString) {
            matchingTask.date = newDate
        }
        
        if let newRecurrence = params.new_recurrence { matchingTask.recurrenceRule = newRecurrence }
        
        // 알림 재설정
        NotificationManager.shared.scheduleNotification(for: matchingTask)
        
        setUndoAction(.deleted([previousState]), message: "\(matchingTask.task) 일정이 업데이트되었습니다.") // Undo는 복잡하여 단순 삭제처리로 갈음하거나 메시지만 띄움
    }
    
    // MARK: - 3. Delete Specific Task
    private func deleteSpecificTask(params: DeleteTaskParams) {
        let deleted = deleteByNameBatch(
            containing: params.target_task_name,
            category: params.target_category,
            dateString: params.target_date
        )
        if !deleted.isEmpty {
            setUndoAction(.deleted(deleted), message: L.voice.undoDeleted(deleted.count))
        } else {
            print("❌ [deleteSpecificTask] 일치하는 일정을 찾을 수 없음: \(params.target_task_name)")
        }
    }
    
    // MARK: - 4. Clear All Tasks (특정 날짜)
    private func clearAllTasks(params: ClearTasksParams) {
        guard let context = modelContext else { return }
        
        let isAllTime = (params.target_date.lowercased() == "all")
        let targetDate = date(from: params.target_date)
        
        // 안전망: 날짜가 지정되었는데 카테고리가 없으면 루틴 보호를 위해 Appointment로 간주
        let finalCategory = (params.target_category == nil && !isAllTime) ? "Appointment" : params.target_category
        
        do {
            let allTasks = try context.fetch(FetchDescriptor<AppTask>())
            var deletedCount = 0
            var deletedSnapshots: [(task: String, time: String?, date: Date?, category: String, recurrenceRule: String?)] = []
            
            for task in allTasks {
                // 1) 날짜 조건 검사 ("all" 이면 무조건 참, 아니면 해당 날짜에 해당하는지)
                let dateMatches = isAllTime || (targetDate != nil && task.occursOn(targetDate!))
                
                // 2) 카테고리 조건 검사
                let categoryMatches = (finalCategory == nil || finalCategory?.lowercased() == "all" || task.category == finalCategory)
                
                let shouldDelete = dateMatches && categoryMatches
                
                if shouldDelete {
                    deletedSnapshots.append((task: task.task, time: task.time, date: task.date, category: task.category, recurrenceRule: task.recurrenceRule))
                    NotificationManager.shared.cancelNotification(for: task)
                    context.delete(task)
                    deletedCount += 1
                }
            }
            
            if deletedCount > 0 {
                setUndoAction(.deleted(deletedSnapshots), message: L.voice.undoDeleted(deletedCount))
            }
        } catch {
            print("❌ [clearAllTasks] 예외 발생: \(error)")
        }
    }
    
    // MARK: - 5. Postpone All Tasks
    private func postponeAllTasks(params: PostponeTasksParams) {
        guard let context = modelContext,
              let fromDate = date(from: params.from_date),
              let toDate = date(from: params.to_date) else {
            print("❌ [postponeAllTasks] 날짜 파싱 실패: \(params.from_date) -> \(params.to_date)")
            return
        }
        
        do {
            let allTasks = try context.fetch(FetchDescriptor<AppTask>())
            var postponedCount = 0
            
            for task in allTasks {
                if let taskDate = task.date, Calendar.current.isDate(taskDate, inSameDayAs: fromDate) {
                    NotificationManager.shared.cancelNotification(for: task)
                    task.date = toDate
                    NotificationManager.shared.scheduleNotification(for: task)
                    postponedCount += 1
                }
            }
            
            if postponedCount > 0 {
                undoSnackbarMessage = "\(postponedCount)개의 일정이 연기되었습니다."
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    showUndoSnackbar = true
                }
            }
        } catch {
            print("❌ [postponeAllTasks] 예외 발생: \(error)")
        }
    }
    
    // MARK: - 6. Mark Task Complete
    private func markTaskComplete(params: MarkTaskCompleteParams) {
        guard let matchingTask = findBestMatch(name: params.target_task_name) else {
            print("❌ [markTaskComplete] 일치하는 일정을 찾을 수 없음: \(params.target_task_name)")
            return
        }
        
        let previousState = matchingTask.isCompleted
        matchingTask.isCompleted = true
        setUndoAction(.toggled(matchingTask, previousState), message: L.voice.undoCompleted)
    }
    
    // MARK: - 7. Request Clarification (명확화 요청)
    private func requestClarification(params: ClarificationParams) {
        // 기존 UI의 스낵바를 활용해 텍스트 피드백 표출
        undoSnackbarMessage = "🤔 \(params.reason)"
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showUndoSnackbar = true
        }
        
        // 5초 뒤 자동 숨김 설정 (기존 setUndoAction 로직 차용)
        undoDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.showUndoSnackbar = false
            }
        }
        undoDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }
    
    // MARK: - Helpers
    
    /// 이름 기반 다중 타겟 대신 1개의 가장 근접한 Task를 반환 (Update, Complete용)
    private func findBestMatch(name: String) -> AppTask? {
        guard let context = modelContext else { return nil }
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        do {
            let all = try context.fetch(FetchDescriptor<AppTask>())
            // 1. 정확히 매칭
            if let exactMatch = all.first(where: { $0.task.lowercased() == query }) {
                return exactMatch
            }
            // 2. 검색어가 포함된 것 매칭 (2글자 이상)
            if query.count >= 2 {
                if let partialMatch = all.first(where: { $0.task.lowercased().contains(query) }) {
                    return partialMatch
                }
            }
        } catch {
            print("❌ findBestMatch 에러: \(error)")
        }
        return nil
    }
    
    private func date(from string: String?) -> Date? {
        guard let string = string, string.lowercased() != "all" else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)
    }
}
