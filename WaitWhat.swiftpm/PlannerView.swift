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
                            let calendar = Calendar.current
                            let today = calendar.startOfDay(for: Date())
                            let days = (-3...3).compactMap { offset in
                                calendar.date(byAdding: .day, value: offset, to: today)
                            }
                            
                            let weekdayFormatter: DateFormatter = {
                                let f = DateFormatter()
                                f.dateFormat = "E"
                                return f
                            }()
                            
                            let dayFormatter: DateFormatter = {
                                let f = DateFormatter()
                                f.dateFormat = "d"
                                return f
                            }()
                            
                            ForEach(days, id: \.self) { date in
                                let isToday = calendar.isDateInToday(date)
                                VStack(spacing: 6) {
                                    Text(weekdayFormatter.string(from: date).prefix(1)) // M, T, W
                                        .font(DesignSystem.Typography.bodyMd)
                                        .foregroundColor(isToday ? .white : DesignSystem.Colors.onSurfaceVariant)
                                    Text(dayFormatter.string(from: date)) // 12, 13
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
