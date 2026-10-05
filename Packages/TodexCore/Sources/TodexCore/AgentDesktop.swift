import Foundation

// Agent desktop tools (`todex_desktop` MCP server). Both the agent browser and
// Computer Use run in the daemon on its own host; clients only watch (live
// frames, screenshots, the action journal) and answer prompts. Mirrors
// TodeX_protocol/src/agentDesktop.ts and the `desktopBrowser` /
// `desktopComputer` projections of conversationRuntime.ts.

/// Newest `desktop.browser.action` / `desktop.computer.action` events kept per conversation.
public let desktopActionLimit = 50

/// A failed tool call as journaled in `desktop.*.action` events.
public struct DesktopActionFailure: Sendable, Equatable {
    /// `NO_TAB`, `APP_CONFIRM`, `PERMISSION_REQUIRED`, ... (see `ExecutorErrorCode`).
    public var code: String
    public var message: String
}

/// `desktop.browser.action`: one agent-browser tool call, without image data.
public struct DesktopBrowserAction: Sendable, Equatable, Identifiable {
    public var actionId: String
    public var tool: String
    public var ok: Bool
    public var url: String?
    public var title: String?
    /// Short human summary, e.g. `click "Sign in"`.
    public var summary: String
    public var error: DesktopActionFailure?
    /// `GET /v2/conversations/{id}/agent-shots/{shotId}`.
    public var shotId: String?
    public var deviceId: String
    public var deviceName: String
    /// Journal time of the event.
    public var time: String
    public var id: String { actionId }
}

/// `desktop.computer.action`: one Computer Use tool call, without image data.
public struct DesktopComputerAction: Sendable, Equatable, Identifiable {
    public var actionId: String
    public var tool: String
    public var ok: Bool
    public var summary: String
    public var app: String?
    public var windowTitle: String?
    /// `background`, `pointer` or `none`.
    public var path: String?
    public var error: DesktopActionFailure?
    public var shotId: String?
    public var deviceId: String
    public var deviceName: String
    public var time: String
    public var id: String { actionId }
}

/// Agent desktop browser of one conversation: whether it holds a grant, and
/// its newest actions. History pages do not extend it.
public struct DesktopBrowserState: Sendable, Equatable {
    public var granted = false
    /// The conversation has a tab open (the last successful open/close says
    /// so); nil until an action reports it.
    public var tabOpen: Bool?
    /// The computer the browser runs on.
    public var deviceName: String?
    public var actions: [DesktopBrowserAction] = []
    public init() {}
}

/// Computer Use of one conversation. History pages do not extend it.
public struct DesktopComputerState: Sendable, Equatable {
    /// The conversation currently controls the host's screen.
    public var active = false
    /// Its first grant waits for the person at the host.
    public var awaitingHost = false
    public var deviceId: String?
    /// The host's name.
    public var deviceName: String?
    public var actions: [DesktopComputerAction] = []
    public init() {}
}

extension DesktopActionFailure {
    init?(_ value: JSONValue) {
        guard case .object = value else { return nil }
        code = value["code"].stringValue
        message = value["message"].stringValue
    }
}

private func nonEmpty(_ value: JSONValue) -> String? {
    guard let string = value.optionalString, !string.isEmpty else { return nil }
    return string
}

extension DesktopBrowserState {
    /// `desktop.browser.grant` / `desktop.browser.action`, as `projectDesktopBrowser`.
    mutating func apply(type: String, payload: JSONValue, time: String) {
        if type == "desktop.browser.grant" {
            let isGranted = payload["status"].stringValue == "granted"
            granted = isGranted
            if !isGranted { tabOpen = false }
            deviceName = isGranted ? nonEmpty(payload["deviceName"]) : nil
            return
        }
        guard let actionId = nonEmpty(payload["actionId"]), !actions.contains(where: { $0.actionId == actionId })
        else { return }
        let action = DesktopBrowserAction(
            actionId: actionId, tool: payload["tool"].stringValue, ok: payload["ok"].boolValue,
            url: payload["url"].optionalString, title: payload["title"].optionalString,
            summary: payload["summary"].stringValue, error: DesktopActionFailure(payload["error"]),
            shotId: payload["shotId"].optionalString, deviceId: payload["deviceId"].stringValue,
            deviceName: payload["deviceName"].stringValue, time: time)
        // Acting implies a grant even when the grant event lies below the window.
        granted = true
        tabOpen =
            action.ok
            ? action.tool != "browser_close"
            : action.error?.code == "NO_TAB" ? false : tabOpen ?? (action.tool != "browser_open")
        deviceName = nonEmpty(payload["deviceName"]) ?? deviceName
        actions.append(action)
        if actions.count > desktopActionLimit { actions.removeFirst(actions.count - desktopActionLimit) }
    }
}

extension DesktopComputerState {
    /// `desktop.computer.grant` / `.session` / `.action`, as `projectDesktopComputer`.
    mutating func apply(type: String, payload: JSONValue, time: String) {
        if type == "desktop.computer.grant" {
            awaitingHost = payload["status"].stringValue == "requested"
            deviceName = nonEmpty(payload["deviceName"]) ?? deviceName
            return
        }
        if type == "desktop.computer.session" {
            active = payload["status"].stringValue == "started"
            if active {
                deviceId = nonEmpty(payload["deviceId"])
                deviceName = nonEmpty(payload["deviceName"])
            }
            return
        }
        guard let actionId = nonEmpty(payload["actionId"]), !actions.contains(where: { $0.actionId == actionId })
        else { return }
        let action = DesktopComputerAction(
            actionId: actionId, tool: payload["tool"].stringValue, ok: payload["ok"].boolValue,
            summary: payload["summary"].stringValue, app: payload["app"].optionalString,
            windowTitle: payload["windowTitle"].optionalString, path: payload["path"].optionalString,
            error: DesktopActionFailure(payload["error"]), shotId: payload["shotId"].optionalString,
            deviceId: payload["deviceId"].stringValue, deviceName: payload["deviceName"].stringValue, time: time)
        deviceId = nonEmpty(payload["deviceId"]) ?? deviceId
        deviceName = nonEmpty(payload["deviceName"]) ?? deviceName
        actions.append(action)
        if actions.count > desktopActionLimit { actions.removeFirst(actions.count - desktopActionLimit) }
    }
}

// MARK: - REST models

/// Whether the daemon's host can run Computer Use.
public struct ComputerHostStatus: Codable, Sendable, Equatable {
    public struct Permissions: Codable, Sendable, Equatable {
        public var screen: Bool
        public var accessibility: Bool
    }
    /// The host's OS and session can run it at all.
    public var supported: Bool
    /// Supported, permitted, and someone at the host can confirm grants.
    public var available: Bool
    /// Why it is not available.
    public var reason: String?
    /// The computer agents would control.
    public var host: String
    /// `macos`, `windows`, `linux`, ...
    public var platform: String
    /// OS permissions granted to the TodeX backend on the host.
    public var permissions: Permissions
}

/// The daemon's pinned Chromium (Chrome for Testing).
public struct AgentBrowserInstall: Codable, Sendable, Equatable {
    public var version: String
    public var installed: Bool
    public var downloading: Bool
    /// 0...1 while downloading.
    public var progress: Double?
    public var error: String?
    /// `TODEX_AGENT_BROWSER_PATH` points at another Chromium.
    public var overridden: Bool
}

/// Whether the daemon's host can run the agent browser.
public struct AgentBrowserStatus: Codable, Sendable, Equatable {
    public var available: Bool
    public var reason: String?
    /// The computer the browser runs on (its `localhost`).
    public var host: String
    public var chromium: AgentBrowserInstall
}

/// `GET|PUT /v2/agent-desktop`. A 404 means the daemon predates desktop tools.
public struct AgentDesktopSettings: Codable, Sendable, Equatable {
    /// Agents get the `todex_desktop` MCP server. Off by default.
    public var enabled: Bool
    /// Agents also get the `computer_*` tools (needs `enabled`). Off by default.
    public var computerEnabled: Bool
    /// Absent from daemons where Computer Use still ran on desktops.
    public var computer: ComputerHostStatus?
    /// Absent from daemons where the browser still ran on desktops.
    public var browser: AgentBrowserStatus?
}

public struct AgentBrowserProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Unix milliseconds.
    public var createdAt: Double
}

/// `GET /v2/agent-browser/profiles` (and the result of every profile change).
public struct AgentBrowserProfiles: Codable, Sendable, Equatable {
    public var profiles: [AgentBrowserProfile]
    /// Workspace id (path for workspaces without one) → profile id.
    public var workspaces: [String: String]
}

/// A JPEG of the host's screen, a browser tab or a journaled shot
/// (`ComputerFrame` / `AgentShot`); `dataUrl` is a base64 `data:` URL.
public struct AgentDesktopImage: Codable, Sendable, Equatable {
    public var shotId: String?
    public var mimeType: String
    public var dataUrl: String

    /// The image bytes of `dataUrl`, or nil when it is not a base64 data URL.
    public var data: Data? {
        guard dataUrl.hasPrefix("data:"), let comma = dataUrl.firstIndex(of: ","),
            dataUrl[..<comma].hasSuffix(";base64")
        else { return nil }
        return Data(base64Encoded: String(dataUrl[dataUrl.index(after: comma)...]))
    }
}

/// What `revokeAgentDesktop(conversationId:capability:)` stops.
public enum AgentDesktopCapability: String, Sendable {
    case browser
    /// Computer Use.
    case screen
}

/// `agentBrowser.frame` payload after `agentBrowser.watch { conversationId }`
/// on `/v2/ws`. Only the latest frame is kept when the connection is slow.
public struct AgentBrowserFrame: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        /// Base64 JPEG (no data-URL prefix); decode off the main thread.
        case image(seq: Int, base64: String, width: Int, height: Int)
        /// The conversation has no tab.
        case closed
    }
    public var conversationId: String
    public var content: Content

    public init(conversationId: String, content: Content) {
        self.conversationId = conversationId
        self.content = content
    }

    public init?(payload: JSONValue) {
        guard let id = payload["conversationId"].optionalString, !id.isEmpty else { return nil }
        conversationId = id
        if payload["closed"] == true {
            content = .closed
        } else if let data = payload["data"].optionalString, !data.isEmpty {
            content = .image(
                seq: payload["seq"].intValue, base64: data, width: payload["width"].intValue,
                height: payload["height"].intValue)
        } else {
            return nil
        }
    }
}
