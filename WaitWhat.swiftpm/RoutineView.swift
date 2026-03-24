import SwiftUI

struct RoutineView: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            // 1. Off-white background
            DesignSystem.Colors.background
                .ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 48) { // 부드럽고 시원한 여백 유지
                    
                    // 영역: My Routines Title
                    Text("My Routines")
                        .font(DesignSystem.Typography.displayLg)
                        .foregroundColor(DesignSystem.Colors.primary) // 시각적 위계 높은 제목
                        .tracking(-0.5)
                        .padding(.top, 16) // 위쪽 여백 축소 (시각적 밸런스 조정)
                        .padding(.horizontal, 32)
                    
                    // 영역: Daily Routines
                    VStack(alignment: .leading, spacing: 32) {
                        Text("Daily Routines")
                            .font(DesignSystem.Typography.titleSm)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .padding(.horizontal, 32)
                        
                        LazyVStack(spacing: 32) { // 항목 간 여백 넓게
                            TaskRow(title: "Morning Meditation", time: "07:00 AM", isCompleted: true)
                            TaskRow(title: "Check Email", time: "08:30 AM", isCompleted: false)
                            TaskRow(title: "Water Plants", time: "09:00 AM", isCompleted: false)
                        }
                    }
                    
                    // 영역: Today's Tasks
                    VStack(alignment: .leading, spacing: 32) {
                        Text("Today's Tasks")
                            .font(DesignSystem.Typography.titleSm)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .padding(.horizontal, 32)
                        
                        LazyVStack(spacing: 32) {
                            TaskRow(title: "Project Review", time: "01:00 PM", isCompleted: false)
                            TaskRow(title: "Call Mom", time: "06:00 PM", isCompleted: false)
                        }
                    }
                    
                    // 바텀 플로팅 바가 텍스트를 가리지 않도록 공간 확보
                    Spacer(minLength: 140)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

// MARK: - Task Row Component (할 일 항복 컴포넌트)
struct TaskRow: View {
    let title: String
    let time: String
    @State var isCompleted: Bool
    
    var body: some View {
        HStack(spacing: 20) {
            // 1. 좌측: 크고 명확한 원형 체크박스
            Button(action: {
                // 부드러운 상태 전환 곡선 적용 (DESIGN.md 규칙: soft transitions)
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
                    isCompleted.toggle()
                }
            }) {
                ZStack {
                    Circle()
                        .stroke(DesignSystem.Colors.onSurfaceVariant.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 32, height: 32)
                    
                    if isCompleted {
                        Circle()
                            // 체크 시엔 성공 피드백, Tertiary(#006A63) 컬러 사용
                            .fill(Color(hex: "#006A63"))
                            .frame(width: 32, height: 32)
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            
            // 2. 중앙: 할 일 제목과 흐릿한(Muted) 시간 텍스트
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(DesignSystem.Typography.bodyMd)
                    .strikethrough(isCompleted, color: DesignSystem.Colors.onSurfaceVariant)
                    // 완료되면 본문 색상도 대비를 낮춰서 뒤로 물리게 함
                    .foregroundColor(isCompleted ? DesignSystem.Colors.onSurfaceVariant.opacity(0.4) : DesignSystem.Colors.onSurfaceVariant)
                
                Text(time)
                    .font(DesignSystem.Typography.labelSm)
                    // 시각적 노이즈를 줄이기 위한 매우 연한 톤 (Muted gray)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
            }
            
            Spacer()
            
            // 3. 우측: 극단적으로 대비를 낮춘 수정 및 음성(마이크) 툴 아이콘
            HStack(spacing: 16) {
                Button(action: { /* Mic Edit Action */ }) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18))
                }
                Button(action: { /* Manual Edit Action */ }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 18))
                }
            }
            // 낮춤 대비(Low-contrast)로 주의력 뺏지 않음
            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.2))
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Preview
struct RoutineView_Previews: PreviewProvider {
    static var previews: some View {
        RoutineView()
    }
}
