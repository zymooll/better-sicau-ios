//
//  ContentView.swift
//  test
//
//  Created by zymooll on 2026/8/10.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: AppStore

    init() {
        #if DEBUG
        if DebugFixtures.enabled {
            _store = StateObject(wrappedValue: DebugFixtures.makeStore())
            return
        }
        #endif
        let session = SicauSession()
        _store = StateObject(
            wrappedValue: AppStore(
                authService: session,
                academicService: LiveAcademicService(gateway: session)
            )
        )
    }

    init(authService: any AuthService, academicService: any AcademicService) {
        _store = StateObject(
            wrappedValue: AppStore(
                authService: authService,
                academicService: academicService
            )
        )
    }

    var body: some View {
        Group {
            switch store.sessionState {
            case .restoring:
                LaunchView(message: store.bootstrapMessage)
            case .signedOut:
                LoginView(store: store)
            case .signedIn:
                MainTabView(store: store)
            }
        }
        #if DEBUG
        .modifier(DebugPreviewAppearance())
        #endif
        .animation(.easeInOut(duration: 0.22), value: store.sessionState)
        .task { await store.bootstrap() }
        .task { await store.watchBusinessDate() }
        .onChange(of: scenePhase) { _, phase in
            store.setAppActive(phase == .active)
        }
        .alert(item: $store.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("好")) { store.dismissNotice() }
            )
        }
    }
}

private struct LaunchView: View {
    let message: String
    var body: some View {
        VStack(spacing: 20) {
            BrandMark()
            VStack(spacing: 8) {
                Text("Better Sicau")
                    .font(.title.bold())
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                ProgressView()
                    .tint(.sicauGreen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}
