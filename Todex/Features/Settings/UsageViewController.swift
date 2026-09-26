import Charts
import SwiftUI
import TodexCore
import UIKit

/// Runtime contract: one confirmed record per turn, with provider/model and optional numeric
/// inputTokens/outputTokens/cachedInputTokens/cacheWriteTokens/totalTokens, cacheSemantics,
/// and updatedAt (ISO 8601 or Unix milliseconds). Missing values never become zero.
/// Records come from AppSession's per-backend usage ledger, so closed
/// conversations still count; the view follows the ledger while it is open.
@MainActor
final class UsageViewController: SettingsListController {
    private var records: [JSONValue]
    private var provider: String?
    private var model: String?
    private weak var session: AppSession?
    private var observer: UUID?
    private var renderedRevision: Int?

    init(records: [JSONValue], session: AppSession? = nil) {
        self.records = records
        self.session = session
        super.init(title: String(localized: "使用统计"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        observer = session?.observe { [weak self] in
            guard let self, let session else { return }
            guard session.usageRevision != renderedRevision else { return }
            renderedRevision = session.usageRevision
            update(records: session.usageRecords)
        }
    }

    isolated deinit { if let observer { session?.removeObserver(observer) } }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        guard row.id.hasPrefix("usage.chart.") else { return super.tableView(tableView, cellForRowAt: indexPath) }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = row.id
        let rows = filtered
        if row.id == "usage.chart.daily" {
            cell.contentConfiguration = UIHostingConfiguration { UsageDailyChart(days: UsageCalculation.daily(rows)) }
        } else {
            let composition = UsageCalculation.cacheComposition(rows)
            let rate = UsageCalculation.cacheRate(rows).rate
            cell.contentConfiguration = UIHostingConfiguration {
                UsageCacheChart(slices: composition.slices, count: composition.count, total: rows.count, rate: rate)
            }
        }
        return cell
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
        guard let value = record[key].optionalString, !value.isEmpty else { return String(localized: "未知") }
        return value
    }

    private func filter(_ key: String) {
        let values = Array(Set((key == "provider" ? records : providerRecords).map { Self.name($0, key) })).sorted()
        let selected = key == "provider" ? provider : model
        let choices = [("all", String(localized: "全部"))] + values.enumerated().map { (String($0.offset), $0.element) }
        choose(
            title: key == "provider" ? "Provider" : String(localized: "模型"), choices: choices,
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
                title: String(localized: "筛选"),
                footer: String(localized: "统计本机为此后端保存的已确认用量记录（含已关闭的对话，最多保留最近 2000 条），不代表账户余额或剩余额度。未报告的数据保留为未知。"),
                rows: [
                    SettingsRow(title: "Provider", detail: provider ?? String(localized: "全部"), id: "usage.filter.provider") {
                        [weak self] in self?.filter("provider")
                    },
                    SettingsRow(title: String(localized: "模型"), detail: model ?? String(localized: "全部"), id: "usage.filter.model") { [weak self] in
                        self?.filter("model")
                    },
                ])
        ]
        guard !rows.isEmpty else {
            sections.append(
                SettingsSection(
                    title: String(localized: "用量"),
                    rows: [
                        SettingsRow(
                            title: String(localized: "暂无用量记录"), detail: String(localized: "Agent 返回 usage 后，可在此查看已确认的统计。"), symbol: "chart.bar",
                            id: "usage.empty")
                    ]))
            redraw()
            return
        }
        let metrics: [(String, String, (JSONValue) -> Double?)] = [
            (String(localized: "总用量"), "total", UsageCalculation.total),
            (String(localized: "输入 tokens"), "input", { UsageCalculation.number($0, "inputTokens") }),
            (String(localized: "输出 tokens"), "output", { UsageCalculation.number($0, "outputTokens") }),
            (String(localized: "缓存读取"), "cacheRead", { UsageCalculation.number($0, "cachedInputTokens") }),
            (String(localized: "缓存写入"), "cacheWrite", { UsageCalculation.number($0, "cacheWriteTokens") }),
        ]
        sections.append(
            SettingsSection(
                title: String(localized: "\(rows.count) 条记录"), footer: String(localized: "缓存 included 时属于输入；additional 时另计。缺少总量且缓存口径未知的记录不推算总量。"),
                rows: metrics.map { label, key, metric in
                    let summary = UsageCalculation.summary(rows, metric: metric)
                    return SettingsRow(
                        title: String(localized: "\(label)：\(summary.value)"), detail: summary.detail, id: "usage.metric.\(key)")
                }))
        sections.append(
            SettingsSection(
                title: String(localized: "趋势与缓存构成"),
                rows: [
                    SettingsRow(title: String(localized: "每日用量"), id: "usage.chart.daily"),
                    SettingsRow(title: String(localized: "缓存构成"), id: "usage.chart.cache"),
                ]))
        let cache = UsageCalculation.cacheRate(rows)
        sections.append(
            SettingsSection(
                title: String(localized: "缓存与记录"),
                rows: [
                    SettingsRow(
                        title: String(localized: "缓存命中率：\(cache.rate.map { String(format: "%.1f%%", $0 * 100) } ?? String(localized: "未知"))"),
                        detail: String(localized: "\(cache.count)/\(rows.count) 条记录的缓存口径和输入明细可确认"), id: "usage.cacheRate"),
                    SettingsRow(
                        title: String(localized: "最近更新"),
                        detail: rows.compactMap(UsageCalculation.date).max().map {
                            $0.formatted(date: .abbreviated, time: .standard)
                        } ?? String(localized: "未知"), id: "usage.updatedAt"),
                    SettingsRow(
                        title: String(localized: "模型数"),
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
            sections.append(SettingsSection(title: key == "provider" ? String(localized: "按 Provider 汇总") : String(localized: "按模型汇总"), rows: groupedRows))
        }
        sections.append(
            SettingsSection(
                title: String(localized: "记录明细"),
                rows: rows.enumerated().map { index, record in
                    SettingsRow(
                        title: "\(Self.name(record, "provider")) · \(Self.name(record, "model"))",
                        detail: String(localized: "\(UsageCalculation.total(record).map(UsageCalculation.format) ?? String(localized: "未知")) tokens"),
                        id: "usage.record.\(index)"
                    ) { [weak self] in
                        self?.navigationController?.pushViewController(
                            SettingsTextController(title: String(localized: "用量记录"), text: record.prettyPrinted), animated: true)
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
        guard !known.isEmpty else { return (String(localized: "未知"), String(localized: "\(records.count) 条记录尚无可确认数值")) }
        let sum = known.reduce(0, +)
        guard sum.isFinite else { return (String(localized: "未知"), String(localized: "数值超出可汇总范围")) }
        let complete = known.count == records.count
        return (
            format(sum) + (complete ? "" : String(localized: "（已知部分）")),
            complete
                ? String(localized: "\(known.count) 条记录已报告") : String(localized: "\(known.count)/\(records.count) 条已报告，另有 \(records.count - known.count) 条未知")
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

    struct Day: Identifiable, Sendable {
        let date: Date
        var total = 0.0
        var unknown = 0
        var id: Date { date }
    }

    /// Known totals per local calendar day for the trailing `days`, oldest
    /// first. Records without a total are counted separately, never as zero.
    static func daily(_ records: [JSONValue], days: Int = 14, now: Date = Date(), calendar: Calendar = .current)
        -> [Day]
    {
        let today = calendar.startOfDay(for: now)
        guard days > 0, let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var buckets = (0..<days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.map { Day(date: $0) }
        for record in records {
            guard let date = date(record), date >= start,
                let index = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day,
                buckets.indices.contains(index)
            else { continue }
            if let total = total(record) { buckets[index].total += total } else { buckets[index].unknown += 1 }
        }
        return buckets
    }

    struct CacheSlice: Identifiable, Sendable {
        let label: String
        let value: Double
        var id: String { label }
    }

    /// Input split into uncached / cache read / cache write over records whose
    /// cache semantics are known, on the same base as `cacheRate`.
    static func cacheComposition(_ records: [JSONValue]) -> (slices: [CacheSlice], count: Int) {
        var uncached = 0.0
        var read = 0.0
        var write = 0.0
        var count = 0
        for record in records {
            guard let input = number(record, "inputTokens"), let cached = number(record, "cachedInputTokens") else {
                continue
            }
            switch record["cacheSemantics"].stringValue {
            case "included":
                guard cached <= input else { continue }
                uncached += input - cached
                read += cached
            case "additional":
                guard let written = number(record, "cacheWriteTokens") else { continue }
                uncached += input
                read += cached
                write += written
            default: continue
            }
            count += 1
        }
        let slices = [(String(localized: "未缓存输入"), uncached), (String(localized: "缓存读取"), read), (String(localized: "缓存写入"), write)]
            .filter { $0.1 > 0 && $0.1.isFinite }.map { CacheSlice(label: $0.0, value: $0.1) }
        return (slices, count)
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

private func compactTokens(_ value: Double) -> String {
    value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
}

private struct UsageDailyChart: View {
    let days: [UsageCalculation.Day]

    var body: some View {
        let unknown = days.reduce(0) { $0 + $1.unknown }
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "最近 14 天")).font(.headline)
            Text(
                unknown == 0
                    ? String(localized: "按记录更新时间的本地日期汇总已确认的 token 总量。")
                    : String(localized: "按本地日期汇总已确认的 token 总量；另有 \(unknown) 条记录未报告总量，未计入柱高。")
            )
            .font(.footnote).foregroundStyle(.secondary)
            Chart(days) { day in
                BarMark(x: .value(String(localized: "日期"), day.date, unit: .day), y: .value("Tokens", day.total))
                    .foregroundStyle(Color(Theme.accent))
                    .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue("\(UsageCalculation.format(day.total)) tokens")
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let tokens = value.as(Double.self) { Text(compactTokens(tokens)) } }
                }
            }
            .frame(height: 180)
        }
        .padding(.vertical, 8)
    }
}

private struct UsageCacheChart: View {
    let slices: [UsageCalculation.CacheSlice]
    let count: Int
    let total: Int
    let rate: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "缓存构成")).font(.headline)
            Text(String(localized: "仅计算已知缓存计数口径的记录（\(count)/\(total) 条）；旧记录或未知口径不参与比例计算。"))
                .font(.footnote).foregroundStyle(.secondary)
            if slices.isEmpty {
                Text(String(localized: "缓存口径待确认")).font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(slices) { slice in
                    SectorMark(angle: .value("Tokens", slice.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(by: .value(String(localized: "构成"), slice.label))
                        .accessibilityLabel(slice.label)
                        .accessibilityValue("\(UsageCalculation.format(slice.value)) tokens")
                }
                .chartForegroundStyleScale([
                    String(localized: "未缓存输入"): Color(Theme.accent), String(localized: "缓存读取"): Color.orange, String(localized: "缓存写入"): Color.gray,
                ])
                .chartBackground { proxy in
                    GeometryReader { geometry in
                        if let plot = proxy.plotFrame {
                            let frame = geometry[plot]
                            VStack(spacing: 2) {
                                Text(rate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                                    .font(.title3.weight(.semibold)).monospacedDigit()
                                Text(String(localized: "缓存命中率")).font(.caption2).foregroundStyle(.secondary)
                            }
                            .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .frame(height: 200)
            }
        }
        .padding(.vertical, 8)
    }
}
