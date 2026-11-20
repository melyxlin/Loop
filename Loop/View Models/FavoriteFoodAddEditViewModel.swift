//
//  FavoriteFoodAddEditViewModel.swift
//  Loop
//
//  Created by Noah Brauner on 7/31/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopCore
import LoopAlgorithm

final class FavoriteFoodAddEditViewModel: ObservableObject {
    enum Alert: Identifiable {
        var id: Self {
            return self
        }
        
        case maxQuantityExceded
        case warningQuantityValidation
    }
    
    @Published var name = ""
    
    @Published var carbsQuantity: Double? = nil
    @Published var protein: Double = 0
    @Published var fat: Double = 0
    var preferredCarbUnit = LoopUnit.gram
    var maxCarbEntryQuantity = LoopConstants.maxCarbEntryQuantity
    var warningCarbEntryQuantity = LoopConstants.warningCarbEntryQuantity
    
    @Published var foodType = ""

    @Published var absorptionTime: TimeInterval
    let minAbsorptionTime = LoopConstants.minCarbAbsorptionTime
    let maxAbsorptionTime = LoopConstants.maxCarbAbsorptionTime
    var absorptionRimesRange: ClosedRange<TimeInterval> {
        return minAbsorptionTime...maxAbsorptionTime
    }
    
    @Published var alert: FavoriteFoodAddEditViewModel.Alert?
    
    private let onSave: (NewFavoriteFood) -> ()
    
    init(originalFavoriteFood: StoredFavoriteFood?, onSave: @escaping (NewFavoriteFood) -> ()) {
        self.onSave = onSave
        if let food = originalFavoriteFood {
            self.originalFavoriteFood = food
            self.name = food.name
            self.carbsQuantity = food.carbsQuantity.doubleValue(for: preferredCarbUnit)
            self.foodType = food.foodType
            self.absorptionTime = food.absorptionTime
            self.protein = food.protein ?? 0
            self.fat = food.fat ?? 0
        }
        else {
            self.absorptionTime = .hours(3)
        }
    }
    
    init(carbsQuantity: Double?, foodType: String, absorptionTime: TimeInterval, protein: Double = 0, fat: Double = 0, onSave: @escaping (NewFavoriteFood) -> ()) {
        self.onSave = onSave
        self.carbsQuantity = carbsQuantity
        self.absorptionTime = absorptionTime
        self.protein = protein
        self.fat = fat
        
        // foodType of Apple 🍎 --> name: Apple, foodType: 🍎
        var name = foodType
        name.removeAll(where: \.isEmoji)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.foodType = foodType.filter(\.isEmoji)
        self.name = name
    }
    
    var originalFavoriteFood: StoredFavoriteFood?
    var updatedFavoriteFood: NewFavoriteFood? {
        if let quantity = carbsQuantity, quantity != 0, name != "", foodType != "" {
            let savedProtein = protein > 0 ? protein : nil
            let savedFat = fat > 0 ? fat : nil

            if let original = originalFavoriteFood,
               original.name == name,
               original.carbsQuantity.doubleValue(for: preferredCarbUnit) == quantity,
               original.foodType == foodType,
               original.absorptionTime == absorptionTime,
               original.protein == savedProtein,
               original.fat == savedFat {
                return nil
            }

            return NewFavoriteFood(
                name: name,
                carbsQuantity: LoopQuantity(unit: preferredCarbUnit, doubleValue: quantity),
                foodType: foodType,
                absorptionTime: absorptionTime,
                protein: savedProtein,
                fat: savedFat
            )
        }
        else {
            return nil
        }
    }

    func save() {
        guard let updatedFavoriteFood, absorptionTime <= maxAbsorptionTime else { return }

        guard let carbsQuantity, carbsQuantity > 0 else { return }
        let quantity = LoopQuantity(unit: preferredCarbUnit, doubleValue: carbsQuantity)
        if quantity.compare(maxCarbEntryQuantity) == .orderedDescending {
            self.alert = .maxQuantityExceded
            return
        }
        else if quantity.compare(warningCarbEntryQuantity) == .orderedDescending {
            self.alert = .warningQuantityValidation
            return
        }
        
        onSave(updatedFavoriteFood)
    }
    
    func clearAlertAndSave() {
        guard let updatedFavoriteFood else { return }
        self.alert = nil
        onSave(updatedFavoriteFood)
    }
    
    func clearAlert() {
        self.alert = nil
    }
}
