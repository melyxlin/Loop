//
//  WatchActionsView.swift
//  Loop
//
//  Created by Pete Schwamb on 8/15/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//


import SwiftUI
import LoopKit
import LoopCore
import WatchConnectivity
import WatchKit

struct WatchActionsView: View {
    @Environment(LoopDataManager.self) var loopManager

    @State private var isShowingPresets: Bool = false
    @State private var overrideToShow: TemporaryScheduleOverride?
    @State private var isShowingManualGlucoseEntry: Bool = false
    @State private var isShowingLoopModeConfirmation = false
    @State private var isChangingLoopMode = false
    @State private var loopModeError: String?
    
    private var isClosedLoop: Bool {
        loopManager.activeContext?.isClosedLoop == true
    }

    var overrideActive: Bool {
        return loopManager.watchInfo.scheduleOverride?.isActive() == true
    }

    var body: some View {
        ScrollView(.vertical) {
            LoopHeader()

            HStack(spacing: 0) {
                CircleTintedButton(
                    label: "Carbs",
                    image: Image("carbs"),
                    foregroundTint: .carbs,
                    backgroundTint: .darkCarbs
                ) {
                    loopManager.bolusViewModel = CarbAndBolusFlowViewModel(configuration: .carbEntry(nil))
                }
                CircleTintedButton(
                    label: "Bolus",
                    image: Image("bolus"),
                    foregroundTint: .insulin,
                    backgroundTint: .darkInsulin
                ) {
                    loopManager.bolusViewModel = CarbAndBolusFlowViewModel(configuration: .manualBolus)
                }
            }
            .padding(.bottom, 4)
            HStack(spacing: 0) {
                CircleTintedButton(
                    label: "Presets",
                    image: Image("presets"),
                    foregroundTint: overrideActive ? .darkPresets : .presets,
                    backgroundTint: overrideActive ? .presets : .darkPresets
                ) {
                    if overrideActive {
                        overrideToShow = loopManager.watchInfo.scheduleOverride
                    } else {
                        isShowingPresets = true
                    }
                }

                CircleTintedButton(
                    label: "Fingerstick",
                    image: Image(systemName: "drop.fill"),
                    foregroundTint: Color(UIColor.glucose),
                    backgroundTint: Color(UIColor.darkGlucose)
                ) {
                    isShowingManualGlucoseEntry = true
                }
            }
            HStack(spacing: 0) {
                CircleTintedButton(
                    label: isClosedLoop ? "Open Loop" : "Resume Loop",
                    image: Image(systemName: isClosedLoop ? "pause.circle.fill" : "play.circle.fill"),
                    foregroundTint: .orange,
                    backgroundTint: .orange.opacity(0.2)
                ) {
                    isShowingLoopModeConfirmation = true
                }
                .disabled(isChangingLoopMode)

                Spacer()
            }
        }
        .font(.system(size: 14, weight: .light))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingPresets) {
            PresetsView()
        }
        .sheet(isPresented: Binding(get: {
            overrideToShow != nil
        }, set: {
            if !$0 { overrideToShow = nil }
        })) {
            let preset = loopManager.selectablePresets.first(where: { $0.id == overrideToShow!.presetId })
            PresetConfirmationView(preset: preset)
        }
        .sheet(isPresented: $isShowingManualGlucoseEntry) {
            ManualGlucoseEntryView()
        }
        .sheet(isPresented:Binding(
            get: { loopManager.bolusViewModel != nil },
            set: { if !$0 { loopManager.bolusViewModel = nil } }
        )) {
            CarbAndBolusFlow(viewModel: loopManager.bolusViewModel!)
        }
        .confirmationDialog(
            isClosedLoop ? "Turn Off Automatic Dosing?" : "Resume Automatic Dosing?",
            isPresented: $isShowingLoopModeConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                isClosedLoop ? "Open Loop" : "Resume Loop"
            ) {
                Task {
                    await changeLoopMode()
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            if isClosedLoop {
                Text("Your pump and CGM will continue operating, but Loop will not make automatic insulin adjustments.")
            } else {
                Text("Loop will resume automatic insulin adjustments.")
            }
        }
        .alert(
            "Unable to Change Loop Mode",
            isPresented: Binding(
                get: { loopModeError != nil },
                set: {
                    if !$0 {
                        loopModeError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loopModeError ?? "")
        }
        .environment(\.glucoseDisplayUnit, loopManager.displayGlucoseUnit)
    }
    
    @MainActor
    private func changeLoopMode() async {
        guard !isChangingLoopMode else {
            return
        }

        isChangingLoopMode = true
        defer {
            isChangingLoopMode = false
        }

        let requestedDosingEnabled = !isClosedLoop
        let message = SetLoopModeUserInfo(
            dosingEnabled: requestedDosingEnabled
        )

        do {
            let updatedContext = try await WCSession.default
                .sendLoopModeMessage(message)

            LoopDataManager.shared.updateContext(updatedContext)

            WKInterfaceDevice.current().play(.success)
        } catch {
            WKInterfaceDevice.current().play(.failure)

            loopModeError = NSLocalizedString(
                "Make sure your iPhone is nearby and try again.",
                comment: "Recovery message after changing Loop mode from Apple Watch fails"
            )
        }
    }

}
