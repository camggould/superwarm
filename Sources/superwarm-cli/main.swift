import Foundation
import SuperwarmCore

// superwarm-cli [today|week|month|year|all] [--no-cache]
let args = CommandLine.arguments.dropFirst()
let period: Period = switch args.first(where: { !$0.hasPrefix("--") }) {
case "today": .today
case "week": .week
case "year": .year
case "all": .allTime
default: .month
}

var cache = args.contains("--no-cache") ? ScanCache() : ScanCache.load()
let started = Date()
let scan = UsageScanner().scan(cache: &cache)
try? cache.save()
let elapsed = Date().timeIntervalSince(started)

let model = EmissionsModel()
let report = UsageReport(records: scan.records, model: model, overrides: ModelOverride.load())
let interval = period.interval()
let summary = report.summary(in: interval)
let fp = summary.footprint

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

print("Superwarm — \(period.label)")
print("Scanned \(scan.filesFound) files (\(scan.filesParsed) re-parsed) in \(String(format: "%.1f", elapsed))s, \(scan.records.count) responses total")
for issue in scan.issues.prefix(5) { print("  ! \(issue)") }
print("")
print("CO2e    \(Format.grams(fp.co2Grams.central))  (90% range \(Format.grams(fp.co2Grams.low)) – \(Format.grams(fp.co2Grams.high)))")
print("Energy  \(Format.energy(wh: fp.energyWh.central))")
print("Tokens  out \(Format.tokens(summary.tokens.output)) · in \(Format.tokens(summary.tokens.input)) · cache write \(Format.tokens(summary.tokens.cacheWrite)) · cache read \(Format.tokens(summary.tokens.cacheRead))")
print("Efficiency dividend vs 2024-era models: \(Format.grams(fp.efficiencyDividendGrams)) avoided (baseline \(Format.grams(fp.baselineCO2Grams)))")
print("")
print("That's about:")
for e in Equivalents.highlights(for: fp.co2Grams.central, grid: model.grid, settings: EquivalentSettings(), limit: 6) {
    print("  • \(e.phrase(for: fp.co2Grams.central))")
}
print("")
print(pad("Model", 34) + pad("Tier", 9) + pad("Gen", 12) + pad("CO2e", 11) + "g/1k out")
let df = DateFormatter()
df.dateFormat = "yyyy-MM"
for m in report.byModel(in: interval).prefix(12) {
    let gen = df.string(from: m.profile.generation) + (m.profile.generationSource == .firstSeen ? "*" : m.profile.generationSource == .override ? "†" : "")
    print(pad(m.profile.displayName, 34) + pad(m.profile.tier.displayName, 9) + pad(gen, 12)
          + pad(Format.grams(m.summary.footprint.co2Grams.central), 11) + String(format: "%.3f", m.gramsPerThousandOutput))
}
print("* generation inferred from first appearance in your logs  † from models.json override")
