import Testing
import Foundation
@testable import Tokenomics

@Suite("CostBasis")
struct CostBasisTests {

    // MARK: - Isolated UserDefaults helper

    /// Returns a fresh, isolated UserDefaults suite plus a cleanup closure that
    /// wipes its persistent domain. Each test uses a unique suite name so the
    /// parallel test runner never shares global state.
    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "CostBasisTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Start from a clean slate in case a name ever collides.
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func cleanup(_ defaults: UserDefaults, _ suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Preset plans map to .subscription(presetFee)

    @Test("Claude preset plan resolves to subscription with that preset fee")
    func claudePresetPlan() throws {
        // Arrange
        let (defaults, suiteName) = makeDefaults()
        defer { cleanup(defaults, suiteName) }
        defaults.set(ClaudePlan.max5x.rawValue, forKey: CostBasisStore.claudePlanKey)

        // Act
        let basis = CostBasisStore.claude(defaults)

        // Assert
        let preset = try #require(ClaudePlan.max5x.presetFee)
        #expect(basis == .subscription(monthlyUSD: preset))
        #expect(basis == .subscription(monthlyUSD: 100))
    }

    @Test("GPT preset plan resolves to subscription with that preset fee")
    func gptPresetPlan() throws {
        // Arrange
        let (defaults, suiteName) = makeDefaults()
        defer { cleanup(defaults, suiteName) }
        defaults.set(GPTPlan.pro.rawValue, forKey: CostBasisStore.gptPlanKey)

        // Act
        let basis = CostBasisStore.gpt(defaults)

        // Assert
        let preset = try #require(GPTPlan.pro.presetFee)
        #expect(basis == .subscription(monthlyUSD: preset))
        #expect(basis == .subscription(monthlyUSD: 200))
    }

    // MARK: - Custom with positive fee -> .subscription(custom)

    @Test("Claude custom plan with positive fee resolves to subscription with that fee")
    func claudeCustomPositive() {
        // Arrange
        let (defaults, suiteName) = makeDefaults()
        defer { cleanup(defaults, suiteName) }
        defaults.set(ClaudePlan.custom.rawValue, forKey: CostBasisStore.claudePlanKey)
        defaults.set(57.5, forKey: CostBasisStore.claudeCustomKey)

        // Act
        let basis = CostBasisStore.claude(defaults)

        // Assert
        #expect(basis == .subscription(monthlyUSD: 57.5))
    }

    @Test("GPT custom plan with positive fee resolves to subscription with that fee")
    func gptCustomPositive() {
        // Arrange
        let (defaults, suiteName) = makeDefaults()
        defer { cleanup(defaults, suiteName) }
        defaults.set(GPTPlan.custom.rawValue, forKey: CostBasisStore.gptPlanKey)
        defaults.set(42.0, forKey: CostBasisStore.gptCustomKey)

        // Act
        let basis = CostBasisStore.gpt(defaults)

        // Assert
        #expect(basis == .subscription(monthlyUSD: 42.0))
    }

    // MARK: - Custom with 0 fee -> .api

    @Test("Claude custom plan with zero fee falls back to API")
    func claudeCustomZero() {
        // Arrange
        let (defaults, suiteName) = makeDefaults()
        defer { cleanup(defaults, suiteName) }
        defaults.set(ClaudePlan.custom.rawValue, forKey: CostBasisStore.claudePlanKey)
        defaults.set(0.0, forKey: CostBasisStore.claudeCustomKey)

        // Act
        let basis = CostBasisStore.claude(defaults)

        // Assert
        #expect(basis == .api)
    }

    @Test("GPT custom plan with zero fee falls back to API")
    func gptCustomZero() {
        // Arrange
        let (defaults, suiteName) = makeDefaults()
        defer { cleanup(defaults, suiteName) }
        defaults.set(GPTPlan.custom.rawValue, forKey: CostBasisStore.gptPlanKey)
        // No custom fee written: defaults.double returns 0.

        // Act
        let basis = CostBasisStore.gpt(defaults)

        // Assert
        #expect(basis == .api)
    }

    // MARK: - Unknown / absent plan -> .api

    @Test("Claude unknown plan raw value falls back to API")
    func claudeUnknownPlan() {
        // Arrange
        let (defaults, suiteName) = makeDefaults()
        defer { cleanup(defaults, suiteName) }
        defaults.set("not-a-real-plan", forKey: CostBasisStore.claudePlanKey)

        // Act
        let basis = CostBasisStore.claude(defaults)

        // Assert
        #expect(basis == .api)
    }

    @Test("Claude absent plan key defaults to API")
    func claudeAbsentPlan() {
        // Arrange: nothing written to the defaults at all.
        let (defaults, suiteName) = makeDefaults()
        defer { cleanup(defaults, suiteName) }

        // Act
        let basis = CostBasisStore.claude(defaults)

        // Assert
        #expect(basis == .api)
    }

    @Test("GPT absent plan key defaults to API")
    func gptAbsentPlan() {
        // Arrange: nothing written to the defaults at all.
        let (defaults, suiteName) = makeDefaults()
        defer { cleanup(defaults, suiteName) }

        // Act
        let basis = CostBasisStore.gpt(defaults)

        // Assert
        #expect(basis == .api)
    }

    // MARK: - Explicit .api plan -> .api

    @Test("Claude API plan resolves to API even with a custom fee present")
    func claudeApiPlanIgnoresCustom() {
        // Arrange: a custom fee is set, but the plan is API so it must be ignored.
        let (defaults, suiteName) = makeDefaults()
        defer { cleanup(defaults, suiteName) }
        defaults.set(ClaudePlan.api.rawValue, forKey: CostBasisStore.claudePlanKey)
        defaults.set(123.0, forKey: CostBasisStore.claudeCustomKey)

        // Act
        let basis = CostBasisStore.claude(defaults)

        // Assert
        #expect(basis == .api)
    }

    @Test("GPT API plan resolves to API even with a custom fee present")
    func gptApiPlanIgnoresCustom() {
        // Arrange: a custom fee is set, but the plan is API so it must be ignored.
        let (defaults, suiteName) = makeDefaults()
        defer { cleanup(defaults, suiteName) }
        defaults.set(GPTPlan.api.rawValue, forKey: CostBasisStore.gptPlanKey)
        defaults.set(999.0, forKey: CostBasisStore.gptCustomKey)

        // Act
        let basis = CostBasisStore.gpt(defaults)

        // Assert
        #expect(basis == .api)
    }

    // MARK: - Vendors are isolated from each other

    @Test("Claude and GPT read independent keys without cross-contamination")
    func vendorKeysAreIndependent() {
        // Arrange: only Claude is configured as a subscription.
        let (defaults, suiteName) = makeDefaults()
        defer { cleanup(defaults, suiteName) }
        defaults.set(ClaudePlan.pro.rawValue, forKey: CostBasisStore.claudePlanKey)

        // Act
        let claude = CostBasisStore.claude(defaults)
        let gpt = CostBasisStore.gpt(defaults)

        // Assert
        #expect(claude == .subscription(monthlyUSD: 20))
        #expect(gpt == .api)
    }

    // MARK: - Preset fee values for every plan case

    @Test("ClaudePlan preset fee values are correct for every case")
    func claudePresetFees() {
        #expect(ClaudePlan.api.presetFee == nil)
        #expect(ClaudePlan.pro.presetFee == 20)
        #expect(ClaudePlan.max5x.presetFee == 100)
        #expect(ClaudePlan.max20x.presetFee == 200)
        #expect(ClaudePlan.custom.presetFee == nil)
    }

    @Test("GPTPlan preset fee values are correct for every case")
    func gptPresetFees() {
        #expect(GPTPlan.api.presetFee == nil)
        #expect(GPTPlan.plus.presetFee == 20)
        #expect(GPTPlan.pro.presetFee == 200)
        #expect(GPTPlan.custom.presetFee == nil)
    }

    // MARK: - Labels are non-empty for every case

    @Test("ClaudePlan label is non-empty for every case")
    func claudeLabelsNonEmpty() {
        for plan in ClaudePlan.allCases {
            #expect(!plan.label.isEmpty)
        }
    }

    @Test("GPTPlan label is non-empty for every case")
    func gptLabelsNonEmpty() {
        for plan in GPTPlan.allCases {
            #expect(!plan.label.isEmpty)
        }
    }

    // MARK: - CostBasis.monthlyFee accessor

    @Test("CostBasis.monthlyFee returns the fee for subscription and nil for API")
    func monthlyFeeAccessor() {
        #expect(CostBasis.subscription(monthlyUSD: 100).monthlyFee == 100)
        #expect(CostBasis.api.monthlyFee == nil)
    }
}
