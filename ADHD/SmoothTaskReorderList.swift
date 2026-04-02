import SwiftUI

// MARK: - Row Frame Preference Key
private struct RowFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Smooth Task Reorder List
/// onDrag/onDrop 대신 DragGesture 기반으로 구현한 부드러운 드래그 리오더 리스트.
/// RoutineView(루틴/일정)와 PlannerView(플래너) 양쪽에서 재사용.
struct SmoothTaskReorderList: View {
    let source: [AppTask]
    let taskManager: TaskManager

    @State private var order: [UUID]
    @State private var draggingId: UUID?
    @State private var fingerY: CGFloat = 0
    @State private var frames: [UUID: CGRect] = [:]
    @State private var lastHapticNeighbor: UUID?  // 재정렬 햅틱 중복 방지

    private let itemSpacing: CGFloat = 10

    init(tasks: [AppTask], taskManager: TaskManager) {
        self.source = tasks
        self.taskManager = taskManager
        _order = State(initialValue: tasks.map(\.id))
    }

    private var orderedTasks: [AppTask] {
        order.compactMap { id in source.first { $0.id == id } }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // ── 기본 리스트 (드래그 중인 항목은 투명하게) ──
            VStack(spacing: itemSpacing) {
                ForEach(orderedTasks) { task in
                    baseRow(task: task)
                }
            }
            .coordinateSpace(name: "reorderList")
            .onPreferenceChange(RowFrameKey.self) { frames = $0 }

            // ── 드래그 중 떠오르는 고스트 아이템 ──
            if let id = draggingId,
               let task = source.first(where: { $0.id == id }) {
                rowVisual(task: task, isGhost: true)
                    .scaleEffect(1.05)
                    .shadow(color: .black.opacity(0.2), radius: 18, x: 0, y: 8)
                    .offset(y: fingerY - (frames[id]?.height ?? 58) / 2)
                    .allowsHitTesting(false)
                    .zIndex(100)
            }
        }
        // 외부 @Query 변경 시 아이디 순서 동기화 (드래그 중엔 무시)
        .onChange(of: source.map(\.id)) { _, ids in
            guard draggingId == nil else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                order = ids
            }
        }
    }

    // MARK: - Base Row
    @ViewBuilder
    private func baseRow(task: AppTask) -> some View {
        rowVisual(task: task, isGhost: false)
            .opacity(draggingId == task.id ? 0 : 1)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: RowFrameKey.self,
                        value: [task.id: geo.frame(in: .named("reorderList"))]
                    )
                }
            )
            // 왼쪽 핸들 영역에만 highPriorityGesture 적용 → ScrollView 충돌 최소화
            .overlay(alignment: .leading) {
                handleArea(task: task)
            }
    }

    // MARK: - Invisible Handle Hit Area
    @ViewBuilder
    private func handleArea(task: AppTask) -> some View {
        Color.clear
            .frame(width: 64, height: 58)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("reorderList"))
                    .onChanged { value in
                        if draggingId != task.id {
                            draggingId = task.id
                            fingerY = value.location.y
                            lastHapticNeighbor = nil
                            Haptic.impact(.medium)
                        }
                        fingerY = value.location.y
                        updateOrder(dragging: task.id, to: fingerY)
                    }
                    .onEnded { _ in
                        commitOrder()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                            draggingId = nil
                        }
                        Haptic.impact(.light)
                    }
            )
    }

    // MARK: - Row Visual (기본 + 고스트 공용)
    private func rowVisual(task: AppTask, isGhost: Bool) -> some View {
        HStack(spacing: 16) {
            // 드래그 핸들
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.3))
                .frame(width: 22)

            // 완료 아이콘
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundColor(
                    task.isCompleted
                        ? DesignSystem.Colors.tertiary
                        : DesignSystem.Colors.onSurfaceVariant.opacity(0.25)
                )

            // 태스크 정보
            VStack(alignment: .leading, spacing: 3) {
                Text(task.task)
                    .font(DesignSystem.Typography.bodyMd)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    .lineLimit(1)
                if let time = task.time, !time.isEmpty {
                    HStack(spacing: 4) {
                        Text(time)
                        if let label = task.recurrenceLabel {
                            Image(systemName: "repeat").font(.system(size: 9))
                            Text(label)
                        }
                    }
                    .font(DesignSystem.Typography.labelSm)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                }
            }

            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.leading, 24)
        .padding(.trailing, 20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    isGhost
                        ? DesignSystem.Colors.surfaceContainerLow
                        : DesignSystem.Colors.surfaceContainerLow.opacity(0.85)
                )
        )
        .padding(.horizontal, 24)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: order)
    }

    // MARK: - Reorder Logic
    /// fingerY 위치를 기준으로 드래그 중인 아이템의 순서를 실시간 갱신
    private func updateOrder(dragging dragId: UUID, to y: CGFloat) {
        guard let currentIdx = order.firstIndex(of: dragId) else { return }

        // 다른 아이템들의 midY를 위에서 아래 순으로 정렬
        let others = order
            .filter { $0 != dragId }
            .compactMap { id -> (UUID, CGFloat)? in
                guard let midY = frames[id]?.midY else { return nil }
                return (id, midY)
            }
            .sorted { $0.1 < $1.1 }

        // y가 어느 슬롯에 해당하는지 계산
        var newIdx = 0
        for (_, midY) in others {
            if y > midY { newIdx += 1 }
        }

        guard newIdx != currentIdx else { return }

        // 이동 대상 이웃 ID로 중복 햅틱 방지
        let neighborId = newIdx < others.count ? others[newIdx].0 : others.last?.0
        if neighborId != lastHapticNeighbor {
            lastHapticNeighbor = neighborId
            Haptic.impact(.soft)
        }

        withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
            var newOrder = order.filter { $0 != dragId }
            newOrder.insert(dragId, at: min(newIdx, newOrder.count))
            order = newOrder
        }
    }

    // MARK: - Commit to SwiftData
    private func commitOrder() {
        for (i, id) in order.enumerated() {
            source.first(where: { $0.id == id })?.sortOrder = (i + 1) * 10
        }
        taskManager.safeSave()
    }
}
