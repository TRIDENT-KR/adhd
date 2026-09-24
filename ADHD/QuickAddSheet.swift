import SwiftUI

// MARK: - Quick Add Mode
/// D9: AI 미경유 빠른 추가 — 진입한 탭/섹션이 category·date를 결정한다.
enum QuickAddMode {
    case routine              // Routine 탭 · Daily Routines 섹션
    case todayTask            // Routine 탭 · Today's Tasks 섹션
    case appointment(Date)    // Planner 탭 (연관값 = 현재 선택 날짜)
}

// MARK: - Quick Add Sheet
/// AI 할당량과 무관한 수동 추가 시트 — SubscriptionManager 접근 자체가 없어야 한다 (D9).
struct QuickAddSheet: View {
    let mode: QuickAddMode
    @EnvironmentObject private var taskManager: TaskManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var langManager = LocalizationManager.shared
    @State private var name = ""
    @State private var time = ""                 // "" = 시간 미정 (AppTask.time nil 규약)
    @State private var urgency: Urgency = .strong
    @State private var showTimePicker = false
    @State private var saveFailed = false
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 20) {
            // 타이틀 행
            HStack {
                Text(L.quickAdd.title)
                    .font(.title3.bold())
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NoEffectButtonStyle())
                .accessibilityLabel("Close")
            }

            // 이름 입력
            TextField(L.voice.fieldName, text: $name)
                .font(DesignSystem.Typography.bodyMd)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(DesignSystem.Colors.surfaceContainerLow)
                .cornerRadius(14)
                .focused($isNameFocused)
                .submitLabel(.done)
                .onSubmit { save() }

            // 칩 행: 시간 + 긴급도 (TaskRow 편집 모드와 동일 시각 패턴)
            HStack(spacing: 8) {
                Text(time.isEmpty ? L.voice.fieldTime : time)
                    .font(DesignSystem.Typography.labelSm)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(DesignSystem.Colors.onSurfaceVariant.opacity(0.1))
                    .cornerRadius(6)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    .onTapGesture { showTimePicker = true }
                    .accessibilityLabel("Set time")
                    .accessibilityAddTraits(.isButton)

                Button(action: {
                    urgency = (urgency == .weak) ? .strong : .weak
                    Haptic.impact(.light)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: urgency == .strong ? "bolt.fill" : "bolt")
                            .font(.caption2.weight(.semibold))
                        Text(urgency == .strong ? L.voice.urgencyStrong : L.voice.urgencyWeak)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundColor(urgency == .strong ? .orange : DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background((urgency == .strong ? Color.orange : DesignSystem.Colors.onSurfaceVariant).opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(NoEffectButtonStyle())
                .accessibilityLabel(urgency == .strong ? L.voice.urgencyStrong : L.voice.urgencyWeak)

                Spacer()
            }

            // (appointment) 날짜 표시 행 — 표시 전용. 날짜 변경은 Planner 주간 셀렉터에서 (정보 밀도 금기)
            if case .appointment(let date) = mode {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.caption)
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(DesignSystem.Typography.labelSm)
                }
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 저장 실패 안내 — 입력은 남아 있으니 다시 누르기만 하면 된다
            if saveFailed {
                Text(L.quickAdd.saveFailed)
                    .font(DesignSystem.Typography.bodyMd)
                    .foregroundColor(DesignSystem.Colors.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            // 저장 버튼
            Button(action: save) {
                Text(L.quickAdd.save)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SatisfyingButtonStyle(color: DesignSystem.Colors.primary))
            .disabled(trimmedName.isEmpty)
            .opacity(trimmedName.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .background(DesignSystem.Colors.background)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showTimePicker) {
            TimePickerModal(timeString: $time, isPresented: $showTimePicker)
        }
        .onAppear {
            // 자동 포커스 — 시트 전이 애니메이션이 끝난 뒤 (즉시 포커스는 키보드 프레임 충돌)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isNameFocused = true
            }
        }
    }

    private func save() {
        let trimmed = trimmedName
        guard !trimmed.isEmpty else { return }   // 버튼 disabled로 선차단, 이중 방어

        let (category, date): (String, Date?)
        switch mode {
        case .routine:              (category, date) = ("Routine", nil)         // date nil = 매일 반복 규약
        case .todayTask:            (category, date) = ("Appointment", Date())  // 오늘 할 일 (LLM 규약과 동일)
        case .appointment(let d):   (category, date) = ("Appointment", d)
        }

        let task = AppTask(task: trimmed, time: time.isEmpty ? nil : time,
                           date: date, category: category, urgency: urgency)
        // 저장이 확정된 뒤에만 알림·Undo·성공 피드백. 실패하면 시트와 입력을 그대로 둡니다.
        guard taskManager.insertAndSave(task) else {
            saveFailed = true
            Haptic.notification(.error)
            AccessibilityNotification.Announcement(L.quickAdd.saveFailed).post()
            return
        }
        NotificationManager.shared.scheduleNotification(for: task)
        taskManager.setUndoAction(.added([task.id]), message: L.voice.undoAdded(1))
        Haptic.notification(.success)
        dismiss()
    }
}
