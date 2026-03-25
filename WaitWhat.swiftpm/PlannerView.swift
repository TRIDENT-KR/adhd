import SwiftUI

struct PlannerView: View {
    @EnvironmentObject var taskManager: TaskManager
    @State private var editingTaskId: UUID?
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    
    private let calendar = Calendar.current
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
                                let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
                                Button(action: {
                                    withAnimation(.spring()) {
                                        selectedDate = date
                                    }
                                }) {
                                    VStack(spacing: 6) {
                                        Text(weekdayFormatter.string(from: date).prefix(1)) // M, T, W
                                            .font(DesignSystem.Typography.bodyMd)
                                            .foregroundColor(isSelected ? .white : DesignSystem.Colors.onSurfaceVariant)
                                        Text(dayFormatter.string(from: date)) // 12, 13
                                            .font(DesignSystem.Typography.titleSm)
                                            .foregroundColor(isSelected ? .white : DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                                    }
                                    .padding(.vertical, 16)
                                    .padding(.horizontal, 16)
                                    .background(isSelected ? Capsule().fill(DesignSystem.Colors.primaryContainer) : Capsule().fill(Color.clear))
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 32)
                    }
                    
                    // Timeline View
                    let filteredIndices = taskManager.appointments.indices.filter { index in
                        if let taskDate = taskManager.appointments[index].date {
                            return calendar.isDate(taskDate, inSameDayAs: selectedDate)
                        }
                        return false
                    }
                    
                    if filteredIndices.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "circle.dotted")
                                .font(.system(size: 40))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.2))
                            Text("No plans for this date.")
                                .font(DesignSystem.Typography.bodyMd)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        LazyVStack(spacing: 24) {
                            ForEach(filteredIndices, id: \.self) { index in
                                EventCard(appointment: $taskManager.appointments[index], editingTaskId: $editingTaskId)
                            }
                        }
                    }
                    
                    Spacer(minLength: 140) // Space for bottom bar
                }
            }
        }
    }
}

// MARK: - Event Card Component
struct EventCard: View {
    @Binding var appointment: ParsedTask
    @Binding var editingTaskId: UUID?
    @FocusState private var isTitleFocused: Bool
    @State private var showingTimePicker = false
    
    var isEditing: Bool {
        editingTaskId == appointment.id
    }
    
    var isDimmed: Bool {
        editingTaskId != nil && editingTaskId != appointment.id
    }
    
    var body: some View {
        HStack(spacing: 20) {
            if isEditing {
                Text(appointment.time?.isEmpty == false ? appointment.time! : "Set Time")
                    .font(DesignSystem.Typography.labelSm)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(DesignSystem.Colors.onSurfaceVariant.opacity(0.1))
                    .cornerRadius(6)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    .onTapGesture {
                        showingTimePicker = true
                    }
                    .sheet(isPresented: $showingTimePicker) {
                        TimePickerModal(timeString: $appointment.time, isPresented: $showingTimePicker)
                    }
                
                TextField("Title", text: $appointment.task)
                    .focused($isTitleFocused)
                    .font(DesignSystem.Typography.bodyMd)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    .submitLabel(.done)
                    .onSubmit { finishEditing() }
            } else {
                Text(appointment.time ?? "")
                    .font(DesignSystem.Typography.labelSm)
                    .tracking(0.3)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                    .frame(width: 64, alignment: .leading)
                
                Text(appointment.task)
                    .font(DesignSystem.Typography.bodyMd)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
            }
            
            Spacer()
            
            // Edit Button inside the card
            Button(action: {
                withAnimation {
                    if isEditing {
                        finishEditing()
                    } else {
                        startEditing()
                    }
                }
            }) {
                Image(systemName: isEditing ? "checkmark" : "pencil")
                    .font(.system(size: 16))
            }
            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.3))
        }
        .padding(24)
        // Very faint pastel tint
        .background(DesignSystem.Colors.primary.opacity(0.05))
        .cornerRadius(24) // Soft rounded corners
        .padding(.horizontal, 32)
        .opacity(isDimmed ? 0.3 : 1.0)
        .onChange(of: editingTaskId) { newValue in
            if newValue == appointment.id {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTitleFocused = true
                }
            } else {
                isTitleFocused = false
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if isEditing {
                    Spacer()
                    Button("Done") {
                        withAnimation {
                            finishEditing()
                        }
                    }
                }
            }
        }
    }
    
    private func finishEditing() {
        if editingTaskId == appointment.id {
            editingTaskId = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
    
    private func startEditing() {
        editingTaskId = appointment.id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

struct PlannerView_Previews: PreviewProvider {
    static var previews: some View {
        PlannerView()
            .environmentObject(TaskManager())
    }
}
