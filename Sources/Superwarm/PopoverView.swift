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
        VStack(alignment: .leading, spacing: 12) {
            header
            PeriodPicker(selection: $model.period)

            if model.report == nil {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading your coding-agent logs…")
                        .font(.callout)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else if model.summary.responses == 0 {
                emptyState
            } else {
                HeroCard(summary: model.summary)
                EquivalentsGrid(grams: model.summary.footprint.co2Grams.central, settings: model.settings)
                TimelineCard()
                EfficiencyCard(footprint: model.summary.footprint)
                ModelsCard()
            }
            footer
        }
        .padding(16)
        .frame(width: 400)
        .foregroundStyle(Theme.ink)
        .background(
            LinearGradient(colors: [Theme.paperTop, Theme.paperBottom], startPoint: .top, endPoint: .bottom)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: Logo.template(size: 17))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Theme.logoTile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text("Superwarm").font(Theme.title)
                Text("The carbon cost of your coding agents")
                    .font(.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Group {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Rescan logs")
                }
            }
            .frame(width: 26, height: 26)
            .buttonStyle(IconButtonStyle())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "leaf")
                .font(.system(size: 28))
                .foregroundStyle(Theme.moss)
            Text("Nothing in this period").font(Theme.title)
            Text("Superwarm reads Claude Code logs in ~/.claude/projects and Codex logs in ~/.codex/sessions.")
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .card()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.issues.prefix(2), id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.clay)
            }
            HStack(spacing: 4) {
                if let last = model.lastScan {
                    Text("Updated \(last.formatted(date: .omitted, time: .shortened)) · \(model.filesFound) logs")
                        .font(.caption)
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                Button {
                    openWindow(id: "methodology")
                    NSApp.activate()
                } label: {
                    Label("Methodology", systemImage: "book.closed")
                }
                .help("How the estimate works, with sources")
                Button {
                    openSettings()
                    NSApp.activate()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Superwarm")
            }
            .buttonStyle(IconButtonStyle())
        }
        .padding(.top, 2)
    }
}

// MARK: - Controls

struct IconButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Theme.track.opacity(hovering || configuration.isPressed ? 1 : 0))
            )
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

/// Pill segmented control on a soft track.
struct PeriodPicker: View {
    @Binding var selection: Period
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Period.allCases) { period in
                let selected = period == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = period }
                } label: {
                    Text(period.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.paperTop : Theme.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Theme.ink)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.track, in: Capsule())
    }
}

// MARK: - Hero

struct HeroCard: View {
    let summary: Summary

    var body: some View {
        let fp = summary.footprint
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Estimated emissions")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.grams(fp.co2Grams.central))
                    .font(Theme.display(44))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("CO₂e")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Format.energy(wh: fp.energyWh.central))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("electricity")
                        .font(.caption2)
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            RangeBar(interval: fp.co2Grams)
            HStack(spacing: 6) {
                TokenChip(label: "output", value: summary.tokens.output)
                TokenChip(label: "input", value: summary.tokens.input + summary.tokens.cacheWrite)
                TokenChip(label: "cached", value: summary.tokens.cacheRead)
                Spacer(minLength: 0)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// The 90% interval drawn on a log scale, with the central estimate marked.
struct RangeBar: View {
    let interval: Interval

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let lo = log(max(interval.low, 1e-9))
                let hi = log(max(interval.high, 1e-9))
                let mid = log(max(interval.central, 1e-9))
                let t = hi > lo ? (mid - lo) / (hi - lo) : 0.5
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.sageWash, Theme.clayWash, Theme.sageWash],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 6)
                    Circle()
                        .fill(Theme.clay)
                        .overlay(Circle().strokeBorder(Theme.card, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .offset(x: geo.size.width * t - 6)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)
            HStack {
                Text(Format.grams(interval.low))
                Spacer()
                Text("likely range")
                Spacer()
                Text(Format.grams(interval.high))
            }
            .font(.caption2)
            .foregroundStyle(Theme.inkTertiary)
            .monospacedDigit()
        }
    }
}

struct TokenChip: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 3) {
            Text(Format.tokens(value)).fontWeight(.semibold).monospacedDigit()
            Text(label).foregroundStyle(Theme.inkSecondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.track, in: Capsule())
    }
}

// MARK: - Equivalents

struct EquivalentsGrid: View {
    let grams: Double
    let settings: AppSettings

    var body: some View {
        let picks = Equivalents.highlights(for: grams, grid: settings.grid, settings: settings.equivalents, limit: 4)
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("That's about the same as")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(picks) { e in
                    let n = e.units(for: grams)
                    let (value, caption) = phrasing(e, units: n)
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: e.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.moss)
                            .frame(width: 30, height: 30)
                            .background(Theme.mossWash, in: Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text(value)
                                .font(.system(size: 17, weight: .semibold, design: .serif))
                                .monospacedDigit()
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                    .help("\(e.note) Source: \(e.citation.publisher), \(e.citation.title)")
                }
            }
        }
    }

    /// Fractions of a single everyday thing read better as a percentage.
    private func phrasing(_ e: Equivalent, units n: Double) -> (String, String) {
        if n < 1 && n >= 0.005 {
            return ("\(Int((n * 100).rounded()))%", e.id == "commute" ? "of your commute" : "of a \(e.singular)")
        }
        return (Format.count(n), abs(n - 1) < 0.05 ? e.singular : e.plural)
    }
}

// MARK: - Timeline

struct TimelineCard: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Date?

    var body: some View {
        let unit = UsageReport.bucket(for: model.period)
        let points = model.report?.timeline(in: model.interval, by: unit) ?? []
        let providers = Provider.allCases.filter { p in points.contains { $0.provider == p } }
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Emissions per \(unitName(unit))", trailing: hoveredBucket(points: points, unit: unit))
            Chart(points) { point in
                BarMark(
                    x: .value("Time", point.start, unit: unit),
                    y: .value("CO₂e (g)", point.co2Grams)
                )
                .foregroundStyle(by: .value("Tool", point.provider.displayName))
                .cornerRadius(3)
                if let selection, Calendar.current.isDate(point.start, equalTo: selection, toGranularity: unit) {
                    RuleMark(x: .value("Time", point.start, unit: unit))
                        .foregroundStyle(Theme.track)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(domain: Provider.allCases.map(\.displayName),
                                       range: Provider.allCases.map(Theme.color(for:)))
            .chartLegend(.hidden)
            .chartXSelection(value: $selection)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let grams = value.as(Double.self) {
                            Text(Format.grams(grams)).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: axisFormat(unit)).foregroundStyle(Theme.inkTertiary)
                }
            }
            .frame(height: 110)
            if providers.count > 1 {
                HStack(spacing: 14) {
                    ForEach(providers, id: \.self) { provider in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: provider)).frame(width: 10, height: 10)
                            Text(provider.displayName).font(.caption).foregroundStyle(Theme.inkSecondary)
                        }
                    }
                }
            }
        }
        .card()
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
        case .day, .weekOfYear: .dateTime.month(.abbreviated).day()
        default: .dateTime.month(.abbreviated).year(.twoDigits)
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

// MARK: - Efficiency dividend

struct EfficiencyCard: View {
    let footprint: Footprint

    var body: some View {
        let baseline = footprint.baselineCO2Grams
        let actual = footprint.co2Grams.central
        let saved = baseline - actual
        let fraction = baseline > 0 ? saved / baseline : 0
        let scale = max(baseline, actual)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: saved >= 0 ? "leaf.fill" : "flame.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(saved >= 0 ? Theme.moss : Theme.clay)
                    .frame(width: 30, height: 30)
                    .background(saved >= 0 ? Theme.mossWash : Theme.clayWash, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(saved >= 0 ? "Newer models avoided \(Format.grams(saved))" : "Older models added \(Format.grams(-saved))")
                        .font(Theme.title)
                    Text(saved >= 0
                         ? "\(Int((fraction * 100).rounded()))% less than the same work on 2024-era models"
                         : "compared with 2024-era models of the same size")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            VStack(spacing: 6) {
                comparisonBar(label: "2024-era models", value: baseline, scale: scale, fill: Theme.inkTertiary.opacity(0.45))
                comparisonBar(label: "Your models", value: actual, scale: scale, fill: Theme.moss)
            }
        }
        .card(fill: Theme.mossWash)
        .help("Assumes energy per token falls ~1.7× per year of model generation (newer accelerators, low-precision inference, better batching, distillation). See Methodology for sources.")
    }

    private func comparisonBar(label: String, value: Double, scale: Double, fill: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 96, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(fill).frame(width: scale > 0 ? max(6, geo.size.width * value / scale) : 0)
                }
            }
            .frame(height: 8)
            Text(Format.grams(value))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
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
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("By model", trailing: "g / 1k output")
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.color(for: row.provider))
                            .frame(width: 4, height: 26)
                            .accessibilityLabel(row.provider.displayName)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.profile.displayName)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                TierTag(tier: row.profile.tier)
                                Text("\(generationText(row.profile)) · \(Format.grams(row.summary.footprint.co2Grams.central))")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.inkTertiary)
                            }
                        }
                        Spacer()
                        Text(String(format: "%.2f", row.gramsPerThousandOutput))
                            .font(.system(size: 14, weight: .semibold, design: .serif))
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule()
                                .fill(Theme.color(for: row.provider).opacity(0.75))
                                .frame(width: geo.size.width * (total > 0 ? row.summary.footprint.co2Grams.central / total : 0))
                        }
                    }
                    .frame(height: 3)
                    .accessibilityHidden(true)
                }
            }
        }
        .card()
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

struct TierTag: View {
    let tier: ModelTier

    var body: some View {
        Text(tier.displayName.lowercased())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Theme.sage)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.sageWash, in: Capsule())
    }
}
