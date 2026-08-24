//
//  StatisticsRangeEditor.swift
//  Loop
//
//  Created by Melissa Lin on 8/24/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

enum EditableStatisticsRange: String, Identifiable {
    case low
    case high
    case veryHigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:
            return "Low"
        case .high:
            return "High"
        case .veryHigh:
            return "Very High"
        }
    }
}

struct StatisticsRangeEditor: View {
    let range: EditableStatisticsRange

    @Binding var targetLow: Double
    @Binding var targetHigh: Double
    @Binding var veryHigh: Double

    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int = 0

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 24) {

                VStack(alignment: .leading, spacing: 8) {
                    Text(range.title)
                        .font(.title2.weight(.semibold))

                    Text(descriptionText)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 12)

                Picker("", selection: $selection) {
                    ForEach(allowedValues, id: \.self) { value in
                        Text("\(value) mg/dL")
                            .tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSelection()
                        onSave()
                        dismiss()
                    }
                }
            }
            .onAppear {
                selection = currentValue
            }
        }
    }

    // MARK: - Current Value

    private var currentValue: Int {
        switch range {
        case .low:
            return Int(targetLow.rounded())

        case .high:
            return Int(targetHigh.rounded())

        case .veryHigh:
            return Int(veryHigh.rounded())
        }
    }

    // MARK: - Allowed Picker Values

    private var allowedValues: [Int] {
        switch range {
        case .low:
            // Must stay above very-low (54)
            // and below the high end of the target range.
            let minimum = 55
            let maximum = max(minimum, Int(targetHigh.rounded()) - 1)

            return Array(minimum...maximum)

        case .high:
            // Must stay above targetLow
            // and below the very-high threshold.
            let minimum = Int(targetLow.rounded()) + 1
            let maximum = max(
                minimum,
                Int(veryHigh.rounded()) - 1
            )

            return Array(minimum...maximum)

        case .veryHigh:
            // Must stay above targetHigh.
            let minimum = Int(targetHigh.rounded()) + 1
            let maximum = 400

            return Array(minimum...maximum)
        }
    }

    // MARK: - Description

    private var descriptionText: String {
        switch range {
        case .low:
            return "Select the minimum value for your target range."

        case .high:
            return "Select the maximum value for your target range."

        case .veryHigh:
            return "Select the value above which glucose is considered very high."
        }
    }

    // MARK: - Save

    private func saveSelection() {
        switch range {
        case .low:
            targetLow = Double(selection)

        case .high:
            targetHigh = Double(selection)

        case .veryHigh:
            veryHigh = Double(selection)
        }
    }
}
