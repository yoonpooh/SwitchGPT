import XCTest
@testable import SwitchGPT

final class ModelRoutingPolicyTests: XCTestCase {
    func testDefaultUsesIndependentConservativeThresholds() {
        let policy = JevRoutingPolicy.default
        XCTAssertEqual(policy.modelUpgradeConfidence, 0.8)
        XCTAssertEqual(policy.modelDowngradeConfidence, 0.8)
        XCTAssertEqual(policy.effortUpgradeConfidence, 0.65)
        XCTAssertEqual(policy.effortDowngradeConfidence, 0.8)
    }

    func testEffortUpgradeBoundaryDoesNotRelaxDowngradeOrModelPolicy() {
        let policy = JevRoutingPolicy.default
        for (confidence, expected) in [(0.649, false), (0.65, true), (0.69, true), (0.76, true)] {
            let plan = policy.plan(selection: JevRoutingSelection(model: .luna, effort: .high,
                modelConfidence: confidence, effortConfidence: confidence),
                originalModel: "gpt-6-astra", originalEffort: "medium", routeModel: true, routeEffort: true)
            XCTAssertNil(plan.model)
            XCTAssertEqual(plan.effort, expected ? "high" : nil)
        }
        let down = policy.plan(selection: JevRoutingSelection(model: .luna, effort: .medium,
            modelConfidence: 0.76, effortConfidence: 0.76),
            originalModel: "gpt-6-astra", originalEffort: "high", routeModel: true, routeEffort: true)
        XCTAssertFalse(down.changed)
    }

    func testDirectionSpecificThresholdsCanBeSweptWithoutChangingEngine() {
        let policy = JevRoutingPolicy(modelUpgradeConfidence: 0.65,
                                      modelDowngradeConfidence: 0.85,
                                      effortUpgradeConfidence: 0.7,
                                      effortDowngradeConfidence: 0.9)
        XCTAssertTrue(policy.allows(0.65, direction: .upgrade, dimension: .model))
        XCTAssertFalse(policy.allows(0.84, direction: .downgrade, dimension: .model))
        XCTAssertTrue(policy.allows(0.7, direction: .upgrade, dimension: .effort))
        XCTAssertFalse(policy.allows(0.89, direction: .downgrade, dimension: .effort))
    }

    func testAllAdvertisedAutomaticEffortsCanBeAppliedWithoutChangingModel() {
        let policy = JevRoutingPolicy.default
        for model in ["gpt-5.6-luna", "gpt-5.6-sol", "gpt-6-astra"] {
            for effort in [JevEffortChoice.high, .max] {
                let plan = policy.plan(selection: JevRoutingSelection(
                    model: .keep, effort: effort, modelConfidence: 0.99, effortConfidence: 0.99),
                    originalModel: model, originalEffort: "medium", routeModel: false, routeEffort: true)
                XCTAssertEqual(plan, JevRoutingPlan(model: nil, effort: effort.rawValue), model)
            }
        }
    }

    func testKnownLowBaselineCanUpgradeButDisabledAndUncertainEffortStayLow() {
        let policy = JevRoutingPolicy.default
        for (enabled, confidence, expected) in [(true, 0.99, "high"), (true, 0.64, ""), (false, 0.99, "")] {
            let plan = policy.plan(selection: JevRoutingSelection(
                model: .keep, effort: .high, modelConfidence: 0.99, effortConfidence: confidence),
                originalModel: "gpt-5.6-sol", originalEffort: "low", routeModel: false, routeEffort: enabled)
            XCTAssertEqual(plan.effort, expected.isEmpty ? nil : expected)
            XCTAssertNil(plan.model)
        }
    }

    func testModelOnlyPreservesSupportedLowAndAbsentEffort() {
        let policy = JevRoutingPolicy.default
        for effort in ["low", nil] {
            let plan = policy.plan(selection: JevRoutingSelection(model: .luna, effort: .high,
                modelConfidence: 0.99, effortConfidence: 0.99),
                originalModel: "gpt-6-astra", originalEffort: effort, routeModel: true, routeEffort: false)
            XCTAssertEqual(plan, JevRoutingPlan(model: "gpt-5.6-luna", effort: nil))
        }
    }

    func testExpandedPairsAndUnknownBaselineValuesArePreserved() {
        let policy = JevRoutingPolicy.default
        let unsupported = policy.plan(
            selection: JevRoutingSelection(model: .astra, effort: .max,
                                           modelConfidence: 0.99, effortConfidence: 0.99),
            originalModel: "gpt-6-astra", originalEffort: "medium",
            routeModel: true, routeEffort: true)
        XCTAssertEqual(unsupported, JevRoutingPlan(model: nil, effort: "max"))

        let unknownEffort = policy.plan(
            selection: JevRoutingSelection(model: .keep, effort: .high,
                                           modelConfidence: 0.99, effortConfidence: 0.99),
            originalModel: "gpt-6-astra", originalEffort: "xhigh",
            routeModel: false, routeEffort: true)
        XCTAssertEqual(unknownEffort, JevRoutingPlan(model: nil, effort: nil))

        let maxToHighDowngrade = policy.plan(
            selection: JevRoutingSelection(model: .keep, effort: .high,
                                           modelConfidence: 0.99, effortConfidence: 0.99),
            originalModel: "gpt-6-astra", originalEffort: "max",
            routeModel: false, routeEffort: true)
        XCTAssertEqual(maxToHighDowngrade, JevRoutingPlan(model: nil, effort: "high"))
    }
}
