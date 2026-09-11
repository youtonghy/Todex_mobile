import UIKit
import XCTest

nonisolated final class TodexUITests: XCTestCase {
    @MainActor private func application() -> XCUIApplication {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        for key in ["TODEX_TEST_PORT", "TODEX_TEST_TOKEN"] {
            if let value = ProcessInfo.processInfo.environment[key] { app.launchEnvironment[key] = value }
        }
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        return app
    }

    @MainActor func testAddedBackendSurvivesRelaunch() throws {
        continueAfterFailure = false
        // No fixture environment: the real on-disk connection catalog is under test.
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.navigationBars["TodeX"].waitForExistence(timeout: 10))
        app.buttons["连接与设置"].tap()
        let add = app.cells["settings.backend.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let field = app.alerts.textFields["settings.backend.serverURL.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("http://127.0.0.1:1")
        app.alerts.buttons["保存"].tap()
        app.buttons["settings.done"].tap()
        app.terminate()
        app.launch()
        app.buttons["连接与设置"].tap()
        let row = app.cells.containing(.staticText, identifier: "新后端").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "添加的后端在重启后丢失")
        row.tap()
        app.cells["settings.backend.delete"].tap()
        app.alerts.buttons["继续"].tap()
        app.buttons["settings.done"].tap()
    }
    @MainActor func testEmptyLaunchAndSettings() throws {
        continueAfterFailure = false
        let app = application()
        app.launch()
        XCTAssertTrue(app.navigationBars["TodeX"].waitForExistence(timeout: 10))
        app.buttons["连接与设置"].tap()
        XCTAssertTrue(app.staticTexts["后端连接"].waitForExistence(timeout: 5))
    }

    @MainActor func testConversationApprovalDraftAndAdaptiveLayout() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["TODEX_TEST_PORT"] != nil else {
            throw XCTSkip("Requires the explicitly configured isolated Rust backend fixture")
        }
        let app = application()
        app.launch()
        let newConversation = app.buttons["新建"]
        XCTAssertTrue(newConversation.waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Isolated Fixture")).firstMatch
                .waitForExistence(timeout: 30))
        newConversation.tap()
        app.buttons["新建对话"].tap()
        app.sheets["选择工作区"].buttons["Isolated Fixture"].tap()
        let codex = app.sheets["选择 Agent"].buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Codex"))
            .firstMatch
        XCTAssertTrue(codex.waitForExistence(timeout: 5))
        codex.tap()
        let input = app.textViews["chat.composer"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("fixture:permission mobile-ui")
        let send = app.buttons["chat.send"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 20)
        send.tap()
        let permission = app.buttons["chat.permission"]
        XCTAssertTrue(permission.waitForExistence(timeout: 25))
        permission.tap()
        XCTAssertTrue(app.scrollViews["permission.form"].waitForExistence(timeout: 5))
        let approvalImage = XCTAttachment(screenshot: app.screenshot())
        approvalImage.name = "Native approval"
        approvalImage.lifetime = .keepAlways
        add(approvalImage)
        let allow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "permission.option.", "允许")
        ).firstMatch
        if !allow.isHittable { app.scrollViews["permission.form"].swipeUp() }
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 2) {
            app.alerts.buttons["确认"].tap()
        }
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let completed = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fixture Codex"))
            .firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 25))
        input.tap()
        input.typeText("保留这条未发送草稿")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let conversation = app.tables.cells.containing(.staticText, identifier: "新对话").firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "保留这条未发送草稿")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            let landscape = expectation(
                for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
            wait(for: [landscape], timeout: 8)
            XCTAssertTrue(app.buttons["新标签"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["新标签"].isHittable)
            XCTAssertTrue(input.isHittable)
        } else {
            app.segmentedControls["conversation.panes"].buttons["操作台"].tap()
            XCTAssertTrue(app.buttons["新标签"].waitForExistence(timeout: 5))
            app.segmentedControls["conversation.panes"].buttons["对话"].tap()
            XCTAssertTrue(input.exists)
        }
        // Let the rotation compositor settle before capturing a shareable image.
        let settled = expectation(description: "Rotation animation completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Conversation adaptive layout"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCUIDevice.shared.orientation = .portrait
        let restored = expectation(description: "Restore portrait for the next test")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { restored.fulfill() }
        wait(for: [restored], timeout: 3)
        app.terminate()
    }

    @MainActor func testDarkAppearanceAndLargeText() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["TODEX_TEST_PORT"] != nil else {
            throw XCTSkip("Requires the explicitly configured isolated Rust backend fixture")
        }
        let app = application()
        app.launchArguments += [
            "-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Isolated Fixture")).firstMatch
                .waitForExistence(timeout: 30))
        let home = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        home.name = "Dark accessibility home"
        home.lifetime = .keepAlways
        add(home)
        app.buttons["新建"].tap()
        XCTAssertTrue(app.buttons["新建对话"].waitForExistence(timeout: 8))
        app.buttons["新建对话"].tap()
        app.sheets["选择工作区"].buttons["Isolated Fixture"].tap()
        app.sheets["选择 Agent"].buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Codex")).firstMatch.tap()
        let input = app.textViews["chat.composer"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("大字体与键盘")
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(app.buttons["chat.send"].isHittable)
        let dark = XCTAttachment(screenshot: app.screenshot())
        dark.name = "Dark accessibility text and keyboard"
        dark.lifetime = .keepAlways
        add(dark)
        app.terminate()
    }

    @MainActor func testRichTextFileEditingTerminalAndBrowser() throws {
        continueAfterFailure = false
        guard let port = ProcessInfo.processInfo.environment["TODEX_TEST_PORT"] else {
            throw XCTSkip("Requires the explicitly configured isolated Rust backend fixture")
        }
        let app = application()
        app.launch()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Isolated Fixture")).firstMatch
                .waitForExistence(timeout: 30))
        // Task plan: per-workspace task lists replaced the today board (desktop parity).
        app.buttons["任务"].tap()
        let newTask = app.staticTexts["新建任务"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 5))
        newTask.tap()
        let taskField = app.alerts["新建任务"].textFields.firstMatch
        XCTAssertTrue(taskField.waitForExistence(timeout: 5))
        taskField.typeText("回归任务")
        app.alerts["新建任务"].buttons["确定"].tap()
        let taskTitle = app.staticTexts["回归任务"]
        XCTAssertTrue(taskTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["计划 · 未关联对话"].waitForExistence(timeout: 3))
        app.cells.containing(.staticText, identifier: "回归任务").firstMatch.press(forDuration: 1)
        let markDone = app.descendants(matching: .any)["已完成"]
        XCTAssertTrue(markDone.waitForExistence(timeout: 5))
        markDone.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已完成")).firstMatch
                .waitForExistence(timeout: 5))
        app.buttons["工作区"].tap()
        app.buttons["新建"].tap()
        app.buttons["新建对话"].tap()
        app.sheets["选择工作区"].buttons["Isolated Fixture"].tap()
        app.sheets["选择 Agent"].buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Codex")).firstMatch.tap()
        let input = app.textViews["chat.composer"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText(
            """
            ## 移动端渲染验收
            行内公式 $E=mc^2$，以及 **加粗** 和 `代码`。

            $$\\int_0^1 x^2 dx = \\frac{1}{3}$$

            ```swift
            let greeting = "Hello, TodeX"
            print(greeting)
            ```

            | 功能 | 状态 |
            | --- | --- |
            | 离线公式 | 可用 |

            [打开 README](./README.md)
            """)
        let send = app.buttons["chat.send"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 20)
        send.tap()
        XCTAssertTrue(
            app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fixture Codex")).firstMatch
                .waitForExistence(timeout: 25))
        app.webViews["chat.timeline"].swipeDown()
        let rich = XCTAttachment(screenshot: app.screenshot())
        rich.name = "Markdown formula code table"
        rich.lifetime = .keepAlways
        add(rich)
        let fileLink = app.webViews.links["打开 README"].firstMatch
        XCTAssertTrue(fileLink.waitForExistence(timeout: 5))
        fileLink.tap()
        let editor = app.textViews["workbench.file.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let fileStatus = app.staticTexts["workbench.file.status"]
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "bytes"), evaluatedWith: fileStatus)
        waitForExpectations(timeout: 15)
        let fileOptions = app.buttons["文件选项"]
        fileOptions.tap()
        let edit = app.buttons["编辑"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        editor.typeText("\nTODEX_UI_FILE_SAVED\n")
        fileOptions.tap()
        app.buttons["保存"].tap()
        expectation(
            for: NSPredicate(format: "label BEGINSWITH %@", "已保存"),
            evaluatedWith: fileStatus)
        waitForExpectations(timeout: 15)
        fileOptions.tap()
        app.buttons["引用"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue((input.value as? String ?? "").contains("README.md"))
        input.tap()
        app.swipeDown()
        let panes = app.segmentedControls["conversation.panes"]
        if panes.exists { panes.buttons["操作台"].tap() }
        app.buttons["新标签"].tap()
        app.sheets["新建标签"].buttons["终端"].tap()
        // Terminal tabs auto-start their PTY once the backend reports none running.
        let status = app.staticTexts["workbench.terminal.status"]
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "运行中"), evaluatedWith: status)
        waitForExpectations(timeout: 30)
        let terminal = XCTAttachment(screenshot: app.screenshot())
        terminal.name = "Native PTY running"
        terminal.lifetime = .keepAlways
        add(terminal)
        app.buttons["停止"].tap()
        app.alerts["停止此终端？"].buttons["停止"].tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "已退出"), evaluatedWith: status)
        waitForExpectations(timeout: 20)
        app.buttons["新标签"].tap()
        app.sheets["新建标签"].buttons["网页"].tap()
        // The browser tab auto-loads the backend's own address on open.
        let browserStatus = app.staticTexts["workbench.browser.status"]
        expectation(
            for: NSPredicate(format: "label BEGINSWITH %@", "HTTP"),
            evaluatedWith: browserStatus)
        waitForExpectations(timeout: 20)
        let address = app.textFields["workbench.browser.address"]
        XCTAssertTrue((address.value as? String ?? "").hasPrefix("http://127.0.0.1:\(port)"))
        address.tap()
        address.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        address.typeText("http://127.0.0.1:\(port)/health")
        app.buttons["刷新"].tap()
        expectation(
            for: NSPredicate(format: "label BEGINSWITH %@", "HTTP 200"),
            evaluatedWith: browserStatus)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(app.webViews["workbench.browser.page"].exists)
        app.buttons["新标签"].tap()
        app.sheets["新建标签"].buttons["Git"].tap()
        XCTAssertTrue(app.staticTexts["来源：后端 Git 状态"].waitForExistence(timeout: 20))
        let git = XCTAttachment(screenshot: app.screenshot())
        git.name = "Git workspace status"
        git.lifetime = .keepAlways
        add(git)
        // The header Git icon drives operations; the tab itself only lists changes.
        let gitMenu = app.buttons["Git 操作"]
        XCTAssertTrue(gitMenu.waitForExistence(timeout: 5))
        gitMenu.tap()
        let refresh = app.descendants(matching: .any)["刷新状态"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()
        app.terminate()
    }

    @MainActor func testComposerInlineSuggestions() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["TODEX_TEST_PORT"] != nil else {
            throw XCTSkip("Requires the explicitly configured isolated Rust backend fixture")
        }
        let app = application()
        app.launch()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Isolated Fixture")).firstMatch
                .waitForExistence(timeout: 30))
        app.buttons["新建"].tap()
        app.buttons["新建对话"].tap()
        app.sheets["选择工作区"].buttons["Isolated Fixture"].tap()
        app.sheets["选择 Agent"].buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Codex")).firstMatch.tap()
        let input = app.textViews["chat.composer"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        // "/" lists live control/provider commands; Codex always offers /compact and /retry.
        input.typeText("/")
        let slash = app.buttons["chat.suggestion.0"]
        XCTAssertTrue(slash.waitForExistence(timeout: 10))
        XCTAssertTrue(slash.isHittable)
        // A non-matching token hides the suggestion list again.
        input.typeText("zzz")
        let hidden = expectation(
            for: NSPredicate(format: "hittable == false"), evaluatedWith: slash)
        wait(for: [hidden], timeout: 5)
        input.typeText("\u{8}\u{8}\u{8}\u{8}")
        // "@" searches workspace entries and inserts the file path.
        input.typeText("@")
        let mention = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.suggestion.", "README"))
            .firstMatch
        XCTAssertTrue(mention.waitForExistence(timeout: 15))
        mention.tap()
        XCTAssertTrue((input.value as? String ?? "").contains("@README.md"))
        app.terminate()
    }
}
