import Foundation
import Testing
@testable import SuperwarmCore

@Suite struct EquivalentsTests {
    let grid = GridSettings()

    @Test func commuteScalesWithDistance() {
        let e = Equivalents.all(grid: grid, settings: EquivalentSettings(commuteMilesOneWay: 10)).first { $0.id == "commute" }!
        #expect(e.gramsPerUnit == 8_000)
        #expect(e.units(for: 16_000) == 2)
    }

    @Test func gridDependentEquivalentsFollowGrid() {
        let kettle = { (g: GridSettings) in Equivalents.all(grid: g, settings: .init()).first { $0.id == "kettle" }!.gramsPerUnit }
        #expect(abs(kettle(GridSettings(gramsCO2PerKWh: 400)) - 40) < 1e-9)
    }

    @Test func highlightsLeadWithCommuteAndPreferReadableCounts() {
        let picks = Equivalents.highlights(for: 4_000, grid: grid, settings: .init(), limit: 4)
        #expect(picks.first?.id == "commute")
        #expect(picks.count == 4)
        for pick in picks.dropFirst() {
            let n = pick.units(for: 4_000)
            #expect(n >= 0.5 && n <= 500)
        }
    }

    @Test func formatting() {
        #expect(Format.grams(0.5) == "0.50 g")
        #expect(Format.grams(1_234) == "1.23 kg")
        #expect(Format.energy(wh: 2_500) == "2.50 kWh")
        #expect(Format.count(12_345) == "12.3k")
    }
}
