//
//  PrebolusTimerManager.swift
//  Loop
//
//  Created by Melissa Lin on 9/18/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

final class PrebolusTimerManager {

    static let shared = PrebolusTimerManager()

    private let userDefaults: UserDefaults
    private let storageKey = "PrebolusTimerState"

    private(set) var state: PrebolusTimerState? {
        didSet {
            persistState()
        }
    }

    private init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.state = Self.loadState(
            from: userDefaults,
            key: storageKey
        )
    }

    func prepare(
        decisionId: UUID,
        durationMinutes: Int
    ) {
        state = PrebolusTimerState(
            decisionId: decisionId,
            durationMinutes: durationMinutes
        )
    }

    func startCountdown() {
        guard var state,
              state.phase == .pendingBolusCompletion
        else {
            return
        }

        state.phase = .countingDown

        let duration = TimeInterval(state.durationMinutes * 60)
        state.endDate = Date().addingTimeInterval(duration)

        self.state = state
    }

    func startManualCountdown(
        durationMinutes: Int
    ) {
        state = PrebolusTimerState(
            manualDurationMinutes: durationMinutes
        )
    }

    func markCompleted() {
        guard var state else {
            return
        }

        state.phase = .completed
        state.completedAt = state.endDate ?? Date()
        self.state = state
    }
    
    func clear() {
        state = nil
    }

    private func persistState() {
        guard let state else {
            userDefaults.removeObject(forKey: storageKey)
            return
        }

        guard let data = try? JSONEncoder().encode(state) else {
            return
        }

        userDefaults.set(data, forKey: storageKey)
    }

    private static func loadState(
        from userDefaults: UserDefaults,
        key: String
    ) -> PrebolusTimerState? {
        guard let data = userDefaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(
            PrebolusTimerState.self,
            from: data
        )
    }
}
