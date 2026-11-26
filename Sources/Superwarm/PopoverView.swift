import AppKit
import Charts
import SwiftUI
import SuperwarmCore

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    static let size = CGSize(width: 440, height: 560)

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: Logo.template(size: 18))
                    .foregroundStyle(Theme.clay)
                Picker("Period", selection: $model.period) {
                    ForEach(Period.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                content
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)

            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder
    private var content: some View {
        if model.report == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if model.summary.responses == 0 {
            Text("No usage in this period.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            let summary = model.summary
            VStack(alignment: .leading, spacing: 22) {
                Hero(footprint: summary.footprint)
                EquivalentsRow(grams: summary.footprint.co2Grams.central, settings: model.settings)
                TimelineChart()
                ComparisonsList()
                ModelsList()
            }
            .padding(.top, 6)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let issue = model.issues.first {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.clay)
                    .help(issue)
            }
            if model.isScanning {
                ProgressView().controlSize(.mini)
            }
            if let year = YearInReview.seasonalYear(), model.report != nil {
                Button {
                    openWindow(id: "year-in-review")
                    NSApp.activate()
                } label: {
                    Label("Your \(String(year)) in carbon", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Theme.clay)
                }
                .help("Your year in review")
            }
            Spacer()
            Button {
                openWindow(id: "methodology")
                NSApp.activate()
            } label: {
                Image(systemName: "info.circle")
            }
            .help("How this is estimated")
            Button {
                openSettings()
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

// MARK: - Hero

struct Hero: View {
    let footprint: Footprint

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.grams(footprint.co2Grams.central))
                    .font(.system(size: 42, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("CO₂e")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Text("\(Format.grams(footprint.co2Grams.low))–\(Format.grams(footprint.co2Grams.high)) likely · \(Format.energy(wh: footprint.energyWh.central))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Equivalents

struct EquivalentsRow: View {
    let grams: Double
    let settings: AppSettings

    var body: some View {
        let picks = Equivalents.headline(for: grams, grid: settings.grid, settings: settings.equivalents)
        HStack(spacing: 0) {
            ForEach(Array(picks.enumerated()), id: \.element.id) { index, e in
                if index > 0 {
                    Divider().frame(height: 44)
                }
                let (value, label) = phrasing(e, units: e.units(for: grams))
                VStack(spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: e.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.moss)
                        Text(value)
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                    }
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .help(e.phrase(for: grams) + ". " + e.note)
            }
        }
    }

    /// Short labels. Fractions of one thing read as a percentage, and less
    /// than an hour of home electricity reads in minutes.
    private func phrasing(_ e: Equivalent, units n: Double) -> (String, String) {
        let short: [String: (String, String)] = [
            "commute": ("commute", "commutes"),
            "burger": ("beef burger", "beef burgers"),
            "home-hour": ("hour of home power", "hours of home power"),
            "home-day": ("day of home power", "days of home power"),
        ]
        let (one, many) = short[e.id] ?? (e.singular, e.plural)
        if e.id == "home-hour" && n < 1 {
            return ("\(max(1, Int((n * 60).rounded()))) min", "of home power")
        }
        if n < 1 && n >= 0.005 {
            return ("\(Int((n * 100).rounded()))%", "of a \(one)")
        }
        return (Format.count(n), abs(n - 1) < 0.05 ? one : many)
    }
}

// MARK: - Timeline

struct TimelineChart: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Date?

    var body: some View {
        let unit = UsageReport.bucket(for: model.period)
        let points = model.report?.timeline(in: model.interval, by: unit) ?? []
        let providers = Provider.allCases.filter { p in points.contains { $0.provider == p } }
        VStack(alignment: .leading, spacing: 6) {
            Chart(points) { point in
                BarMark(
                    x: .value("Time", point.start, unit: unit),
                    y: .value("CO₂e (g)", point.co2Grams)
                )
                .foregroundStyle(by: .value("Tool", point.provider.displayName))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale(domain: Provider.allCases.map(\.displayName),
                                       range: Provider.allCases.map(Theme.color(for:)))
            .chartLegend(.hidden)
            .chartXSelection(value: $selection)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let grams = value.as(Double.self) { Text(Format.grams(grams)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: axisFormat(unit))
                }
            }
            .frame(height: 120)

            HStack(spacing: 12) {
                if providers.count > 1 {
                    ForEach(providers, id: \.self) { provider in
                        HStack(spacing: 4) {
                            Circle().fill(Theme.color(for: provider)).frame(width: 7, height: 7)
                            Text(provider.displayName)
                        }
                    }
                }
                Spacer()
                if let hovered = hoveredBucket(points: points, unit: unit) {
                    Text(hovered).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 14)
        }
    }

    private func axisFormat(_ unit: Calendar.Component) -> Date.FormatStyle {
        switch unit {
        case .hour: .dateTime.hour()
        case .day, .weekOfYear: .dateTime.month(.abbreviated).day()
        default: .dateTime.month(.abbreviated)
        }
    }

    private func hoveredBucket(points: [TimelinePoint], unit: Calendar.Component) -> String? {
        guard let selection else { return nil }
        let matching = points.filter { Calendar.current.isDate($0.start, equalTo: selection, toGranularity: unit) }
        guard let first = matching.first else { return nil }
        let total = matching.reduce(0) { $0 + $1.co2Grams }
        let when = first.start.formatted(unit == .hour ? .dateTime.hour() : .dateTime.month(.abbreviated).day())
        return "\(when) · \(Format.grams(total))"
    }
}

// MARK: - Comparisons

struct ComparisonsList: View {
    @Environment(AppModel.self) private var model

    struct Row: Identifiable {
        let id: String
        let symbol: String
        let text: String
        let delta: Double
        let help: String
        /// A what-if suggestion rather than something that happened: neutral
        /// styling and no signed delta.
        var isTip = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.symbol)
                        .foregroundStyle(row.isTip ? AnyShapeStyle(.secondary) : AnyShapeStyle(row.delta <= 0 ? Theme.moss : Theme.clay))
                        .frame(width: 18)
                    Text(row.text)
                        .lineLimit(1)
                    Spacer()
                    if row.isTip {
                        Text("could save \(Format.grams(abs(row.delta)))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text((row.delta <= 0 ? "−" : "+") + Format.grams(abs(row.delta)))
                            .foregroundStyle(row.delta <= 0 ? Theme.moss : Theme.clay)
                            .monospacedDigit()
                    }
                }
                .font(.callout)
                .help(row.help)
            }
        }
    }

    private var rows: [Row] {
        guard let report = model.report else { return [] }
        let summary = model.summary
        let current = summary.footprint.co2Grams.central
        var rows: [Row] = []

        // Newer models vs the same work on 2024-era models.
        let baseline = summary.footprint.baselineCO2Grams
        if baseline > 0 {
            rows.append(Row(
                id: "generation", symbol: "leaf.fill",
                text: relative(current, to: baseline, than: "than on 2024 models"),
                delta: current - baseline,
                help: "The same tokens on 2024-era models of the same size would have emitted \(Format.grams(baseline)). Assumes energy per token falls ~1.7× per year."
            ))
        }

        // This period vs the one before, cut off at the same point. Skipped when
        // the logs don't reach back over the whole earlier window.
        let firstRecord = report.entries.lazy.map(\.record.timestamp).min()
        if let label = model.period.previousLabel,
           let previousInterval = model.period.previousInterval(),
           let firstRecord, firstRecord <= previousInterval.start {
            let previous = report.summary(in: previousInterval).footprint.co2Grams.central
            if previous > 0 {
                rows.append(Row(
                    id: "previous", symbol: current <= previous ? "arrow.down.right" : "arrow.up.right",
                    text: relative(current, to: previous, than: "than \(label)"),
                    delta: current - previous,
                    help: "\(Format.grams(previous)) over the same stretch of \(label)."
                ))
            }
        }

        // Tip: the large-model work on mid-size models. A what-if, not an achievement.
        let swap = report.whatIf(tier: .large, as: .medium, in: model.interval)
        if swap.actual > 0 {
            let saving = swap.actual - swap.alternative
            let largeModels = report.byModel(in: model.interval).filter { $0.profile.tier == .large }
            let allClaude = largeModels.allSatisfy { $0.profile.id.contains("opus") }
            rows.append(Row(
                id: "tier", symbol: "lightbulb",
                text: allClaude ? "Sonnet-size models instead of Opus" : "Mid-size models instead of flagships",
                delta: -saving,
                help: "Your work on large models emitted \(Format.grams(swap.actual)). The same tokens on mid-size models (Sonnet-class) would be about \(Format.grams(swap.alternative)). That assumes the smaller model could do the same work in the same number of tokens, which holds for routine tasks but not always for hard ones.",
                isTip: true
            ))
        }
        return rows
    }

    private func relative(_ value: Double, to reference: Double, than phrase: String) -> String {
        let change = (value - reference) / reference * 100
        let percent = Int(abs(change).rounded())
        let bare = phrase.hasPrefix("than ") ? String(phrase.dropFirst(5)) : phrase
        if percent == 0 { return "Same as \(bare)" }
        if change >= 100 { return "\(Format.count(value / reference))× \(bare)" }
        return "\(percent)% \(change < 0 ? "lower" : "higher") \(phrase)"
    }
}

// MARK: - Models

struct ModelsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = Array((model.report?.byModel(in: model.interval) ?? []).prefix(5))
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                HStack {
                    Circle()
                        .fill(Theme.color(for: row.provider))
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(row.provider.displayName)
                    Text(row.profile.displayName).lineLimit(1)
                    Spacer()
                    Text(Format.grams(row.summary.footprint.co2Grams.central))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.vertical, 7)
                .help("\(row.profile.tier.displayName) model · \(String(format: "%.2f", row.gramsPerThousandOutput)) g per 1k output tokens")
            }
        }
    }
}
