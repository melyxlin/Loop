//
//  PrebolusTimerState.swift
//  Loop
//
//  Created by Melissa Lin on 9/18/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

struct PrebolusTimerState: Codable, Equatable {
    enum Phase: String, Codable {
        case pendingBolusCompletion
        case countingDown
        case completed
    }

    var decisionId: UUID
    var durationMinutes: Int
    var phase: Phase
    var endDate: Date?
    var completedAt: Date?

    init(
        decisionId: UUID,
        durationMinutes: Int
    ) {
        self.decisionId = decisionId
        self.durationMinutes = durationMinutes
        self.phase = .pendingBolusCompletion
        self.endDate = nil
        self.completedAt = nil
    }
}
