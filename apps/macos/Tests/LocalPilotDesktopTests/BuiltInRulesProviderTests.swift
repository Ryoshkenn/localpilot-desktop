import Foundation
import Testing
@testable import LocalPilotDesktop

struct BuiltInRulesProviderTests {
    @Test
    func defaultSettingsUseBuiltInRules() {
        let settings = AppSettings.defaultValue

        #expect(settings.modelProviderMode == .builtIn)
        #expect(settings.plannerConfiguration().modelName == "built-in-rules")
    }

    @Test
    func internalPlannerReturnsOneStructuredActionWithoutRuntime() async throws {
        let provider = BuiltInRulesProvider()
        let planner = JSONActionPlanner(provider: provider)

        let first = try await planner.proposeOneAction(
            originalTask: "look at the screen",
            context: .empty,
            recentMessages: []
        )
        let second = try await planner.proposeOneAction(
            originalTask: "look at the screen",
            context: .empty,
            recentMessages: []
        )

        #expect(first.type == .observe)
        #expect(first.riskLevel == .low)
        #expect(second.type == .finish)
    }

    @Test
    func internalPlannerCanRunSimpleTaskAfterObservation() async throws {
        let provider = BuiltInRulesProvider()
        let planner = JSONActionPlanner(provider: provider)

        let first = try await planner.proposeOneAction(
            originalTask: "open https://example.com",
            context: .empty,
            recentMessages: []
        )
        let second = try await planner.proposeOneAction(
            originalTask: "open https://example.com",
            context: .empty,
            recentMessages: []
        )
        let third = try await planner.proposeOneAction(
            originalTask: "open https://example.com",
            context: .empty,
            recentMessages: []
        )

        #expect(first.type == .observe)
        #expect(second.type == .openURL)
        #expect(second.targetText == "https://example.com")
        #expect(third.type == .finish)
    }

    @Test
    func internalPlannerSupportsKeyboardAndTerminalTaskShapes() async throws {
        let typingProvider = BuiltInRulesProvider()
        let typingPlanner = JSONActionPlanner(provider: typingProvider)
        _ = try await typingPlanner.proposeOneAction(
            originalTask: "type \"hello local pilot\"",
            context: .empty,
            recentMessages: []
        )
        let typingAction = try await typingPlanner.proposeOneAction(
            originalTask: "type \"hello local pilot\"",
            context: .empty,
            recentMessages: []
        )

        let terminalProvider = BuiltInRulesProvider()
        let terminalPlanner = JSONActionPlanner(provider: terminalProvider)
        _ = try await terminalPlanner.proposeOneAction(
            originalTask: "run `pwd`",
            context: .empty,
            recentMessages: []
        )
        let terminalAction = try await terminalPlanner.proposeOneAction(
            originalTask: "run `pwd`",
            context: .empty,
            recentMessages: []
        )

        #expect(typingAction.type == .typeTextSafe)
        #expect(typingAction.text == "hello local pilot")
        #expect(terminalAction.type == .runTerminalCommand)
        #expect(terminalAction.command == "pwd")
    }
}
