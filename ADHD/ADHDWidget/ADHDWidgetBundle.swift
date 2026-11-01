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

        // Control (잠금 화면 아래 버튼·제어 센터·동작 버튼)
        SpeakControl()

        // AlarmKit Live Activity (강한 알람 스누즈 카운트다운)
        AlarmLiveActivity()
    }
}
