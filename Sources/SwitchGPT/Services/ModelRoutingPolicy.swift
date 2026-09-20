import Foundation

/// The model families that the relay is allowed to write.  The classifier may
/// use either these short names or the canonical ids on the wire; everything
/// else is deliberately left unchanged.
enum JevModelChoice: String, CaseIterable, Codable, Sendable {
    case luna
    case sol
    case astra
    case keep

    init?(answerValue rawValue: String?) {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "keep", "preserve", "baseline": self = .keep
        case "luna", "gpt-5.6-luna", "gpt_5_6_luna": self = .luna
        case "sol", "gpt-5.6-sol", "gpt_5_6_sol": self = .sol
        case "astra", "gpt-6-astra", "gpt_6_astra": self = .astra
        default: return nil
        }
    }

    var modelID: String? {
        switch self {
        case .luna: return "gpt-5.6-luna"
        case .sol: return "gpt-5.6-sol"
        case .astra: return "gpt-6-astra"
        case .keep: return nil
        }
    }
}

/// The reasoning levels that are known to be valid for at least one target
/// model family.  `keep` is a classifier instruction, never an API value.
enum JevEffortChoice: String, CaseIterable, Codable, Sendable {
    case medium
    case high
    case max
    case keep

    init?(answerValue rawValue: String?) {
        guard let rawValue else { return nil }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "keep", "preserve", "baseline": self = .keep
        case "medium": self = .medium
        case "high": self = .high
        case "max": self = .max
        default: return nil
        }
    }
}

enum JevRoutingDirection: Sendable, Equatable {
    case upgrade
    case downgrade
}

/// Pure policy and compatibility rules for the Jev model/effort split.
///
/// Thresholds are intentionally independent so a later offline sweep can
/// tune model and effort without changing the router engine.  Effort upgrades
/// allow a lower threshold than downgrades; model changes remain conservative.
struct JevRoutingPolicy: Sendable, Equatable {
    let modelUpgradeConfidence: Double
    let modelDowngradeConfidence: Double
    let effortUpgradeConfidence: Double
    let effortDowngradeConfidence: Double

    static let `default` = JevRoutingPolicy()

    init(modelUpgradeConfidence: Double = 0.8,
         modelDowngradeConfidence: Double = 0.8,
         effortUpgradeConfidence: Double = 0.65,
         effortDowngradeConfidence: Double = 0.8) {
        self.modelUpgradeConfidence = Self.normalizedThreshold(modelUpgradeConfidence)
        self.modelDowngradeConfidence = Self.normalizedThreshold(modelDowngradeConfidence)
        self.effortUpgradeConfidence = Self.normalizedThreshold(effortUpgradeConfidence)
        self.effortDowngradeConfidence = Self.normalizedThreshold(effortDowngradeConfidence)
    }

    func threshold(for direction: JevRoutingDirection, dimension: JevRoutingDimension) -> Double {
        switch (dimension, direction) {
        case (.model, .upgrade): return modelUpgradeConfidence
        case (.model, .downgrade): return modelDowngradeConfidence
        case (.effort, .upgrade): return effortUpgradeConfidence
        case (.effort, .downgrade): return effortDowngradeConfidence
        }
    }

    func allows(_ confidence: Double?, direction: JevRoutingDirection, dimension: JevRoutingDimension) -> Bool {
        guard let confidence, confidence.isFinite, (0...1).contains(confidence) else { return false }
        return confidence >= threshold(for: direction, dimension: dimension)
    }

    func modelRank(_ value: String) -> Int? {
        guard let choice = JevModelChoice(answerValue: value) else { return nil }
        switch choice {
        case .luna: return 0
        case .sol: return 1
        case .astra: return 2
        case .keep: return nil
        }
    }

    func effortRank(_ value: String?) -> Int? {
        guard let value else { return nil }
        // low is a supported incoming baseline, not a generated classifier choice.
        if value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "low" { return -1 }
        guard let choice = JevEffortChoice(answerValue: value) else { return nil }
        switch choice {
        case .medium: return 0
        case .high: return 1
        case .max: return 2
        case .keep: return nil
        }
    }

    /// Whether this exact family/effort pair is one the relay has explicitly
    /// validated.  A missing effort is retained as the upstream default when
    /// a model-only decision is applied, so it remains valid here.
    func supports(model: String, effort: String?) -> Bool {
        guard let family = JevModelChoice(answerValue: model), family != .keep else { return false }
        guard let effort else { return true }
        // Codex 0.155.0 models_cache.json, refreshed 2026-09-20 UTC, advertises
        // medium/high/max for all three families. The old six presets described
        // routing preferences, not model capabilities. low may be preserved.
        return effortRank(effort) != nil
    }

    func direction(wanted: Int, current: Int?) -> JevRoutingDirection {
        guard let current else { return .upgrade }
        return wanted < current ? .downgrade : .upgrade
    }

    private static func normalizedThreshold(_ value: Double) -> Double {
        guard value.isFinite else { return 0.8 }
        return min(1, max(0, value))
    }
}

enum JevRoutingDimension: Sendable, Equatable {
    case model
    case effort
}

/// A validated independent classifier selection. A `nil` dimension means the
/// answer explicitly kept that baseline dimension; `preserveBaseline` is a
/// global safety result and must keep both dimensions.
struct JevRoutingSelection: Sendable, Equatable {
    let model: JevModelChoice?
    let effort: JevEffortChoice?
    let modelConfidence: Double?
    let effortConfidence: Double?
    let preserveBaseline: Bool

    init(model: JevModelChoice?, effort: JevEffortChoice?, modelConfidence: Double?,
         effortConfidence: Double?, preserveBaseline: Bool = false) {
        self.model = model
        self.effort = effort
        self.modelConfidence = modelConfidence
        self.effortConfidence = effortConfidence
        self.preserveBaseline = preserveBaseline
    }
}

/// Applies independent choices while refusing to create an unsupported pair.
/// If both requested values cannot coexist, the individually valid choice is
/// retained when it can be applied with the other baseline value.  When both
/// are viable but conflict, model wins and effort stays at baseline; this is
/// the conservative result that leaves the other baseline dimension unchanged.
struct JevRoutingPlan: Sendable, Equatable {
    let model: String?
    let effort: String?

    var changed: Bool { model != nil || effort != nil }
}

extension JevRoutingPolicy {
    func requestsChange(model choice: JevModelChoice?, original: String, enabled: Bool) -> Bool {
        guard enabled, let choice, choice != .keep, let modelID = choice.modelID,
              let wanted = modelRank(modelID), let current = modelRank(original) else {
            return false
        }
        return wanted != current
    }

    func requestsChange(effort choice: JevEffortChoice?, original: String?, enabled: Bool) -> Bool {
        guard enabled, let choice, choice != .keep, let original,
              let wanted = effortRank(choice.rawValue), let current = effortRank(original) else {
            return false
        }
        return wanted != current
    }

    func plan(selection: JevRoutingSelection, originalModel: String, originalEffort: String?,
              routeModel: Bool, routeEffort: Bool) -> JevRoutingPlan {
        guard !selection.preserveBaseline else { return JevRoutingPlan(model: nil, effort: nil) }


        let currentModelRank = modelRank(originalModel)
        let currentEffortRank = effortRank(originalEffort)
        var wantedModel: String?
        if routeModel, let choice = selection.model, choice != .keep,
           let modelID = choice.modelID,
           let wantedRank = modelRank(modelID), currentModelRank != nil, wantedRank != currentModelRank,
           allows(selection.modelConfidence, direction: direction(wanted: wantedRank, current: currentModelRank), dimension: .model) {
            wantedModel = modelID
        }

        var wantedEffort: String?
        if routeEffort, originalEffort != nil, let choice = selection.effort, choice != .keep,
           let wantedRank = effortRank(choice.rawValue), wantedRank != currentEffortRank,
           currentEffortRank != nil,
           allows(selection.effortConfidence, direction: direction(wanted: wantedRank, current: currentEffortRank), dimension: .effort) {
            wantedEffort = choice.rawValue
        }


        guard wantedModel != nil || wantedEffort != nil else {
            return JevRoutingPlan(model: nil, effort: nil)
        }

        let candidateModel = wantedModel ?? originalModel
        let candidateEffort = wantedEffort ?? originalEffort
        if supports(model: candidateModel, effort: candidateEffort) {
            return JevRoutingPlan(model: wantedModel, effort: wantedEffort)
        }

        // A split answer can still be useful if only one side forms a known
        // pair with the incoming baseline. Never synthesize an unsupported
        // family/effort combination; the caller records a rejected changed
        // request as KEEP rather than reporting a silent route.
        let modelOnly = wantedModel.flatMap { supports(model: $0, effort: originalEffort) ? $0 : nil }
        let effortOnly = wantedEffort.flatMap { supports(model: originalModel, effort: $0) ? $0 : nil }
        if modelOnly != nil { return JevRoutingPlan(model: modelOnly, effort: nil) }
        if effortOnly != nil { return JevRoutingPlan(model: nil, effort: effortOnly) }
        return JevRoutingPlan(model: nil, effort: nil)
    }
}
