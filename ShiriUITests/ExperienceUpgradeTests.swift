import XCTest

final class ExperienceUpgradeTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch(page: String = "cards", title: String? = nil, scenario: String = "experience-upgrade", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment = ["NIANYI_TEST_STORE_ID": UUID().uuidString, "NIANYI_FIXED_NOW": "2026-09-12T06:00:00Z", "NIANYI_FIXTURE": "warm-paper", "NIANYI_SCENARIO": scenario, "NIANYI_PAGE": page]
        if let title { app.launchEnvironment["NIANYI_CARD_TITLE"] = title }
        if large { app.launchEnvironment["NIANYI_DARK"] = "1" }
        app.launch(); addTeardownBlock { app.terminate() }; return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<9 where !element.isHittable { app.scrollForeground() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func field(_ id: String, in app: XCUIApplication) -> XCUIElement { app.textFields[id].exists ? app.textFields[id] : app.textViews[id] }
    private func acknowledge(_ app: XCUIApplication) { if app.alerts.buttons["知道了"].waitForExistence(timeout: 2) { app.alerts.buttons["知道了"].tap() } }
    func testEmptyStateOffersNoteAndImportantDayWithoutCreatingSampleCards() {
        let app = launch(page: "today", scenario: "empty")
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 20))
        reveal(app.buttons["startNote"], in: app); capture(app, "01_空白页三个真实入口")
        app.buttons["startNote"].tap()
        XCTAssertTrue(app.buttons["composerKind_note"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["composerReminder"].exists)
        app.buttons["取消"].tap()
        reveal(app.buttons["startOccasion"], in: app); app.buttons["startOccasion"].tap()
        XCTAssertTrue(app.textFields["birthdayName"].waitForExistence(timeout: 5)); capture(app, "02_重要日子直接进入日期编辑")
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["从一件小事开始"].waitForExistence(timeout: 15))
    }
    func testOccasionPreparationsPersistOnceAndOpenAsIndependentTask() {
        let app = launch(title: "妈妈的生日")
        XCTAssertTrue(app.buttons["occasionPreparations"].waitForExistence(timeout: 20))
        reveal(app.buttons["occasionPreparations"], in: app); capture(app, "03_重要日子的日期倒数与准备入口")
        app.buttons["occasionPreparations"].tap()
        let toggle = app.switches["prepare_gift"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
        let save = app.buttons["savePreparations"]; reveal(save, in: app); XCTAssertTrue(save.isEnabled); XCTAssertTrue(save.label.contains("1 件")); capture(app, "04_确认准备日期后才添加"); save.tap()
        XCTAssertTrue(app.descendants(matching: .any)["preparationSaved"].waitForExistence(timeout: 8))
        for _ in 0..<7 where !app.staticTexts["选一份生日礼物 · 已添加"].isHittable { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["选一份生日礼物 · 已添加"].exists, app.debugDescription)
        app.buttons["完成"].firstMatch.tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["occasionPreparations"].waitForExistence(timeout: 20)); reveal(app.buttons["occasionPreparations"], in: app); app.buttons["occasionPreparations"].tap()
        XCTAssertTrue(app.staticTexts["选一份生日礼物 · 已添加"].waitForExistence(timeout: 5))
        let prepared = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '选一份生日礼物' AND label CONTAINS '点击查看安排'")).firstMatch
        reveal(prepared, in: app); prepared.tap()
        XCTAssertTrue(app.buttons["detailComplete"].waitForExistence(timeout: 8)); reveal(app.buttons["detailComplete"], in: app)
        capture(app, "05_准备事项是可独立完成的待办")
    }
    func testAllReviewNotesCanBecomeMemoriesAndExportOnlySelectedContent() {
        let app = launch(page: "review")
        let all = app.buttons["reviewAllNotes"]; XCTAssertTrue(all.waitForExistence(timeout: 20)); reveal(all, in: app); all.tap()
        XCTAssertTrue(app.staticTexts["周末公园里的晚霞"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["晚饭后的一句话"].exists); capture(app, "06_回顾保留全部随手记")
        app.buttons["完成"].tap()
        app.buttons["reviewMode_memories"].tap(); app.buttons["memoryActions"].tap()
        app.buttons["chooseMemories"].firstMatch.tap()
        let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'memorySource_' AND label CONTAINS '周末公园里的晚霞'")).firstMatch
        reveal(candidate, in: app); candidate.tap()
        XCTAssertTrue(app.buttons["saveMemory"].waitForExistence(timeout: 5)); app.buttons["saveMemory"].tap()
        XCTAssertTrue(app.staticTexts["memorySavedNotice"].waitForExistence(timeout: 8)); app.buttons["memorySavedDone"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '查看已有回忆'"), object: candidate)], timeout: 8), .completed)
        candidate.tap(); XCTAssertTrue(app.buttons["editMemory"].waitForExistence(timeout: 5)); capture(app, "07_已保存来源直接阅读已有回忆")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars["从记录留成回忆"].buttons["完成"].tap()
        app.buttons["memoryActions"].tap(); app.buttons["exportMemoryBook"].tap()
        XCTAssertTrue(app.switches["memoryExportNotes"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["memoryExportNotes"].value as? String, "0")
        XCTAssertEqual(app.switches["memoryExportPhotos"].value as? String, "0")
        reveal(app.buttons["confirmMemoryExport"], in: app); capture(app, "08_导出前核对摘要和隐私范围")
        app.buttons["confirmMemoryExport"].tap()
        XCTAssertTrue(app.buttons["拷贝"].waitForExistence(timeout: 10) || app.otherElements["ActivityListView"].exists, app.debugDescription)
        capture(app, "09_已生成PDF待用户分享")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["reviewMode_memories"].waitForExistence(timeout: 20)); app.buttons["reviewMode_memories"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'memoryCard_' AND label CONTAINS '周末公园里的晚霞'")).firstMatch.waitForExistence(timeout: 8))
    }
    func testPaidDownloadExportsLetterWithoutAdditionalPurchase() {
        verifyIncludedExportStyle("时光信笺")
    }
    func testPaidDownloadExportsPhotoStoryWithoutAdditionalPurchase() {
        verifyIncludedExportStyle("照片故事", includesPhoto: true)
    }
    private func verifyIncludedExportStyle(_ title: String, includesPhoto: Bool = false) {
        let app = launch(page: "review")
        XCTAssertTrue(app.buttons["reviewMode_memories"].waitForExistence(timeout: 20)); app.buttons["reviewMode_memories"].tap()
        app.buttons["memoryActions"].tap(); app.buttons["chooseMemories"].firstMatch.tap()
        let cardTitle = includesPhoto ? "这次旅行的三个瞬间" : "周末公园里的晚霞"
        let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'memorySource_' AND label CONTAINS %@", cardTitle)).firstMatch
        reveal(candidate, in: app); candidate.tap()
        let save = app.buttons["saveMemory"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["memorySavedNotice"].waitForExistence(timeout: 8)); app.buttons["memorySavedDone"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '查看已有回忆'"), object: candidate)], timeout: 8), .completed)
        app.navigationBars["从记录留成回忆"].buttons["完成"].tap()
        app.buttons["memoryActions"].tap(); app.buttons["exportMemoryBook"].tap()
        let style = app.buttons["memoryExportStyle"]
        reveal(style, in: app); style.tap(); app.buttons[title].tap()
        XCTAssertTrue(style.label.contains(title) || (style.value as? String)?.contains(title) == true)
        XCTAssertEqual(app.switches["memoryExportNotes"].value as? String, "0")
        XCTAssertEqual(app.switches["memoryExportPhotos"].value as? String, "0")
        if includesPhoto {
            let photos = app.switches["memoryExportPhotos"]
            reveal(photos, in: app); (photos.switches.firstMatch.exists ? photos.switches.firstMatch : photos).tap()
            let pageCount = app.staticTexts["memoryExportPageCount"]
            let includesAllPhotos = NSPredicate { _, _ in
                (pageCount.label.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) } ?? 0) >= 4
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: includesAllPhotos, object: pageCount)], timeout: 15), .completed)
        }
        XCTAssertTrue(app.images["memoryExportPreview"].waitForExistence(timeout: 15))
        reveal(app.buttons["confirmMemoryExport"], in: app); capture(app, title + "_无额外购买的摘要预览")
        app.buttons["confirmMemoryExport"].tap()
        XCTAssertTrue(app.buttons["拷贝"].waitForExistence(timeout: 10) || app.buttons["Copy"].exists || app.otherElements["ActivityListView"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["restorePurchase"].exists)
        capture(app, title + "_完整PDF已进入系统分享")
    }
    func testPaidDownloadSettingsHasNoUpgradeOrRestore() {
        let app = launch(page: "today", scenario: "empty")
        XCTAssertTrue(app.tabButton("tab_settings").waitForExistence(timeout: 20)); app.tabButton("tab_settings").tap()
        let info = app.staticTexts["paidDownloadInfo"]
        reveal(info, in: app)
        XCTAssertEqual(info.label, "App Store 一次付费下载，全部功能可用，无应用内购买。")
        XCTAssertFalse(app.buttons["拾日 Pro · 买断升级"].exists)
        XCTAssertFalse(app.buttons["restorePurchase"].exists)
        capture(app, "付费下载_设置无需再次购买")
    }
    func testScreenshotRecognitionRequiresConfirmationAndPreservesOriginalImage() {
        let app = launch(page: "screenshot")
        XCTAssertTrue(app.buttons["recognizeExistingImage"].waitForExistence(timeout: 20))
        app.navigationBars["截图变卡片"].buttons["取消"].tap()
        XCTAssertTrue(app.buttons["composerReminder"].waitForExistence(timeout: 5)); app.buttons["composerReminder"].tap()
        let display = app.switches["liveActivityToggle"]
        reveal(display, in: app)
        if display.value as? String == "0" { (display.switches.firstMatch.exists ? display.switches.firstMatch : display).tap() }
        XCTAssertEqual(display.value as? String, "1")
        app.buttons["完成"].tap()
        app.buttons["screenshotImport"].tap()
        XCTAssertTrue(app.buttons["recognizeExistingImage"].waitForExistence(timeout: 5)); app.buttons["recognizeExistingImage"].tap()
        app.buttons["第 1 张图片"].tap()
        let text = field("recognizedText", in: app)
        let recognized = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '去看展'"), object: text)
        XCTAssertEqual(XCTWaiter.wait(for: [recognized], timeout: 25), .completed)
        XCTAssertFalse(app.buttons["useRecognizedText"].isEnabled); capture(app, "10_设备端识别与原图核对")
        reveal(app.switches["confirmRecognizedText"], in: app); app.switches["confirmRecognizedText"].tap()
        reveal(app.buttons["useRecognizedText"], in: app); app.buttons["useRecognizedText"].tap()
        XCTAssertTrue(field("cardTitle", in: app).waitForExistence(timeout: 5)); XCTAssertTrue((field("cardTitle", in: app).value as? String ?? "").contains("去看展"))
        reveal(app.buttons["composerReminder"], in: app); app.buttons["composerReminder"].tap()
        reveal(display, in: app); XCTAssertEqual(display.value as? String, "1", "截图识别不能清除已开启的锁屏显示")
        capture(app, "截图识别保留锁屏实时活动选项")
        app.buttons["完成"].tap()
        let questions = app.switches["我已逐项检查以上提示与下面的安排"]
        if questions.exists { reveal(questions, in: app); questions.tap() }
        capture(app, "11_识别后仍需确认卡片安排")
        app.buttons["saveCard"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["允许"].waitForExistence(timeout: 3) { springboard.buttons["允许"].tap() }
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 15)); acknowledge(app)
        app.terminate(); app.launchEnvironment["NIANYI_PAGE"] = "cards"; app.launch()
        XCTAssertTrue(app.staticTexts["去看展"].waitForExistence(timeout: 20)); app.staticTexts["去看展"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["detailNote"].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["detailNote"].label.contains("城市美术馆"))
        reveal(app.buttons["查看第 1 张图片"], in: app); XCTAssertFalse(app.buttons["查看第 2 张图片"].exists)
        capture(app, "12_原文日期与图片重开后保留")
    }
    func testNoteDetailAndAppearanceRemainUsableAtLargestText() {
        let app = launch(title: "给未来的自己", large: true)
        XCTAssertTrue(app.buttons["detailEdit"].waitForExistence(timeout: 20)); XCTAssertFalse(app.buttons["detailRecurrence"].exists); XCTAssertFalse(app.buttons["detailReminderStatus"].exists)
        reveal(app.buttons["detailEdit"], in: app); app.buttons["detailEdit"].tap()
        let more = app.buttons["更多设置"]; reveal(more, in: app); more.tap()
        let appearance = app.buttons["composerAppearance"]; reveal(appearance, in: app); appearance.tap()
        let swatch = app.buttons["appearanceTheme_sage"]
        XCTAssertTrue(swatch.waitForExistence(timeout: 5)); XCTAssertTrue(swatch.isHittable, app.debugDescription); capture(app, "13_深色最大字体优先保留外观操作")
        swatch.tap(); app.buttons["完成"].firstMatch.tap(); app.buttons["saveCard"].tap()
        XCTAssertTrue(app.buttons["detailEdit"].waitForExistence(timeout: 8)); reveal(app.buttons["detailEdit"], in: app); capture(app, "14_随手记使用对应动作与完整内容")
    }
    func testNewMemoryCanCancelWithoutLosingTextAndSavesWithOccasionLink() {
        let app = launch(title: "妈妈的生日")
        XCTAssertTrue(app.buttons["occasionNewMemory"].waitForExistence(timeout: 20)); reveal(app.buttons["occasionNewMemory"], in: app); app.buttons["occasionNewMemory"].tap()
        let title = field("memoryTitle", in: app); XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("一起吃生日面")
        app.buttons["取消"].tap(); XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5)); app.buttons["继续编辑"].tap()
        XCTAssertEqual(title.value as? String, "一起吃生日面")
        reveal(app.buttons["saveMemory"], in: app); app.buttons["saveMemory"].tap()
        XCTAssertTrue(app.buttons["occasionMemories"].waitForExistence(timeout: 8)); acknowledge(app); reveal(app.buttons["occasionMemories"], in: app); app.buttons["occasionMemories"].tap()
        XCTAssertTrue(app.staticTexts["一起吃生日面"].waitForExistence(timeout: 8)); capture(app, "15_重要日子的回忆独立保存")
    }
    func testLargestComposerKeepsTypesAndSaveReachableWithKeyboard() {
        let app = launch(title: "给未来的自己", large: true)
        XCTAssertTrue(app.buttons["detailEdit"].waitForExistence(timeout: 20)); reveal(app.buttons["detailEdit"], in: app); app.buttons["detailEdit"].tap()
        XCTAssertTrue(app.buttons["composerKind_note"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["composerKind_note"].frame.minY, app.buttons["composerKind_task"].frame.maxY)
        let title = field("cardTitle", in: app); reveal(title, in: app); title.tap(); title.typeText("的夏天")
        XCTAssertTrue(app.buttons["saveCard"].isHittable, app.debugDescription)
        XCTAssertFalse(app.staticTexts["paperNavigationTitle"].frame.intersects(app.buttons["取消"].frame), "The title and close control must not overlap at the largest font size")
        capture(app, "16_最大字体输入时保留保存入口")
        app.buttons["saveCard"].tap()
        XCTAssertTrue(app.buttons["detailEdit"].waitForExistence(timeout: 10))
    }

    func testTodayGroupsSeveralArrangementsAndDefaultCategoryDoesNotAddNoise() {
        let app = launch(page: "today")
        XCTAssertTrue(app.buttons["todayUpcomingToggle"].waitForExistence(timeout: 20))
        app.buttons["todayUpcomingToggle"].tap()
        XCTAssertTrue(app.staticTexts["今天的安排"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["之后的安排"], in: app)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "identifier == 'cardContext' AND label == '生活'")).firstMatch.exists)
        capture(app, "17_多条安排分组与有效元信息")
    }

}

@available(iOS 16.4, *)
final class WidgetVoiceEntryTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch(large: Bool = false, resetMicrophone: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["NIANYI_TEST_STORE_ID"] = UUID().uuidString
        if resetMicrophone { app.resetAuthorizationStatus(for: .microphone) }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 30)); return app
    }
    private func field(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND (elementType == %d OR elementType == %d)", id, XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)).firstMatch
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func permitNotifications() {
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = board.buttons.matching(NSPredicate(format: "label == '允许' OR label == 'Allow'")).firstMatch
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }
    func testColdVoiceEntryConfirmsTextAndScheduleBeforeSaving() {
        let app = launch(); app.terminate()
        app.open(URL(string: "nianyi://compose?input=voice")!)
        XCTAssertTrue(app.buttons["speechRecord"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["speechConfirm"].isEnabled)
        capture(app, "01_组件入口进入语音待办")
        let text = field("speechTranscript", app); text.tap(); text.typeText("明天下午三点提醒我取语音入口快递")
        app.buttons["speechKeyboardDone"].tap()
        let title = app.staticTexts["speechPreviewTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 8)); XCTAssertEqual(title.label, "取语音入口快递")
        XCTAssertTrue(app.staticTexts["speechPreviewSchedule"].label.contains("15:00"))
        capture(app, "02_保存前核对语音文字和安排")
        XCTAssertTrue(app.buttons["speechConfirm"].isHittable); app.buttons["speechConfirm"].tap(); permitNotifications()
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 15))
        app.terminate(); app.launch()
        app.tabButton("tab_cards").tap()
        XCTAssertTrue(app.staticTexts["取语音入口快递"].firstMatch.waitForExistence(timeout: 15))
        capture(app, "03_语音确认生成真实待办并保留")
    }
    func testVoiceRequestWhileEditingPreservesInputAndCancelDoesNotCreateCard() {
        let app = launch()
        app.buttons["createCard"].tap()
        let input = field("quickInput", app); XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("还在编辑的旅行安排")
        XCUIDevice.shared.system.open(URL(string: "nianyi://compose?input=voice")!)
        XCTAssertTrue(app.otherElements["pendingComposerNotice"].waitForExistence(timeout: 5) || app.staticTexts["先保存或关闭当前卡片，随后打开语音待办。"].exists)
        XCTAssertEqual(input.value as? String, "还在编辑的旅行安排")
        capture(app, "04_组件新增保留当前未保存输入")
        app.buttons["取消"].firstMatch.tap(); app.buttons["放弃编辑"].tap()
        XCTAssertTrue(app.buttons["speechCancel"].waitForExistence(timeout: 8)); app.buttons["speechCancel"].tap()
        XCTAssertTrue(app.buttons["saveCard"].waitForExistence(timeout: 5))
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 8))
        app.tabButton("tab_cards").tap()
        XCTAssertFalse(app.staticTexts["还在编辑的旅行安排"].exists)
    }
    func testLargestVoiceInputKeepsConfirmationAboveKeyboardAndRejectsWhitespace() {
        let app = launch(large: true)
        app.open(URL(string: "nianyi://compose?input=voice")!)
        let text = field("speechTranscript", app); XCTAssertTrue(text.waitForExistence(timeout: 10)); text.tap(); text.typeText("   ")
        XCTAssertFalse(app.buttons["speechConfirm"].isEnabled)
        text.typeText("明天买一束花")
        XCTAssertTrue(app.buttons["speechConfirm"].isHittable)
        XCTAssertTrue(app.buttons["speechRecord"].isHittable)
        capture(app, "05_最大字体与键盘下仍可确认")
        app.buttons["speechCancel"].tap(); app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 8))
    }
    func testDeniedMicrophoneHasKeyboardFallbackAndNeverStartsRecording() {
        let app = launch(resetMicrophone: true)
        app.open(URL(string: "nianyi://compose?input=voice")!)
        XCTAssertTrue(app.buttons["speechRecord"].waitForExistence(timeout: 10)); app.buttons["speechRecord"].tap()
        let deny = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(NSPredicate(format: "label == '不允许' OR label == \"Don't Allow\"")).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 8)); deny.tap()
        XCTAssertTrue(app.staticTexts["麦克风权限未开启，你仍可以直接输入文字。"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["speechRecording"].exists)
        app.buttons["speechUseKeyboard"].tap()
        field("speechTranscript", app).typeText("明天买生日礼物")
        XCTAssertTrue(app.staticTexts["speechPreviewTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["speechConfirm"].isEnabled)
        capture(app, "08_麦克风拒绝后可继续文字输入")
        app.buttons["speechConfirm"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["speechConfirm"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed)
        XCTAssertTrue(field("cardTitle", app).waitForExistence(timeout: 8))
        XCTAssertEqual(field("cardTitle", app).value as? String, "买生日礼物")
        app.buttons["取消"].firstMatch.tap(); app.buttons["放弃编辑"].tap()
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 8))
    }
    func testLegacyLockScreenVoiceButtonOpensANewTaskWithoutCompletingExistingReminder() throws {
        if #available(iOS 18.0, *) {
            throw XCTSkip("iOS 18+ uses AudioRecordingIntent without foreground navigation; recording and Lock Screen authorization require device acceptance.")
        }
        let app = launch()
        app.buttons["createCard"].tap()
        let input = field("quickInput", app); XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("20分钟后提醒我检查锁屏语音入口")
        app.buttons["parseInput"].tap(); app.buttons["saveCard"].tap(); permitNotifications()
        XCTAssertTrue(app.buttons["createCard"].waitForExistence(timeout: 20))
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        board.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01)).press(forDuration: 0.1, thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.85)))
        let existing = board.staticTexts["检查锁屏语音入口"].firstMatch
        XCTAssertTrue(existing.waitForExistence(timeout: 10), board.debugDescription)
        let allow = board.buttons.matching(NSPredicate(format: "label == '允许' OR label == '始终允许' OR label == 'Always Allow'")).firstMatch
        if allow.exists { allow.tap() }
        let microphone = board.buttons["语音新建待办"].firstMatch
        XCTAssertTrue(microphone.waitForExistence(timeout: 10), board.debugDescription)
        capture(board, "06_系统锁屏提醒卡片的语音入口")
        microphone.tap()
        XCTAssertTrue(app.buttons["speechRecord"].waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "07_锁屏按钮实际打开语音待办")
        app.buttons["speechCancel"].tap(); app.buttons["取消"].firstMatch.tap()
        app.tabButton("tab_cards").tap()
        XCTAssertTrue(app.staticTexts["检查锁屏语音入口"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["检查锁屏语音入口"].firstMatch.tap()
        XCTAssertTrue(app.buttons["detailComplete"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["detailComplete"].label.contains("撤销"))
    }
}

final class FiveIssuesTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch(page: String, title: String? = nil, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment = ["NIANYI_TEST_STORE_ID": UUID().uuidString, "NIANYI_FIXED_NOW": "2026-09-15T02:00:00Z", "NIANYI_FIXTURE": "warm-paper", "NIANYI_SCENARIO": "five-issues", "NIANYI_PAGE": page]
        if let title { app.launchEnvironment["NIANYI_CARD_TITLE"] = title }
        app.launch(); addTeardownBlock { app.terminate() }; return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<7 where !element.isHittable { app.scrollForeground() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    func testMainTitlesAreRemovedAndSettingsRetainsItsTitle() {
        let app = launch(page: "today")
        XCTAssertTrue(app.buttons["todayDatePicker"].waitForExistence(timeout: 20))
        for (tab, title) in [("today", "今天"), ("cards", "卡片"), ("review", "回顾"), ("sharing", "分享")] {
            app.tabButton("tab_" + tab).tap()
            let page = app.scrollViews["page_" + tab]
            XCTAssertTrue(page.waitForExistence(timeout: 5))
            XCTAssertFalse(page.staticTexts[title].exists, title)
            capture(app, "无顶部大标题_" + tab)
        }
        app.tabButton("tab_cards").tap()
        app.buttons["搜索卡片"].tap()
        XCTAssertTrue(app.textFields["cardSearch"].waitForExistence(timeout: 5))
        app.buttons["关闭搜索"].tap()
        app.tabButton("tab_settings").tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        capture(app, "保留设置页标题")
    }
    func testDateStripSupportsSlowDraggingAndCancelsShortDrags() {
        let app = launch(page: "today")
        let strip = app.scrollViews["todayWeekStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 20))
        let middle = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        middle.press(forDuration: 0.2, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.55)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.staticTexts["今天待办取快递"].exists)
        for _ in 0..<2 {
            strip.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55)).press(forDuration: 0.2,
                thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.55)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(app.buttons["todayDatePicker"].label.contains("9月29日"), app.debugDescription)
        capture(app, "日期可跟手拖动到两周后")
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.55)).press(forDuration: 0.2,
            thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.staticTexts["下周二去公园"].waitForExistence(timeout: 8))
        app.buttons["todayReturnCurrent"].tap()
        XCTAssertTrue(app.staticTexts["今天待办取快递"].waitForExistence(timeout: 8))
        app.buttons["day_16"].tap()
        XCTAssertTrue(app.buttons["todayDatePicker"].label.contains("9月16日"))
    }
    func testLargestDateStripCanDragAcrossWeeks() {
        let app = launch(page: "today", large: true)
        let strip = app.scrollViews["todayWeekStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 20)); XCTAssertTrue(strip.isHittable)
        for _ in 0..<3 {
            strip.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.55)).press(forDuration: 0.2,
                thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.55)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(app.buttons["todayDatePicker"].label.contains("9月24日"), app.debugDescription)
        XCTAssertTrue(app.buttons["todayPreviousWeek"].isHittable)
        XCTAssertTrue(app.buttons["day_24"].isHittable)
        capture(app, "最大字号仍可拖动浏览日期")
    }
    func testPendingCardsStayBeforeRecentlyCompletedPinnedCards() {
        let app = launch(page: "cards")
        let waiting = app.staticTexts["今天待办取快递"], done = app.staticTexts["今天已完成并固定"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 20)); reveal(done, app: app)
        XCTAssertLessThan(waiting.frame.minY, done.frame.minY)
        capture(app, "01_未完成排在已完成固定卡片前")
    }
    func testWeekSwipeAndButtonsBrowseOtherWeeksAndReturnToday() {
        let app = launch(page: "today")
        let next = app.buttons["todayNextWeek"], previous = app.buttons["todayPreviousWeek"]
        XCTAssertTrue(next.waitForExistence(timeout: 20)); next.tap()
        XCTAssertTrue(app.staticTexts["下周二去公园"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["今天待办取快递"].exists)
        capture(app, "02_跨周查看对应日期的待办")
        let strip = app.descendants(matching: .any)["todayWeekStrip"].firstMatch
        strip.swipeRight()
        XCTAssertTrue(app.staticTexts["今天待办取快递"].waitForExistence(timeout: 8))
        previous.tap()
        XCTAssertTrue(app.staticTexts["上周二去书店"].waitForExistence(timeout: 8))
        app.buttons["todayReturnCurrent"].tap()
        XCTAssertTrue(app.staticTexts["今天待办取快递"].waitForExistence(timeout: 8))
        let done = app.staticTexts["今天已完成并固定"]; reveal(done, app: app)
        XCTAssertLessThan(app.staticTexts["今天待办取快递"].frame.minY, done.frame.minY)
        capture(app, "03_今天的已处理事项单独放在下面")
    }
    func testCommonEditsShareOnePageAndPersist() {
        let app = launch(page: "cards", title: "今天待办取快递")
        let edit = app.buttons["detailEdit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20)); reveal(edit, app: app); edit.tap()
        let title = app.textInput("cardTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        capture(app, "04_常用编辑集中在一个页面")
        title.tap()
        title.press(forDuration: 1.2)
        let selectAll = app.menuItems["全选"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3)); selectAll.tap()
        title.typeText("去菜鸟驿站取快递")
        app.scrollForeground()
        XCTAssertTrue(app.datePickers["quickScheduleDate"].exists)
        XCTAssertTrue(app.switches["quickTimeEnabled"].exists)
        XCTAssertTrue(app.switches["quickReminderEnabled"].exists)
        let note = app.textInput("composerNote"); reveal(note, app: app); note.tap(); note.typeText("带上取件码")
        app.scrollForeground()
        capture(app, "04_标题日程提醒备注集中编辑")
        app.buttons["saveCard"].tap()
        XCTAssertTrue(app.staticTexts["去菜鸟驿站取快递"].waitForExistence(timeout: 8))
        app.terminate(); app.launchEnvironment.removeValue(forKey: "NIANYI_CARD_TITLE"); app.launch()
        XCTAssertTrue(app.staticTexts["去菜鸟驿站取快递"].waitForExistence(timeout: 20))
        app.staticTexts["去菜鸟驿站取快递"].tap()
        XCTAssertTrue(app.staticTexts["带上取件码"].waitForExistence(timeout: 8))
    }
    func testReviewOpensOnCompletedWorkAndExpandedStatistics() {
        let app = launch(page: "review")
        let count = app.descendants(matching: .any)["reviewCount"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 20)); XCTAssertEqual(count.value as? String, "1")
        XCTAssertTrue(app.descendants(matching: .any)["reviewKeyMetrics"].exists)
        let done = app.staticTexts["今天已完成并固定"]
        XCTAssertTrue(done.exists)
        XCTAssertFalse(app.staticTexts["今天待办取快递"].exists)
        XCTAssertTrue(done.isHittable)
        capture(app, "05_回顾默认展开统计并突出完成记录")
    }
}
