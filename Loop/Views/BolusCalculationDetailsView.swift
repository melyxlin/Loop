//
//  BolusCalculationDetailsView.swift
//  Loop
//
//  Created by Melissa Lin on 9/6/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
import SwiftUI

struct BolusCalculationDetailsView: View {
    let details: BolusCalculationDetails

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                referenceCalculationsSection
                loopPredictionSection
                loopCalculationSection

                footer
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Header

private extension BolusCalculationDetailsView {
    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bolus Calculator")
                .font(.title2.bold())

            Text("How Loop calculates your bolus")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Reference Calculations

private extension BolusCalculationDetailsView {
    @ViewBuilder
    var referenceCalculationsSection: some View {
        if details.glucoseCorrectionReference != nil ||
            details.carbCoverageReference != nil
        {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Reference Calculations")

                if let correction = details.glucoseCorrectionReference {
                    glucoseCorrectionCard(correction)
                }

                if let coverage = details.carbCoverageReference {
                    carbCoverageCard(coverage)
                }
            }
        }
    }

    func glucoseCorrectionCard(_ correction: Double) -> some View {
        calculationCard(
            title: "Glucose Correction",
            subtitle: "Reference only — Loop doses from predicted glucose"
        ) {
            if let currentGlucose = details.currentGlucose {
                valueRow(
                    "Current",
                    glucoseString(currentGlucose)
                )
            }

            if let targetGlucose = details.targetGlucose {
                valueRow(
                    "Target",
                    glucoseString(targetGlucose)
                )
            }

            if let sensitivity = details.insulinSensitivity {
                valueRow(
                    "ISF",
                    String(format: "%.0f mg/dL/U", sensitivity)
                )
            }

            Divider()

            valueRow(
                "Reference Correction",
                insulinString(correction)
            )
        }
    }

    func carbCoverageCard(_ coverage: Double) -> some View {
        calculationCard(
            title: "Carb Coverage",
            subtitle: "Reference only — carbs are modeled in Loop's prediction"
        ) {
            if let carbs = details.enteredCarbs {
                valueRow(
                    "Carbs",
                    String(format: "%.0f g", carbs)
                )
            }

            if let carbRatio = details.carbRatio {
                valueRow(
                    "Carb Ratio",
                    String(format: "%.0f g/U", carbRatio)
                )
            }

            Divider()

            valueRow(
                "Equivalent Coverage",
                insulinString(coverage)
            )
        }
    }
}

// MARK: - Loop Prediction

private extension BolusCalculationDetailsView {
    var loopPredictionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Loop Prediction")

            if let activeInsulin = details.activeInsulin {
                insulinEffectCard(activeInsulin)
            }

            if let activeCarbs = details.activeCarbs,
                activeCarbs > 0
            {
                carbohydrateEffectCard(activeCarbs)
            }

            if let momentum = details.glucoseMomentumDescription {
                glucoseMomentumCard(momentum)
            }

            if let retrospectiveCorrection =
                details.retrospectiveCorrectionDescription
            {
                retrospectiveCorrectionCard(retrospectiveCorrection)
            }

            if details.lowestPredictedGlucose != nil ||
                details.eventualPredictedGlucose != nil
            {
                predictedGlucoseCard
            }
        }
    }

    func insulinEffectCard(_ activeInsulin: Double) -> some View {
        calculationCard(
            title: "Insulin Effect",
            subtitle: "Included in Loop's glucose prediction"
        ) {
            valueRow(
                "Active Insulin",
                insulinString(activeInsulin)
            )
        }
    }

    func carbohydrateEffectCard(_ activeCarbs: Double) -> some View {
        calculationCard(
            title: "Carbohydrate Effect",
            subtitle: "Carbohydrates are modeled using absorption"
        ) {
            valueRow(
                "Active Carbs",
                String(format: "%.0f g", activeCarbs)
            )
        }
    }

    func glucoseMomentumCard(_ momentum: String) -> some View {
        calculationCard(
            title: "Glucose Momentum",
            subtitle: "Recent glucose movement used in prediction"
        ) {
            valueRow(
                "Momentum",
                momentum
            )
        }
    }

    func retrospectiveCorrectionCard(
        _ retrospectiveCorrection: String
    ) -> some View {
        calculationCard(
            title: "Retrospective Correction",
            subtitle: "Adjusts prediction based on recent glucose behavior"
        ) {
            valueRow(
                "Effect",
                retrospectiveCorrection
            )
        }
    }

    var predictedGlucoseCard: some View {
        calculationCard(
            title: "Predicted Glucose",
            subtitle: "Loop evaluates glucose across the insulin effect duration"
        ) {
            if let lowest = details.lowestPredictedGlucose {
                valueRow(
                    "Lowest",
                    glucoseString(lowest)
                )
            }

            if let eventual = details.eventualPredictedGlucose {
                valueRow(
                    "Eventual",
                    glucoseString(eventual)
                )
            }
        }
    }
}

// MARK: - Loop Calculation

private extension BolusCalculationDetailsView {
    var loopCalculationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Loop Calculation")

            if let calculatedBolus = details.calculatedBolus {
                calculationCard(
                    title: "Calculated Bolus",
                    subtitle: "Loop's unrounded bolus recommendation"
                ) {
                    valueRow(
                        "Calculated",
                        insulinString(calculatedBolus)
                    )
                }
            }

            if let difference = details.presetDifference,
                abs(difference) > 0.0001
            {
                presetAdjustmentCard
            }

            recommendedBolusCard
        }
    }

    var presetAdjustmentCard: some View {
        calculationCard(
            title: "Preset Adjustment",
            subtitle: "Shows how the active preset changes Loop's recommendation"
        ) {
            if let withoutPreset = details.recommendationWithoutPreset {
                valueRow(
                    "Without Preset",
                    insulinString(withoutPreset)
                )
            }

            if let withPreset = details.recommendationWithPreset {
                valueRow(
                    "With Preset",
                    insulinString(withPreset)
                )
            }

            if let difference = details.presetDifference {
                Divider()

                valueRow(
                    "Difference",
                    signedInsulinString(difference)
                )
            }
        }
    }

    var recommendedBolusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recommended Bolus")
                        .font(.headline)

                    Text("Rounded for pump")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(
                    details.recommendedBolus.map(insulinString) ?? "—"
                )
                .font(.title2.bold())
                .monospacedDigit()
                .foregroundStyle(.blue)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.12))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.blue.opacity(0.35))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Shared UI

private extension BolusCalculationDetailsView {
    func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    func calculationCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .padding()
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            Color(.secondarySystemGroupedBackground)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: 14)
        )
    }

    func valueRow(
        _ label: String,
        _ value: String
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .monospacedDigit()
        }
    }

    var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)

            Text(
                "Reference calculations are shown for context. " +
                "Loop's recommendation is based on predicted glucose " +
                "and may differ from traditional bolus calculations."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    func insulinString(_ value: Double) -> String {
        String(format: "%.2f U", value)
    }

    func signedInsulinString(_ value: Double) -> String {
        String(format: "%+.2f U", value)
    }

    func glucoseString(_ value: Double) -> String {
        String(format: "%.0f mg/dL", value)
    }
}
