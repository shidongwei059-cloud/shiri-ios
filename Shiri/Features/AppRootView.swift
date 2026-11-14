import SwiftUI
import ShiriCore

struct AppRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var keyboardVisible = false
    @State private var showsStartupDiagnostics = false
    @State private var sharingCard: Card?
    @State private var selectsShareCard = false
    @State private var pendingShareCard: Card?
    @State private var createsAfterShareSelection = false
    var body: some View {
        Group {
            if model.isLoading { LaunchBrandView(showsProgress: true) }
            else if let error = model.fatalError {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle).foregroundColor(Paper.accent)
                        Text("数据暂时无法打开").font(Paper.title(28))
                        Text("原有卡片文件已保留。可以先重试；若仍无法打开，请检查可用空间，并导出诊断摘要以便排查。").font(.body).foregroundColor(Paper.secondary)
                        Button("重新打开卡片") { Task { await model.start() } }
                            .buttonStyle(PaperPrimaryButton()).accessibilityIdentifier("startupRetry")
                        Button("导出诊断摘要") { showsStartupDiagnostics = true }
                            .font(Paper.text(17)).frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("startupDiagnostics")
                        DisclosureGroup("错误详情") { Text(error).font(.footnote).textSelection(.enabled) }
                            .font(.subheadline).foregroundColor(Paper.secondary)
                    }.padding(28)
                }.accessibilityIdentifier("startupFailure")
            } else { mainTabs }
        }.foregroundColor(Paper.ink).background { PaperSurface().ignoresSafeArea() }
            .sheet(isPresented: $showsStartupDiagnostics) {
                NavigationStack {
                    DiagnosticExportView().environmentObject(model)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsStartupDiagnostics = false } } }
                }
            }
            .fullScreenCover(item: $model.composer, onDismiss: model.presentPendingComposer) { draft in
                if draft.card.isMemory { MemoryComposerView(initialDate: draft.card.memoryDate ?? model.now, restoring: draft).environmentObject(model) }
                else { ComposerView(draft: draft).environmentObject(model) }
            }
            .fullScreenCover(item: $model.importPackage, onDismiss: model.presentPendingComposer) { ReceiveScheduleView(package: $0).environmentObject(model) }
            .sheet(isPresented: $selectsShareCard, onDismiss: {
                if createsAfterShareSelection { createsAfterShareSelection = false; model.create() }
                else { sharingCard = pendingShareCard }
                pendingShareCard = nil
            }) {
                NavigationStack {
                    Group {
                        let cards = model.library.cards.filter { $0.lifecycle == .active }
                        if cards.isEmpty {
                            ScrollView {
                                PaperEmptyState(title: "先留下一张卡片", message: "把想分享的安排记好，\n再把这份心意送给对方。", scene: .sharing, actionTitle: "去记一件事", action: { createsAfterShareSelection = true; selectsShareCard = false }).padding(18)
                            }.background(Paper.background)
                        } else {
                            List(cards) { card in Button(card.title) { pendingShareCard = card; selectsShareCard = false } }
                        }
                    }.navigationTitle("选择要分享的卡片").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { selectsShareCard = false } } }
                }
            }
            .sheet(item: $sharingCard) { SharingComposerView(card: $0).environmentObject(model) }
            .sheet(item: $model.reminderResponse) { ReminderResponseView(request: $0).environmentObject(model) }
            .onOpenURL { url in Task { await model.openFile(url) } }
            .onReceive(ComposerIntentRouter.shared.$request) { request in
                guard let request else { return }
                Task { @MainActor in
                    // Published emits before assigning its value; consume after that assignment.
                    guard ComposerIntentRouter.shared.request?.id == request.id else { return }
                    ComposerIntentRouter.shared.consume(request.id)
                    model.requestComposer(request.mode)
                }
            }
            .onChange(of: model.selectedCard?.id) { id in
                if id != nil && model.selectedTab == .settings { model.selectedTab = .cards }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }

    private var mainTabs: some View {
        // The system supplies Liquid Glass on iOS 26 and the native tab bar on earlier versions.
        TabView(selection: $model.selectedTab) {
            ForEach(MainTab.allCases) { tab in
                tabContent(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol).accessibilityIdentifier("tab_\(tab.rawValue)") }
                    .tag(tab)
            }
        }
    }

    @ViewBuilder private func tabContent(_ tab: MainTab) -> some View {
        if tab == .settings {
            SettingsView()
        } else {
            NavigationStack {
                mainPage(tab)
                    .toolbar(.hidden, for: .navigationBar)
                    .toolbar(keyboardVisible || model.selectedCard != nil ? .hidden : .visible, for: .tabBar)
                    .navigationDestination(isPresented: Binding(
                        get: { model.selectedTab == tab && model.selectedCard != nil },
                        set: { if !$0 && model.selectedTab == tab { model.selectedCard = nil } }
                    )) {
                        if let card = model.selectedCard {
                            if card.isMemory { MemoryDetailView(cardID: card.id).toolbar(.hidden, for: .tabBar) }
                            else { CardDetailView(cardID: card.id, occurrence: model.selectedOccurrence).toolbar(.hidden, for: .tabBar) }
                        }
                    }
            }
        }
    }

    private func mainPage(_ tab: MainTab) -> some View {
        VStack(spacing: 0) {
            if tab == .review {
                if let message = model.message {
                    HStack(alignment: .top) {
                        PaperErrorBanner(message: message)
                        Button { model.message = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("关闭提示")
                    }.padding(.horizontal, 16)
                }
                ReviewView()
            }
            else { ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let candidate = model.pendingMemory { MemoryCompletionPrompt(candidate: candidate) }
                    if let message = model.message {
                        HStack(alignment: .top) { PaperErrorBanner(message: message); Button { model.message = nil } label: { Image(systemName: "xmark").frame(width: 30, height: 44) }.accessibilityLabel("关闭提示") }
                    }
                    switch tab {
                    case .today: TodayView()
                    case .cards: LibraryView()
                    case .review: EmptyView()
                    case .sharing: SharingCenterView()
                    case .settings: EmptyView()
                    }
                }.padding(.horizontal, 16).padding(.top, 7).padding(.bottom, 8)
            }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("page_\(tab.rawValue)") }
            if !keyboardVisible && (tab == .today || tab == .cards) {
                HStack(spacing: 0) {
                    Button { model.create() } label: { Label("记一件事", systemImage: "plus").font(Paper.text(18)).frame(maxWidth: .infinity).frame(minHeight: 50) }.accessibilityIdentifier("createCard")
                    Rectangle().fill(Paper.onAccent.opacity(0.4)).frame(width: 1, height: 26)
                    Button { model.create(speech: true) } label: { Image(systemName: "mic").font(.system(size: 22)).frame(width: 56, height: 50) }.accessibilityLabel("语音记一件事")
                }.foregroundColor(Paper.onAccent).paperCard(Paper.accent, radius: 17).padding(.horizontal, 16).padding(.top, 5).padding(.bottom, 10)
            }
            if !keyboardVisible && tab == .sharing {
                Button { selectsShareCard = true } label: { Label("分享一张日程卡", systemImage: "plus") }
                    .buttonStyle(PaperPrimaryButton()).padding(.horizontal, 16).padding(.top, 5).padding(.bottom, 10)
            }
        }.background { PaperSurface().ignoresSafeArea() }
    }
}
