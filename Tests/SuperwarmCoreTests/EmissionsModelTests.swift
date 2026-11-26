import Foundation
import Testing
@testable import SuperwarmCore

@Suite struct EmissionsModelTests {
    let model = EmissionsModel()
    var reference: Date { model.coefficients.referenceGeneration }

    func profile(_ tier: ModelTier, yearsAfterReference years: Double = 0) -> ModelProfile {
        ModelProfile(id: "m", displayName: "m", tier: tier,
                     generation: reference.addingTimeInterval(years * EmissionsModel.secondsPerYear),
                     generationSource: .catalog)
    }

    @Test func baselineOutputMatchesCalibration() {
        // 1,000 output tokens on a large reference model: 0.9 Wh IT × 1.15 PUE.
        let fp = model.footprint(tokens: TokenCounts(output: 1000), profile: profile(.large))
        #expect(abs(fp.energyWh.central - 0.9 * 1.15) < 1e-9)
        #expect(abs(fp.co2Grams.central - 0.9 * 1.15 * 0.373) < 1e-9)
        #expect(fp.co2Grams.low < fp.co2Grams.central && fp.co2Grams.central < fp.co2Grams.high)
        #expect(abs(fp.efficiencyDividendGrams) < 1e-9)
    }

    @Test func tokenKindsAreWeighted() {
        let p = profile(.large)
        let out = model.footprint(tokens: TokenCounts(output: 1000), profile: p).energyWh.central
        let input = model.footprint(tokens: TokenCounts(input: 1000), profile: p).energyWh.central
        let read = model.footprint(tokens: TokenCounts(cacheRead: 1000), profile: p).energyWh.central
        #expect(abs(input / out - 0.2) < 1e-9)
        #expect(abs(read / out - 0.02) < 1e-9)
    }

    @Test func smallerAndNewerModelsEmitLess() {
        let tokens = TokenCounts(input: 100, cacheRead: 50_000, output: 2_000)
        let large = model.footprint(tokens: tokens, profile: profile(.large)).co2Grams.central
        let small = model.footprint(tokens: tokens, profile: profile(.small)).co2Grams.central
        let newer = model.footprint(tokens: tokens, profile: profile(.large, yearsAfterReference: 2))
        #expect(small < large)
        #expect(abs(newer.co2Grams.central - large * 0.36) < 1e-9)
        #expect(newer.efficiencyDividendGrams > 0)
    }

    @Test func uncertaintyWidensWithExtrapolation() {
        let tokens = TokenCounts(output: 1000)
        let now = model.footprint(tokens: tokens, profile: profile(.large))
        let far = model.footprint(tokens: tokens, profile: profile(.large, yearsAfterReference: 3))
        #expect(far.co2Grams.high / far.co2Grams.central > now.co2Grams.high / now.co2Grams.central)
    }

    @Test func trendIsClamped() {
        let tokens = TokenCounts(output: 1000)
        let a = model.footprint(tokens: tokens, profile: profile(.large, yearsAfterReference: 4))
        let b = model.footprint(tokens: tokens, profile: profile(.large, yearsAfterReference: 9))
        #expect(a.co2Grams.central == b.co2Grams.central)
    }

    @Test func gridAndPUEScaleLinearly() {
        let clean = EmissionsModel(grid: GridSettings(gramsCO2PerKWh: 50, pue: 1.1))
        let tokens = TokenCounts(output: 1000)
        let g = clean.footprint(tokens: tokens, profile: profile(.large)).co2Grams.central
        #expect(abs(g - 0.9 * 1.1 * 0.05) < 1e-9)
    }
}
