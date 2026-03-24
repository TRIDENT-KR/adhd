import SwiftUI

struct PlannerView: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            // Off-white background
            DesignSystem.Colors.background.ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    
                    // Header
                    Text("My Planner")
                        .font(DesignSystem.Typography.displayLg)
                        .foregroundColor(DesignSystem.Colors.primary)
                        .tracking(-0.5)
                        .padding(.top, 16)
                        .padding(.horizontal, 32)
                    
                    // Date Selector (7 days)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            // Dummy data representing M 12 to S 18
                            let days = ["M 12", "T 13", "W 14", "T 15", "F 16", "S 17", "S 18"]
                            
                            ForEach(0..<days.count, id: \.self) { index in
                                let isToday = index == 3 // Simulate 'Thursday 15' as today
                                VStack(spacing: 6) {
                                    Text(days[index].prefix(1)) // M, T, W
                                        .font(DesignSystem.Typography.bodyMd)
                                        .foregroundColor(isToday ? .white : DesignSystem.Colors.onSurfaceVariant)
                                    Text(days[index].dropFirst(2)) // 12, 13
                                        .font(DesignSystem.Typography.titleSm)
                                        .foregroundColor(isToday ? .white : DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                                }
                                .padding(.vertical, 16)
                                .padding(.horizontal, 16)
                                .background(isToday ? Capsule().fill(DesignSystem.Colors.primaryContainer) : Capsule().fill(Color.clear))
                            }
                        }
                        .padding(.horizontal, 32)
                    }
                    
                    // Timeline View
                    LazyVStack(spacing: 24) {
                        EventCard(time: "10:00 AM", title: "Design Sync")
                        EventCard(time: " 2:00 PM", title: "Doctor Appointment")
                        EventCard(time: " 4:30 PM", title: "Read Chapter 4")
                    }
                    
                    Spacer(minLength: 140) // Space for bottom bar
                }
            }
        }
    }
}

// MARK: - Event Card Component
struct EventCard: View {
    let time: String
    let title: String
    
    var body: some View {
        HStack(spacing: 20) {
            Text(time)
                .font(DesignSystem.Typography.labelSm)
                .tracking(0.3)
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                .frame(width: 64, alignment: .leading)
            
            Text(title)
                .font(DesignSystem.Typography.bodyMd)
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant) // soft, non-alarming
            
            Spacer()
        }
        .padding(24)
        // Very faint pastel tint
        .background(DesignSystem.Colors.primary.opacity(0.05))
        .cornerRadius(24) // Soft rounded corners
        .padding(.horizontal, 32)
    }
}

struct PlannerView_Previews: PreviewProvider {
    static var previews: some View {
        PlannerView()
    }
}
