import SwiftUI
import SuperwarmCore

struct MethodologyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let c = model.report?.model.coefficients ?? EnergyCoefficients()
        let grid = model.settings.grid
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("How the estimate works") {
                    Text("Superwarm reads the token counts your coding agents already log locally. Nothing leaves your Mac. Each response is converted to energy, then to carbon:")
                    Text("CO₂e = Wh/token × tier × trend × tokens × PUE × grid intensity")
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                    Text("Output tokens are the expensive part: each one is a full forward pass. Uncached input (prefill) is processed in parallel and costs a fraction as much per token. Prompt-cache reads skip most of that work. Agentic coding reads millions of cached tokens per session, so this weighting matters.")
                }

                section("Assumptions") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        row("Large model, 2024 generation", "\(fmt(c.baseWhPer1kOutput.central)) Wh / 1k output tokens", spread: c.baseWhPer1kOutput.spread)
                        row("Medium tier (Sonnet-class)", "× \(fmt(c.tierMultiplier[.medium]!.central))", spread: c.tierMultiplier[.medium]!.spread)
                        row("Small tier (Haiku / mini)", "× \(fmt(c.tierMultiplier[.small]!.central))", spread: c.tierMultiplier[.small]!.spread)
                        row("Uncached input token", "× \(fmt(c.inputToOutputRatio.central)) of an output token", spread: c.inputToOutputRatio.spread)
                        row("Cache read", "× \(fmt(c.cacheReadToInputRatio.central)) of an input token", spread: c.cacheReadToInputRatio.spread)
                        row("Cache write", "× \(fmt(c.cacheWriteToInputRatio.central)) of an input token", spread: c.cacheWriteToInputRatio.spread)
                        row("Efficiency trend", "× \(fmt(c.annualEfficiencyFactor.central)) per year of model generation", spread: c.annualEfficiencyFactor.spread)
                        row("PUE", fmt(grid.pue), spread: nil)
                        row("Grid intensity", "\(Int(grid.gramsCO2PerKWh)) g CO₂e / kWh", spread: nil)
                    }
                    Text("Ranges show an approximate 90% interval. Each assumption's uncertainty is combined in log space, and the range widens the further the efficiency trend is extrapolated.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }

                section("Why newer models are cheaper per token") {
                    Text("Google measured a 33× drop in energy per median Gemini prompt over 12 months (May 2024 → May 2025). Measured per-token energy on B200 is ~1.7× better than H100, and H200 uses 0.61–0.84× of H100's energy. Software gains add to this: FP8/FP4 inference, speculative decoding, mixture-of-experts and better batching. Superwarm assumes a conservative 1.7× per year, well below Google's figure. The \"efficiency dividend\" shows what the same tokens would have cost on 2024-era models of the same tier.")
                }

                section("What's not included") {
                    Text("• Training, amortised over a model's lifetime (Mistral's LCA attributes most of its lifecycle emissions to training and inference combined).\n• Embodied emissions from manufacturing GPUs and buildings.\n• Water use.\n• Your own laptop and network.\n• Market-based renewable purchases: the grid figure is location-based. Choose a low-carbon preset if you know your provider's region.")
                }

                section("Sources") {
                    ForEach(Citations.all) { citation in
                        VStack(alignment: .leading, spacing: 2) {
                            Link("\(citation.title)", destination: citation.url)
                            Text("\(citation.publisher), \(String(citation.year)). \(citation.usedFor)")
                                .font(.caption)
                                .foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .foregroundStyle(Theme.ink)
        .background(LinearGradient(colors: [Theme.paperTop, Theme.paperBottom], startPoint: .top, endPoint: .bottom))
        .tint(Theme.lake)
        .frame(width: 600, height: 680)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 19, weight: .semibold, design: .serif))
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ label: String, _ value: String, spread: Double?) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.inkSecondary)
            Text(value).monospacedDigit()
            Text(spread.map { $0 > 1.0001 ? "×÷ \(fmt($0))" : "" } ?? "").foregroundStyle(Theme.inkTertiary)
        }
    }

    private func fmt(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(1...3)))
    }
}
