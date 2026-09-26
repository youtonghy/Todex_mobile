import Foundation

/// Categorized, actionable explanation of a failed backend connection,
/// mirroring TodeX_protocol `connectionError.ts` (ConnectionFailureCode and
/// its user messages) for the errors the iOS transport actually raises.
/// Presentation only: reconnect policy stays with `TodexError.stopsReconnect`.
public struct ConnectionDiagnostic: Sendable, Equatable {
    public enum Category: String, Sendable, CaseIterable {
        case backendUnreachable = "backend_unreachable"
        case networkOffline = "network_offline"
        case timeout
        case invalidServerURL = "invalid_server_url"
        case authenticationFailed = "authentication_failed"
        case encryptionPolicy = "encryption_policy"
        case protocolMismatch = "protocol_mismatch"
        case handshakeFailed = "websocket_failed"
        case tls
        case serverError = "server_error"
        case unknown
    }

    public let category: Category
    /// Short label, e.g. "Backend 未启动或端口错误".
    public let title: String
    /// What the user can do about it.
    public let suggestion: String
    /// Raw detail for support; never contains credentials (errors carry none).
    public let technicalDetails: String
    /// Mirrors `TodexError.stopsReconnect`: false means retries cannot succeed.
    public let retryable: Bool

    public static func classify(_ error: any Error) -> ConnectionDiagnostic {
        let details = technicalDetails(error)
        let retryable = !TodexError.stopsReconnect(error)
        if let urlError = error as? URLError {
            return classify(urlError, details: details)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return classify(URLError(URLError.Code(rawValue: nsError.code)), details: details)
        }
        switch error {
        case TodexError.configuration(let message):
            return .init(
                category: .encryptionPolicy, title: String(localized: "传输加密配置不匹配", bundle: .module),
                suggestion: String(localized: "\(message)。请在设置中核对“传输加密”与“加密公钥”，或重新导入后端配对信息。", bundle: .module),
                technicalDetails: details, retryable: false)
        case TodexError.server(let code, _):
            let upper = code.uppercased()
            if ["401", "403", "UNAUTHENTICATED", "UNAUTHORIZED"].contains(upper) {
                return .init(
                    category: .authenticationFailed, title: String(localized: "设备未验证或凭据无效", bundle: .module),
                    suggestion: String(localized: "后端拒绝了本机设备签名。请在“配对与设备验证”中重新申请设备验证，并在后端批准。", bundle: .module),
                    technicalDetails: details, retryable: retryable)
            }
            if let status = Int(code), status >= 500 {
                return .init(
                    category: .serverError, title: String(localized: "服务器暂时不可用", bundle: .module),
                    suggestion: String(localized: "后端返回 HTTP \(status)，请稍后重试或检查后端日志。", bundle: .module),
                    technicalDetails: details, retryable: retryable)
            }
            if upper == "404" {
                return .init(
                    category: .protocolMismatch, title: String(localized: "后端版本不兼容", bundle: .module),
                    suggestion: String(localized: "后端没有提供 /v2 接口。请确认地址指向 TodeX 后端根地址，并将后端升级到最新版本。", bundle: .module),
                    technicalDetails: details, retryable: retryable)
            }
            if Int(code) == nil {
                // connection.closed frames: the socket dropped after opening.
                return .init(
                    category: .handshakeFailed, title: String(localized: "连接已中断", bundle: .module),
                    suggestion: retryable
                        ? String(localized: "实时连接被中断，应用会自动重连；若反复出现请检查网络或后端日志。", bundle: .module)
                        : String(localized: "后端终止了连接且不会自动重试，请检查后端配置后重新连接。", bundle: .module),
                    technicalDetails: details, retryable: retryable)
            }
            return .init(
                category: .handshakeFailed, title: String(localized: "WebSocket 握手失败", bundle: .module),
                suggestion: String(localized: "后端拒绝了实时连接。请确认后端版本与应用一致，并检查反向代理是否支持 WebSocket。", bundle: .module),
                technicalDetails: details, retryable: retryable)
        case TodexError.disconnected:
            return .init(
                category: .handshakeFailed, title: String(localized: "连接已断开", bundle: .module),
                suggestion: String(localized: "实时连接在建立过程中断开。请检查网络后重新连接。", bundle: .module),
                technicalDetails: details, retryable: retryable)
        case TodexError.invalid(let message):
            if message == CoreMessage.v1Removed || message.contains("/v1") {
                return .init(
                    category: .protocolMismatch, title: String(localized: "协议已废弃（/v1）", bundle: .module),
                    suggestion: String(localized: "请将后端地址改为根地址（不要包含 /v1）。", bundle: .module), technicalDetails: details, retryable: false)
            }
            if CoreMessage.addressMessages.contains(message) {
                return .init(
                    category: .invalidServerURL, title: String(localized: "Backend 地址无效", bundle: .module),
                    suggestion: String(localized: "\(message)。示例：http://192.168.1.10:7345", bundle: .module), technicalDetails: details,
                    retryable: false)
            }
            if CoreMessage.handshakeMessages.contains(message) {
                return .init(
                    category: .handshakeFailed, title: String(localized: "WebSocket 握手失败", bundle: .module),
                    suggestion: String(localized: "后端未完成握手验证。请确认后端版本与应用一致。", bundle: .module), technicalDetails: details,
                    retryable: retryable)
            }
            return unknown(details, retryable: retryable)
        default:
            return unknown(details, retryable: retryable)
        }
    }

    private static func classify(_ error: URLError, details: String) -> ConnectionDiagnostic {
        switch error.code {
        case .cannotConnectToHost:
            return .init(
                category: .backendUnreachable, title: String(localized: "Backend 未启动或端口错误（连接被拒绝）", bundle: .module),
                suggestion: String(localized: "请确认后端已启动，端口与地址一致，且监听地址允许局域网访问（不是仅 127.0.0.1）。", bundle: .module),
                technicalDetails: details, retryable: true)
        case .cannotFindHost, .dnsLookupFailed:
            return .init(
                category: .backendUnreachable, title: String(localized: "Backend 未启动或地址不可达", bundle: .module),
                suggestion: String(localized: "无法解析后端主机名。请检查后端地址拼写，或改用 IP 地址。", bundle: .module),
                technicalDetails: details, retryable: true)
        case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed:
            return .init(
                category: .networkOffline, title: String(localized: "网络不可用", bundle: .module),
                suggestion: String(localized: "设备当前没有网络连接。请检查 Wi-Fi/蜂窝网络，并确认已允许 TodeX 访问本地网络。", bundle: .module),
                technicalDetails: details, retryable: true)
        case .timedOut:
            return .init(
                category: .timeout, title: String(localized: "连接超时，请确认 Backend 已启动", bundle: .module),
                suggestion: String(localized: "后端在规定时间内没有响应。请确认设备与后端在同一网络，且防火墙放行该端口。", bundle: .module),
                technicalDetails: details, retryable: true)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
            .clientCertificateRequired:
            return .init(
                category: .tls, title: String(localized: "HTTPS 证书或 TLS 握手失败", bundle: .module),
                suggestion: String(localized: "请确认后端证书受信任且未过期；局域网调试可改用 http:// 地址。", bundle: .module),
                technicalDetails: details, retryable: true)
        case .appTransportSecurityRequiresSecureConnection:
            return .init(
                category: .invalidServerURL, title: String(localized: "系统拒绝了不安全的连接", bundle: .module),
                suggestion: String(localized: "该地址被 App Transport Security 拦截。请使用局域网地址或改用 HTTPS。", bundle: .module),
                technicalDetails: details, retryable: false)
        case .badURL, .unsupportedURL:
            return .init(
                category: .invalidServerURL, title: String(localized: "Backend 地址无效", bundle: .module),
                suggestion: String(localized: "请填写 http:// 或 https:// 开头的后端根地址。", bundle: .module), technicalDetails: details,
                retryable: false)
        case .badServerResponse, .cannotParseResponse:
            return .init(
                category: .handshakeFailed, title: String(localized: "WebSocket 握手失败", bundle: .module),
                suggestion: String(localized: "后端响应无效。请确认地址指向 TodeX 后端，且中间代理支持 WebSocket。", bundle: .module),
                technicalDetails: details, retryable: true)
        default:
            return .init(
                category: .backendUnreachable, title: String(localized: "Backend 未启动或地址不可达", bundle: .module),
                suggestion: String(localized: "请确认后端已启动、地址正确且网络可达。", bundle: .module), technicalDetails: details, retryable: true)
        }
    }

    private static func unknown(_ details: String, retryable: Bool) -> ConnectionDiagnostic {
        .init(
            category: .unknown, title: String(localized: "连接失败", bundle: .module), suggestion: String(localized: "请检查后端地址与网络后重试。", bundle: .module), technicalDetails: details,
            retryable: retryable)
    }

    private static func technicalDetails(_ error: any Error) -> String {
        switch error {
        case let urlError as URLError:
            return "URLError \(urlError.code.rawValue) · \(urlError.localizedDescription)"
        case TodexError.server(let code, let message): return "\(code) · \(message)"
        case TodexError.configuration(let message): return "configuration · \(message)"
        case TodexError.invalid(let message): return message
        default:
            let ns = error as NSError
            return "\(ns.domain) \(ns.code) · \(error.localizedDescription)"
        }
    }
}
