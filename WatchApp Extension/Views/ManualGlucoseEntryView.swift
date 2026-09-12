//
//  ManualGlucoseEntryView.swift
//  Loop
//
//  Created by Melissa Lin on 9/11/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import WatchKit
import LoopKit
import LoopCore
import WatchConnectivity

struct ManualGlucoseEntryView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.glucoseDisplayUnit) private var glucoseDisplayUnit
    @Environment(LoopDataManager.self) private var loopManager

    @State private var glucoseValue: Double = 0
    @State private var hasAdjustedValue = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var increment: Double {
        glucoseDisplayUnit == .milligramsPerDeciliter ? 1 : 0.1
    }

    private var validDisplayRange: ClosedRange<Double> {
        if glucoseDisplayUnit == .milligramsPerDeciliter {
            return 10...600
        } else {
            return 10.0 / 18.0...600.0 / 18.0
        }
    }

    private var crownValue: Binding<Double> {
        Binding(
            get: { glucoseValue },
            set: { newValue in
                if newValue != glucoseValue {
                    glucoseValue = newValue
                    hasAdjustedValue = true
                }
            }
        )
    }

    private var glucoseFormatter: NumberFormatter {
        NumberFormatter.glucoseFormatter(for: glucoseDisplayUnit)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(formattedGlucose)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color(UIColor.glucose))

            Text(glucoseDisplayUnit.localizedShortUnitString)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Turn Digital Crown")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    await save()
                }
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text("Save")
                }
            }
            .disabled(!hasAdjustedValue || isSaving)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .focusable()
        .digitalCrownRotation(
            crownValue,
            from: validDisplayRange.lowerBound,
            through: validDisplayRange.upperBound,
            by: increment,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .alert(
            "Unable to Reach iPhone",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            initializeValue()
        }
    }
    
    

    private var formattedGlucose: String {
        glucoseFormatter.string(from: glucoseValue)
            ?? String(glucoseValue)
    }

    private func initializeValue() {
        guard glucoseValue == 0 else {
            return
        }

        if let glucose = loopManager.activeContext?.glucose {
            glucoseValue = glucose
                .doubleValue(for: glucoseDisplayUnit)
                .clamped(to: validDisplayRange)
        } else {
            glucoseValue = glucoseDisplayUnit == .milligramsPerDeciliter
                ? 100
                : 100.0 / 18.0
        }
    }

    @MainActor
    private func save() async {
        guard hasAdjustedValue else {
            return
        }

        isSaving = true
        defer { isSaving = false }

        let valueInMgDL: Double

        if glucoseDisplayUnit == .milligramsPerDeciliter {
            valueInMgDL = glucoseValue
        } else {
            valueInMgDL = glucoseValue * 18.0
        }

        let message = SetManualGlucoseUserInfo(
            valueInMgDL: valueInMgDL,
            date: Date(),
            syncIdentifier: UUID().uuidString
        )

        do {
            let updatedContext = try await WCSession.default
                .sendManualGlucoseMessage(message)

            LoopDataManager.shared.updateContext(updatedContext)

            WKInterfaceDevice.current().play(.success)

            dismiss()
        } catch {
            WKInterfaceDevice.current().play(.failure)
            errorMessage = NSLocalizedString(
                "Make sure your iPhone is nearby and try again.",
                comment: "Recovery message after a manual glucose entry from Apple Watch fails"
            )
        }
    }
}
