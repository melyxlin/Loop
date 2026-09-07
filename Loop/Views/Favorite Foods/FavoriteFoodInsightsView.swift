//
//  FavoriteFoodInsightsView.swift
//  Loop
//
//  Created by Noah Brauner on 7/15/24.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import LoopAlgorithm

struct FavoriteFoodInsightsView: View {
    @StateObject private var viewModel: FavoriteFoodInsightsViewModel
    
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @Environment(\.dismiss) private var dismiss
    
    @State private var isInteractingWithChart = false
    
    @State private var showHowCarbEffectsWorks = false

    let presentedAsSheet: Bool
    
    init(viewModel: FavoriteFoodInsightsViewModel, presentedAsSheet: Bool = true) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.presentedAsSheet = presentedAsSheet
    }
    
    var body: some View {
        if presentedAsSheet {
            NavigationView {
                content
                    .toolbar {
                        dismissButton
                    }
            }
        }
        else {
            content
                .insetGroupedListStyle()
        }
    }
    
    private var content: some View {
        List {
                historicalCarbEntriesSection
                glucoseResponseSection
                insulinResponseSection
                historicalDataReviewSection
        }
        .padding(.top, -28)
        .navigationTitle("Favorite Food Insights")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showHowCarbEffectsWorks) {
            HowCarbEffectsWorksView()
        }
    }

    private var historicalCarbEntriesSection: some View {
        Section {
            if let carbEntry = viewModel.carbEntry {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Spacer()
                        
                        let isAtStart = viewModel.carbEntryIndex == 0
                        Button(action: {
                            guard !isAtStart else { return }
                            viewModel.carbEntryIndex -= 1
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.title3.bold())
                        }
                        .disabled(isAtStart)
                        .opacity(isAtStart ? 0.4 : 1)
                        .buttonStyle(BorderlessButtonStyle())
                        .contentShape(Rectangle())
                        
                        VStack(spacing: 2) {
                            Text(viewModel.dateFormater.string(from: carbEntry.startDate))
                                .font(.headline)

                            Text("\(viewModel.carbEntryIndex + 1) of \(viewModel.carbEntries.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        let isAtEnd = viewModel.carbEntryIndex >= viewModel.carbEntries.count - 1
                        Button(action: {
                            guard !isAtEnd else { return }
                            viewModel.carbEntryIndex += 1
                        }) {
                            Image(systemName: "chevron.right")
                                .font(.title3.bold())
                        }
                        .disabled(isAtEnd)
                        .opacity(isAtEnd ? 0.4 : 1)
                        .buttonStyle(BorderlessButtonStyle())
                        .contentShape(Rectangle())
                        
                        Spacer()
                    }
                    
                    if let formattedCarbQuantity = viewModel.carbFormatter.string(from: carbEntry.quantity), let absorptionTime = carbEntry.absorptionTime, let formattedAbsorptionTime = viewModel.absorptionTimeFormatter.string(from: absorptionTime) {
                        let formattedRelativeDate = viewModel.relativeDateFormatter.localizedString(for: carbEntry.startDate, relativeTo: viewModel.now)
                        let formattedDate = viewModel.dateFormater.string(from: carbEntry.startDate)
                        
                        let rows: [(field: String, value: String)] = [
                            ("Food", viewModel.food.title),
                            ("Carb Quantity",  formattedCarbQuantity),
                            ("Date", "\(formattedDate) - \(formattedRelativeDate)"),
                            ("Absorption Time", "\(formattedAbsorptionTime)")
                        ]
                        
                        ForEach(rows, id: \.field) { row in
                            HStack(alignment: .top) {
                                Text(row.field)
                                    .font(.subheadline)
                                Spacer()
                                Text(row.value)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
    
    private var glucoseResponseSection: some View {
        Section("Response") {
            VStack(spacing: 16) {
                if viewModel.hasOverlappingFood,
                   let timeUntilFood = viewModel.timeUntilOverlappingFood {
                    HStack(spacing: 8) {
                        Image(systemName: "fork.knife")
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Additional Food")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Text(
                                "Response limited to \(durationString(timeUntilFood)) after meal"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
}
                if let startingGlucose = viewModel.startingGlucose {
                    responseRow(
                        "Starting Glucose",
                        value: glucoseString(startingGlucose)
                    )
                }

                if let peakGlucose = viewModel.peakGlucose {
                    responseRow(
                        "Peak Glucose",
                        value: glucoseString(peakGlucose)
                    )
                }

                if let rise = viewModel.glucoseRise {
                    responseRow(
                        "Rise",
                        value: String(format: "%+.0f mg/dL", rise)
                    )
                }

                if let timeToPeak = viewModel.timeToPeak {
                    responseRow(
                        "Time to Peak",
                        value: durationString(timeToPeak)
                    )
                }

                if let lowestGlucose = viewModel.lowestGlucose {
                    responseRow(
                        "Lowest Glucose",
                        value: glucoseString(lowestGlucose)
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }
    
    private var insulinResponseSection: some View {
        Section("Insulin") {
            VStack(spacing: 16) {
                if let startingIOB = viewModel.startingIOB {
                    responseRow(
                        "Starting IOB",
                        value: String(format: "%.1f U", startingIOB)
                    )
                }

                responseRow(
                    "Meal Bolus",
                    value: String(format: "%.1f U", viewModel.mealBolus)
                )

                responseRow(
                    "Additional Bolus",
                    value: String(format: "%.1f U", viewModel.additionalBolus)
                )

                responseRow(
                    "Total Bolus",
                    value: String(format: "%.1f U", viewModel.totalBolus)
                )
            }
            .padding(.vertical, 8)
        }
    }

    private func responseRow(
        _ title: String,
        value: String
    ) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)

            Spacer()

            Text(value)
                .font(.subheadline)
        }
    }

    private func glucoseString(_ quantity: LoopQuantity) -> String {
        let value = quantity.doubleValue(
            for: displayGlucosePreference.unit
        )

        return String(
            format: "%.0f %@",
            value,
            displayGlucosePreference.unit.localizedShortUnitString
        )
    }

    private func durationString(_ duration: TimeInterval) -> String {
        let totalMinutes = Int(duration / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    private var historicalDataReviewSection: some View {
        Section(header: historicalDataReviewHeader) {
            FavoriteFoodsInsightsChartsView(viewModel: viewModel, showHowCarbEffectsWorks: $showHowCarbEffectsWorks)
        }
    }
    
    private var historicalDataReviewHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text("Historical Data")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text(viewModel.dateIntervalFormatter.string(from: viewModel.startDate, to: viewModel.endDate))
            }
            
            Spacer()
        }
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 20, leading: 4, bottom: 10, trailing: 4))
    }
    
    private var dismissButton: some View {
        Button(action: {
            dismiss()
        }) {
            Text("Done")
        }
    }
}
