import Foundation
import Testing
@testable import LocalPilotDesktop

actor SpyComputerController: ComputerControlling {
    private(set) var clicks: [CGPoint] = []
    private(set) var doubleClicks: [CGPoint] = []
    private(set) var typedText: [String] = []
    private(set) var scrolls: [Int32] = []
    private(set) var keys: [String] = []
    private(set) var copyCount = 0
    private(set) var pastedText: [String] = []
    private(set) var openedURLs: [String] = []
    private(set) var terminalCommands: [String] = []
    private(set) var switchedApps: [String] = []
    private(set) var browserCalls: [String] = []

    func click(at point: CGPoint) async {
        clicks.append(point)
    }

    func doubleClick(at point: CGPoint) async {
        doubleClicks.append(point)
    }

    func typeText(_ text: String) async {
        typedText.append(text)
    }

    func scroll(deltaY: Int32, at point: CGPoint?) async {
        scrolls.append(deltaY)
    }

    func pressKey(named key: String) async {
        keys.append(key)
    }

    func copySelection() async {
        copyCount += 1
    }

    func pasteText(_ text: String) async {
        pastedText.append(text)
    }

    func openURL(_ urlString: String) async -> Bool {
        openedURLs.append(urlString)
        return true
    }

    func runTerminalCommand(_ command: String) async -> String {
        terminalCommands.append(command)
        return "spy output"
    }

    func browserAction(_ type: ActionType, value: String) async -> String {
        browserCalls.append(type.rawValue + ":" + value)
        return "Chrome action completed."
    }

    func switchApp(named appName: String) async -> Bool {
        switchedApps.append(appName)
        return true
    }
}

@MainActor
struct ActionExecutorTests {
    @Test
    func dryRunClickDoesNotTouchComputerController() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: true)
        let action = StructuredAction(
            type: .click,
            targetKind: "point",
            targetText: "Search",
            coordinates: [40, 80],
            expectedResult: "clicked",
            riskLevel: .low,
            reason: "test"
        )

        let result = await executor.execute(action)

        #expect(result.contains("Dry-run only"))
        #expect(await controller.clicks.isEmpty)
    }

    @Test
    func permissionedClickUsesCoordinates() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)
        let action = StructuredAction(
            type: .click,
            targetKind: "point",
            targetText: "Search",
            coordinates: [40, 80],
            expectedResult: "clicked",
            riskLevel: .low,
            reason: "test"
        )

        let result = await executor.execute(action)

        #expect(result == "Clicked Search at 40,80.")
        #expect(await controller.clicks == [CGPoint(x: 40, y: 80)])
    }

    @Test
    func permissionedTypingScrollAndKeyUseComputerController() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)

        _ = await executor.execute(StructuredAction(
            type: .typeTextSafe,
            targetKind: "focused_field",
            targetText: "focused field",
            text: "hello",
            expectedResult: "typed",
            riskLevel: .low,
            reason: "test"
        ))
        _ = await executor.execute(StructuredAction(
            type: .scroll,
            targetKind: "window",
            targetText: "main window",
            coordinates: [0, -3],
            expectedResult: "scrolled",
            riskLevel: .low,
            reason: "test"
        ))
        _ = await executor.execute(StructuredAction(
            type: .pressKey,
            targetKind: "keyboard",
            targetText: "Return",
            text: "return",
            expectedResult: "pressed",
            riskLevel: .low,
            reason: "test"
        ))

        #expect(await controller.typedText == ["hello"])
        #expect(await controller.scrolls == [-3])
        #expect(await controller.keys == ["return"])
    }

    @Test
    func permissionedExtendedDesktopActionsUseComputerController() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)

        _ = await executor.execute(StructuredAction(
            type: .doubleClick,
            targetKind: "point",
            targetText: "File",
            coordinates: [100, 200],
            expectedResult: "opened",
            riskLevel: .low,
            reason: "test"
        ))
        _ = await executor.execute(StructuredAction(
            type: .copy,
            targetKind: "selection",
            targetText: "selected text",
            expectedResult: "copied",
            riskLevel: .medium,
            reason: "test"
        ))
        _ = await executor.execute(StructuredAction(
            type: .paste,
            targetKind: "focused_field",
            targetText: "focused field",
            text: "safe paste",
            expectedResult: "pasted",
            riskLevel: .medium,
            reason: "test"
        ))
        _ = await executor.execute(StructuredAction(
            type: .openURL,
            targetKind: "browser",
            targetText: "https://example.com",
            expectedResult: "opened",
            riskLevel: .medium,
            reason: "test"
        ))
        let terminalResult = await executor.execute(StructuredAction(
            type: .runTerminalCommand,
            targetKind: "terminal",
            targetText: "shell",
            command: "pwd",
            expectedResult: "printed cwd",
            riskLevel: .low,
            reason: "test"
        ))
        _ = await executor.execute(StructuredAction(
            type: .switchApp,
            targetKind: "app",
            targetText: "Finder",
            expectedResult: "Finder activated",
            riskLevel: .low,
            reason: "test"
        ))

        #expect(await controller.doubleClicks == [CGPoint(x: 100, y: 200)])
        #expect(await controller.copyCount == 1)
        #expect(await controller.pastedText == ["safe paste"])
        #expect(await controller.openedURLs == ["https://example.com"])
        #expect(await controller.terminalCommands == ["pwd"])
        #expect(terminalResult == "Terminal command completed: spy output")
        #expect(await controller.switchedApps == ["Finder"])
    }

    @Test
    func permissionedExtendedActionsValidateRequiredFields() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)

        let doubleClickResult = await executor.execute(StructuredAction(
            type: .doubleClick,
            targetKind: "point",
            targetText: "File",
            expectedResult: "opened",
            riskLevel: .low,
            reason: "test"
        ))
        let pasteResult = await executor.execute(StructuredAction(
            type: .paste,
            targetKind: "focused_field",
            targetText: "focused field",
            expectedResult: "pasted",
            riskLevel: .medium,
            reason: "test"
        ))
        let terminalResult = await executor.execute(StructuredAction(
            type: .runTerminalCommand,
            targetKind: "terminal",
            targetText: "shell",
            expectedResult: "ran",
            riskLevel: .low,
            reason: "test"
        ))

        #expect(doubleClickResult.contains("coordinates are missing"))
        #expect(pasteResult.contains("text is missing"))
        #expect(terminalResult.contains("command is missing"))
        #expect(await controller.doubleClicks.isEmpty)
        #expect(await controller.pastedText.isEmpty)
        #expect(await controller.terminalCommands.isEmpty)
    }

    @Test
    func pausedExecutorBlocksOSControl() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)

        await executor.setPaused(true)
        let result = await executor.execute(StructuredAction(
            type: .click, targetKind: "point", targetText: "Search",
            coordinates: [10, 20], expectedResult: "clicked", riskLevel: .low, reason: "test"
        ))

        #expect(result == "Executor paused.")
        #expect(await controller.clicks.isEmpty)
    }

    @Test
    func stoppedExecutorBlocksOSControl() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)

        await executor.stopImmediately()
        let result = await executor.execute(StructuredAction(
            type: .click, targetKind: "point", targetText: "Search",
            coordinates: [10, 20], expectedResult: "clicked", riskLevel: .low, reason: "test"
        ))

        #expect(result == "Executor disabled.")
        #expect(await controller.clicks.isEmpty)
    }

    @Test
    func pauseThenUnpauseRestoresExecution() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)

        await executor.setPaused(true)
        let paused = await executor.execute(StructuredAction(
            type: .click, targetKind: "point", targetText: "Search",
            coordinates: [10, 20], expectedResult: "clicked", riskLevel: .low, reason: "test"
        ))
        #expect(paused == "Executor paused.")

        await executor.setPaused(false)
        let resumed = await executor.execute(StructuredAction(
            type: .click, targetKind: "point", targetText: "Search",
            coordinates: [10, 20], expectedResult: "clicked", riskLevel: .low, reason: "test"
        ))
        #expect(resumed == "Clicked Search at 10,20.")
        #expect(await controller.clicks == [CGPoint(x: 10, y: 20)])
    }

    @Test
    func emptyKeyPressIsBlocked() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)

        let result = await executor.execute(StructuredAction(
            type: .pressKey,
            targetKind: "keyboard",
            targetText: "   ",
            text: nil,
            expectedResult: "pressed",
            riskLevel: .low,
            reason: "test"
        ))

        #expect(result.contains("key name is missing"))
        #expect(await controller.keys.isEmpty)
    }

    @Test
    func clickWithTargetElementIDResolvesToElementCenter() async {
        let observer = StubScreenObserver(observation: ScreenObservation(
            activeApp: "Notes",
            activeWindow: "Untitled",
            screenshotWidth: 100,
            screenshotHeight: 100,
            screenshotPNGBase64: "abc",
            accessibilitySummary: nil,
            elements: [
                AXElementSnapshot(id: 0, role: "Button", label: "Save", centerX: 150, centerY: 250, width: 80, height: 30)
            ]
        ))
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(
            screenObserver: observer,
            computerController: controller,
            dryRun: false
        )
        let action = StructuredAction(
            type: .click,
            targetKind: "element",
            targetText: "Save",
            targetElementID: 0,
            expectedResult: "clicked",
            riskLevel: .low,
            reason: "test"
        )

        let result = await executor.execute(action)

        #expect(result == "Clicked Save at 150,250.")
        #expect(await controller.clicks == [CGPoint(x: 150, y: 250)])
    }

    @Test
    func clickWithUnknownTargetElementIDIsBlocked() async {
        let observer = StubScreenObserver(observation: ScreenObservation(
            activeApp: "Notes",
            activeWindow: "Untitled",
            screenshotWidth: 100,
            screenshotHeight: 100,
            screenshotPNGBase64: "abc",
            accessibilitySummary: nil,
            elements: []
        ))
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(
            screenObserver: observer,
            computerController: controller,
            dryRun: false
        )
        let action = StructuredAction(
            type: .click,
            targetKind: "element",
            targetText: "Save",
            targetElementID: 7,
            expectedResult: "clicked",
            riskLevel: .low,
            reason: "test"
        )

        let result = await executor.execute(action)

        #expect(result.contains("element 7 not found or stale"))
        #expect(await controller.clicks.isEmpty)
    }

    @Test
    func typeTextSafeWithTargetElementIDFocusesThenTypes() async {
        let observer = StubScreenObserver(observation: ScreenObservation(
            activeApp: "Notes",
            activeWindow: "Untitled",
            screenshotWidth: 100,
            screenshotHeight: 100,
            screenshotPNGBase64: "abc",
            accessibilitySummary: nil,
            elements: [
                AXElementSnapshot(id: 2, role: "TextField", label: "Search", centerX: 60, centerY: 90, width: 200, height: 24)
            ]
        ))
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(
            screenObserver: observer,
            computerController: controller,
            dryRun: false
        )
        let action = StructuredAction(
            type: .typeTextSafe,
            targetKind: "element",
            targetText: "Search",
            targetElementID: 2,
            text: "hello",
            expectedResult: "typed",
            riskLevel: .low,
            reason: "test"
        )

        let result = await executor.execute(action)

        #expect(result == "Typed safe text into Search at 60,90.")
        #expect(await controller.clicks == [CGPoint(x: 60, y: 90)])
        #expect(await controller.typedText == ["hello"])
        #expect(await controller.keys == ["cmd+a"])
    }

    @Test
    func dryRunClickWithTargetElementIDDoesNotObserveOrClick() async {
        let observer = StubScreenObserver(observation: ScreenObservation(
            activeApp: "Notes",
            activeWindow: "Untitled",
            screenshotWidth: 100,
            screenshotHeight: 100,
            screenshotPNGBase64: "abc",
            accessibilitySummary: nil,
            elements: [
                AXElementSnapshot(id: 0, role: "Button", label: "Save", centerX: 10, centerY: 20, width: 4, height: 4)
            ]
        ))
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(
            screenObserver: observer,
            computerController: controller,
            dryRun: true
        )
        let action = StructuredAction(
            type: .click,
            targetKind: "element",
            targetText: "Save",
            targetElementID: 0,
            expectedResult: "clicked",
            riskLevel: .low,
            reason: "test"
        )

        let result = await executor.execute(action)

        #expect(result.contains("Dry-run only"))
        #expect(observer.captureCount == 0)
        #expect(await controller.clicks.isEmpty)
    }

    @Test
    func nonFiniteAndNegativeCoordinatesAreRejected() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)

        let negative = await executor.execute(StructuredAction(
            type: .click, targetKind: "point", targetText: "Search",
            coordinates: [-1, 50], expectedResult: "clicked", riskLevel: .low, reason: "test"
        ))
        let nan = await executor.execute(StructuredAction(
            type: .click, targetKind: "point", targetText: "Search",
            coordinates: [.nan, 50], expectedResult: "clicked", riskLevel: .low, reason: "test"
        ))

        #expect(negative.contains("coordinates are missing"))
        #expect(nan.contains("coordinates are missing"))
        #expect(await controller.clicks.isEmpty)
    }
}

@MainActor
struct BrowserActionRoutingTests {
    @Test
    func cannedBrowserCommandsRouteWithoutOpeningChrome() async throws {
        let spy = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: spy, dryRun: false)
        let response = try JSONActionPlanner.parseResponse(#"{"actions":[{"type":"browser_new_tab","url":"https://example.com"},{"type":"browser_navigate","url":"https://example.org"},{"type":"browser_switch_tab","target":"2"},{"type":"browser_close_tab","target":"2"}]}"#)
        for action in response.actions { _ = await executor.execute(action) }
        #expect(await spy.browserCalls == ["browser_new_tab:https://example.com", "browser_navigate:https://example.org", "browser_switch_tab:2", "browser_close_tab:2"])
        await executor.prepareForRun(dryRun: true)
        _ = await executor.execute(response.actions[0])
        #expect(await spy.browserCalls.count == 4)
    }
}
