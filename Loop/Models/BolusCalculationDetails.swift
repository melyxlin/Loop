//
//  BolusCalculationDetails.swift
//  Loop
//
//  Created by Melissa Lin on 9/6/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
import Foundation

struct BolusCalculationDetails {
    // MARK: - Reference Calculations

    var currentGlucose: Double?
    var targetGlucose: Double?
    var insulinSensitivity: Double?
    var glucoseCorrectionReference: Double?

    var enteredCarbs: Double?
    var carbRatio: Double?
    var carbCoverageReference: Double?

    // MARK: - Loop Prediction

    var activeInsulin: Double?
    var activeCarbs: Double?

    var glucoseMomentumDescription: String?
    var retrospectiveCorrectionDescription: String?

    var lowestPredictedGlucose: Double?
    var eventualPredictedGlucose: Double?

    // MARK: - Loop Calculation

    var calculatedBolus: Double?
    var recommendedBolus: Double?

    // MARK: - Preset Adjustment

    var recommendationWithoutPreset: Double?
    var recommendationWithPreset: Double?

    var presetDifference: Double? {
        guard
            let withoutPreset = recommendationWithoutPreset,
            let withPreset = recommendationWithPreset
        else {
            return nil
        }

        return withPreset - withoutPreset
    }
}
