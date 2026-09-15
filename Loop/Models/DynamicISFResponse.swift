//
//  DynamicISFResponse.swift
//  Loop
//
//  Created by Melissa Lin on 9/8/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

enum DynamicISFState: String {
    case inactive
    case observing
    case waitingForResponse
    case resistant
    case recovering
}

enum DynamicISFReason: String {
    case glucoseNotElevated
    case insufficientInsulinExposure
    case insulinResponseTooEarly
    case insulinEffectPending
    case responseMatchesExpected
    case responseBelowExpected
    case glucoseResponding
    case glucoseRecovering
}

struct DynamicISFConcernEpisode {
    let startDate: Date
    let startEffectProgress: Double
    let startDiscrepancy: Double
}

struct DynamicISFResponse {
    let state: DynamicISFState
    let reason: DynamicISFReason
    let observedGlucoseChange: Double
    let recentGlucoseChange: Double?
    let expectedInsulinEffect: Double
    let expectedCarbEffect: Double
    let expectedNetEffect: Double
    let responseDiscrepancy: Double
    let responseDeficitFraction: Double
    let remainingInsulinEffect: Double
    let insulinEffectProgress: Double
}
