import AppKit
import Charts
import SwiftUI
import SuperwarmCore

/// One full-bleed card in the year-in-review slideshow.
struct Slide: Identifiable {
    enum Accessory {
        case none
        case equivalents([(String, String, String)])  // symbol, value, label
        case months([Double])
    }

    let id: String
    let background: Color
    let lightText: Bool
    let kicker: String
    let headline: String
    let caption: String
    var accessory: Accessory = .none
}

enum SlideDeck {
    static let soil = Color(red: 0.17, green: 0.15, blue: 0.13)
    static let moss = Color(red: 0.25, green: 0.35, blue: 0.18)
    static let clay = Color(red: 0.64, green: 0.28, blue: 0.16)
    static let lake = Color(red: 0.14, green: 0.33, blue: 0.50)
    static let sand = Color(red: 0.88, green: 0.83, blue: 0.73)
    static let forest = Color(red: 0.14, green: 0.22, blue: 0.16)

    static func make(_ r: YearInReview, settings: AppSettings) -> [Slide] {
        guard r.totalGrams > 0 else {
            return [Slide(id: "empty", background: soil, lightText: true, kicker: String(r.year),
                          headline: "Nothing to review yet",
                          caption: "Superwarm found no coding-agent usage for \(String(r.year)).")]
        }
        let grams = r.totalGrams
        let fp = r.summary.footprint
        let all = Equivalents.all(grid: settings.grid, settings: settings.equivalents)
        func units(_ id: String, of amount: Double? = nil) -> Double { all.first { $0.id == id }!.units(for: amount ?? grams) }
        /// Symbol, value and label for an equivalent of `amount` grams.
        func item(_ id: String, _ label: String, of amount: Double? = nil) -> (String, String, String) {
            let e = all.first { $0.id == id }!
            return (e.symbol, friendly(e.units(for: amount ?? grams)), label)
        }
        let monthName: [String] = DateFormatter().monthSymbols ?? []

        var slides: [Slide] = [
            Slide(id: "intro", background: soil, lightText: true, kicker: String(r.year),
                  headline: "Your year in carbon",
                  caption: "What your coding agents cost the planet, and how much newer models helped."),
            Slide(id: "total", background: clay, lightText: true, kicker: "This year your AI emitted",
                  headline: "\(Format.grams(grams)) CO₂e",
                  caption: "Likely between \(Format.grams(fp.co2Grams.low)) and \(Format.grams(fp.co2Grams.high)), across \(Format.count(Double(r.summary.responses))) responses in \(r.projectCount) projects."),
        ]

        let homeDays = units("home-day")
        slides.append(Slide(
            id: "home", background: sand, lightText: false, kicker: "That's the same as",
            headline: homeDays >= 1 ? "\(Format.count(homeDays)) days" : "\(Format.count(units("home-hour"))) hours",
            caption: "of electricity for an average US home.",
            accessory: .equivalents([
                item("commute", "commutes"),
                item("burger", "beef burgers"),
                item("gasoline", "gallons of gas"),
            ])
        ))

        let flights = units("flight-nyc-la")
        slides.append(Slide(
            id: "flight", background: lake, lightText: true, kicker: "In the air, that's",
            headline: flights >= 1 ? "\(friendly(flights)) flights" : "\(percent(flights)) of a flight",
            caption: "from New York to LA, for one passenger. By train, the same carbon would take you \(friendly(units("train-km"))) km."
        ))

        let charges = units("phone")
        let chargeDays = charges / 365.25
        slides.append(Slide(
            id: "phone", background: clay, lightText: true, kicker: "Or charging your iPhone",
            headline: "\(friendly(charges)) times",
            caption: chargeDays >= 1
                ? "That's once a day for \(friendly(chargeDays)) years."
                : "That's once a day for \(Int(charges.rounded())) days."
        ))

        let ledYears = units("led-year")
        slides.append(Slide(
            id: "led", background: soil, lightText: true, kicker: "Or leaving a light on",
            headline: ledYears >= 1 ? "\(friendly(ledYears)) years" : "\(friendly(ledYears * 12)) months",
            caption: "One LED bulb, burning day and night."
        ))

        slides.append(Slide(
            id: "numbers", background: sand, lightText: false, kicker: "By the numbers",
            headline: "Also about",
            caption: "Same carbon, everyday things.",
            accessory: .equivalents([
                item("shower", "hot showers"),
                item("kettle", "kettle boils"),
                item("streaming", "hours of streaming"),
                item("macbook", "MacBook charges"),
                item("train-km", "km by train"),
                item("us-day", "days of a US life"),
            ])
        ))

        slides.append(Slide(
            id: "tokens", background: lake, lightText: true, kicker: "Your agents read",
            headline: "\(Format.tokens(r.tokensRead)) tokens",
            caption: "and wrote \(Format.tokens(r.summary.tokens.output)), about \(Format.count(r.novelsWritten)) novels' worth."
        ))

        if let day = r.busiestDay {
            slides.append(Slide(
                id: "day", background: forest, lightText: true, kicker: "Your heaviest day",
                headline: day.date.formatted(.dateTime.month(.wide).day()),
                caption: "\(Format.grams(day.grams)) in a single day, \(Int((day.grams / grams * 100).rounded()))% of your year."
            ))
        }

        if r.nightShare >= 0.25 {
            slides.append(Slide(
                id: "night", background: soil, lightText: true, kicker: "Night owl",
                headline: "\(Int((r.nightShare * 100).rounded()))%",
                caption: "of your emissions came between 10 pm and 6 am."
            ))
        } else if let hour = r.peakHour {
            let label = Calendar.current.date(from: DateComponents(hour: hour))!.formatted(.dateTime.hour())
            slides.append(Slide(
                id: "peak", background: soil, lightText: true, kicker: "Peak hour",
                headline: label,
                caption: "is when your agents worked hardest."
            ))
        }

        if r.longestStreak > 1 {
            slides.append(Slide(
                id: "streak", background: moss, lightText: true, kicker: "Longest streak",
                headline: "\(r.longestStreak) days",
                caption: "in a row with your agents, and \(r.activeDays) active days in total."
            ))
        }

        if let model = r.topModel {
            slides.append(Slide(
                id: "model", background: clay, lightText: true, kicker: "Your workhorse",
                headline: model.name,
                caption: "carried \(Int((model.fraction * 100).rounded()))% of your footprint."
            ))
        }

        if let project = r.topProject {
            slides.append(Slide(
                id: "project", background: lake, lightText: true, kicker: "Most carbon went into",
                headline: project.name,
                caption: "\(Format.grams(project.grams)), \(Int((project.fraction * 100).rounded()))% of the year."
            ))
        }

        if let month = r.busiestMonth {
            slides.append(Slide(
                id: "months", background: sand, lightText: false, kicker: "Month by month",
                headline: monthName[month - 1],
                caption: "was your biggest month.",
                accessory: .months(r.monthly)
            ))
        }

        if r.dividendGrams > 0 {
            let baseline = fp.baselineCO2Grams
            slides.append(Slide(
                id: "dividend", background: moss, lightText: true, kicker: "Newer models saved",
                headline: Format.grams(r.dividendGrams),
                caption: "\(Int((r.dividendGrams / baseline * 100).rounded()))% less than the same work on 2024-era models. That's the same as skipping:",
                accessory: .equivalents([
                    item("phone", "iPhone charges", of: r.dividendGrams),
                    item("shower", "hot showers", of: r.dividendGrams),
                    item("commute", "commutes", of: r.dividendGrams),
                ])
            ))
        }

        let trees = max(1, Int(units("tree").rounded(.up)))
        slides.append(Slide(
            id: "outro", background: forest, lightText: true, kicker: "To absorb it all",
            headline: "\(trees) \(trees == 1 ? "tree" : "trees")",
            caption: "growing for a decade each. Choosing smaller models when they're enough keeps this number down."
        ))
        return slides
    }

    /// "0.4", "4.1", "1,854", "34,120", "1.2M".
    static func friendly(_ n: Double) -> String {
        let a = abs(n)
        if a >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if a >= 100 { return Int(n.rounded()).formatted(.number.grouping(.automatic)) }
        if a >= 10 { return String(format: "%.0f", n) }
        let text = String(format: "%.1f", n)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func percent(_ fraction: Double) -> String {
        "\(max(1, Int((fraction * 100).rounded())))%"
    }
}

struct SlideView: View {
    let slide: Slide
    let index: Int
    let count: Int

    var body: some View {
        let ink: Color = slide.lightText ? .white : SlideDeck.soil
        ZStack(alignment: .topLeading) {
            slide.background
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(ink.opacity(i <= index ? 0.9 : 0.25))
                            .frame(height: 3)
                    }
                }
                Spacer()
                Text(slide.kicker)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ink.opacity(0.75))
                Text(slide.headline)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(ink)
                    .minimumScaleFactor(0.35)
                    .lineLimit(slide.id == "intro" ? 2 : 1)
                    .padding(.vertical, 6)
                Text(slide.caption)
                    .font(.system(size: 19))
                    .foregroundStyle(ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                accessory(ink: ink)
                    .padding(.top, 28)
                Spacer()
                HStack {
                    Image(nsImage: Logo.template(size: 16))
                        .foregroundStyle(ink.opacity(0.6))
                    Text("Superwarm")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.6))
                    Spacer()
                    Text(index == count - 1 ? "" : "Click or → to continue")
                        .font(.system(size: 12))
                        .foregroundStyle(ink.opacity(0.5))
                }
            }
            .padding(36)
        }
    }

    @ViewBuilder
    private func accessory(ink: Color) -> some View {
        switch slide.accessory {
        case .none:
            EmptyView()
        case .equivalents(let items):
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .topLeading), count: 3),
                      alignment: .leading, spacing: 20) {
                ForEach(items, id: \.2) { symbol, value, label in
                    VStack(alignment: .leading, spacing: 2) {
                        Image(systemName: symbol)
                            .font(.system(size: 18))
                            .frame(height: 22, alignment: .bottomLeading)
                        Text(value).font(.system(size: 26, weight: .bold)).monospacedDigit()
                        Text(label).font(.system(size: 13)).opacity(0.75)
                    }
                    .foregroundStyle(ink)
                }
            }
        case .months(let values):
            let names: [String] = DateFormatter().veryShortMonthSymbols ?? []
            Chart(Array(values.enumerated()), id: \.offset) { item in
                BarMark(
                    x: .value("Month", names.indices.contains(item.offset) ? "\(item.offset):\(names[item.offset])" : "\(item.offset)"),
                    y: .value("CO₂e", item.element)
                )
                .foregroundStyle(ink.opacity(0.85))
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let key = value.as(String.self) {
                            Text(key.split(separator: ":").last.map(String.init) ?? key)
                                .foregroundStyle(ink.opacity(0.7))
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 140)
        }
    }
}

struct YearInReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @FocusState private var focused: Bool

    static let size = CGSize(width: 520, height: 640)

    var body: some View {
        let slides = currentSlides
        Group {
            if slides.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let i = min(index, slides.count - 1)
                SlideView(slide: slides[i], index: i, count: slides.count)
                    .id(slides[i].id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
                    .contentShape(Rectangle())
                    .onTapGesture { advance(count: slides.count) }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { index = 0; focused = true }
        .onKeyPress(.rightArrow) { advance(count: slides.count); return .handled }
        .onKeyPress(.space) { advance(count: slides.count); return .handled }
        .onKeyPress(.leftArrow) {
            withAnimation(.easeInOut(duration: 0.3)) { index = max(0, index - 1) }
            return .handled
        }
    }

    private var currentSlides: [Slide] {
        guard let report = model.report else { return [] }
        let year = YearInReview.seasonalYear() ?? Calendar.current.component(.year, from: Date())
        return SlideDeck.make(YearInReview(report: report, year: year), settings: model.settings)
    }

    private func advance(count: Int) {
        if index >= count - 1 {
            dismiss()
            index = 0
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { index += 1 }
        }
    }
}
