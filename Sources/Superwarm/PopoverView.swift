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
                EfficiencyLine(footprint: summary.footprint)
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
        let picks = Equivalents.highlights(for: grams, grid: settings.grid, settings: settings.equivalents, limit: 3)
        HStack(alignment: .top, spacing: 0) {
            ForEach(picks) { e in
                let (value, label) = phrasing(e, units: e.units(for: grams))
                VStack(alignment: .leading, spacing: 3) {
                    Image(systemName: e.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.moss)
                    Text(value)
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(e.phrase(for: grams) + ". " + e.note)
            }
        }
    }

    /// Short labels; fractions of one thing read as a percentage.
    private func phrasing(_ e: Equivalent, units n: Double) -> (String, String) {
        let short: [String: (String, String)] = [
            "car-mile": ("mile driven", "miles driven"),
            "commute": ("commute", "commutes"),
            "kettle": ("kettle boil", "kettle boils"),
            "phone": ("phone charge", "phone charges"),
            "streaming": ("hour streaming", "hours streaming"),
            "flight-km": ("km flown", "km flown"),
            "gasoline": ("gallon of gas", "gallons of gas"),
            "burger": ("burger", "burgers"),
            "us-day": ("day of a US life", "days of a US life"),
            "tree": ("tree-decade", "tree-decades"),
            "gemini-prompt": ("chat prompt", "chat prompts"),
        ]
        let (one, many) = short[e.id] ?? (e.singular, e.plural)
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

// MARK: - Efficiency

struct EfficiencyLine: View {
    let footprint: Footprint

    var body: some View {
        let baseline = footprint.baselineCO2Grams
        let saved = footprint.efficiencyDividendGrams
        let percent = baseline > 0 ? Int((saved / baseline * 100).rounded()) : 0
        HStack(spacing: 8) {
            Image(systemName: "leaf.fill").foregroundStyle(Theme.moss)
            if saved >= 0 {
                Text("\(percent)% lower than on 2024 models")
                Spacer()
                Text("−\(Format.grams(saved))").foregroundStyle(Theme.moss).monospacedDigit()
            } else {
                Text("Higher than on 2024 models")
                Spacer()
                Text("+\(Format.grams(-saved))").foregroundStyle(Theme.clay).monospacedDigit()
            }
        }
        .font(.callout)
        .help("The same tokens on 2024-era models of the same size would have emitted \(Format.grams(baseline)). Assumes energy per token falls ~1.7× per year. See How this is estimated.")
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
