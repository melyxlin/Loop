//
//  ManualBolusRecommendationResult.swift
//  Loop
//
//  Created by Melissa Lin on 9/7/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
import LoopAlgorithm

struct ManualBolusRecommendationResult {
    let recommendation: ManualBolusRecommendation?
    let calculatedBolus: Double?
    let momentumEffect: Double?
    let retrospectiveCorrectionEffect: Double?
}
