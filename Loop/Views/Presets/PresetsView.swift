//
//  PresetsView.swift
//  Loop
//
//  Created by Cameron Ingham on 10/23/24.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import LoopAlgorithm
import LoopKit
import LoopKitUI
import SwiftUI
import LoopCore

enum PresetSortOption: Int, CaseIterable {
    case name
    case lastUsed
    case dateCreated

    var description: String {
        switch self {
        case .name:
            return NSLocalizedString("Name", comment: "Preset sorting option description for sorting by name")
        case .lastUsed:
            return NSLocalizedString("Last Used", comment: "Preset sorting option description for sorting by last used")
        case .dateCreated:
            return NSLocalizedString("Date Created", comment: "Preset sorting option description for sorting by date created")
        }
    }
}

// Define an enum to represent the active sheet
enum ActiveSheet: Identifiable {
    case editPreset(SelectablePreset) // For EditPresetView
    case presetDetent(SelectablePreset) // For PresetDetentView
    case training(navigationPath: [PresetsTraining.Step] = [], startingAt: PresetsTraining.Chapter? = nil, editPresetWhenComplete: SelectablePreset? = nil)

    var id: String {
        switch self {
        case .editPreset(let preset):
            return "edit_\(preset.id)" // Assuming Preset has an id
        case .presetDetent(let preset):
            return "detent_\(preset.id)"
        case .training:
            return "training"
        }
    }
}

struct PresetsView: View {

    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @Environment(\.appName) private var appName
    @Environment(\.settingsManager) private var settingsManager
    @Environment(\.temporaryPresetsManager) private var temporaryPresetsManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var trainingCompletion: PresetsTrainingCompletion
    @State private var editMode: EditMode = .inactive
    @State private var showingMenu: Bool = false
    @State private var presentCreateView: Bool = false
    @State private var presentTrainingNeededAlert: Bool = false
    @State private var showPresetsTrainingSheet: Bool = false
    @State private var activeSheet: ActiveSheet?
    @State private var navigationPath = NavigationPath()
    
    private let carbStore: CarbStore
    private let doseStore: DoseStore
    private let glucoseStore: GlucoseStore
    private let trainingContent: [MediaContent]
    private let automationHistory: () -> [AutomationHistoryEntry]

    @AppStorage("presetsSortAscending") private var presetsSortAscending: Bool = true
    @AppStorage("presetsSortOrder") private var selectedSortOption: PresetSortOption = .name
    
    init(
        roundBasalRate: ((Double) -> Double)?,
        carbStore: CarbStore,
        doseStore: DoseStore,
        glucoseStore: GlucoseStore,
        trainingContent: [MediaContent],
        automationHistory: @escaping () -> [AutomationHistoryEntry]
    ) {
        self.trainingCompletion = PresetsTrainingCompletion(allowDebugFeatures: FeatureFlags.allowDebugFeatures)
        self.roundBasalRate = roundBasalRate
        self.carbStore = carbStore
        self.doseStore = doseStore
        self.glucoseStore = glucoseStore
        self.trainingContent = trainingContent
        self.automationHistory = automationHistory
    }

    var isDescending: Bool { !presetsSortAscending }

    var presetsSorted: [SelectablePreset] {
        temporaryPresetsManager.selectablePresets
            .filter { $0.id != temporaryPresetsManager.activeOverride?.presetId }
            .sorted(by: {
            switch (selectedSortOption) {
            case .name:
                return ($0.name.lowercased() < $1.name.lowercased()) != isDescending
            case .dateCreated:
                return ($0.dateCreated > $1.dateCreated) != isDescending
            default:
                return ((temporaryPresetsManager.lastUsed(id: $0.id) ?? .distantPast) > (temporaryPresetsManager.lastUsed(id: $1.id) ?? .distantPast)) != isDescending
            }
        })
    }
    
    var scheduledPresets: [(preset: SelectablePreset, nextStart: Date)] {
        temporaryPresetsManager.selectablePresets
            .compactMap { preset in
                guard preset.isScheduled,
                      let nextStart = preset.nextScheduledStartAfter(Date())
                else {
                    return nil
                }

                return (preset: preset, nextStart: nextStart)
            }
            .sorted { $0.nextStart < $1.nextStart }
    }

    var scheduledRange: ClosedRange<LoopQuantity>? {
        settingsManager.therapySettings.glucoseTargetRangeSchedule?.quantityRange(at: Date())
    }
    
    let roundBasalRate: ((Double) -> Double)?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: 20) {
                    if let activePreset = temporaryPresetsManager.selectablePresets.first(where: { $0.id == temporaryPresetsManager.activePreset?.id })
                    {
                        PresetCard(
                            activePreset,
                            guardrail: settingsManager.correctionRangeGuardrailForPreset(activePreset),
                            expectedEndTime: temporaryPresetsManager.activeOverride?.expectedEndTime,
                            activePresetId: { temporaryPresetsManager.activePreset?.id },
                            effectiveCorrectionRange: temporaryPresetsManager.effectiveCorrectionRange
                        )
                        .onTapGesture {
                            activeSheet = .presetDetent(activePreset)
                        }
                    }
                    if !scheduledPresets.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Scheduled Presets")
                                    .font(.headline.weight(.semibold))

                                Spacer()

                                Image(systemName: "alarm.fill")
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 10)

                            LazyVStack(spacing: 10) {
                                ForEach(scheduledPresets, id: \.preset.id) { item in
                                    SwipeToUnscheduleRow(
                                        onUnschedule: {
                                            unschedulePreset(item.preset)
                                        }
                                    ) {
                                        scheduledPresetRow(
                                            preset: item.preset,
                                            nextStart: item.nextStart
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            activeSheet = .presetDetent(item.preset)
                                        }
                                    }
                                }
                                
                            }
                        }
                    }
                    
                    // All Presets Section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("All Presets")
                                .font(.headline.weight(.semibold))
                                .accessibilityIdentifier("text_AllPresets")
                            Spacer()
                            
                            Button("Sort") {
                                showingMenu.toggle()
                            }
                            .popover(isPresented: $showingMenu) {
                                sortMenu
                            }
                            
                            Button(action: {
                                if trainingCompletion.isComplete {
                                    presentCreateView = true
                                } else {
                                    presentTrainingNeededAlert = true
                                }
                            }) {
                                Image(systemName: "plus")
                            }
                            .foregroundStyle(trainingCompletion.isComplete ? Color.accentColor : Color.secondary)
                        }
                        .padding(.horizontal, 10)
                        
                        LazyVStack(spacing: 12) {
                            if !trainingCompletion.isComplete {
                                PresetsTrainingCard(trainingCompletion: trainingCompletion)
                                    .onTapGesture {
                                        activeSheet = .training()
                                    }
                            }
                            
                            ForEach(presetsSorted) { preset in
                                PresetCard(
                                    preset,
                                    guardrail: settingsManager.correctionRangeGuardrailForPreset(preset),
                                    activePresetId: { temporaryPresetsManager.activePreset?.id },
                                    effectiveCorrectionRange: temporaryPresetsManager.effectiveCorrectionRange
                                )
                                .cornerRadius(12)
                                .onTapGesture {
                                    activeSheet = .presetDetent(preset)
                                }
                            }
                        }
                    }
                    
                    if trainingCompletion.isComplete {
                        // Support Section
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Support")
                                .font(.headline.weight(.semibold))
                                .padding(.horizontal, 10)

                            Button {
                                activeSheet = .training()
                            } label: {
                                HStack {
                                    Image("book")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 32, height: 32)

                                    Text("Learning Hub")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(10)
                            .foregroundStyle(.primary)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(Color(UIColor.tertiarySystemBackground))
                                .stroke(Color(UIColor.secondarySystemBackground), lineWidth: 1)
                                .frame(maxWidth: .infinity))
                        }
                    }
                }
                .padding()
                .animation(.default, value: temporaryPresetsManager.activeOverride)
            }
            .background(Color(UIColor.secondarySystemBackground))
            .navigationTitle(Text("Presets", comment: "Presets screen title"))
            .navigationBarItems(trailing: dismissButton)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .presetDetent(let preset):
                PresetDetentView(preset: preset, roundBasalRate: roundBasalRate, didTapEdit: {
                    activeSheet = .editPreset(preset)
                })
            case .editPreset(let preset):
                Group {
                    if let scheduledRange {
                        EditPresetView(
                            preset: preset,
                            scheduledRange: scheduledRange,
                            trainingCompletion: trainingCompletion,
                            onSave: { updatedPreset in
                                settingsManager.savePreset(updatedPreset)
                                Task {
                                    await temporaryPresetsManager.scheduleNextPresetReminder()
                                }
                            },
                            onDelete: { preset in
                                settingsManager.deletePreset(preset)
                                Task {
                                    await temporaryPresetsManager.unschedulePresetReminderIfNeeded(preset)
                                    await temporaryPresetsManager.scheduleNextPresetReminder()
                                }
                            },
                            correctionRangeGuardrailForPreset: settingsManager.correctionRangeGuardrailForPreset,
                            impactForInsulinMultiplier: { settingsManager.therapySettings.impact(for: $0) },
                            showPresetsTrainingSheet: { showPresetsTrainingSheet = true },
                            suspendThreshold: { settingsManager.settings.suspendThreshold }
                        )
                        .sheet(isPresented: $showPresetsTrainingSheet) {
                            PresetsTrainingView(
                                trainingCompletionConfiguration: .trainingCompletion(trainingCompletion),
                                trainingContent: trainingContent
                            )
                        }
                    }
                }
            case .training(let navigationPath, let startingAt, let editPresetWhenComplete):
                PresetsTrainingView(
                    navigationPath: navigationPath,
                    startingAt: startingAt,
                    trainingCompletionConfiguration: .trainingCompletion(trainingCompletion),
                    trainingContent: trainingContent
                ) {
                    if let editPresetWhenComplete {
                        activeSheet = .editPreset(editPresetWhenComplete)
                    }
                }
            }
        }
        .sheet(isPresented: $presentCreateView) {
            CreatePresetView(
                createPreset: settingsManager.createPreset,
                impactForInsulinMultiplier: { settingsManager.therapySettings.impact(for: $0) },
                scheduleNextPresetReminder: temporaryPresetsManager.scheduleNextPresetReminder,
                scheduledRange: { scheduledRange },
                setScheduleOverride: { temporaryPresetsManager.scheduleOverride = $0 },
                suspendThreshold: { settingsManager.settings.suspendThreshold }
            )
        }
        .alert(isPresented: $presentTrainingNeededAlert) {
            trainingNeededAlert
        }
    }
    
    @ViewBuilder
    private func scheduledPresetRow(
        preset: SelectablePreset,
        nextStart: Date
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(preset.name)
                    .font(.headline)

                Text(scheduleDescription(for: preset))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if preset.repeatOptions != .none {
                    Text("Next: \(nextScheduledDateDescription(nextStart))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(.green)

                Text(preset.duration.localizedTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.tertiarySystemBackground))
        )
    }
    
    private struct SwipeToUnscheduleRow<Content: View>: View {
        let onUnschedule: () -> Void
        @ViewBuilder let content: () -> Content

        @State private var offset: CGFloat = 0

        private let actionWidth: CGFloat = 110

        var body: some View {
            ZStack(alignment: .trailing) {
                Button(role: .destructive) {
                    withAnimation {
                        offset = 0
                    }

                    onUnschedule()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "calendar.badge.minus")
                        Text("Unschedule")
                            .font(.caption)
                    }
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
                }

                content()
                    .offset(x: offset)
                    .gesture(
                        DragGesture(minimumDistance: 15)
                            .onChanged { value in
                                let translation = value.translation.width

                                if translation < 0 {
                                    offset = max(
                                        translation,
                                        -actionWidth
                                    )
                                } else if offset < 0 {
                                    offset = min(
                                        0,
                                        -actionWidth + translation
                                    )
                                }
                            }
                            .onEnded { value in
                                withAnimation(.snappy) {
                                    if value.translation.width < -40 {
                                        offset = -actionWidth
                                    } else {
                                        offset = 0
                                    }
                                }
                            }
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }  
    
    private func unschedulePreset(_ preset: SelectablePreset) {
        var updatedPreset = preset

        // Remove recurrence and scheduled start.
        updatedPreset.repeatOptions = .none
        updatedPreset.scheduleStartDate = nil

        // Save the preset itself — we are NOT deleting it.
        settingsManager.savePreset(updatedPreset)

        Task {
            // Remove any notification/reminder associated with
            // the old scheduled version.
            await temporaryPresetsManager
                .unschedulePresetReminderIfNeeded(preset)

            // Schedule the reminder for whichever scheduled
            // preset is now next.
            await temporaryPresetsManager
                .scheduleNextPresetReminder()
        }
    }
    
    private func scheduleDescription(for preset: SelectablePreset) -> String {
        guard let startDate = preset.scheduleStartDate else {
            return "Scheduled"
        }

        if preset.repeatOptions == .none {
            let formattedDate = startDate.formatted(
                .dateTime
                    .weekday(.wide)
                    .month(.wide)
                    .day()
                    .hour()
                    .minute()
            )

            return "Scheduled for \(formattedDate)"
        }

        let time = startDate.formatted(
            date: .omitted,
            time: .shortened
        )

        return "Repeats \(preset.repeatOptions) at \(time)"
    }

    
    private func nextScheduledDateDescription(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "Today at \(date.formatted(date: .omitted, time: .shortened))"
        }

        if calendar.isDateInTomorrow(date) {
            return "Tomorrow at \(date.formatted(date: .omitted, time: .shortened))"
        }

        return date.formatted(
            .dateTime
                .weekday(.abbreviated)
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
        )
    }
    
    private var trainingNeededAlert: SwiftUI.Alert {
        Alert(title: Text("Training Required for New Presets", comment: "Preset training needed alert title"),
              message: Text("To create a new preset, you must complete the required training.", comment: "Preset training needed alert message"),
              primaryButton: startNeededTrainingButton,
              secondaryButton: closeButton)
    }
    
    private var startNeededTrainingButton: SwiftUI.Alert.Button {
        .cancel(Text("Close", comment: "Preset training needed alert cancel button"))
    }

    private var closeButton: SwiftUI.Alert.Button {
        .default(Text("Start Required Training", comment: "CPreset training needed alert start training button")) {
            activeSheet = .training()
        }
    }

    private var sortMenu: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sort By")
                    .font(.headline)
                Spacer()
                Button(action: {
                    presetsSortAscending.toggle()
                }) {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            .padding(.horizontal)
            .padding(.top, 20)
            Divider()

            ForEach(PresetSortOption.allCases, id: \.self) { option in
                Button(action: {
                    selectedSortOption = option
                    showingMenu = false
                }) {
                    HStack {
                        if selectedSortOption == option {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: "checkmark")
                                .hidden()
                        }
                        Text(option.description)
                            .font(.body)
                    }
                    .padding(.horizontal)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.bottom, option == PresetSortOption.allCases.last ? 12 : 0)
                if option != PresetSortOption.allCases.last {
                    Divider()
                }
            }
        }
        .frame(width: 200)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .presentationCompactAdaptation(.popover)
    }

    private var dismissButton: some View {
        Button("Done") {
            dismiss()
        }
        .bold()
        .accessibilityIdentifier("button_done")
    }
}

extension PresetCard {
    init (_ preset: SelectablePreset, guardrail: Guardrail<LoopQuantity>, expectedEndTime: PresetExpectedEndTime? = nil, activePresetId: @escaping () -> String?, effectiveCorrectionRange: @escaping () -> ClosedRange<LoopQuantity>?) {
        var activityPresetIsModified: Bool? = nil
        if case let .activity(activityPreset) = preset {
            activityPresetIsModified = activityPreset.isModifiedFromDefault
        }
        
        self.init(
            presetId: preset.id,
            icon: preset.icon,
            presetName: preset.name,
            duration: preset.duration,
            insulinMultiplier: preset.insulinNeedsScaleFactor,
            correctionRange: preset.correctionRange,
            guardrail: guardrail,
            expectedEndTime: expectedEndTime,
            isScheduled: preset.isScheduled,
            activityPresetIsModified: activityPresetIsModified,
            activePresetId: activePresetId,
            effectiveCorrectionRange: effectiveCorrectionRange
        )
    }
}
