import SwiftUI

@main
struct LocalPilotDesktopApp: App {
    @State private var controller = AgentController()

    var body: some Scene {
        WindowGroup {
            MainWindowView(controller: controller)
                .frame(minWidth: 1080, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1536, height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") {
                    controller.newConversation()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandMenu("Agent") {
                Button("Pause") {
                    controller.pause()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(controller.runStatus != .running)

                Button("Stop") {
                    controller.stop()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!controller.runStatus.isActive)

                Divider()

                Text("Stop from any app: ⌥⌘.")
            }
        }
    }
}
