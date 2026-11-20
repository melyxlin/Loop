//
//  StoredDataAlgorithmInput.swift
//  Loop
//
//  Created by Pete Schwamb on 2/23/24.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import LoopAlgorithm

public struct StoredDataAlgorithmInput: AlgorithmInput {
    public typealias CarbType = StoredCarbEntry

    public typealias GlucoseType = StoredGlucoseSample

    public typealias InsulinDoseType = SimpleInsulinDose

    public var glucoseHistory: [StoredGlucoseSample]
    
    public var doses: [SimpleInsulinDose]

    public var carbEntries: [StoredCarbEntry]
    
    public var predictionStart: Date
    
    public var basal: [LoopAlgorithm.AbsoluteScheduleValue<Double>]
    
    public var sensitivityMgdlPerUnit: [LoopAlgorithm.AbsoluteScheduleValue<Double>]
    
    public var carbRatio: [LoopAlgorithm.AbsoluteScheduleValue<Double>]
    
    public var targetMgdl: LoopAlgorithm.GlucoseRangeTimeline
    
    public var suspendThresholdMgdl: Double?
    
    public var maxBolus: Double
    
    public var maxBasalRate: Double
    
    public var useIntegralRetrospectiveCorrection: Bool
    
    public var includePositiveVelocityAndRC: Bool
    
    public var carbAbsorptionModel: CarbAbsorptionModel
    
    public var recommendationInsulinModel: LoopAlgorithm.InsulinModel
    
    public var recommendationType: DoseRecommendationType
    
    public var automaticBolusApplicationFactor: Double?

    public let useMidAbsorptionISF: Bool = true

    public var maxActiveInsulinMultiplier: Double? = nil

    public var gradualTransitionsThreshold: Double? = nil

    public var experiments: Set<ExperimentOption> = []

    public var volatilityBaseline: Double? = nil

    public var negativeInsulinDamper: Double? = nil
}

// MARK: - Negative Insulin Damper (algorithm experiment)

extension UserDefaults {
    public static let negativeInsulinDamperEnabledKey = "com.loopkit.algorithmExperiments.negativeInsulinDamperEnabled"

    public var negativeInsulinDamperEnabled: Bool {
        get {
            bool(forKey: Self.negativeInsulinDamperEnabledKey)
        }
        set {
            set(newValue, forKey: Self.negativeInsulinDamperEnabledKey)
        }
    }
}

extension StoredDataAlgorithmInput {
    static func calculateNegativeInsulinDamperAlpha(_ anchorAlpha: Double, _ anchorPoint: Double, _ marginalSlope: Double, _ posDeltaSum: Double) -> Double {
        let linearScaleSlope = (1.0 - anchorAlpha)/anchorPoint // how alpha scales down in the linear scale region

        // the slope in the linear scale region of alpha * posDeltaSum is 1 - 2*linearScaleSlope*posDeltaSum.
        // the transitionPoint is where we transition from linear scale region to marginalSlope. The slope is continuous at this point
        let transitionPoint = (1 - marginalSlope) / (2 * linearScaleSlope)

        if posDeltaSum < transitionPoint { // linear scaling region
            return 1 - linearScaleSlope * posDeltaSum
        } else { // marginal slope region
            let transitionValue = (1 - linearScaleSlope * transitionPoint) * transitionPoint
            return (transitionValue + marginalSlope * (posDeltaSum - transitionPoint)) / posDeltaSum
        }
    }

    /// The Negative Insulin Damper coefficient in [0,1] for this input, or nil.
    /// The predicted future rise attributable to negative insulin (delivery below scheduled basal,
    /// up to 15 minutes ago) sets the damper strength.
    func computeNegativeInsulinDamper() -> Double? {
        guard let latestGlucose = glucoseHistory.last else { return nil }
        let anchorDate = latestGlucose.startDate
        let lastDoseStartDate = anchorDate.addingTimeInterval(.minutes(-15))

        // Predicted insulin glucose-effect of everything delivered up to 15 minutes ago
        // (doses starting later are dropped, basal-type doses trimmed at t-15, boluses kept whole).
        let annotatedDoses = doses
            .trimmed(to: lastDoseStartDate)
            .annotated(with: basal)

        // Fail safe (disable the damper) rather than trip glucoseEffects' ISF-coverage
        // preconditionFailure, which would crash automated dosing.
        for dose in annotatedDoses {
            guard let isf = sensitivityMgdlPerUnit.closestPrior(to: dose.startDate), isf.endDate >= dose.startDate else {
                return nil
            }
        }

        let effects = annotatedDoses.glucoseEffects(insulinSensitivityHistoryMgdlPerUnit: sensitivityMgdlPerUnit, from: anchorDate.addingTimeInterval(.minutes(-5)))

        // Sum of positive 5-min deltas — the predicted future rise from negative insulin.
        var posDeltaSum = 0.0
        for (offset, effect) in effects.enumerated() where offset > 0 {
            let delta = effect.mgdl - effects[offset - 1].mgdl
            posDeltaSum += max(0, delta)
        }

        guard let isfMgdlPerUnit = sensitivityMgdlPerUnit.closestPrior(to: anchorDate)?.value,
              let basalRate = basal.closestPrior(to: anchorDate)?.value else {
            return nil
        }

        // anchorScale is ~1 hour for rapid-acting adult, ~44 min for ultra-rapid insulins.
        let model = (recommendationInsulinModel as? AlgorithmInsulinModel)?.model
        let anchorScale: Double
        if let expModel = model as? LoopKit.ExponentialInsulinModel {
            anchorScale = 0.8 * expModel.peakActivityTime.hours
        } else if let preset = model as? LoopKit.ExponentialInsulinModelPreset {
            anchorScale = 0.8 * preset.peakActivity.hours
        } else if let expModel = recommendationInsulinModel as? LoopAlgorithm.ExponentialInsulinModel {
            anchorScale = 0.8 * expModel.peakActivityTime.hours
        } else if let preset = recommendationInsulinModel as? LoopAlgorithm.ExponentialInsulinModelPreset {
            anchorScale = 0.8 * preset.peakActivity.hours
        } else {
            anchorScale = 1.0
        }

        let marginalSlope = 0.05
        let anchorAlpha = 0.75
        // anchorPoint is unaffected by overrides (the basal and ISF multipliers cancel out).
        let anchorPoint = anchorScale * basalRate * isfMgdlPerUnit

        // A 0 U/hr basal segment would make anchorPoint 0 → NaN → constant 95% damping; disable instead.
        guard anchorPoint > 0 else { return nil }

        let alpha = Self.calculateNegativeInsulinDamperAlpha(anchorAlpha, anchorPoint, marginalSlope, posDeltaSum)
        // alpha should never be less than marginalSlope
        return max(0, 1 - max(marginalSlope, alpha))
    }
}
