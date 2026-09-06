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
    let primaryEntryIdentifier: String
    var secondaryEntryIdentifier: String?
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
        primaryEntryIdentifier: String,
        secondaryEntryIdentifier: String?,
        state: BolusProEntryState
    ) {
        self.primaryEntryIdentifier = primaryEntryIdentifier
        self.secondaryEntryIdentifier = secondaryEntryIdentifier
        self.fatGrams = state.macros.fatGrams
        self.proteinGrams = state.macros.proteinGrams
        self.enabled = state.enabled
        self.sliderCoverage = state.sliderCoverage
        self.autoDetected = state.autoDetected
    }
}

private func identifier(for entry: StoredCarbEntry) -> String? {
    if let syncIdentifier = entry.syncIdentifier {
        return "sync:\(syncIdentifier)"
    }

    if let uuid = entry.uuid {
        return "uuid:\(uuid.uuidString)"
    }

    return nil
}

final class BolusProMealStore {
    static let shared = BolusProMealStore()

    private let defaults: UserDefaults
    private let storageKey = "BolusPro.StoredMeals"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func meal(for primaryEntry: StoredCarbEntry) -> BolusProStoredMeal? {
        guard let identifier = identifier(for: primaryEntry) else {
            return nil
        }

        return meals[identifier]
    }
    
    func isSecondaryEntry(_ entry: StoredCarbEntry) -> Bool {
        guard let entryIdentifier = identifier(for: entry) else {
            return false
        }

        return meals.values.contains {
            $0.secondaryEntryIdentifier == entryIdentifier
        }
    }
    
    func secondaryIdentifier(for primaryEntry: StoredCarbEntry) -> String? {
        meal(for: primaryEntry)?.secondaryEntryIdentifier
    }
    
    
    func save(
        state: BolusProEntryState,
        primaryEntry: StoredCarbEntry,
        secondaryEntry: StoredCarbEntry?
    ) {
        guard let primaryIdentifier = identifier(for: primaryEntry) else {
            return
        }

        let meal = BolusProStoredMeal(
            primaryEntryIdentifier: primaryIdentifier,
            secondaryEntryIdentifier: secondaryEntry.flatMap { identifier(for: $0) },
            state: state
        )

        var updatedMeals = meals
        updatedMeals[primaryIdentifier] = meal
        meals = updatedMeals
    }

    func remove(for primaryEntry: StoredCarbEntry) {
        guard let identifier = identifier(for: primaryEntry) else {
            return
        }

        var updatedMeals = meals
        updatedMeals.removeValue(forKey: identifier)
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
