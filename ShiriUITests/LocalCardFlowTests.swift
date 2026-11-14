import XCTest

extension XCUIApplication {
    func tabButton(_ tab: String) -> XCUIElement {
        // iPadOS can expose a wrapper and its child with the same tab identifier.
        buttons.matching(identifier: tab.hasPrefix("tab_") ? tab : "tab_" + tab).firstMatch
    }
    func scrollForeground(up: Bool = true) {
        let types = [XCUIElement.ElementType.scrollView.rawValue, XCUIElement.ElementType.table.rawValue, XCUIElement.ElementType.collectionView.rawValue] as NSArray
        let visible = descendants(matching: .any).matching(NSPredicate(format: "elementType IN %@", types)).allElementsBoundByIndex.last { $0.isHittable }
        let target: XCUIElement = visible ?? self
        if up { target.swipeUp() } else { target.swipeDown() }
    }
    /// iOS 16 exposes a multiline SwiftUI TextField as a TextView.
    func textInput(_ identifier: String) -> XCUIElement {
        let introduction = staticTexts["Speed up your typing by sliding your finger across the letters to compose a word."]
        if introduction.exists && buttons["Continue"].isHittable { buttons["Continue"].tap() }
        let types = [XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue] as NSArray
        return descendants(matching: .any).matching(NSPredicate(format: "elementType IN %@", types)).matching(identifier: identifier).firstMatch
    }
}

final class AcceptanceCoverageTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment = ["NIANYI_TEST_STORE_ID": UUID().uuidString, "NIANYI_FIXTURE": "warm-paper", "NIANYI_FIXED_NOW": "2026-09-11T19:30:00+08:00"]
        app.launch()
        XCTAssertTrue(app.tabButton("tab_today").waitForExistence(timeout: 30))
        addTeardownBlock { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testIPadLandscapeNavigationAndComposer() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: app)], timeout: 5), .completed)
        for tab in ["today", "cards", "review", "sharing", "settings"] {
            let button = app.tabButton(tab)
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: button)], timeout: 5), .completed)
            button.tap()
            if tab == "review" { XCTAssertTrue(app.buttons["reviewMode_completed"].waitForExistence(timeout: 15)) }
            capture(app, "iPadLandscape-" + tab)
        }
        app.tabButton("tab_today").tap()
        app.buttons["createCard"].tap()
        let input = app.textInput("quickInput")
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("记一下横屏验收的想法")
        app.buttons["parseInput"].tap()
        let save = app.buttons["saveCard"]
        for _ in 0..<8 where !save.isHittable { app.scrollViews["composerScroll"].swipeUp() }
        XCTAssertTrue(save.isHittable); capture(app, "iPadLandscape-Composer"); save.tap()
        XCTAssertTrue(app.tabButton("tab_cards").waitForExistence(timeout: 10)); app.tabButton("tab_cards").tap()
        XCTAssertTrue(app.staticTexts["横屏验收的想法"].waitForExistence(timeout: 5))
    }
}

final class LocalCardFlowTests: XCTestCase {
    func testLocalNoteSurvivesRelaunchAndSearch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["NIANYI_TEST_STORE_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 15))
        app.buttons["createCard"].tap()
        let input = app.textInput("quickInput")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("记一下停车位 B2 C16")
        app.buttons["parseInput"].tap()
        let save = app.buttons["saveCard"]
        for _ in 0..<5 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(app.tabButton("tab_cards").waitForExistence(timeout: 5))
        app.tabButton("tab_cards").tap()
        XCTAssertTrue(app.staticTexts["停车位 B2 C16"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabButton("tab_cards").waitForExistence(timeout: 10)); app.tabButton("tab_cards").tap()
        app.buttons["搜索卡片"].tap()
        let search = app.textFields["cardSearch"]; search.tap(); search.typeText("B2 C16\n")
        XCTAssertTrue(app.staticTexts["停车位 B2 C16"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["停车位 B2 C16"].isHittable)
        let evidence = XCTAttachment(screenshot: app.screenshot()); evidence.name = "保存并重启后的本地记事"; evidence.lifetime = .keepAlways; add(evidence)
    }
}

final class R1FunctionalFlowTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["NIANYI_TEST_STORE_ID"] = UUID().uuidString
        app.launch(); addTeardownBlock { app.terminate() }; return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testChangedInputRequiresReviewAndOnlySavesNewContent() {
        let app = launch()
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 15)); app.buttons["createCard"].tap()
        let input = app.textInput("quickInput")
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("记一下旧停车位 B2")
        app.buttons["parseInput"].tap()
        input.tap(); input.press(forDuration: 1.1)
        let selectAll = app.menuItems["全选"]
        if !selectAll.waitForExistence(timeout: 2) { input.press(forDuration: 1.1) }
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); selectAll.tap()
        input.typeText("记一下新停车位 C3")
        app.buttons["saveCard"].tap()
        XCTAssertTrue(app.staticTexts["已更新识别结果，请校对安排后再次保存"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveCard"].exists); capture(app, "R1_改写输入必须再次校对")
        app.buttons["saveCard"].tap()
        XCTAssertTrue(app.tabButton("tab_cards").waitForExistence(timeout: 5)); app.tabButton("tab_cards").tap()
        XCTAssertTrue(app.staticTexts["新停车位 C3"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["旧停车位 B2"].exists); capture(app, "R1_仅保存校对后的内容")
    }
    func testPermissionCenterCanRequestAlarmAndShowsSystemState() {
        let app = launch()
        XCTAssertTrue(app.tabButton("settings").waitForExistence(timeout: 15)); app.tabButton("settings").tap()
        let permission = app.buttons["权限与提醒状态"]
        for _ in 0..<6 where !permission.isHittable { app.swipeUp() }
        XCTAssertTrue(permission.isHittable); permission.tap()
        app.buttons["允许普通通知"].tap()
        allowSystemPrompt(app)
        let alarm = app.buttons["允许系统闹钟"]
        for _ in 0..<8 where !alarm.isHittable { app.swipeUp() }
        XCTAssertTrue(alarm.isHittable); alarm.tap()
        allowSystemPrompt(app)
        let state = app.staticTexts["alarmAuthorization"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertEqual(state.label, "已就绪")
        capture(app, "R1_首次系统闹钟授权已允许")

    }

    func testNoteOnlyCancelKeepsDraftAndSuggestedTitleNeedsConfirmation() {
        let app = launch()
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 15)); app.buttons["createCard"].tap()
        let note = app.textInput("composerNote")
        for _ in 0..<8 where !note.isHittable { app.scrollViews["composerScroll"].swipeUp() }
        XCTAssertTrue(note.waitForExistence(timeout: 5)); note.tap(); note.typeText("只有备注，也要保留")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["保存为草稿"].waitForExistence(timeout: 5)); app.buttons["保存为草稿"].tap()
        XCTAssertTrue(app.tabButton("settings").waitForExistence(timeout: 5)); app.tabButton("settings").tap(); app.buttons["草稿箱"].tap()
        let savedDraft = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "只有备注，也要保留")).firstMatch
        XCTAssertTrue(savedDraft.waitForExistence(timeout: 5)); savedDraft.tap()
        XCTAssertTrue(app.buttons["saveCard"].waitForExistence(timeout: 5)); app.buttons["saveCard"].tap()
        XCTAssertTrue(app.staticTexts["已建议标题，请确认或修改后再次保存"].waitForExistence(timeout: 5))
        capture(app, "R1_纯备注草稿恢复与标题确认")
        app.buttons["saveCard"].tap()
        XCTAssertTrue(app.tabButton("tab_cards").waitForExistence(timeout: 5)); app.tabButton("tab_cards").tap()
        XCTAssertTrue(app.staticTexts["只有备注，也要保留"].firstMatch.waitForExistence(timeout: 5))
    }
    func testRepeatEditScopeAndCloseKeepCardWithoutCompletingIt() {
        let app = launch()
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 15)); app.buttons["createCard"].tap()
        let input = app.textInput("quickInput"); XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("每天晚上八点读书"); app.buttons["parseInput"].tap()
        app.buttons["saveCard"].tap(); allowSystemPrompt(app)
        XCTAssertTrue(app.tabButton("tab_cards").waitForExistence(timeout: 8)); app.tabButton("tab_cards").tap()
        let title = app.staticTexts["读书"].firstMatch; XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap()
        let edit = app.buttons["detailEdit"]
        for _ in 0..<7 where !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.isHittable); edit.tap()
        XCTAssertTrue(app.buttons["仅本次日期与时间"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["本次及以后"].exists)
        capture(app, "R1_重复修改范围")
        app.buttons["本次及以后"].tap(); XCTAssertTrue(app.buttons["saveCard"].waitForExistence(timeout: 5)); app.buttons["saveCard"].tap()
        let menu = app.buttons["卡片更多操作"]; XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        app.buttons["关闭整个重复规则"].tap(); app.buttons["关闭重复规则"].tap()
        XCTAssertTrue(app.staticTexts["重复已关闭"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["detailComplete"].exists); capture(app, "R1_关闭重复保留卡片")
    }
    private func allowSystemPrompt(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = app.alerts.firstMatch.waitForExistence(timeout: 3) ? app.alerts.firstMatch : springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            let allow = alert.buttons.matching(NSPredicate(format: "label == '允许' OR label == 'Allow'")).firstMatch
            XCTAssertTrue(allow.exists); allow.tap()
        }
    }
}

/// Run explicitly when changing rendering or data flow. All fixtures stay in a UUID store.
final class PerformanceFlowTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func application(largeLibrary: Bool = true, distinctPhotos: Bool = false, standardDataset: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["NIANYI_TEST_STORE_ID"] = UUID().uuidString
        if largeLibrary {
            app.launchEnvironment["NIANYI_FIXTURE"] = "warm-paper"
            app.launchEnvironment["NIANYI_SCENARIO"] = standardDataset ? "performance-standard" : "performance"
            app.launchEnvironment["NIANYI_FIXED_NOW"] = "2026-09-13T02:00:00Z"
            if distinctPhotos { app.launchEnvironment["NIANYI_DISTINCT_PHOTOS"] = "1" }
        }
        app.launch()
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 60))
        if largeLibrary { XCTAssertTrue(app.staticTexts["生活事项 0000"].firstMatch.waitForExistence(timeout: 15)) }
        addTeardownBlock { app.terminate() }
        return app
    }
    private var options: XCTMeasureOptions {
        let value = XCTMeasureOptions(); value.iterationCount = 3; return value
    }
    func testLaunchWithThousandCards() {
        let app = application(); app.terminate()
        let launchOptions = options; launchOptions.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true), XCTClockMetric()], options: launchOptions) {
            app.launch()
            XCTAssertTrue(app.staticTexts["生活事项 0000"].firstMatch.waitForExistence(timeout: 15))
            app.terminate()
        }
    }
    func testPhotoLibraryScrollPerformance() {
        let app = application()
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            let scroll = app.scrollViews["page_cards"]
            for _ in 0..<3 { scroll.swipeUp(velocity: .fast) }
            for _ in 0..<3 { scroll.swipeDown(velocity: .fast) }
        }
        XCTAssertTrue(app.tabButton("tab_review").isHittable)
    }
    func testDocumentedDatasetLaunch() {
        let app = application(standardDataset: true); app.terminate()
        let launchOptions = options; launchOptions.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true), XCTClockMetric()], options: launchOptions) {
            app.launch()
            XCTAssertTrue(app.staticTexts["生活事项 0000"].firstMatch.waitForExistence(timeout: 20))
            app.terminate()
        }
    }
    func testSearchAndClearWithThousandCards() {
        let app = application()
        app.buttons["搜索卡片"].tap()
        let field = app.textFields["cardSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)], options: options) {
            field.tap(); field.typeText("0999")
            XCTAssertTrue(app.staticTexts["生活事项 0999"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["生活事项 0000"].exists)
            app.buttons["关闭搜索"].tap()
            XCTAssertTrue(app.staticTexts["生活事项 0000"].firstMatch.waitForExistence(timeout: 5))
            app.buttons["搜索卡片"].tap()
        }
    }
    func testExpandTodayAndSwitchReviewWithThousandCards() {
        let app = application()
        app.tabButton("tab_today").tap()
        app.buttons["todayUpcomingToggle"].tap()
        app.scrollViews["page_today"].swipeUp(velocity: .fast)
        XCTAssertTrue(app.tabButton("tab_review").isHittable)
        app.tabButton("tab_review").tap()
        XCTAssertTrue(app.buttons["reviewMode_completed"].waitForExistence(timeout: 15))
        app.buttons["reviewPeriod_month"].tap()
        XCTAssertTrue(app.buttons["reviewDateSelector"].isHittable)
        app.buttons["reviewDateSelector"].tap()
        XCTAssertTrue(app.datePickers["reviewDatePicker"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        app.tabButton("tab_cards").tap()
        XCTAssertTrue(app.staticTexts["生活事项 0000"].firstMatch.waitForExistence(timeout: 5))
    }
    func testComposerRepeatedFocusAndTypingRemainsResponsive() {
        let app = application(largeLibrary: false)
        for index in 0..<3 {
            app.buttons["createCard"].tap()
            let input = app.textInput("quickInput")
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap(); input.typeText("记一下响应验证 \(index)")
            XCTAssertTrue(app.buttons["parseInput"].isHittable)
            app.buttons["parseInput"].tap()
            XCTAssertTrue(app.textInput("cardTitle").waitForExistence(timeout: 5))
            app.buttons["取消"].tap()
            app.buttons["放弃编辑"].tap()
            XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 5))
        }
    }
    @available(iOS 26.0, *)
    func testDistinctPhotoScrollingAndHitches() {
        let app = application(distinctPhotos: true)
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            let scroll = app.scrollViews["page_cards"]
            for _ in 0..<4 { scroll.swipeUp(velocity: .fast) }
            for _ in 0..<4 { scroll.swipeDown(velocity: .fast) }
        }
        app.tabButton("tab_settings").tap()
        XCTAssertTrue(app.buttons["权限与提醒状态"].waitForExistence(timeout: 5))
    }
}

@available(iOS 16.4, *)
final class ReminderVoiceFlowTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["NIANYI_TEST_STORE_ID"] = UUID().uuidString
        app.launch(); addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 20)); return app
    }
    func testLaunchAnimationReachesInteractiveHome() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--show-launch-animation", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["NIANYI_TEST_STORE_ID"] = UUID().uuidString
        app.launch(); addTeardownBlock { app.terminate() }
        let home = app.buttons["createCard"]
        XCTAssertTrue(home.waitForExistence(timeout: 15)); XCTAssertTrue(home.isHittable)
        XCTAssertFalse(app.otherElements["launchBrand"].exists)
        capture(app, "07_开屏动画后进入可操作首页")
    }
    private func field(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND (elementType == %d OR elementType == %d)", id, XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)).firstMatch
    }
    private func replace(_ element: XCUIElement, with text: String) {
        element.tap()
        let current = element.value as? String ?? ""
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<7 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func reminders(_ app: XCUIApplication) {
        app.buttons["createCard"].tap()
        let input = field("quickInput", app); XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("明天下午三点提前十分钟提醒我取自定义节点快递")
        app.buttons["parseInput"].tap()
        let reminder = app.buttons["composerReminder"]; reveal(reminder, in: app); reminder.tap()
        XCTAssertTrue(app.buttons["advanceNode_10"].waitForExistence(timeout: 5))
    }
    private func addNode(_ amount: String, unit: String, followUp: Bool = false, app: XCUIApplication) {
        let add = app.buttons[followUp ? "add_followUp" : "add_advance"]; reveal(add, in: app); add.tap()
        let input = app.textFields["nodeAmount"]; XCTAssertTrue(input.waitForExistence(timeout: 5))
        replace(input, with: amount); app.segmentedControls["nodeUnit"].buttons[unit].tap()
        app.buttons["saveReminderNode"].tap()
    }
    func testCustomNodesEditMergeDeleteAndPersistAfterRelaunch() {
        let app = launch(); reminders(app)
        addNode("2", unit: "小时", app: app)
        XCTAssertTrue(app.buttons["advanceNode_120"].waitForExistence(timeout: 5))
        addNode("120", unit: "分钟", app: app)
        XCTAssertEqual(app.buttons.matching(identifier: "advanceNode_120").count, 1)
        app.buttons["advanceNode_120"].tap()
        replace(app.textFields["nodeAmount"], with: "3"); app.buttons["saveReminderNode"].tap()
        XCTAssertTrue(app.buttons["advanceNode_180"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["advanceNode_120"].exists)
        addNode("2", unit: "天", app: app)
        app.buttons["delete_advance_2880"].tap(); XCTAssertFalse(app.buttons["advanceNode_2880"].exists)
        addNode("45", unit: "分钟", followUp: true, app: app)
        XCTAssertTrue(app.buttons["followUpNode_45"].waitForExistence(timeout: 5))
        capture(app, "01_自定义提醒节点编辑合并与删除")
        app.buttons["reminderDone"].tap(); app.buttons["saveCard"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(NSPredicate(format: "label == '允许' OR label == 'Allow'")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 20))
        app.terminate(); app.launch(); app.tabButton("tab_cards").tap()
        let card = app.staticTexts["取自定义节点快递"].firstMatch; XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        let edit = app.buttons["detailEdit"].firstMatch; reveal(edit, in: app); edit.tap()
        let reminder = app.buttons["composerReminder"]; XCTAssertTrue(reminder.waitForExistence(timeout: 5)); reveal(reminder, in: app); reminder.tap()
        XCTAssertTrue(app.buttons["advanceNode_180"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["advanceNode_10"].exists)
        XCTAssertTrue(app.buttons["followUpNode_45"].exists); XCTAssertFalse(app.buttons["advanceNode_2880"].exists)
        capture(app, "02_重启后自定义节点完整保留")
    }
    func testInvalidDurationAndCancelKeepExistingNodes() {
        let app = launch(); reminders(app)
        addNode("366", unit: "天", app: app)
        XCTAssertTrue(app.staticTexts["nodeError"].waitForExistence(timeout: 5))
        app.buttons["cancelReminderNode"].tap()
        XCTAssertTrue(app.buttons["advanceNode_10"].waitForExistence(timeout: 5))
        addNode("25", unit: "小时", followUp: true, app: app)
        XCTAssertTrue(app.staticTexts["nodeError"].waitForExistence(timeout: 5)); capture(app, "03_超范围节点保留输入并提示")
        app.buttons["cancelReminderNode"].tap()
        XCTAssertTrue(app.buttons["advanceNode_10"].exists); XCTAssertFalse(app.buttons["followUpNode_1500"].exists)
    }
    func testVoicePreviewCreatesConciseCardInOneConfirmation() {
        let app = launch()
        app.open(URL(string: "nianyi://compose?input=voice")!)
        let text = field("speechTranscript", app); XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap(); text.typeText("明天下午三点提前十分钟提醒我去菜鸟驿站取语音快递")
        app.buttons["speechKeyboardDone"].tap()
        let title = app.staticTexts["speechPreviewTitle"]; XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertTrue(title.isHittable)
        XCTAssertEqual(title.label, "去菜鸟驿站取语音快递")
        XCTAssertTrue(app.staticTexts["speechPreviewSchedule"].label.contains("15:00"))
        XCTAssertTrue(app.staticTexts["speechPreviewReminders"].label.contains("提前 10 分钟"))
        XCTAssertTrue(app.staticTexts["speechPreviewReminders"].isHittable)
        capture(app, "04_语音自动分离标题时间和提醒节点")
        app.buttons["speechConfirm"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(NSPredicate(format: "label == '允许' OR label == 'Allow'")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 20))
        app.tabButton("tab_cards").tap()
        XCTAssertTrue(app.staticTexts["去菜鸟驿站取语音快递"].firstMatch.waitForExistence(timeout: 8))
        capture(app, "05_语音确认一次后创建卡片")
    }
    func testAmbiguousVoiceContinuesToReviewWithoutSaving() {
        let app = launch(); app.open(URL(string: "nianyi://compose?input=voice")!)
        let text = field("speechTranscript", app); XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap(); text.typeText("明天三点提前十分钟提醒我取待核对快递")
        XCTAssertTrue(app.staticTexts["speechPreviewTitle"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["speechConfirm"].label, "继续核对安排")
        app.buttons["speechConfirm"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["speechConfirm"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed)
        let title = field("cardTitle", app); XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertEqual(title.value as? String, "取待核对快递")
        XCTAssertTrue(app.staticTexts["这个时间是上午还是下午？"].exists)
        capture(app, "06_含糊时间保持未保存并核对")
    }

    func testVoiceRelativeDurationCreatesAnOrdinaryTask() {
        let app = launch(); app.open(URL(string: "nianyi://compose?input=voice")!)
        let text = field("speechTranscript", app); XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap(); text.typeText("请帮我在一个半小时后提醒我关烤箱"); app.buttons["speechKeyboardDone"].tap()
        let title = app.staticTexts["speechPreviewTitle"]; XCTAssertTrue(title.waitForExistence(timeout: 8)); XCTAssertEqual(title.label, "关烤箱")
        XCTAssertTrue(app.staticTexts["speechPreviewSchedule"].exists)
        XCTAssertEqual(app.buttons["speechConfirm"].label, "确认并创建卡片")
        capture(app, "08_相对时长识别为关烤箱")
        app.buttons["speechConfirm"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(NSPredicate(format: "label == '允许' OR label == 'Allow'")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["speechConfirm"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        app.tabButton("tab_cards").tap(); XCTAssertTrue(app.staticTexts["关烤箱"].firstMatch.waitForExistence(timeout: 8))
    }

    func testVoiceRepeatingScheduleIsVisibleAndSaved() {
        let app = launch(); app.open(URL(string: "nianyi://compose?input=voice")!)
        let text = field("speechTranscript", app); XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap(); text.typeText("每周一、周三、周五晚上八点提前十分钟提醒我背单词"); app.buttons["speechKeyboardDone"].tap()
        let rule = app.staticTexts["speechPreviewRepeat"]; XCTAssertTrue(rule.waitForExistence(timeout: 8))
        XCTAssertEqual(rule.label, "每周一、三、五"); XCTAssertEqual(app.staticTexts["speechPreviewTitle"].label, "背单词")
        XCTAssertTrue(app.staticTexts["speechPreviewSchedule"].label.contains("20:00"))
        XCTAssertTrue(app.staticTexts["speechPreviewReminders"].label.contains("提前 10 分钟"))
        capture(app, "09_语音预览完整显示重复规则")
        app.buttons["speechConfirm"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(NSPredicate(format: "label == '允许' OR label == 'Allow'")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["speechConfirm"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        app.terminate(); app.launch(); app.tabButton("tab_cards").tap()
        XCTAssertTrue(app.staticTexts["背单词"].firstMatch.waitForExistence(timeout: 8))
    }

    func testVoiceTimeRangeRequiresExplicitReview() {
        let app = launch(); app.open(URL(string: "nianyi://compose?input=voice")!)
        let text = field("speechTranscript", app); XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap(); text.typeText("明天下午三点到四点在会议室讨论方案"); app.buttons["speechKeyboardDone"].tap()
        XCTAssertTrue(app.staticTexts["speechPreviewTitle"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["speechPreviewTitle"].label, "在会议室讨论方案")
        XCTAssertEqual(app.buttons["speechConfirm"].label, "继续核对安排")
        XCTAssertTrue(app.staticTexts["说了多个时刻或时间范围，请确认提醒时间"].exists)
        capture(app, "10_时间范围不会直接保存")
        app.buttons["speechConfirm"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["speechConfirm"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed)
        XCTAssertTrue(app.buttons["saveCard"].exists); XCTAssertEqual(field("cardTitle", app).value as? String, "在会议室讨论方案")
    }
}

final class MemoryExperienceFlowTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch(fixtures: Bool = false, dark: Bool = false, largeType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment = ["NIANYI_TEST_STORE_ID": UUID().uuidString, "NIANYI_FIXED_NOW": "2026-09-15T02:00:00Z", "NIANYI_PAGE": "review"]
        if fixtures { app.launchEnvironment["NIANYI_FIXTURE"] = "warm-paper"; app.launchEnvironment["NIANYI_SCENARIO"] = "memory-upgrade" }
        if dark { app.launchEnvironment["NIANYI_DARK"] = "1" }
        app.launch(); addTeardownBlock { app.terminate() }; openMemories(app); return app
    }
    private func openMemories(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabButton("tab_review").waitForExistence(timeout: 25)); app.tabButton("tab_review").tap()
        XCTAssertTrue(app.buttons["reviewMode_memories"].waitForExistence(timeout: 10)); app.buttons["reviewMode_memories"].tap()
        XCTAssertTrue(app.buttons["reviewNewMemory"].waitForExistence(timeout: 10))
    }
    private func field(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.textFields[id].exists ? app.textFields[id] : app.textViews[id] }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, down: Bool = false) {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<15 where !element.isHittable { app.scrollForeground(up: !down) }
        XCTAssertTrue(element.isHittable, element.debugDescription)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func memory(_ title: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "memoryCard_", title)).firstMatch
    }
    private func search(_ text: String, _ app: XCUIApplication) {
        let field = app.textFields["memorySearch"]; reveal(field, app, down: true); field.tap(); field.typeText(text + "\n")
    }
    private func visibleDetailTitle(_ app: XCUIApplication) -> String {
        let titles = app.staticTexts.matching(identifier: "memoryDetailTitle").allElementsBoundByIndex
        return (titles.first { $0.isHittable } ?? titles.first)?.label ?? ""
    }
    private func assertSaved(_ title: String, _ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["memorySavedNotice"].waitForExistence(timeout: 10))
        XCTAssertEqual(visibleDetailTitle(app), title)
        XCTAssertTrue(app.buttons["memorySavedDone"].isHittable)
    }
    private func toggle(_ id: String, _ app: XCUIApplication) {
        let element = app.switches[id]; reveal(element, app)
        (element.switches.firstMatch.exists ? element.switches.firstMatch : element).tap()
    }
    func testEmptyMemoryCreatesFromOneSentenceAndSurvivesRelaunch() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["留下第一段回忆"].waitForExistence(timeout: 5)); capture(app, "01_首次使用回忆空态")
        app.buttons["reviewNewMemory"].tap()
        XCTAssertTrue(app.buttons["saveMemory"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["saveMemory"].isEnabled)
        let note = field("memoryNote", app); note.tap(); note.typeText("今天看到了彩虹。想记住这一刻")
        app.buttons["memoryKeyboardDone"].tap(); capture(app, "02_正文优先与持续字段标签")
        app.buttons["saveMemory"].tap(); assertSaved("今天看到了彩虹", app)
        XCTAssertEqual(app.staticTexts["memoryDetailNote"].label, "今天看到了彩虹。想记住这一刻"); capture(app, "03_保存后直接阅读结果")
        app.buttons["memorySavedDone"].tap()
        XCTAssertTrue(memory("今天看到了彩虹", app).waitForExistence(timeout: 8))
        app.terminate(); app.launch(); openMemories(app)
        XCTAssertTrue(memory("今天看到了彩虹", app).waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["resumeMemoryDraft"].exists)
        capture(app, "04_重启后正式回忆保留草稿清除")
    }
    func testNarrativeSpeechDraftSurvivesTerminationAndEditingCanBeDiscarded() {
        let app = launch(); app.buttons["reviewNewMemory"].tap(); app.buttons["memoryDictate"].tap()
        let transcript = field("memorySpeechTranscript", app); XCTAssertTrue(transcript.waitForExistence(timeout: 5)); transcript.tap()
        let story = "去年妈妈喊我吃饭，今天还记得她笑的样子。"
        transcript.typeText(story); app.buttons["memorySpeechKeyboardDone"].tap(); app.buttons["memorySpeechBack"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["memoryPendingSpeech"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveMemory"].isEnabled)
        let status = app.descendants(matching: .any)["memoryDraftStatus"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '草稿已保存在本机'"), object: status)], timeout: 5), .completed)
        app.terminate(); app.launch(); openMemories(app)
        XCTAssertTrue(app.buttons["resumeMemoryDraft"].waitForExistence(timeout: 8)); app.buttons["resumeMemoryDraft"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["memoryDraftRecovered"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["memoryDictate"].tap(); XCTAssertEqual(field("memorySpeechTranscript", app).value as? String, story)
        capture(app, "05_进程重启恢复未确认的叙述语音文字")
        app.buttons["memorySpeechConfirm"].tap(); app.buttons["saveMemory"].tap()
        XCTAssertTrue(app.staticTexts["memorySavedNotice"].waitForExistence(timeout: 8)); XCTAssertEqual(app.staticTexts["memoryDetailNote"].label, story)
        app.buttons["editMemory"].tap()
        let note = field("memoryNote", app); XCTAssertTrue(note.waitForExistence(timeout: 5)); note.tap(); note.typeText("没有保存的补充")
        app.buttons["memoryKeyboardDone"].tap(); app.buttons["cancelMemory"].tap(); app.buttons["放弃编辑"].tap()
        XCTAssertEqual(app.staticTexts["memoryDetailNote"].label, story)
    }
    func testOldDateAndPhotoDraftRecoversAndSaveLocatesItsMonth() {
        let app = launch(fixtures: true)
        XCTAssertEqual(app.staticTexts["memoryResultCount"].label, "共 4 段")
        search("妈妈", app); let old = memory("和妈妈一起吃生日面", app); XCTAssertTrue(old.waitForExistence(timeout: 5)); old.tap()
        app.buttons["editMemory"].tap()
        let note = field("memoryNote", app); XCTAssertTrue(note.waitForExistence(timeout: 5)); note.tap(); note.typeText("今年补记：仍然记得那个味道")
        app.buttons["memoryKeyboardDone"].tap(); app.buttons["cancelMemory"].tap(); app.buttons.matching(identifier: "keepMemoryDraft").firstMatch.tap()
        app.terminate(); app.launch(); openMemories(app); app.buttons["resumeMemoryDraft"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["memoryDraftRecovered"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue((field("memoryNote", app).value as? String)?.contains("今年补记") == true)
        XCTAssertTrue(app.buttons["memoryManagePhotos"].exists)
        XCTAssertTrue(app.datePickers["memoryDate"].label.contains("经历日期") || app.buttons["日期选择器"].exists)
        capture(app, "06_旧日期和照片随编辑草稿恢复")
        app.buttons["saveMemory"].tap(); assertSaved("和妈妈一起吃生日面", app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2025年9月15日'")).firstMatch.exists)
        app.buttons["memorySavedDone"].tap()
        XCTAssertTrue(memory("和妈妈一起吃生日面", app).waitForExistence(timeout: 8)); reveal(app.buttons["memoryDateFilter"], app, down: true)
        XCTAssertTrue(app.buttons["memoryDateFilter"].label.contains("2025年9月")); capture(app, "07_补记保存后定位旧月份")
    }
    func testBookSearchThemesMonthsAndPhotoGallery() {
        let app = launch(fixtures: true); capture(app, "08_默认全部日期内容优先")
        XCTAssertEqual(app.staticTexts["memoryResultCount"].label, "共 4 段")
        XCTAssertTrue(memory("周末的海边", app).isHittable)
        app.buttons["memoryDateFilter"].tap(); app.buttons["选择月份…"].tap(); app.buttons["2025年9月"].tap()
        XCTAssertTrue(memory("和妈妈一起吃生日面", app).waitForExistence(timeout: 5))
        app.buttons["memoryDateFilter"].tap(); app.buttons["全部日期"].tap()
        search("不存在的片刻", app); XCTAssertTrue(app.buttons["memoryResetFilters"].waitForExistence(timeout: 5))
        app.buttons["memoryResetFilters"].tap()
        app.buttons["memoryThemeFilter"].tap(); app.buttons["memoryTheme_旅行"].tap(); search("海边", app)
        let card = memory("周末的海边", app); XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        let third = app.buttons["memoryDetailPhoto_2"]; reveal(third, app); third.tap()
        let count = app.staticTexts["photoGalleryCount"]; XCTAssertTrue(count.waitForExistence(timeout: 5)); XCTAssertTrue(count.label.contains("3"))
        capture(app, "09_从第三张进入整组照片")
        app.buttons["上一张照片"].tap(); XCTAssertTrue(count.label.contains("第 2 张")); app.buttons["上一张照片"].tap()
        XCTAssertFalse(app.buttons["上一张照片"].isEnabled); app.buttons["下一张照片"].tap()
        XCTAssertTrue(count.label.contains("第 2 张"))
        let gallery = app.descendants(matching: .any)["photoGallery"].firstMatch
        gallery.doubleTap(); capture(app, "10_照片双击放大")
        gallery.swipeLeft(); capture(app, "11_放大后移动照片")
        gallery.doubleTap(); app.buttons["关闭"].tap(); XCTAssertTrue(third.isHittable)
    }
    func testReunionTemporarySkipPreservesMemoryAndFollowUpIsIndependent() {
        let app = launch(fixtures: true)
        let reunion = app.buttons["memoryReunion"]; reveal(reunion, app)
        XCTAssertTrue(reunion.label.contains("和妈妈一起吃生日面")); capture(app, "12_重逢理由日期与就地偏好")
        let actions = app.buttons["memoryReunionActions"]; reveal(actions, app); actions.tap(); app.buttons["skipMemoryReunionToday"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT label CONTAINS '和妈妈一起吃生日面'"), object: reunion)], timeout: 5), .completed)
        search("妈妈", app); let card = memory("和妈妈一起吃生日面", app); XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        app.buttons["memoryDetailActions"].tap(); app.buttons["memoryDetailContinue"].tap()
        let note = field("memoryNote", app); XCTAssertTrue(note.waitForExistence(timeout: 5)); note.tap(); note.typeText("今年也一起吃面。新的故事")
        app.buttons["memoryKeyboardDone"].tap(); app.buttons["saveMemory"].tap(); assertSaved("今年也一起吃面", app)
        let previous = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '上一篇' AND label CONTAINS '2025年9月15日'")).firstMatch
        reveal(previous, app); capture(app, "13_后续立即打开并关联上一篇")
        previous.tap(); XCTAssertEqual(visibleDetailTitle(app), "和妈妈一起吃生日面")
        let next = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '后续' AND label CONTAINS '今年也一起吃面'")).firstMatch
        reveal(next, app); next.tap(); XCTAssertEqual(visibleDetailTitle(app), "今年也一起吃面")
    }
    func testPermanentReunionExclusionCanBeRestoredWithoutDeletingMemory() {
        let app = launch(fixtures: true)
        search("妈妈", app); let card = memory("和妈妈一起吃生日面", app); XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        app.buttons["memoryDetailActions"].tap()
        app.descendants(matching: .any).matching(identifier: "memoryAllowsReunion").firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["memoryActions"].tap(); app.buttons["不再推荐的回忆"].tap()
        let excluded = app.buttons["和妈妈一起吃生日面"]; XCTAssertTrue(excluded.waitForExistence(timeout: 5)); excluded.tap()
        XCTAssertTrue(app.buttons["editMemory"].waitForExistence(timeout: 5))
        app.buttons["memoryDetailActions"].tap(); app.descendants(matching: .any).matching(identifier: "memoryAllowsReunion").firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["还没有排除的片刻"].waitForExistence(timeout: 8)); capture(app, "21_不再推荐可恢复且回忆保留")
    }
    func testImageAndBookletExportsKeepDifferentOutputAndPrivateDefaults() {
        let app = launch(fixtures: true); search("六个片刻", app); let card = memory("山间的六个片刻", app); XCTAssertTrue(card.waitForExistence(timeout: 8)); card.tap()
        XCTAssertTrue(app.buttons["editMemory"].isHittable, "Editing must not require scrolling through all six photos")
        app.buttons["memoryDetailActions"].tap(); app.buttons["memoryDetailImageExport"].tap()
        XCTAssertTrue(app.switches["memoryExportNotes"].waitForExistence(timeout: 5)); XCTAssertEqual(app.switches["memoryExportNotes"].value as? String, "0")
        XCTAssertEqual(app.switches["memoryExportPhotos"].value as? String, "0")
        let imageExport = app.buttons["confirmMemoryImageExport"]; reveal(imageExport, app); XCTAssertTrue(imageExport.isEnabled)
        XCTAssertFalse(app.buttons["confirmMemoryExport"].exists); capture(app, "14_单篇图片标题预览与明确产物")
        app.navigationBars["回忆图片预览"].buttons["完成"].tap()
        app.buttons["memoryDetailActions"].tap(); app.buttons["memoryDetailPDFExport"].tap()
        toggle("memoryExportNotes", app); toggle("memoryExportPhotos", app)
        let preview = app.images["memoryExportPreview"]; XCTAssertTrue(preview.waitForExistence(timeout: 15)); reveal(preview, app)
        let pageCount = app.staticTexts["memoryExportPageCount"]; reveal(pageCount, app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (pageCount.label.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) } ?? 0) > 4 }, object: pageCount)], timeout: 15), .completed)
        app.buttons["下一页"].tap(); capture(app, "15_长文六图完整分页预览")
        let export = app.buttons["confirmMemoryExport"]; reveal(export, app); XCTAssertTrue(export.isEnabled); XCTAssertFalse(app.buttons["confirmMemoryImageExport"].exists)
        export.tap(); XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 8) || app.buttons["Copy"].exists || app.buttons["拷贝"].exists)
        capture(app, "16_完整回忆册进入系统分享待用户选择")
    }
    func testSourceEmptyStateCanCreateAndCompletionDoesNotOfferDuplicateEntry() {
        let empty = launch(); empty.buttons["chooseMemories"].tap()
        XCTAssertTrue(empty.buttons["memorySourceCreate"].waitForExistence(timeout: 5)); empty.buttons["memorySourceCreate"].tap()
        XCTAssertTrue(empty.buttons["saveMemory"].waitForExistence(timeout: 5)); empty.terminate()
        let app = launch(fixtures: true); app.tabButton("tab_today").tap()
        let task = app.staticTexts["一起去公园散步"]; XCTAssertTrue(task.waitForExistence(timeout: 8)); task.tap()
        let complete = app.buttons["detailComplete"]; reveal(complete, app); complete.tap()
        let keep = app.buttons.matching(identifier: "completionKeepMemory").firstMatch; reveal(keep, app, down: true)
        XCTAssertFalse(app.buttons["keepCardMemory"].exists); capture(app, "17_完成邀请单一入口")
        keep.tap(); let note = field("memoryNote", app); XCTAssertTrue(note.waitForExistence(timeout: 5)); note.tap(); note.typeText("沿着湖边走了一圈，很开心")
        app.buttons["memoryKeyboardDone"].tap(); app.buttons["saveMemory"].tap(); assertSaved("一起去公园散步", app)
        app.buttons["memorySavedDone"].tap(); XCTAssertTrue(app.buttons["detailComplete"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["detailComplete"].label, "撤销完成"); XCTAssertFalse(app.buttons["completionKeepMemory"].exists)
        XCTAssertEqual(app.buttons["keepCardMemory"].label, "已留下回忆 · 查看")
    }
    func testDarkLargestTextMemoryEntryAndSavedReadingStayReachable() {
        let app = launch(fixtures: true, dark: true, largeType: true); capture(app, "18_最大辅助字号回忆筛选")
        app.buttons["reviewMode_completed"].tap()
        XCTAssertTrue(app.buttons["reviewDateSelector"].waitForExistence(timeout: 5)); capture(app, "18a_最大辅助字号完成回顾日期分行")
        app.buttons["reviewMode_memories"].tap()
        let create = app.buttons["reviewNewMemory"]; XCTAssertTrue(create.isHittable); create.tap()
        let note = field("memoryNote", app); XCTAssertTrue(note.waitForExistence(timeout: 5))
        capture(app, "19_最大辅助字号正文优先")
        XCTAssertGreaterThanOrEqual(note.frame.minX, app.frame.minX + 20); XCTAssertLessThanOrEqual(note.frame.maxX, app.frame.maxX - 20)
        let dictate = app.buttons["memoryDictate"]; XCTAssertGreaterThanOrEqual(dictate.frame.minX, app.frame.minX + 20); XCTAssertLessThanOrEqual(dictate.frame.maxX, app.frame.maxX - 20)
        reveal(note, app); XCTAssertGreaterThanOrEqual(note.frame.minX, app.frame.minX + 20); XCTAssertLessThanOrEqual(note.frame.maxX, app.frame.maxX - 20)
        note.tap(); note.typeText("大字模式也能留下今天")
        app.buttons["memoryKeyboardDone"].tap(); XCTAssertTrue(app.buttons["saveMemory"].isHittable)
        let date = app.buttons["memoryDate"]; reveal(date, app)
        XCTAssertGreaterThanOrEqual(date.frame.minX, app.frame.minX + 20); XCTAssertLessThanOrEqual(date.frame.maxX, app.frame.maxX - 20)
        XCTAssertEqual(date.value as? String, "2026年9月15日"); capture(app, "19b_最大辅助字号完整日期与主题")
        date.tap(); XCTAssertTrue(app.buttons["memoryDateDone"].waitForExistence(timeout: 5))
        app.buttons["9月14日 星期一"].tap(); app.buttons["memoryDateDone"].tap()
        XCTAssertEqual(date.value as? String, "2026年9月14日")
        app.buttons["saveMemory"].tap(); assertSaved("大字模式也能留下今天", app)
        XCTAssertTrue(app.buttons["editMemory"].isHittable); capture(app, "20_最大辅助字号保存和编辑仍可达")
    }
}
