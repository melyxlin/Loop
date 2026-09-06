//
//  BolusPro_MealStore.swift
//  Loop
//
//  Created by Melissa Lin on 9/6/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
import Foundation
import LoopKit

struct BolusProStoredMeal: Codable, Equatable {
    let primaryEntryUUID: UUID

    var secondaryEntryUUID: UUID?

    var fatGrams: Double
    var proteinGrams: Double

    var enabled: Bool
    var sliderCoverage: Double
    var autoDetected: Bool

    var state: BolusProEntryState {
        BolusProEntryState(
            enabled: enabled,
            macros: BolusProMacroInputs(
                fatGrams: fatGrams,
                proteinGrams: proteinGrams
            ),
            sliderCoverage: sliderCoverage,
            autoDetected: autoDetected
        )
    }

    init(
        primaryEntryUUID: UUID,
        secondaryEntryUUID: UUID?,
        state: BolusProEntryState
    ) {
        self.primaryEntryUUID = primaryEntryUUID
        self.secondaryEntryUUID = secondaryEntryUUID
        self.fatGrams = state.macros.fatGrams
        self.proteinGrams = state.macros.proteinGrams
        self.enabled = state.enabled
        self.sliderCoverage = state.sliderCoverage
        self.autoDetected = state.autoDetected
    }
}

final class BolusProMealStore {
    static let shared = BolusProMealStore()

    private let defaults: UserDefaults
    private let storageKey = "BolusPro.StoredMeals"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func meal(for primaryEntry: StoredCarbEntry) -> BolusProStoredMeal? {
        guard let uuid = primaryEntry.uuid else {
            return nil
        }

        return meals[uuid.uuidString]
    }

    func save(
        state: BolusProEntryState,
        primaryEntry: StoredCarbEntry,
        secondaryEntry: StoredCarbEntry?
    ) {
        guard let primaryUUID = primaryEntry.uuid else {
            return
        }

        let meal = BolusProStoredMeal(
            primaryEntryUUID: primaryUUID,
            secondaryEntryUUID: secondaryEntry?.uuid,
            state: state
        )

        var updatedMeals = meals
        updatedMeals[primaryUUID.uuidString] = meal
        meals = updatedMeals
    }

    func remove(for primaryEntry: StoredCarbEntry) {
        guard let uuid = primaryEntry.uuid else {
            return
        }

        var updatedMeals = meals
        updatedMeals.removeValue(forKey: uuid.uuidString)
        meals = updatedMeals
    }

    private var meals: [String: BolusProStoredMeal] {
        get {
            guard let data = defaults.data(forKey: storageKey) else {
                return [:]
            }

            return (try? JSONDecoder().decode(
                [String: BolusProStoredMeal].self,
                from: data
            )) ?? [:]
        }

        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                return
            }

            defaults.set(data, forKey: storageKey)
        }
    }
}
