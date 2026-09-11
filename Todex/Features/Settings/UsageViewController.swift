import TodexCore
import UIKit

/// Runtime contract: one confirmed record per turn, with provider/model and optional numeric
/// inputTokens/outputTokens/cachedInputTokens/cacheWriteTokens/totalTokens, cacheSemantics,
/// and updatedAt (ISO 8601 or Unix milliseconds). Missing values never become zero.
@MainActor
final class UsageViewController: SettingsListController {
    private var records: [JSONValue]
    private var provider: String?
    private var model: String?

    init(records: [JSONValue]) {
        self.records = records
        super.init(title: "使用统计")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    func update(records: [JSONValue]) {
        self.records = records
        if let provider, !records.contains(where: { Self.name($0, "provider") == provider }) {
            self.provider = nil
            model = nil
        }
        if let model, !providerRecords.contains(where: { Self.name($0, "model") == model }) { self.model = nil }
        render()
    }

    private var providerRecords: [JSONValue] {
        records.filter { provider == nil || Self.name($0, "provider") == provider }
    }
    private var filtered: [JSONValue] { providerRecords.filter { model == nil || Self.name($0, "model") == model } }

    private static func name(_ record: JSONValue, _ key: String) -> String {
        guard let value = record[key].optionalString, !value.isEmpty else { return "未知" }
        return value
    }

    private func filter(_ key: String) {
        let values = Array(Set((key == "provider" ? records : providerRecords).map { Self.name($0, key) })).sorted()
        let selected = key == "provider" ? provider : model
        let choices = [("all", "全部")] + values.enumerated().map { (String($0.offset), $0.element) }
        choose(
            title: key == "provider" ? "Provider" : "模型", choices: choices,
            selected: selected.flatMap { values.firstIndex(of: $0).map(String.init) } ?? "all"
        ) { [weak self] value in
            guard let self else { return }
            let next = Int(value).flatMap { values.indices.contains($0) ? values[$0] : nil }
            if key == "provider" {
                provider = next
                model = nil
            } else {
                model = next
            }
            render()
        }
    }

    private func render() {
        let rows = filtered
        sections = [
            SettingsSection(
                title: "筛选", footer: "统计当前提供的已确认会话记录，不代表账户余额或剩余额度。未报告的数据保留为未知。",
                rows: [
                    SettingsRow(title: "Provider", detail: provider ?? "全部", id: "usage.filter.provider") {
                        [weak self] in self?.filter("provider")
                    },
                    SettingsRow(title: "模型", detail: model ?? "全部", id: "usage.filter.model") { [weak self] in
                        self?.filter("model")
                    },
                ])
        ]
        guard !rows.isEmpty else {
            sections.append(
                SettingsSection(
                    title: "用量",
                    rows: [
                        SettingsRow(
                            title: "暂无用量记录", detail: "Agent 返回 usage 后，可在此查看已确认的统计。", symbol: "chart.bar",
                            id: "usage.empty")
                    ]))
            redraw()
            return
        }
        let metrics: [(String, String, (JSONValue) -> Double?)] = [
            ("总用量", "total", UsageCalculation.total),
            ("输入 tokens", "input", { UsageCalculation.number($0, "inputTokens") }),
            ("输出 tokens", "output", { UsageCalculation.number($0, "outputTokens") }),
            ("缓存读取", "cacheRead", { UsageCalculation.number($0, "cachedInputTokens") }),
            ("缓存写入", "cacheWrite", { UsageCalculation.number($0, "cacheWriteTokens") }),
        ]
        sections.append(
            SettingsSection(
                title: "\(rows.count) 条记录", footer: "缓存 included 时属于输入；additional 时另计。缺少总量且缓存口径未知的记录不推算总量。",
                rows: metrics.map { label, key, metric in
                    let summary = UsageCalculation.summary(rows, metric: metric)
                    return SettingsRow(
                        title: "\(label)：\(summary.value)", detail: summary.detail, id: "usage.metric.\(key)")
                }))
        let cache = UsageCalculation.cacheRate(rows)
        sections.append(
            SettingsSection(
                title: "缓存与记录",
                rows: [
                    SettingsRow(
                        title: "缓存命中率：\(cache.rate.map { String(format: "%.1f%%", $0 * 100) } ?? "未知")",
                        detail: "\(cache.count)/\(rows.count) 条记录的缓存口径和输入明细可确认", id: "usage.cacheRate"),
                    SettingsRow(
                        title: "最近更新",
                        detail: rows.compactMap(UsageCalculation.date).max().map {
                            $0.formatted(date: .abbreviated, time: .standard)
                        } ?? "未知", id: "usage.updatedAt"),
                    SettingsRow(
                        title: "模型数",
                        detail: String(
                            Set(rows.compactMap { $0["model"].optionalString }.filter { !$0.isEmpty }).count),
                        id: "usage.models"),
                ]))
        for key in ["provider", "model"] {
            let groups = Dictionary(grouping: rows) { Self.name($0, key) }
            let groupedRows = groups.keys.sorted().map { name in
                let summary = UsageCalculation.summary(groups[name] ?? [], metric: UsageCalculation.total)
                return SettingsRow(
                    title: name, detail: "\(summary.value) tokens · \(summary.detail)", id: "usage.group.\(key).\(name)"
                )
            }
            sections.append(SettingsSection(title: key == "provider" ? "按 Provider 汇总" : "按模型汇总", rows: groupedRows))
        }
        sections.append(
            SettingsSection(
                title: "记录明细",
                rows: rows.enumerated().map { index, record in
                    SettingsRow(
                        title: "\(Self.name(record, "provider")) · \(Self.name(record, "model"))",
                        detail: "\(UsageCalculation.total(record).map(UsageCalculation.format) ?? "未知") tokens",
                        id: "usage.record.\(index)"
                    ) { [weak self] in
                        self?.navigationController?.pushViewController(
                            SettingsTextController(title: "用量记录", text: record.prettyPrinted), animated: true)
                    }
                }))
        redraw()
    }
}

/// Kept independent of UIKit so the missing-data and cache arithmetic can be verified directly.
nonisolated enum UsageCalculation {
    static func number(_ record: JSONValue, _ key: String) -> Double? {
        guard let value = record[key].doubleValue, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func total(_ record: JSONValue) -> Double? {
        if let explicit = number(record, "totalTokens") { return explicit }
        guard let input = number(record, "inputTokens"), let output = number(record, "outputTokens") else { return nil }
        let total: Double
        switch record["cacheSemantics"].stringValue {
        case "included": total = input + output
        case "additional":
            guard let read = number(record, "cachedInputTokens"), let write = number(record, "cacheWriteTokens") else {
                return nil
            }
            total = input + output + read + write
        default: return nil
        }
        return total.isFinite ? total : nil
    }

    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func summary(_ records: [JSONValue], metric: (JSONValue) -> Double?) -> (value: String, detail: String) {
        let known = records.compactMap(metric)
        guard !known.isEmpty else { return ("未知", "\(records.count) 条记录尚无可确认数值") }
        let sum = known.reduce(0, +)
        guard sum.isFinite else { return ("未知", "数值超出可汇总范围") }
        let complete = known.count == records.count
        return (
            format(sum) + (complete ? "" : "（已知部分）"),
            complete
                ? "\(known.count) 条记录已报告" : "\(known.count)/\(records.count) 条已报告，另有 \(records.count - known.count) 条未知"
        )
    }

    static func cacheRate(_ records: [JSONValue]) -> (rate: Double?, count: Int) {
        var readTotal = 0.0
        var baseTotal = 0.0
        var count = 0
        for record in records {
            guard let input = number(record, "inputTokens"), let read = number(record, "cachedInputTokens") else {
                continue
            }
            let base: Double
            switch record["cacheSemantics"].stringValue {
            case "included": base = input
            case "additional":
                guard let write = number(record, "cacheWriteTokens") else { continue }
                base = input + read + write
            default: continue
            }
            guard base.isFinite, read <= base else { continue }
            baseTotal += base
            readTotal += read
            count += 1
        }
        guard baseTotal > 0, baseTotal.isFinite, readTotal.isFinite else { return (nil, count) }
        return (readTotal / baseTotal, count)
    }

    static func date(_ record: JSONValue) -> Date? {
        if let value = number(record, "updatedAt") { return Date(timeIntervalSince1970: value / 1_000) }
        guard let text = record["updatedAt"].optionalString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
