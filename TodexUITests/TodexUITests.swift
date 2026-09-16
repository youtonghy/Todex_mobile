import CryptoKit
import UIKit
import XCTest

nonisolated final class TodexUITests: XCTestCase {
    @MainActor private func application() -> XCUIApplication {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        for key in ["TODEX_TEST_PORT", "TODEX_TEST_DEVICE_SECRET"] {
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
        // Task plan: desktop-parity kanban, one column per workspace.
        app.buttons["任务"].tap()
        let newTask = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "新建任务")
        ).firstMatch
        XCTAssertTrue(newTask.waitForExistence(timeout: 5))
        newTask.tap()
        let taskField = app.alerts["新建任务"].textFields.firstMatch
        XCTAssertTrue(taskField.waitForExistence(timeout: 5))
        taskField.typeText("回归任务")
        app.alerts["新建任务"].buttons["确定"].tap()
        let taskTitle = app.staticTexts["回归任务"]
        XCTAssertTrue(taskTitle.waitForExistence(timeout: 5))
        let statusChip = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "任务状态：计划")
        ).firstMatch
        XCTAssertTrue(statusChip.waitForExistence(timeout: 3))
        statusChip.tap()
        // The board also shows "已完成" as a column header and chip label —
        // both static texts; only the presented UIMenu action is a button.
        let markDone = app.buttons["已完成"].firstMatch
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
        let markdown = app.webViews["workbench.file.markdown"]
        XCTAssertTrue(markdown.waitForExistence(timeout: 10))
        let editor = app.textViews["workbench.file.editor"]
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

    // MARK: - Desktop-parity additions

    /// REST helpers let the test drive the fixture while the app is
    /// backgrounded; UIKit launches cannot race the notification pipeline.
    /// Settings is a presented sheet; rows below the fold are not in the
    /// accessibility tree until scrolled into view.
    @MainActor private func revealSettingsCell(
        _ app: XCUIApplication, containing text: String, file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let cell = app.cells.containing(.staticText, identifier: text).firstMatch
        let table = app.sheets.firstMatch.tables.firstMatch.exists
            ? app.sheets.firstMatch.tables.firstMatch : app.tables.firstMatch
        for _ in 0..<8 where !cell.exists { table.swipeUp() }
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "设置里没有找到「\(text)」", file: file, line: line)
        return cell
    }

    /// UI tests sign requests with the same fixture device the fixture script
    /// pre-enrolled in devices.json. The helper below is a compact copy of the
    /// todex.device-auth.v1 scheme; keeping it local avoids linking TodexCore
    /// internals into the UI bundle.
    @MainActor private func fixtureRequest(
        _ method: String, _ path: String, body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let port = ProcessInfo.processInfo.environment["TODEX_TEST_PORT"]!
        let secret = ProcessInfo.processInfo.environment["TODEX_TEST_DEVICE_SECRET"]!
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        for (key, value) in try UITestDeviceAuth.headers(method: method, pathAndQuery: path, secret: secret, body: request.httpBody ?? Data()) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Tapping a completion notification must open that conversation; a cold
    /// routing path refreshes before declaring it missing.
    @MainActor func testParityNotificationOpensConversation() async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["TODEX_TEST_PORT"] != nil else {
            throw XCTSkip("Requires the explicitly configured isolated Rust backend fixture")
        }
        let app = application()
        // Notification authorization is already granted on this simulator
        // (sectionInfo authorizationStatus = authorized). The toggle's
        // requestAuthorization call can wedge on the simulator's
        // usernotificationsd, so seed the app-side preference directly: the
        // launch-argument domain feeds UserDefaults.bool(forKey:).
        app.launchArguments += ["-completionNotifications", "YES"]
        app.launch()
        // The first connect may race a 30s retry timer after a rejected or
        // interrupted handshake; allow two retry windows.
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Isolated Fixture")).firstMatch
                .waitForExistence(timeout: 75))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Create the target conversation over REST so it exists before launch.
        let workspaces = try await fixtureRequest("GET", "/v2/workspaces")
        let workspace = (workspaces["workspaces"] as? [[String: Any]])?.first
        let path = workspace?["path"] as? String ?? ""
        XCTAssertFalse(path.isEmpty)
        let created = try await fixtureRequest(
            "POST", "/v2/conversations",
            body: ["workspace": path, "provider": "codex", "title": "通知测试会话"])
        let conversationId = created["id"] as? String
            ?? (created["conversation"] as? [String: Any])?["id"] as? String
        XCTAssertNotNil(conversationId)
        app.terminate()
        app.launch()
        let row = app.tables.cells.containing(.staticText, identifier: "通知测试会话").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // Conversation events only reach sockets that subscribed; open the
        // conversation once so the backend pushes its turn events live.
        row.tap()
        XCTAssertTrue(app.textViews["chat.composer"].waitForExistence(timeout: 15))
        // Background the app, then complete a turn remotely so the local
        // notification is posted while `foreground == false`. The fixture turn
        // finishes in ~200ms, so wait for the scene transition first.
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(3))
        _ = try await fixtureRequest(
            "POST", "/v2/conversations/\(conversationId!)/prompt",
            body: ["text": "通知深链验证"])
        let notification = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Fixture Codex", "通知测试会话")
        ).firstMatch
        if !notification.waitForExistence(timeout: 10) {
            // Banner already retracted: pull down Notification Center.
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            top.press(forDuration: 0.05, thenDragTo: springboard.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            XCTAssertTrue(notification.waitForExistence(timeout: 8), "完成通知没有出现在横幅或通知中心")
        }
        notification.tap()
        let input = app.textViews["chat.composer"]
        XCTAssertTrue(input.waitForExistence(timeout: 15), "点击通知后未进入对应会话")
    }

    /// Settings surface: health latency on Home, the About page (app/backend
    /// version, server info, links), and the editable tenant field.
    @MainActor func testParitySettingsAboutTenantAndHealth() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["TODEX_TEST_PORT"] != nil else {
            throw XCTSkip("Requires the explicitly configured isolated Rust backend fixture")
        }
        let app = application()
        app.launch()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Isolated Fixture")).firstMatch
                .waitForExistence(timeout: 30))
        let status = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "已连接", "ms")
        ).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20), "首页没有显示 /health 延迟")
        app.buttons["连接与设置"].tap()
        let about = revealSettingsCell(app, containing: "关于")
        about.tap()
        XCTAssertTrue(app.staticTexts["应用版本"].waitForExistence(timeout: 5))
        // /v2/version loads asynchronously; the fixture reports DEV0.0.0.
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "DEV0.0.0")).firstMatch
                .waitForExistence(timeout: 10), "About 页没有加载后端版本")
        XCTAssertTrue(app.staticTexts["后端地址"].exists)
        XCTAssertTrue(app.staticTexts["Tenant"].exists)
        XCTAssertTrue(app.staticTexts["数据目录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["about.project"].exists)
        app.navigationBars.buttons["设置"].tap()
        // tenantId is editable and reflected in the backend row subtitle.
        let tenantRow = revealSettingsCell(app, containing: "Tenant")
        tenantRow.tap()
        let tenantInput = app.alerts.textFields["settings.backend.tenantId.input"]
        XCTAssertTrue(tenantInput.waitForExistence(timeout: 5))
        tenantInput.tap()
        tenantInput.typeText(String(repeating: "\u{8}", count: 12) + "uitest-tenant")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "uitest-tenant")).firstMatch
                .waitForExistence(timeout: 5), "Tenant 编辑未生效")
        tenantRow.tap()
        let tenantAgain = app.alerts.textFields["settings.backend.tenantId.input"]
        XCTAssertTrue(tenantAgain.waitForExistence(timeout: 5))
        tenantAgain.tap()
        tenantAgain.typeText(String(repeating: "\u{8}", count: 20) + "local")
        app.alerts.buttons["保存"].tap()
        app.buttons["settings.done"].tap()
    }

    /// `#` lists backend skills and inserting one produces the same removable
    /// chip as the catalog attach flow; a photo attachment becomes an inline
    /// composer capsule and renders a persisted receipt card that survives
    /// relaunch.
    @MainActor func testParitySkillMentionAndAttachmentReceipt() throws {
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
        app.sheets["选择 Agent"].buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Codex")).firstMatch.tap()
        let input = app.textViews["chat.composer"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("#")
        let skill = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.suggestion.", "fixture-skill")
        ).firstMatch
        XCTAssertTrue(skill.waitForExistence(timeout: 15), "# 没有列出 fixture skill")
        skill.tap()
        let chip = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "fixture-skill", "移除")
        ).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "选择 Skill 后没有生成 chip")
        XCTAssertFalse((input.value as? String ?? "").contains("#"), "#token 未从草稿移除")
        chip.tap() // remove so the receipt send stays a plain text prompt
        // Attach the seeded simulator photo and send it.
        app.buttons["附件"].tap()
        let photos = app.descendants(matching: .any)["照片"].firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        photos.tap()
        // PHPicker grid cells are images tagged PXGGridLayout-Info; the first
        // one is the photo seeded via `simctl addmedia`.
        let photoCell = app.images.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "PXGGridLayout")).firstMatch
        XCTAssertTrue(photoCell.waitForExistence(timeout: 10), "照片选择器没有可用图片")
        photoCell.tap()
        // Multi-select picker needs the enabled 完成 button after marking.
        let confirm = app.buttons["完成"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let capsuleValue = NSPredicate(format: "value CONTAINS %@", "图片.jpg")
        expectation(for: capsuleValue, evaluatedWith: input)
        waitForExpectations(timeout: 10)
        input.tap()
        input.typeText("带附件")
        let send = app.buttons["chat.send"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 20)
        send.tap()
        let receipt = app.webViews.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "图片.jpg")).firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 15), "已发消息没有附件回执")
        // Receipts are part of the persisted snapshot: relaunch and reopen.
        app.terminate()
        app.launch()
        let row = app.tables.cells.containing(.staticText, identifier: "新对话").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(
            app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "图片.jpg"))
                .firstMatch.waitForExistence(timeout: 15), "回执没有随快照恢复")
        app.terminate()
    }

    /// Terminal shell selection feeds terminal.start and the PTY echo fills the
    /// field back; the worktree action adds a workspace visible on Home.
    @MainActor func testParityTerminalShellAndWorktree() throws {
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
        app.sheets["选择 Agent"].buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Codex")).firstMatch.tap()
        let input = app.textViews["chat.composer"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        let panes = app.segmentedControls["conversation.panes"]
        if panes.exists { panes.buttons["操作台"].tap() }
        app.buttons["新标签"].tap()
        app.sheets["新建标签"].buttons["终端"].tap()
        let status = app.staticTexts["workbench.terminal.status"]
        // The tab auto-starts a PTY; stop it so the shell field can be set.
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "运行中"), evaluatedWith: status)
        waitForExpectations(timeout: 30)
        app.buttons["停止"].tap()
        app.alerts["停止此终端？"].buttons["停止"].tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "已退出"), evaluatedWith: status)
        waitForExpectations(timeout: 20)
        let shellField = app.textFields["workbench.terminal.shell"]
        XCTAssertTrue(shellField.waitForExistence(timeout: 5))
        shellField.tap()
        // The stopped PTY echoed its shell into the field; select all first.
        shellField.press(forDuration: 1.2)
        let selectAll = app.menuItems.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Select All", "全选")).firstMatch
        if selectAll.waitForExistence(timeout: 3) { selectAll.tap() }
        shellField.typeText("/bin/zsh")
        // A system keyboard-coaching card ("Quickly Change Keyboards" →
        // Continue) can appear and block all app taps; poll app+springboard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<10 {
            let coaching = [app, springboard].lazy
                .map { $0.buttons.matching(NSPredicate(
                    format: "label == %@ OR label == %@", "Continue", "继续")).firstMatch }
                .first { $0.exists }
            if let coaching { coaching.tap(); break }
            sleep(1)
        }
        let start = app.buttons["启动"]
        start.tap()
        if !app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "运行中"))
            .firstMatch.waitForExistence(timeout: 10) {
            start.tap() // first tap may have only dismissed the selection UI
        }
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "运行中"), evaluatedWith: status)
        waitForExpectations(timeout: 30)
        XCTAssertEqual(shellField.value as? String, "/bin/zsh", "终端没有把所选 shell 回显到输入框")
        app.buttons["终端选项"].tap()
        let clear = app.descendants(matching: .any)["清屏"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(status.exists)
        // Git worktree -> 打开为工作区 -> the new workspace is usable on Home.
        app.buttons["新标签"].tap()
        app.sheets["新建标签"].buttons["Git"].tap()
        XCTAssertTrue(app.staticTexts["来源：后端 Git 状态"].waitForExistence(timeout: 20))
        app.buttons["Git 操作"].tap()
        let worktreeMenu = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "工作树（")).firstMatch
        XCTAssertTrue(worktreeMenu.waitForExistence(timeout: 5))
        worktreeMenu.tap()
        // Worktree items render as "name, branch" (title + subtitle).
        let entry = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "wt-fixture")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Git 菜单没有列出 wt-fixture 工作树")
        entry.tap()
        let openWorkspace = app.descendants(matching: .any)["打开为工作区"].firstMatch
        XCTAssertTrue(openWorkspace.waitForExistence(timeout: 5))
        openWorkspace.tap()
        let added = app.alerts["已添加工作区"].firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 10))
        app.alerts.buttons["知道了"].tap()
        app.navigationBars.buttons["TodeX"].tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "wt-fixture")).firstMatch
                .waitForExistence(timeout: 10), "首页没有出现工作树新增的工作区")
        app.terminate()
    }
}

/// Minimal todex.device-auth.v1 signer for fixture HTTP calls: the fixture
/// backend pre-enrolls this Ed25519 key in devices.json.
private enum UITestDeviceAuth {
    static func headers(method: String, pathAndQuery: String, secret: String, body: Data) throws -> [String: String] {
        let padded = secret.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - secret.count % 4) % 4)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: padded)))
        let deviceID = "dev_" + base64URL(Data(SHA256.hash(data: key.publicKey.rawRepresentation)).prefix(12))
        let (path, query) = split(pathAndQuery)
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = base64URL(randomBytes(16))
        let bodyHash = base64URL(Data(SHA256.hash(data: body)))
        let payload = Data(
            "todex.device-auth.v1\0\(deviceID)\0\(method)\0\(path)\0\(canonicalQuery(query))\0\(timestamp)\0\(nonce)\0\(bodyHash)".utf8)
        let signature = try key.signature(for: payload)
        return [
            "x-todex-device-id": deviceID, "x-todex-auth-ts": timestamp,
            "x-todex-auth-nonce": nonce, "x-todex-auth-sig": base64URL(signature),
        ]
    }

    private static func canonicalQuery(_ query: String) -> String {
        query.split(separator: "&", omittingEmptySubsequences: true)
            .map { pair -> String in
                let text = String(pair)
                guard let separator = text.firstIndex(of: "=") else { return strictEncode(formDecode(text)) + "=" }
                return strictEncode(formDecode(String(text[..<separator])))
                    + "=" + strictEncode(formDecode(String(text[text.index(after: separator)...])))
            }
            .filter { !["device_id", "auth_ts", "auth_nonce", "auth_sig"].contains($0.split(separator: "=").first.map(String.init) ?? "") }
            .sorted().joined(separator: "&")
    }

    private static func split(_ target: String) -> (String, String) {
        guard let separator = target.firstIndex(of: "?") else { return (target, "") }
        return (String(target[..<separator]), String(target[target.index(after: separator)...]))
    }

    private static func formDecode(_ value: String) -> String {
        var bytes: [UInt8] = []
        var index = 0
        let utf8 = Array(value.utf8)
        while index < utf8.count {
            let byte = utf8[index]
            if byte == 0x2B { bytes.append(0x20) } else if byte == 0x25, index + 2 < utf8.count,
                let hi = hex(utf8[index + 1]), let lo = hex(utf8[index + 2])
            { bytes.append(hi << 4 | lo); index += 2 } else { bytes.append(byte) }
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func strictEncode(_ value: String) -> String {
        value.utf8.map { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || [45, 46, 95, 126].contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 65 + 10
        case 97...102: return byte - 97 + 10
        default: return nil
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
