import SwiftUI

struct MainWindowView: View {
    @Bindable var controller: AgentController
    @State private var selectedSection: SidebarSection = .chat
    @State private var taskText = ""
    @State private var researchStore = ResearchStore()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $selectedSection) {
                controller.newConversation()
                taskText = ""
                selectedSection = .chat
            }
            Rectangle()
                .fill(Theme.stroke)
                .frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            FocusReleaser.install()
            OverlayWindowManager.shared.configure(controller: controller)
            // Reconcile on first appearance too, in case the controller is
            // already mid-run when the window opens; `onChange` alone would miss it.
            OverlayWindowManager.shared.sync(with: controller)
            controller.refreshLocalModels()
        }
        .onChange(of: controller.overlayState) { _, _ in
            OverlayWindowManager.shared.sync(with: controller)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .chat:
            ChatPanelView(controller: controller, taskText: $taskText) {
                selectedSection = .settings
            }
        case .research:
            ResearchWorkspaceView(store: researchStore, logFileURL: controller.logFileURL)
        case .history:
            HistoryView(controller: controller) { id in
                controller.openConversation(id: id)
                selectedSection = .chat
            }
        case .permissions:
            PermissionsView()
        case .settings:
            SettingsView(controller: controller)
        }
    }
}
