//
//  FavoriteFoodDetailView.swift
//  Loop
//
//  Created by Noah Brauner on 8/2/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI

public struct FavoriteFoodDetailView: View {
    @ObservedObject var viewModel: FavoriteFoodsViewModel
    
    @State private var isConfirmingDelete = false
    @State private var showFavoriteFoodInsights = false

    public var body: some View {
        if let food = viewModel.selectedFood {
            Group {
                List {
                    informationSection(for: food)

                    if (food.protein ?? 0) > 0 || (food.fat ?? 0) > 0 {
                        bolusProSection(for: food)
                    }

                    actionsSection(for: food)
                    FavoriteFoodInsightsCardView(
                        showFavoriteFoodInsights: $showFavoriteFoodInsights,
                        foodName: viewModel.selectedFood?.name,
                        lastEatenDate: viewModel.selectedFoodLastEaten,
                        relativeDateFormatter: viewModel.relativeDateFormatter,
                        presentInSection: true
                    )
                }
                .alert(isPresented: $isConfirmingDelete) {
                    Alert(
                        title: Text("Delete “\(food.name)”?"),
                        message: Text("Are you sure you want to delete this food?"),
                        primaryButton: .cancel(),
                        secondaryButton: .destructive(Text("Delete"), action: viewModel.deleteSelectedFood)
                    )
                }
                .insetGroupedListStyle()
                .navigationTitle(food.title)
                                
                NavigationLink(destination: FavoriteFoodAddEditView(originalFavoriteFood: viewModel.selectedFood, onSave: viewModel.onFoodSave(_:)), isActive: $viewModel.isEditViewActive) {
                    EmptyView()
                }
                
                NavigationLink(destination: FavoriteFoodInsightsView(viewModel: FavoriteFoodInsightsViewModel(delegate: viewModel.insightsDelegate, food: food), presentedAsSheet: false), isActive: $showFavoriteFoodInsights) {
                    EmptyView()
                }
            }
        }
    }
    
    private func informationSection(for food: StoredFavoriteFood) -> some View {
        Section("Information") {
            VStack(spacing: 16) {
                let rows: [(field: String, value: String)] = [
                    ("Name", food.name),
                    ("Carb", food.carbsString(formatter: viewModel.carbFormatter)),
                    ("Protein", String(format: "%.0f g", food.protein ?? 0)),
                    ("Fat", String(format: "%.0f g", food.fat ?? 0)),
                    ("Food Type", food.foodType),
                    ("Absorption Time", food.absorptionTimeString(formatter: viewModel.absorptionTimeFormatter))
                ]
                ForEach(rows, id: \.field) { row in
                    HStack {
                        Text(row.field)
                            .font(.subheadline)
                        Spacer()
                        Text(row.value)
                            .font(.subheadline)
                    }
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }
    
    private func bolusProSection(for food: StoredFavoriteFood) -> some View {
        let fat = food.fat ?? 0
        let protein = food.protein ?? 0

        let fpuScore = BolusPro_FPUCalculator.fpuScore(
            fatGrams: fat,
            proteinGrams: protein
        )

        let bonusGrams = BolusPro_FPUCalculator.bonusGrams(
            fatGrams: fat,
            proteinGrams: protein,
            coverageFactor: Double(BolusPro_FeatureFlags.coverageFactorPercent) / 100.0,
            sliderPosition: 1.0
        )

        let rows: [(field: String, value: String)] = [
            ("FPU", String(format: "%.1f", fpuScore)),
            ("Equivalent Carbs", String(format: "%.1f g", bonusGrams)),
            ("FPU Delay", "\(BolusPro_FeatureFlags.fpuDelayMinutes) min"),
            ("FPU Absorption", "\(BolusPro_FeatureFlags.fpuAbsorptionHours) hr")
        ]

        return Section("BolusPro") {
            VStack(spacing: 16) {
                ForEach(rows, id: \.field) { row in
                    HStack {
                        Text(row.field)
                            .font(.subheadline)

                        Spacer()

                        Text(row.value)
                            .font(.subheadline)
                    }
                }
            }
        }
        .listRowInsets(
            EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        )
    }
    
    private func actionsSection(for food: StoredFavoriteFood) -> some View {
        Section {
            Button(action: { viewModel.isEditViewActive.toggle() }) {
                HStack {
                    // Fix the list row inset with centered content from shifting to the center.
                    // https://stackoverflow.com/questions/75046730/swiftui-list-divider-unwanted-inset-at-the-start-when-non-text-component-is-u
                    Text("")
                        .frame(maxWidth: 0)
                        .accessibilityHidden(true)
                    
                    Spacer()
                    
                    Text("Edit Food")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .foregroundColor(.accentColor)
                    
                    Spacer()
                }
            }
            
            Button(role: .destructive, action: { isConfirmingDelete.toggle() }) {
                Text("Delete Food")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}
