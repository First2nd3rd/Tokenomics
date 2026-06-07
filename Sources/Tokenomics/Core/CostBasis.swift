import Foundation

/// A billing vendor the break-even view compares against a subscription. Maps 1:1
/// to a usage provider (Claude ← claude-native, GPT ← codex).
enum Vendor: String, CaseIterable {
    case claude, gpt

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .gpt: return "GPT"
        }
    }

    /// The usage provider id whose daily series feeds this vendor's cost.
    var providerID: String {
        switch self {
        case .claude: return "claude-native"
        case .gpt: return "codex"
        }
    }
}

/// How the user pays for a vendor: a fixed monthly subscription (break-even
/// applies) or pure API pay-as-you-go (no break-even — you pay the real cost).
enum CostBasis: Equatable {
    case api
    case subscription(monthlyUSD: Double)

    var monthlyFee: Double? {
        if case .subscription(let fee) = self { return fee }
        return nil
    }
}

/// Subscription plans offered in Settings; raw values persist via @AppStorage and
/// are read back by `CostBasisStore`. `presetFee == nil` means the plan carries no
/// fixed fee (API, or Custom which uses the user-entered amount).
protocol SubscriptionPlan: CaseIterable, Identifiable, RawRepresentable, Hashable where RawValue == String {
    var label: String { get }
    var presetFee: Double? { get }
}

enum ClaudePlan: String, SubscriptionPlan {
    case api, pro, max5x, max20x, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .api: return "API (pay-as-you-go)"
        case .pro: return "Pro · $20/mo"
        case .max5x: return "Max 5× · $100/mo"
        case .max20x: return "Max 20× · $200/mo"
        case .custom: return "Custom…"
        }
    }
    var presetFee: Double? {
        switch self {
        case .pro: return 20
        case .max5x: return 100
        case .max20x: return 200
        case .api, .custom: return nil
        }
    }
}

enum GPTPlan: String, SubscriptionPlan {
    case api, plus, pro, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .api: return "API (pay-as-you-go)"
        case .plus: return "Plus · $20/mo"
        case .pro: return "Pro · $200/mo"
        case .custom: return "Custom…"
        }
    }
    var presetFee: Double? {
        switch self {
        case .plus: return 20
        case .pro: return 200
        case .api, .custom: return nil
        }
    }
}

/// Reads the per-vendor cost-basis the user picked in Settings. The Settings UI
/// writes the same UserDefaults keys via @AppStorage, so both sides agree.
/// Default (no choice yet) is API, so the view shows real cost rather than a
/// guessed break-even.
enum CostBasisStore {
    static let claudePlanKey = "claudePlan"
    static let claudeCustomKey = "claudeCustomFee"
    static let gptPlanKey = "gptPlan"
    static let gptCustomKey = "gptCustomFee"

    static func claude(_ defaults: UserDefaults = .standard) -> CostBasis {
        let plan = ClaudePlan(rawValue: defaults.string(forKey: claudePlanKey) ?? "") ?? .api
        return resolve(plan, custom: defaults.double(forKey: claudeCustomKey))
    }

    static func gpt(_ defaults: UserDefaults = .standard) -> CostBasis {
        let plan = GPTPlan(rawValue: defaults.string(forKey: gptPlanKey) ?? "") ?? .api
        return resolve(plan, custom: defaults.double(forKey: gptCustomKey))
    }

    private static func resolve<P: SubscriptionPlan>(_ plan: P, custom: Double) -> CostBasis {
        if let fee = plan.presetFee { return .subscription(monthlyUSD: fee) }
        // No preset fee: either API, or Custom using the entered amount (if > 0).
        if plan.rawValue == "custom", custom > 0 { return .subscription(monthlyUSD: custom) }
        return .api
    }
}
