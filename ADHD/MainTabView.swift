import SwiftUI

struct MainTabView: View {
    @State private var activeTab: TabSelection = .planner // Start at planner
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Background covers all
            DesignSystem.Colors.background.ignoresSafeArea()
            
            // Current View
            Group {
                switch activeTab {
                case .routine:
                    RoutineView()
                case .voice:
                    HomeVoiceInterfaceView()
                case .planner:
                    PlannerView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Global Bottom Bar
            CustomBottomBar(activeTab: $activeTab)
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
