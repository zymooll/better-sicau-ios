import SwiftUI

struct MainTabView: View {
    @ObservedObject var store: AppStore
    @State private var selectedTab: AppTab = .dashboard

    init(store: AppStore) {
        self.store = store
        #if DEBUG
        if DebugFixtures.enabled {
            let tab: AppTab
            switch DebugFixtures.page {
            case "schedule", "large", "dark": tab = .schedule
            case "exams": tab = .exams
            case "grades": tab = .grades
            default: tab = .dashboard
            }
            _selectedTab = State(initialValue: tab)
        }
        #endif
    }

    enum AppTab: Hashable {
        case dashboard
        case schedule
        case exams
        case grades
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(store: store, selectedTab: $selectedTab)
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(AppTab.dashboard)

            ScheduleView(store: store)
                .tabItem { Label("课表", systemImage: "calendar") }
                .tag(AppTab.schedule)

            ExamsView(store: store)
                .tabItem { Label("考试", systemImage: "pencil.and.list.clipboard") }
                .tag(AppTab.exams)

            GradesView(store: store)
                .tabItem { Label("成绩", systemImage: "chart.bar.fill") }
                .tag(AppTab.grades)

            SettingsView(store: store)
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(.sicauGreen)
    }
}

