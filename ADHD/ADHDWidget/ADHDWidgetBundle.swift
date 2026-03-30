//
//  ADHDWidgetBundle.swift
//  ADHDWidget
//
//  Created by 박정원 on 3/30/26.
//

import WidgetKit
import SwiftUI

@main
struct ADHDWidgetBundle: WidgetBundle {
    var body: some Widget {
        // Home Screen Widgets
        NextTaskWidget()
        TodayRoutinesWidget()
        DailyOverviewWidget()

        // Lock Screen Widgets
        RoutineProgressWidget()
        NextTaskLockWidget()
        TaskCountInlineWidget()
    }
}
