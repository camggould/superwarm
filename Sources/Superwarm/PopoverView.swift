import AppKit
import Charts
import SwiftUI
import SuperwarmCore

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            header
            Picker("Period", selection: $model.period) {
                ForEach(Period.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.report == nil {
                ProgressView("Reading your coding-agent logs…")
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if model.summary.responses == 0 {
                emptyState
            } else {
                HeroView(summary: model.summary)
                EquivalentsGrid(grams: model.summary.footprint.co2Grams.central, settings: model.settings)
                TimelineCard()
                EfficiencyCard(footprint: model.summary.footprint)
                ModelsCard()
            }
            footer
        }
        .padding(16)
        .frame(width: 400)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: Logo.template(size: 20))
                .foregroundStyle(Palette.ember)
            Text("Superwarm").font(.headline)
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rescan logs")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "leaf").font(.largeTitle).foregroundStyle(.secondary)
            Text("No usage in this period").font(.headline)
            Text("Superwarm reads Claude Code logs in ~/.claude/projects and Codex logs in ~/.codex/sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.issues.prefix(2), id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }
            HStack {
                if let last = model.lastScan {
                    Text("Updated \(last.formatted(date: .omitted, time: .shortened)) · \(model.filesFound) logs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Methodology") {
                    openWindow(id: "methodology")
                    NSApp.activate()
                }
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
                .help("Quit Superwarm")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

// MARK: - Hero

struct HeroView: View {
    let summary: Summary

    var body: some View {
        let fp = summary.footprint
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.grams(fp.co2Grams.central))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("CO₂e").font(.title3).foregroundStyle(.secondary)
            }
            Text("Likely between \(Format.grams(fp.co2Grams.low)) and \(Format.grams(fp.co2Grams.high)) · \(Format.energy(wh: fp.energyWh.central))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("\(Format.tokens(summary.tokens.output)) output · \(Format.tokens(summary.tokens.input + summary.tokens.cacheWrite)) input · \(Format.tokens(summary.tokens.cacheRead)) cached tokens across \(Format.count(Double(summary.responses))) responses")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Equivalents

struct EquivalentsGrid: View {
    let grams: Double
    let settings: AppSettings

    var body: some View {
        let picks = Equivalents.highlights(for: grams, grid: settings.grid, settings: settings.equivalents, limit: 4)
        VStack(alignment: .leading, spacing: 8) {
            Text("That's about").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(picks) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: e.symbol)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Format.count(e.units(for: grams)))
                                .font(.headline)
                                .monospacedDigit()
                            Text(abs(e.units(for: grams) - 1) < 0.05 ? e.singular : e.plural)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .help("\(e.note) Source: \(e.citation.publisher), \(e.citation.title)")
                }
            }
        }
    }
}

// MARK: - Timeline

struct TimelineCard: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Date?

    var body: some View {
        let unit = UsageReport.bucket(for: model.period)
        let points = model.report?.timeline(in: model.interval, by: unit) ?? []
        let providers = Set(points.map(\.provider))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CO₂e per \(unitName(unit))").font(.subheadline.weight(.semibold))
                Spacer()
                if let hovered = hoveredBucket(points: points, unit: unit) {
                    Text(hovered).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Chart(points) { point in
                BarMark(
                    x: .value("Time", point.start, unit: unit),
                    y: .value("CO₂e (g)", point.co2Grams)
                )
                .foregroundStyle(by: .value("Tool", point.provider.displayName))
                .cornerRadius(2)
                if let selection, Calendar.current.isDate(point.start, equalTo: selection, toGranularity: unit) {
                    RuleMark(x: .value("Time", point.start, unit: unit))
                        .foregroundStyle(.secondary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(domain: Provider.allCases.map(\.displayName),
                                       range: Provider.allCases.map(Palette.color(for:)))
            .chartLegend(providers.count > 1 ? .visible : .hidden)
            .chartXSelection(value: $selection)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let grams = value.as(Double.self) { Text(Format.grams(grams)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: axisFormat(unit))
                }
            }
            .frame(height: 120)
        }
    }

    private func unitName(_ unit: Calendar.Component) -> String {
        switch unit {
        case .hour: "hour"
        case .day: "day"
        case .weekOfYear: "week"
        default: "month"
        }
    }

    private func axisFormat(_ unit: Calendar.Component) -> Date.FormatStyle {
        switch unit {
        case .hour: .dateTime.hour()
        case .day: .dateTime.month(.abbreviated).day()
        case .weekOfYear: .dateTime.month(.abbreviated).day()
        default: .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }

    private func hoveredBucket(points: [TimelinePoint], unit: Calendar.Component) -> String? {
        guard let selection else { return nil }
        let matching = points.filter { Calendar.current.isDate($0.start, equalTo: selection, toGranularity: unit) }
        guard let first = matching.first else { return nil }
        let total = matching.reduce(0) { $0 + $1.co2Grams }
        let parts = matching.map { "\($0.provider.displayName) \(Format.grams($0.co2Grams))" }.joined(separator: " · ")
        let when = first.start.formatted(unit == .hour ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
        return matching.count > 1 ? "\(when): \(Format.grams(total)) (\(parts))" : "\(when): \(parts)"
    }
}

// MARK: - Efficiency dividend

struct EfficiencyCard: View {
    let footprint: Footprint

    var body: some View {
        let baseline = footprint.baselineCO2Grams
        let actual = footprint.co2Grams.central
        let saved = baseline - actual
        let fraction = baseline > 0 ? saved / baseline : 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: saved >= 0 ? "arrow.down.right.circle.fill" : "arrow.up.right.circle.fill")
                    .foregroundStyle(saved >= 0 ? Palette.leaf : Palette.ember)
                Text(saved >= 0
                     ? "Newer models avoided \(Format.grams(saved)) (\(Int((fraction * 100).rounded()))%)"
                     : "Older models added \(Format.grams(-saved))")
                    .font(.subheadline.weight(.semibold))
            }
            comparisonBar(label: "Same tokens on 2024-era models", value: baseline, max: max(baseline, actual), style: AnyShapeStyle(.tertiary))
            comparisonBar(label: "Your models", value: actual, max: max(baseline, actual), style: AnyShapeStyle(Palette.ember))
            Text("Serving efficiency improves fast: new accelerators, lower-precision math, better batching and smaller distilled models. Assumes ~1.7× less energy per token each year; see Methodology.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func comparisonBar(label: String, value: Double, max: Double, style: AnyShapeStyle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(Format.grams(value)).font(.caption).monospacedDigit()
            }
            GeometryReader { geo in
                Capsule()
                    .fill(style)
                    .frame(width: max > 0 ? geo.size.width * value / max : 0)
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Models

struct ModelsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = Array((model.report?.byModel(in: model.interval) ?? []).prefix(5))
        let total = rows.reduce(0) { $0 + $1.summary.footprint.co2Grams.central }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("By model").font(.subheadline.weight(.semibold))
                Spacer()
                Text("g CO₂e / 1k output").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Palette.color(for: row.provider))
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(row.provider.displayName)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.profile.displayName).font(.callout).lineLimit(1)
                        Text("\(row.profile.tier.displayName) · \(generationText(row.profile)) · \(Format.grams(row.summary.footprint.co2Grams.central))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.2f", row.gramsPerThousandOutput))
                        .font(.callout)
                        .monospacedDigit()
                    ShareBar(fraction: total > 0 ? row.summary.footprint.co2Grams.central / total : 0)
                        .frame(width: 44, height: 4)
                }
            }
        }
    }

    private func generationText(_ profile: ModelProfile) -> String {
        let date = profile.generation.formatted(.dateTime.month(.abbreviated).year())
        switch profile.generationSource {
        case .catalog: return date
        case .override: return "\(date) (override)"
        case .firstSeen: return "first seen \(date)"
        }
    }
}

struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.secondary).frame(width: geo.size.width * fraction)
            }
        }
        .accessibilityLabel("\(Int((fraction * 100).rounded()))% of period total")
    }
}
