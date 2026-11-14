import XCTest

final class ProductFlowTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch(scenario: String = "product-flow", extra: [String: String] = [:], largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment = ["NIANYI_TEST_STORE_ID": UUID().uuidString, "NIANYI_FIXTURE": "warm-paper", "NIANYI_SCENARIO": scenario, "NIANYI_FIXED_NOW": "2026-09-12T06:00:00Z"]
        app.launchEnvironment.merge(extra) { _, new in new }
        app.launch(); addTeardownBlock { app.terminate() }
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    private func chooseDay(_ day: String, picker: XCUIElement) {
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let item = picker.buttons.matching(NSPredicate(format: "label == %@ OR label CONTAINS %@ OR label CONTAINS %@", day, "9月\(day)日", "9月 \(day)日")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), picker.debugDescription); item.tap()
    }
    func testCalendarKeepsSelectedRepeatThroughCompletionAndReturn() {
        let app = launch()
        XCTAssertTrue(app.buttons["todayDatePicker"].waitForExistence(timeout: 20)); app.buttons["todayDatePicker"].tap()
        chooseDay("20", picker: app.datePickers["todayCalendar"]); capture(app, "01_跨周日历选择")
        app.buttons["todayDateConfirm"].tap()
        XCTAssertTrue(app.buttons["day_20"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["day_12"].exists)
        let title = app.staticTexts["每天读十页书"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap()
        XCTAssertTrue(app.staticTexts["detailPlannedDate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["detailPlannedDate"].label.contains("9月20日"))
        let complete = app.buttons["detailComplete"]; reveal(complete, in: app); complete.tap()
        XCTAssertTrue(app.buttons["detailComplete"].waitForExistence(timeout: 5))
        let undone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '撤销完成'"), object: complete)
        XCTAssertEqual(XCTWaiter.wait(for: [undone], timeout: 8), .completed)
        capture(app, "02_完成选中的那一次")
        app.buttons["〈 卡片"].tap()
        XCTAssertTrue(app.staticTexts["已处理"].waitForExistence(timeout: 8)); capture(app, "03_已处理实例仍可找回")
        app.buttons["todayReturnCurrent"].tap()
        XCTAssertTrue(app.buttons["完成：每天读十页书"].waitForExistence(timeout: 8))
        app.buttons["todayDatePicker"].tap(); chooseDay("25", picker: app.datePickers["todayCalendar"])
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["day_12"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["todayReturnCurrent"].exists)
    }
    func testCustomSnoozeShowsAbsoluteTimeAndKeepsDeadline() {
        let app = launch()
        let title = app.staticTexts["提交旅行材料"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20)); title.tap()
        XCTAssertTrue(app.buttons["detailDeadline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["detailDeadline"].label.contains("9月14日 18:00")); capture(app, "04_安排与完成截止分开展示")
        let menu = app.buttons["snoozeMenu"]; reveal(menu, in: app); menu.tap()
        app.buttons["选择日期与时间…"].tap()
        chooseDay("13", picker: app.datePickers["snoozeDatePicker"])
        capture(app, "05_自定义稍后时间")
        app.buttons["confirmCustomSnooze"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["confirmCustomSnooze"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        let status = app.staticTexts["snoozeStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8)); XCTAssertTrue(status.label.contains("9月13日 15:00"))
        reveal(status, in: app)
        capture(app, "06_稍后结果与原安排保留")
        reveal(menu, in: app); menu.tap(); app.buttons["恢复原提醒时间"].tap()
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 8), .completed)
    }
    func testComposerShowsDeadlineAlongsideOriginalPlan() {
        let app = launch()
        let title = app.staticTexts["提交旅行材料"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20)); title.tap()
        let edit = app.buttons["detailEdit"]; reveal(edit, in: app); edit.tap()
        let deadline = app.buttons["composerDeadline"]
        XCTAssertTrue(deadline.waitForExistence(timeout: 5)); XCTAssertTrue(deadline.label.contains("9月14日 18:00"))
        capture(app, "17_保存前校对安排与独立截止")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["detailPlannedDate"].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["detailPlannedDate"].label.contains("9月12日"))
    }
    func testRecoveryPointPreviewCancellationAndRestore() {
        let app = launch()
        XCTAssertTrue(app.tabButton("tab_settings").waitForExistence(timeout: 20)); app.tabButton("tab_settings").tap(); app.buttons["备份与恢复"].tap()
        let point = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recoveryPoint_'")).firstMatch
        XCTAssertTrue(point.waitForExistence(timeout: 5)); capture(app, "07_恢复前备份可找回"); point.tap()
        let preview = app.staticTexts["backupConflictPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5)); XCTAssertTrue(preview.label.contains("重合 5 张"))
        let replace = app.buttons["replaceMatchingBackup"]; reveal(replace, in: app); replace.tap()
        XCTAssertTrue(app.buttons["confirmBackupRestore"].waitForExistence(timeout: 5)); capture(app, "08_替换数量与二次确认")
        app.buttons["取消"].tap(); XCTAssertTrue(replace.waitForExistence(timeout: 5))
        replace.tap(); app.buttons["confirmBackupRestore"].firstMatch.tap()
        let status = app.staticTexts["backupStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10)); XCTAssertTrue(status.label.contains("已恢复 5 张"))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recoveryPoint_'")).count, 2)
        app.tabButton("tab_cards").tap()
        XCTAssertTrue(app.staticTexts["替换前保留的内容"].waitForExistence(timeout: 5)); XCTAssertFalse(app.staticTexts["替换后的内容"].exists)
        capture(app, "09_找回覆盖前的内容")
    }
    func testRestoreCardExplainsFutureAndPastWithoutImmediateOptIn() {
        let app = launch()
        XCTAssertTrue(app.tabButton("tab_settings").waitForExistence(timeout: 20)); app.tabButton("tab_settings").tap(); app.buttons["已归档"].tap()
        XCTAssertTrue(app.buttons["恢复卡片"].waitForExistence(timeout: 5)); app.buttons["恢复卡片"].tap()
        XCTAssertTrue(app.staticTexts["restoreNextPlan"].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["restoreNextPlan"].label.contains("13"))
        capture(app, "10_恢复前确认下次计划与权限")
        let restore = app.buttons["confirmRestoreWithoutReminders"]; reveal(restore, in: app); restore.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: restore)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts["还没有归档卡片"].waitForExistence(timeout: 8))
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["最近删除"].tap(); app.buttons["恢复卡片"].tap()
        XCTAssertTrue(app.staticTexts["restoreNextPlan"].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["restoreNextPlan"].label.contains("不补发过去"))
        capture(app, "11_过去的提醒不补发")
        app.buttons["取消"].tap(); XCTAssertTrue(app.buttons["恢复卡片"].waitForExistence(timeout: 5))
    }
    func testStartupFailureCanExportDiagnosticsAndRetrySameData() {
        let app = launch(extra: ["NIANYI_FAIL_STARTUP_ONCE": "1"])
        XCTAssertTrue(app.buttons["startupRetry"].waitForExistence(timeout: 20)); capture(app, "12_打开失败仍有恢复入口")
        app.buttons["startupDiagnostics"].tap(); app.buttons["生成诊断摘要"].tap()
        XCTAssertTrue(app.buttons["导出这份摘要"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '提交旅行材料'")).firstMatch.exists)
        capture(app, "13_脱敏诊断可导出")
        app.navigationBars.buttons["完成"].tap(); app.buttons["startupRetry"].tap()
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["提交旅行材料"].exists); capture(app, "14_同进程重试保留原卡片")
    }
    func testCalendarAndRecoveryEmptyStateInDarkLargestText() {
        let app = launch(scenario: "empty", extra: ["NIANYI_DARK": "1"], largeText: true)
        XCTAssertTrue(app.buttons["todayDatePicker"].waitForExistence(timeout: 20)); app.buttons["todayDatePicker"].tap()
        XCTAssertTrue(app.datePickers["todayCalendar"].waitForExistence(timeout: 5)); capture(app, "15_深色大字体日期选择")
        app.buttons["取消"].tap(); app.tabButton("tab_settings").tap()
        let backup = app.buttons["备份与恢复"]; reveal(backup, in: app); backup.tap()
        let empty = app.staticTexts["recoveryPointsEmpty"]; reveal(empty, in: app); capture(app, "16_恢复点空态")
    }
}

final class LiveActivityFlowTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    func testSavingTimedCardShowsSystemActivityAndCompletingRemovesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment = ["NIANYI_TEST_STORE_ID": UUID().uuidString]
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 20))
        app.buttons["createCard"].tap()
        let input = app.textInput("quickInput").exists ? app.textInput("quickInput") : app.textViews["quickInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("20分钟后提醒我喝一杯温水")
        app.buttons["parseInput"].tap()
        app.buttons["composerReminder"].tap()
        let live = app.switches["liveActivityToggle"]
        for _ in 0..<5 where !live.isHittable { app.swipeUp() }
        XCTAssertTrue(live.waitForExistence(timeout: 5)); XCTAssertEqual(live.value as? String, "1")
        let confirm = XCTAttachment(screenshot: app.screenshot()); confirm.name = "保存前可关闭锁屏与灵动岛"; confirm.lifetime = .keepAlways; add(confirm)
        app.buttons["完成"].tap()
        app.buttons["saveCard"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["允许"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        // The system renders the app's real ActivityKit surface while the app is in the background.
        // Pull Notification Center down to expose the same system Live Activity card used on Lock Screen.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01)).press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.85)))
        let card = springboard.staticTexts["喝一杯温水"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), springboard.debugDescription)
        let activityApproval = springboard.buttons.matching(NSPredicate(format: "label == '允许' OR label == '始终允许'")).firstMatch
        if activityApproval.exists { activityApproval.tap() }
        let cardSettled = expectation(description: "实时活动授权过渡结束")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { cardSettled.fulfill() }
        wait(for: [cardSettled], timeout: 4)
        let lock = XCTAttachment(screenshot: springboard.screenshot()); lock.name = "通知中心展示的系统实时活动"; lock.lifetime = .keepAlways; add(lock)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        // Home icon pixels and the compact Live Activity settle after the system permission transition.
        let settled = expectation(description: "系统桌面渲染完成")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { settled.fulfill() }
        wait(for: [settled], timeout: 6)
        let island = XCTAttachment(screenshot: springboard.screenshot()); island.name = "保存后灵动岛和应用图标"; island.lifetime = .keepAlways; add(island)
        app.activate()
        let detail = app.staticTexts["喝一杯温水"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10), app.debugDescription)
        detail.tap()
        app.buttons["detailComplete"].tap()
        XCUIDevice.shared.press(.home); springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01)).press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.85)))
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        let finished = XCTAttachment(screenshot: springboard.screenshot()); finished.name = "完成后移除系统卡片"; finished.lifetime = .keepAlways; add(finished)
    }

    func testExistingTimedCardCanEnableActivityFromDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment = ["NIANYI_TEST_STORE_ID": UUID().uuidString]
        app.launch(); addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 20)); app.buttons["createCard"].tap()
        let input = app.textInput("quickInput").exists ? app.textInput("quickInput") : app.textViews["quickInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("20分钟后整理桌面")
        app.buttons["parseInput"].tap(); app.buttons["composerReminder"].tap()
        let display = app.switches["liveActivityToggle"]
        for _ in 0..<5 where !display.isHittable { app.swipeUp() }
        XCTAssertEqual(display.value as? String, "1")
        (display.switches.firstMatch.exists ? display.switches.firstMatch : display).tap()
        XCTAssertEqual(display.value as? String, "0")
        app.buttons["完成"].tap(); app.buttons["saveCard"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["允许"].waitForExistence(timeout: 3) { springboard.buttons["允许"].tap() }
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 15))
        app.staticTexts["整理桌面"].firstMatch.tap()
        let status = app.buttons["detailReminderStatus"]
        for _ in 0..<5 where !status.isHittable { app.swipeUp() }
        XCTAssertTrue(status.isHittable); status.tap()
        XCTAssertTrue(app.buttons["showLiveActivityNow"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["actualLiveActivityStatus"].label, "未开启")
        app.buttons["showLiveActivityNow"].tap()
        let registered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已开启'"), object: app.staticTexts["actualLiveActivityStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [registered], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["liveActivitySystemSettings"].exists)
        let evidence = XCTAttachment(screenshot: app.screenshot()); evidence.name = "已有定时卡片立即显示与系统检查入口"; evidence.lifetime = .keepAlways; add(evidence)
        app.buttons["完成"].tap()
        let complete = app.buttons["detailComplete"]
        for _ in 0..<5 where !complete.isHittable { app.swipeUp() }
        complete.tap()
    }
}


final class ReviewInteractionTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(empty: Bool = false, large: Bool = false, calculationDelay: Int = 0) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment = ["NIANYI_TEST_STORE_ID": UUID().uuidString, "NIANYI_FIXED_NOW": "2026-09-11T19:30:00+08:00", "NIANYI_FIXTURE": "warm-paper", "NIANYI_PAGE": "review", "NIANYI_REVIEW_DELAY_MS": String(calculationDelay)]
        if empty { app.launchEnvironment["NIANYI_SCENARIO"] = "empty" }
        if large { app.launchEnvironment["NIANYI_DARK"] = "1" }
        app.launch(); addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.buttons["reviewDateSelector"].waitForExistence(timeout: 20))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "回顾交互_" + name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func loading(in app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["reviewLoading"] }

    private func matchesCount(_ count: Int, in app: XCUIApplication) -> Bool {
        let element = app.descendants(matching: .any)["reviewCount"].firstMatch
        guard element.exists else { return false }
        return element.label == String(count) || element.label == "本期完成了 \(count) 件小事"
    }

    private func waitForCount(_ count: Int, in app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.loading(in: app).exists && self.matchesCount(count, in: app)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed, app.debugDescription)
    }

    private func chooseSeptemberFirst(in app: XCUIApplication) {
        let picker = app.datePickers["reviewDatePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let day = picker.buttons.matching(NSPredicate(format: "label == '1' OR label CONTAINS '9月1日' OR label CONTAINS '9月 1日'")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5), picker.debugDescription)
        day.tap()
    }

    func testPeriodChangesKeepControlsAndPreviousSummaryVisibleDuringCalculation() {
        let app = launch(calculationDelay: 8_000)
        waitForCount(8, in: app)
        let titleFrame = app.buttons["reviewPeriod_week"].frame
        let dateFrame = app.buttons["reviewDateSelector"].frame
        capture(app, "本周完成记录")

        app.buttons["reviewPeriod_month"].tap()
        XCTAssertTrue(loading(in: app).waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["reviewPeriod_week"].frame.minY, titleFrame.minY, accuracy: 1)
        XCTAssertEqual(app.buttons["reviewDateSelector"].frame.minY, dateFrame.minY, accuracy: 1)
        XCTAssertTrue(matchesCount(8, in: app), app.debugDescription)
        for period in ["week", "month", "year"] { XCTAssertTrue(app.buttons["reviewPeriod_" + period].isHittable) }
        capture(app, "仅统计区域更新")

        app.buttons["reviewPeriod_year"].tap()
        app.buttons["reviewPeriod_week"].tap()
        waitForCount(8, in: app)
        XCTAssertTrue(app.buttons["reviewPeriod_week"].isSelected)
        XCTAssertTrue((app.buttons["reviewDateSelector"].value as? String)?.contains("9月7日") == true)
        app.buttons["全部"].tap()
        XCTAssertTrue(app.navigationBars["详细回顾"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["完成"].tap()
        XCTAssertFalse(loading(in: app).exists)
        waitForCount(8, in: app)
        app.tabButton("tab_settings").tap(); app.tabButton("tab_review").tap()
        XCTAssertFalse(loading(in: app).exists)
        waitForCount(8, in: app)
        XCTAssertEqual(app.buttons["reviewPeriod_week"].frame.minY, titleFrame.minY, accuracy: 1)
    }

    func testDatePickerUsesSelectedDayAcrossPeriodsAndReturnsToCurrentWeek() {
        let app = launch()
        waitForCount(8, in: app)
        app.buttons["reviewDateSelector"].tap()
        chooseSeptemberFirst(in: app); capture(app, "原生日历选择日期")
        app.buttons["confirmReviewDate"].tap()
        waitForCount(6, in: app)
        XCTAssertTrue((app.buttons["reviewDateSelector"].value as? String)?.contains("8月31日") == true)
        XCTAssertTrue((app.buttons["reviewDateSelector"].value as? String)?.contains("9月6日") == true)
        capture(app, "所选日期所在周")
        app.buttons["reviewPeriod_month"].tap(); waitForCount(14, in: app)
        app.buttons["reviewPeriod_year"].tap(); waitForCount(14, in: app)
        capture(app, "所选日期所在年")
        app.buttons["reviewPeriod_week"].tap(); waitForCount(6, in: app)
        app.buttons["reviewCurrentPeriod"].tap(); waitForCount(8, in: app)
        XCTAssertFalse(app.buttons["下一个周期"].isEnabled)
        let currentRange = app.buttons["reviewDateSelector"].value as? String
        app.buttons["reviewDateSelector"].tap(); chooseSeptemberFirst(in: app)
        app.navigationBars.buttons["取消"].tap()
        XCTAssertEqual(app.buttons["reviewDateSelector"].value as? String, currentRange)
        waitForCount(8, in: app)
    }

    func testEmptyReviewDateControlsStayReachableInDarkLargestText() {
        let app = launch(empty: true, large: true)
        XCTAssertTrue(app.staticTexts["小进展，会慢慢留下"].waitForExistence(timeout: 15))
        for period in ["week", "month", "year"] { XCTAssertTrue(app.buttons["reviewPeriod_" + period].isHittable) }
        XCTAssertTrue(app.buttons["reviewDateSelector"].isHittable)
        capture(app, "深色大字体空回顾")
        app.buttons["reviewDateSelector"].tap(); chooseSeptemberFirst(in: app)
        capture(app, "深色大字体日历")
        app.buttons["confirmReviewDate"].tap()
        XCTAssertTrue(app.staticTexts["这一周期没有完成记录"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["reviewCurrentPeriod"].isHittable)
        app.buttons["reviewCurrentPeriod"].tap()
        XCTAssertTrue(app.staticTexts["小进展，会慢慢留下"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabButton("tab_review").isHittable)
    }
}

final class LiquidGlassNavigationTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(scenario: String = "empty", dark: Bool = false, large: Bool = false, showsLaunchAnimation: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if showsLaunchAnimation { app.launchArguments.append("--show-launch-animation") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment = ["NIANYI_TEST_STORE_ID": UUID().uuidString, "NIANYI_FIXED_NOW": "2026-09-11T19:30:00+08:00", "NIANYI_FIXTURE": "warm-paper"]
        if scenario != "reference" { app.launchEnvironment["NIANYI_SCENARIO"] = scenario }
        if dark { app.launchEnvironment["NIANYI_DARK"] = "1" }
        app.launch(); addTeardownBlock { app.terminate() }; return app
    }

    private func select(_ tab: String, in app: XCUIApplication) {
        let button = app.tabButton(tab)
        XCTAssertTrue(button.waitForExistence(timeout: 15), tab)
        XCTAssertTrue(button.isHittable, tab); button.tap()
        XCTAssertTrue(button.isSelected, tab)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "液态导航_" + name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testFiveNativeTabsAndEmptyPagesWithoutBrandHeader() {
        let app = launch(showsLaunchAnimation: true)
        for (tab, title) in [("today", "从一件小事开始"), ("cards", "第一张卡片，留给生活"), ("review", "这一页，等你留下一个片刻"), ("sharing", "把一件小事，分享给对方")] {
            select(tab, in: app)
            for destination in ["today", "cards", "review", "sharing", "settings"] { XCTAssertTrue(app.tabButton(destination).exists) }
            XCTAssertTrue(app.tabButton(tab).isSelected)
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["拾日"].exists)
            capture(app, "空态_" + tab)
        }
        select("settings", in: app)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["草稿箱"].isHittable)
        XCTAssertFalse(app.staticTexts["拾日"].exists)
        XCTAssertFalse(app.navigationBars.buttons["完成"].exists)
        capture(app, "空态_settings")
    }

    func testSettingsHistorySearchAndCardReturnRemainUsable() {
        let app = launch(scenario: "reference")
        XCTAssertTrue(app.tabButton("tab_today").waitForExistence(timeout: 15))
        capture(app, "内容_today")
        select("settings", in: app); capture(app, "内容_settings"); app.buttons["草稿箱"].tap()
        XCTAssertTrue(app.navigationBars["草稿箱"].waitForExistence(timeout: 5))
        select("today", in: app); select("settings", in: app)
        XCTAssertTrue(app.navigationBars["草稿箱"].exists)
        app.navigationBars.buttons["设置"].tap()
        app.buttons["备份与恢复"].tap()
        XCTAssertTrue(app.navigationBars["备份与恢复"].waitForExistence(timeout: 5))
        capture(app, "设置子页保留导航")
        select("cards", in: app)
        capture(app, "内容_cards")
        app.buttons["搜索卡片"].tap()
        app.textFields["cardSearch"].typeText("没有这张卡片\n")
        XCTAssertTrue(app.staticTexts["没有找到这件事"].waitForExistence(timeout: 5))
        capture(app, "搜索无结果")
        app.buttons["关闭搜索"].tap()
        let card = app.staticTexts["去花店取花"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        XCTAssertTrue(app.buttons["detailComplete"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        capture(app, "详情隐藏导航")
        app.buttons["〈 卡片"].tap()
        XCTAssertTrue(app.tabButton("tab_cards").waitForExistence(timeout: 5))
        select("review", in: app); capture(app, "详情返回后切换回顾")
        select("sharing", in: app); capture(app, "内容_sharing")
    }

    func testDarkAndLargestTextKeepAllFiveTabsReachable() {
        for large in [false, true] {
            let app = launch(scenario: "empty", dark: true, large: large)
            for tab in ["today", "cards", "review", "sharing", "settings"] {
                select(tab, in: app)
                XCTAssertFalse(app.staticTexts["拾日"].exists)
                for destination in ["today", "cards", "review", "sharing", "settings"] {
                    XCTAssertTrue(app.tabButton(destination).isHittable)
                }
                capture(app, (large ? "深色最大字体_" : "深色_") + tab)
            }
            app.terminate()
        }
    }
}


final class StateCoverageScreensTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch(_ scenario: String, page: String = "today", dark: Bool = false, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment = ["NIANYI_TEST_STORE_ID": UUID().uuidString, "NIANYI_FIXED_NOW": "2026-09-11T19:30:00+08:00", "NIANYI_FIXTURE": "warm-paper", "NIANYI_PAGE": page]
        if scenario != "reference" { app.launchEnvironment["NIANYI_SCENARIO"] = scenario }
        if dark { app.launchEnvironment["NIANYI_DARK"] = "1" }
        app.launch(); return app
    }
    private func empty(_ app: XCUIApplication, _ title: String) {
        let element = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "emptyStateTitle", title)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        XCTAssertEqual(element.label, title)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "状态_" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    func testEmptyMainPagesAndCreationFromSharing() {
        let app = launch("empty")
        empty(app, "从一件小事开始"); capture(app, "01_首次打开今天")
        XCTAssertTrue(app.buttons["createCard"].isHittable)
        app.tabButton("tab_cards").tap(); empty(app, "第一张卡片，留给生活"); capture(app, "02_空卡片库")
        app.tabButton("tab_review").tap(); empty(app, "小进展，会慢慢留下"); capture(app, "03_空回顾")
        app.tabButton("tab_sharing").tap(); empty(app, "把一件小事，分享给对方"); capture(app, "04_尚未分享")
        app.buttons["我收到的"].tap(); empty(app, "还没收到新的日程"); capture(app, "05_尚未收到")
        XCTAssertTrue(app.buttons["打开日程文件"].isHittable)
        app.buttons["分享一张日程卡"].tap(); empty(app, "先留下一张卡片"); capture(app, "06_没有可分享卡片")
        app.buttons["emptyStateAction"].tap()
        XCTAssertTrue(app.textInput("quickInput").waitForExistence(timeout: 10)); XCTAssertTrue(app.buttons["saveCard"].isHittable)
        capture(app, "07_从分享空态进入创建"); app.terminate()
    }
    func testCompletedAndQuietDaysHaveDistinctStates() {
        let app = launch("completed")
        empty(app, "今天的安排都完成了"); capture(app, "08_全部完成")
        app.buttons["emptyStateAction"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reviewCount"].firstMatch.waitForExistence(timeout: 10)); XCTAssertEqual(app.descendants(matching: .any)["reviewCount"].firstMatch.label, "本期完成了 1 件小事")
        app.buttons["上一个周期"].tap(); empty(app, "这一周期没有完成记录"); capture(app, "09_历史周期无记录")
        app.buttons["emptyStateAction"].tap(); XCTAssertTrue(app.descendants(matching: .any)["reviewCount"].firstMatch.waitForExistence(timeout: 10)); XCTAssertEqual(app.descendants(matching: .any)["reviewCount"].firstMatch.label, "本期完成了 1 件小事")
        app.terminate()
        let notes = launch("notes")
        empty(notes, "暂时没有定时安排"); capture(notes, "10_仅随手记无定时安排")
        notes.tabButton("tab_review").tap()
        XCTAssertTrue(notes.buttons["reviewNote"].waitForExistence(timeout: 10))
        XCTAssertFalse(notes.descendants(matching: .any)["reviewCount"].exists, "随手记不能计入待办完成数")
        notes.buttons["reviewNote"].tap()
        XCTAssertTrue(notes.staticTexts["今天读到的一句话"].waitForExistence(timeout: 5))
        capture(notes, "11_回顾仅有随手记"); notes.terminate()
        let dated = launch("reference")
        XCTAssertTrue(dated.buttons["day_13"].waitForExistence(timeout: 15)); dated.buttons["day_13"].tap()
        empty(dated, "这一天没有安排"); capture(dated, "12_选中日期无安排")
        dated.buttons["emptyStateAction"].tap(); XCTAssertTrue(dated.staticTexts["给妈妈打个电话"].waitForExistence(timeout: 10)); dated.terminate()
    }
    func testSearchAndFiltersRecoverWithoutLosingCards() {
        let app = launch("reference", page: "cards")
        XCTAssertTrue(app.buttons["搜索卡片"].waitForExistence(timeout: 15)); app.buttons["搜索卡片"].tap()
        app.textFields["cardSearch"].typeText("没有这张卡片验收\n")
        empty(app, "没有找到这件事"); capture(app, "13_搜索无结果")
        app.buttons["emptyStateAction"].tap(); XCTAssertTrue(app.staticTexts["去花店取花"].waitForExistence(timeout: 10))
        app.buttons["libraryFilter"].tap(); app.buttons["已归档"].tap()
        empty(app, "还没有归档卡片"); capture(app, "14_归档筛选无结果")
        app.buttons["emptyStateAction"].tap(); XCTAssertTrue(app.staticTexts["去花店取花"].waitForExistence(timeout: 10)); app.terminate()
        let notes = launch("notes", page: "cards")
        XCTAssertTrue(notes.buttons["待办"].waitForExistence(timeout: 15)); notes.buttons["待办"].tap()
        empty(notes, "还没有待办"); capture(notes, "15_待办分类为空")
        notes.buttons["emptyStateAction"].tap(); XCTAssertTrue(notes.staticTexts["今天读到的一句话"].waitForExistence(timeout: 10))
        notes.buttons["libraryFilter"].tap(); notes.buttons["已完成"].tap(); empty(notes, "还没有完成的卡片"); capture(notes, "16_完成筛选为空"); notes.terminate()
    }
    func testSecondaryEmptyScreens() {
        let app = launch("empty")
        XCTAssertTrue(app.tabButton("settings").waitForExistence(timeout: 15)); app.tabButton("settings").tap()
        for (name,title,shot) in [("草稿箱","念头可以慢慢写","17_空草稿箱"),("已归档","还没有归档卡片","18_空归档"),("最近删除","最近没有删除卡片","19_空最近删除")] {
            app.buttons[name].tap(); empty(app, title); capture(app, shot)
            app.navigationBars.buttons["设置"].tap()
        }
        app.terminate()
        let media = launch("notes", page: "media")
        empty(media, "给这件事添一张图片"); reveal(media, media.buttons["从相册选择"]); capture(media, "20_尚未添加图片"); media.terminate()
    }
    func testMixedContentAndAnniversary() {
        let app = launch("mixed", page: "cards")
        XCTAssertTrue(app.staticTexts["今天读到的一句话"].waitForExistence(timeout: 15)); capture(app, "21_普通计划与随手记素材")
        let plain = app.staticTexts["没有配图，也能把一句长长的话完整留下，让文字有足够舒展的空间"]
        app.buttons["搜索卡片"].tap(); app.textFields["cardSearch"].typeText("没有配图\n")
        XCTAssertTrue(plain.waitForExistence(timeout: 10)); capture(app, "22_无插画完整文字")
        app.buttons["关闭搜索"].tap()
        let long = app.staticTexts["读完这本书以后，把喜欢的段落整理出来，写一封信寄给很久没有见面的朋友"]
        reveal(app, long); capture(app, "23_长文本卡片")
        let selected = app.staticTexts["保留我选的小银杏"]; reveal(app, selected); capture(app, "24_保留自选插画")
        let photo = app.staticTexts["用自己的图片留住这一刻"]; reveal(app, photo); capture(app, "25_图片背景与深色纸张"); app.terminate()
        let detail = launch("mixed", page: "detail")
        XCTAssertTrue(detail.buttons["detailComplete"].waitForExistence(timeout: 15)); capture(detail, "26_长文本详情"); detail.terminate()
        let birthday = launch("mixed", page: "birthday")
        XCTAssertTrue(birthday.textFields["birthdayName"].waitForExistence(timeout: 15)); XCTAssertTrue(birthday.staticTexts["纪念日期"].exists)
        capture(birthday, "27_纪念日素材"); birthday.terminate()
    }
    func testSharingPreparedWaitingStoppedAndRevoked() {
        let app = launch("sharing-states", page: "sharing")
        XCTAssertTrue(app.staticTexts["已生成日程文件"].waitForExistence(timeout: 15)); reveal(app, app.staticTexts["等待对方确认"])
        capture(app, "28_文件分享与等待反馈")
        reveal(app, app.staticTexts["邀请已撤销"]); XCTAssertTrue(app.staticTexts["反馈已停止"].exists)
        capture(app, "29_停止反馈与撤销邀请"); app.terminate()
    }
    func testMissingCardAndInvalidFileAreRecoverable() {
        let app = launch("unavailable", page: "detail")
        empty(app, "卡片已不存在"); capture(app, "30_卡片不存在")
        app.buttons["emptyStateAction"].tap(); XCTAssertTrue(app.tabButton("tab_cards").waitForExistence(timeout: 10)); app.terminate()
        let invalid = launch("invalid-file")
        XCTAssertTrue(invalid.otherElements["errorBanner"].exists || invalid.staticTexts["errorBanner"].waitForExistence(timeout: 15))
        capture(invalid, "31_文件读取失败")
        invalid.buttons["关闭提示"].tap(); XCTAssertTrue(invalid.buttons["createCard"].isHittable); invalid.terminate()
    }
    func testDarkIllustrationsAndLargestTextEmptyStates() {
        for (scenario,page,number) in [("empty","today",32),("completed","today",33),("empty","sharing",34)] {
            let app = launch(scenario, page: page, dark: true)
            XCTAssertTrue(app.staticTexts["emptyStateTitle"].waitForExistence(timeout: 15)); capture(app, "\(number)_深色_\(scenario)_\(page)"); app.terminate()
        }
        for page in ["today","cards","review","sharing"] {
            let app = launch("empty", page: page, dark: true, large: true)
            XCTAssertTrue(app.staticTexts["emptyStateTitle"].waitForExistence(timeout: 15)); capture(app, "最大字体_\(page)_上部")
            app.swipeUp(); capture(app, "最大字体_\(page)_下部")
            XCTAssertTrue(app.tabButton(page).isHittable)
            if page == "today" || page == "cards" { XCTAssertTrue(app.buttons["createCard"].isHittable) }
            if page == "review" { reveal(app, app.buttons["emptyStateAction"]); app.buttons["emptyStateAction"].tap(); XCTAssertTrue(app.tabButton("tab_today").isSelected) }
            app.terminate()
        }
    }
}


final class WarmPaperScreensTests: XCTestCase {
    func launch(page: String, dark: Bool = false, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["NIANYI_TEST_STORE_ID"] = UUID().uuidString
        app.launchEnvironment["NIANYI_FIXED_NOW"] = "2026-09-11T19:30:00+08:00"
        app.launchEnvironment["NIANYI_FIXTURE"] = "warm-paper"
        app.launchEnvironment["NIANYI_PAGE"] = page
        if dark { app.launchEnvironment["NIANYI_DARK"] = "1" }
        if large { app.launchEnvironment["NIANYI_LONG_TEXT"] = "1" }
        app.launch(); return app
    }
    func capture(_ app: XCUIApplication,_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testEightReferenceScreensUseNativeViews() {
        let pages = ["today","composer","cards","detail","birthday","sharing","receive","review"]
        for (index,page) in pages.enumerated() {
            let app = launch(page: page)
            let expected: XCUIElement
            switch page {
            case "composer": expected = app.textInput("quickInput")
            case "detail": expected = app.buttons["detailComplete"]
            case "birthday": expected = app.textFields["birthdayName"]
            case "receive": expected = app.buttons["acceptSchedule"]
            default: expected = app.tabButton(page)
            }
            XCTAssertTrue(expected.waitForExistence(timeout: 15),page)
            if page == "review" { XCTAssertTrue(app.descendants(matching: .any)["reviewCount"].waitForExistence(timeout: 15)) }
            XCTAssertTrue(expected.isHittable, "Primary control must be reachable: " + page)
            if page == "today" { XCTAssertLessThanOrEqual(app.buttons["想找个周末，去海边走走"].frame.maxY, app.buttons["createCard"].frame.minY - 3, "The complete note row must fit above the create button") }
            if page == "composer" { XCTAssertTrue(app.buttons["saveCard"].isHittable); XCTAssertTrue(app.textInput("cardTitle").exists) }
            if page == "birthday" { XCTAssertTrue(app.buttons["saveBirthdayRule"].isHittable) }
            if page == "review" { XCTAssertTrue(app.descendants(matching: .any)["reviewCount"].isHittable, "Completed work is the primary review content") }
            if page == "sharing" { XCTAssertTrue(app.staticTexts["周六去看展"].waitForExistence(timeout: 10)); XCTAssertTrue(app.staticTexts["领取演出票"].isHittable) }
            capture(app,String(format: "%02d_%@_真实原生页面",index+1,page))
            app.terminate()
        }
    }
    func testDarkAndLargestTextStates() {
        for page in ["today","cards","review"] {
            let app = launch(page: page,dark: true,large: true)
            XCTAssertTrue(app.tabButton(page).waitForExistence(timeout: 15))
            if page == "review" { XCTAssertTrue(app.descendants(matching: .any)["reviewCount"].waitForExistence(timeout: 15)) }
            capture(app,"深色_最大字体_\(page)")
            app.swipeUp(); capture(app,"深色_最大字体_\(page)_下半页")
            if page == "review" {
                let note = app.buttons["reviewNote"]
                for _ in 0..<6 where !note.isHittable { app.swipeUp() }
                XCTAssertTrue(note.isHittable, "Review content must remain reachable at the largest text size")
                capture(app,"深色_最大字体_review_随手记")
            }
            XCTAssertTrue(app.tabButton(page).isHittable)
            app.terminate()
        }
    }
    func testBirthdaySavePersistsAfterRelaunch() {
        let app = launch(page: "birthday")
        let name = app.textFields["birthdayName"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.tap(); name.typeText("验收")
        let expectedTitle = (name.value as? String ?? "") + "的生日"
        XCTAssertTrue(expectedTitle.contains("验收"))
        let save = app.buttons["saveBirthdayRule"]
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(app.tabButton("tab_cards").waitForExistence(timeout: 10))
        app.terminate()
        app.launchEnvironment["NIANYI_PAGE"] = "cards"
        app.launch()
        XCTAssertTrue(app.buttons["搜索卡片"].waitForExistence(timeout: 15)); app.buttons["搜索卡片"].tap()
        let search = app.textFields["cardSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("验收")
        XCTAssertTrue(app.staticTexts[expectedTitle].waitForExistence(timeout: 8))
        capture(app, "生日保存后重启搜索")
    }
    func testSecondaryEditorAndShareSelectionRemainReachable() {
        let composer = launch(page: "composer")
        let birthday = composer.buttons["composerKind_occasion"]
        XCTAssertTrue(birthday.waitForExistence(timeout: 15))
        for _ in 0..<3 where !birthday.isHittable { composer.swipeUp() }
        XCTAssertTrue(birthday.isHittable); birthday.tap()
        XCTAssertTrue(composer.textFields["birthdayName"].waitForExistence(timeout: 8))
        composer.terminate()
        let sharing = launch(page: "sharing")
        XCTAssertTrue(sharing.buttons["分享一张日程卡"].waitForExistence(timeout: 15)); sharing.buttons["分享一张日程卡"].tap()
        let card = sharing.buttons["去花店取花"]
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        XCTAssertTrue(sharing.navigationBars["分享日程"].waitForExistence(timeout: 8))
        XCTAssertTrue(sharing.staticTexts["对方安装拾日后，可以确认并加入自己的日程。"].exists)
        capture(sharing, "从分享中心选择日程卡")
    }
    func testAdditionalSettingsFlowsAndPermissionStatus() {
        let app = launch(page: "today")
        XCTAssertTrue(app.tabButton("settings").waitForExistence(timeout: 15)); app.tabButton("settings").tap()
        for label in ["草稿箱","最近删除","备份与恢复","权限与提醒状态","iCloud 与保存范围","数据与隐私说明","数据备份边界与删除"] {
            let link = app.buttons[label]
            for _ in 0..<4 where !link.isHittable { app.swipeUp() }
            XCTAssertTrue(link.isHittable,label); link.tap()
            capture(app,"设置_\(label)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }
    func testUnavailableCloudShowsFailureWithoutLeavingItsPage() {
        let app = launch(page: "today")
        XCTAssertTrue(app.tabButton("tab_settings").waitForExistence(timeout: 15)); app.tabButton("tab_settings").tap()
        let cloud = app.buttons["iCloud 与保存范围"]
        for _ in 0..<4 where !cloud.isHittable { app.swipeUp() }
        cloud.tap(); app.buttons["连接我的 iCloud"].tap()
        let alert = app.alerts["操作提示"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'iCloud'")).firstMatch.exists)
        capture(app, "云连接失败直接在当前页说明原因")
        alert.buttons["知道了"].tap()
        XCTAssertTrue(app.navigationBars["iCloud 与保存范围"].exists)
    }
    func testEditorsPresentActualControlsWithoutRequestingPermissions() {
        for (page, title) in [("place", "地点提醒"), ("appearance", "卡片外观"), ("media", "卡片图片"), ("reminders", "提醒方式"), ("speech", "语音输入")] {
            let app = launch(page: page)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15), page)
            capture(app, "编辑器_" + page)
            app.terminate()
        }
        let app = launch(page: "appearance", dark: true, large: true)
        XCTAssertTrue(app.navigationBars["卡片外观"].waitForExistence(timeout: 15))
        app.swipeUp(); capture(app, "深色_最大字体_外观编辑")
    }
    func testImportedFileCreatesIndependentCardOnlyAfterAcceptance() {
        let app = launch(page: "receive")
        XCTAssertTrue(app.buttons["acceptSchedule"].waitForExistence(timeout: 15))
        app.buttons["acceptSchedule"].tap()
        XCTAssertTrue(app.staticTexts["周六去看展"].waitForExistence(timeout: 8))
        capture(app,"普通日程确认添加后的详情")
    }
    func testCompletionUndoAndArchivePreserveCard() {
        let app = launch(page: "detail")
        let complete = app.buttons["detailComplete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 15))
        for _ in 0..<6 where !complete.isHittable { app.swipeUp() }
        XCTAssertTrue(complete.isHittable); complete.tap()
        let undo = app.buttons.matching(NSPredicate(format: "label CONTAINS %@","撤销完成")).firstMatch
        app.swipeUp()
        for _ in 0..<6 where !undo.isHittable { app.swipeUp() }
        XCTAssertTrue(undo.waitForExistence(timeout: 5)); XCTAssertTrue(undo.isHittable)
        capture(app,"本次已完成")
        undo.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@","标记完成")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["卡片更多操作"].tap(); app.buttons["归档"].tap()
        XCTAssertTrue(app.buttons["恢复卡片"].waitForExistence(timeout: 5)); capture(app,"归档状态")
        let restore = app.buttons["恢复卡片"]
        for _ in 0..<6 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.isHittable); restore.tap()
        XCTAssertTrue(app.buttons["confirmRestoreWithReminders"].waitForExistence(timeout: 5)); app.buttons["confirmRestoreWithReminders"].tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
    }
}

final class CardDensityTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch(page: String = "cards", title: String? = nil, scenario: String? = nil, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment = ["NIANYI_TEST_STORE_ID": UUID().uuidString, "NIANYI_FIXTURE": "warm-paper", "NIANYI_PAGE": page, "NIANYI_FIXED_NOW": "2026-09-11T19:30:00+08:00"]
        if let scenario { app.launchEnvironment["NIANYI_SCENARIO"] = scenario }
        if let title { app.launchEnvironment["NIANYI_CARD_TITLE"] = title }
        if large { app.launchEnvironment["NIANYI_DARK"] = "1" }
        app.launch(); addTeardownBlock { app.terminate() }; return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<9 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    func testReferenceCardsFitMoreContentAndShowTheCompleteNoteOnce() {
        let app = launch()
        let flower = app.staticTexts["去花店取花"].firstMatch
        XCTAssertTrue(flower.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["想找个周末，去海边走走"].firstMatch.isHittable)
        capture(app, "01_列表信息与配图紧凑排布")
        flower.tap()
        XCTAssertTrue(app.otherElements["detailHero"].waitForExistence(timeout: 5))
        let note = app.staticTexts["detailNote"]
        XCTAssertEqual(note.label, "周六，给家里添一点颜色\n取一束白色洋桔梗，回家前记得带上花瓶。")
        XCTAssertTrue(app.buttons["detailComplete"].isHittable)
        XCTAssertLessThan(app.buttons["detailComplete"].frame.maxY, app.frame.height - 20)
        capture(app, "02_详情完整备注与操作同屏")
        app.buttons["detailComplete"].tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '撤销完成'"), object: app.buttons["detailComplete"])
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed)
        XCTAssertTrue(app.staticTexts["已完成这一次"].exists)
        app.buttons["detailComplete"].tap()
    }
    func testShortLongRecurringBirthdayAndPhotoCardsKeepTheirActualDetails() {
        let titles = ["散步", "给未来的自己", "每周整理一次照片", "这次旅行的三个瞬间", "妈妈的生日", "深色纸张上的一句提醒"]
        for (index, title) in titles.enumerated() {
            let app = launch(title: title, scenario: "card-density")
            XCTAssertTrue(app.otherElements["detailHero"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts[title].firstMatch.isHittable)
            if index == 0 { XCTAssertTrue(app.staticTexts["cardContext"].label.contains("已固定")); XCTAssertTrue(app.buttons["detailComplete"].isHittable) }
            if index == 1 { XCTAssertTrue(app.staticTexts["detailNote"].label.contains("都值得被看见")); XCTAssertFalse(app.buttons["detailComplete"].exists) }
            if index == 2 { XCTAssertTrue(app.staticTexts["cardContext"].label.contains("重要")); XCTAssertTrue(app.buttons["detailRecurrence"].label.contains("每周")) }
            if index == 3 { XCTAssertTrue(app.staticTexts["cardContext"].label.contains("3 张图片")); reveal(app.buttons["查看第 1 张图片"], in: app) }
            if index == 4 { XCTAssertFalse(app.buttons["detailComplete"].exists) }
            capture(app, "场景_" + title)
            app.terminate()
        }
        let app = launch(scenario: "card-density")
        XCTAssertTrue(app.staticTexts["散步"].firstMatch.waitForExistence(timeout: 20)); capture(app, "03_分类重要性与重复摘要")
    }
    func testLargestTextKeepsLongTitlesNotesAndActionsReachable() {
        let title = "准备周末的短途旅行，把车票、住处和行李逐一确认，给自己留一点从容出发的时间"
        let app = launch(title: title, scenario: "card-density", large: true)
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 20))
        let hero = app.otherElements["detailHero"]
        XCTAssertLessThanOrEqual(hero.frame.maxX, app.frame.width)
        let back = app.buttons["detailBack"]
        let navigationTitle = app.staticTexts["detailNavigationTitle"]
        XCTAssertTrue(back.isHittable)
        XCTAssertLessThanOrEqual(back.frame.maxY, navigationTitle.frame.minY)
        XCTAssertLessThanOrEqual(navigationTitle.frame.maxY, hero.frame.minY)
        capture(app, "04_深色最大字体完整长标题")
        let note = app.staticTexts["detailNote"]; reveal(note, in: app)
        XCTAssertTrue(note.label.contains("最后检查门窗，轻装出发")); capture(app, "05_长备注连续阅读")
        let complete = app.buttons["detailComplete"]
        reveal(complete, in: app)
        for _ in 0..<3 where complete.frame.maxY > app.frame.height - 24 { app.swipeUp() }
        XCTAssertLessThanOrEqual(complete.frame.maxY, app.frame.height - 24)
        capture(app, "06_大字体操作仍可到达")
    }
}
