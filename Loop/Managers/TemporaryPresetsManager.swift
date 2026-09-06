//
//  TemporaryPresetsManager.swift
//  Loop
//
//  Created by Pete Schwamb on 11/1/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import os.log
import LoopCore
import LoopAlgorithm

protocol PresetActivationObserver: AnyObject {
    func presetActivated(context: TemporaryScheduleOverride.Context, duration: TemporaryScheduleOverride.Duration)
    func presetDeactivated(context: TemporaryScheduleOverride.Context)
}

@MainActor
@Observable
class TemporaryPresetsManager {

    @ObservationIgnored private let log = OSLog(category: "TemporaryPresetsManager")

    let managerIdentifier = "TemporaryPresetsManager"

    @ObservationIgnored private var settingsProvider: SettingsProvider

    var presetHistory: TemporaryScheduleOverrideHistory

    @ObservationIgnored private var alertIssuer: AlertIssuer?

    @ObservationIgnored private var presetActivationObservers: [PresetActivationObserver] = []

    @ObservationIgnored private var overrideIntentObserver: NSKeyValueObservation? = nil
    
    @ObservationIgnored private var lastAutoStartedOccurrence: [String: Date] = [:]

    private var now: Date { TestingDate.currentTestingDate() }

    init(settingsProvider: SettingsProvider, alertIssuer: AlertIssuer? = nil, presetHistory: TemporaryScheduleOverrideHistory? = nil) {
        self.settingsProvider = settingsProvider
        self.alertIssuer = alertIssuer

        self.presetHistory = presetHistory ?? TemporaryScheduleOverrideHistoryContainer.shared.fetch()
        TemporaryScheduleOverrideHistory.relevantTimeWindow = Bundle.main.localCacheDuration

        _scheduleOverride = self.presetHistory.activeOverride(at: now)

        overrideIntentObserver = UserDefaults.appGroup?.observe(
            \.intentExtensionOverrideToSet,
             options: [.new],
             changeHandler:
                { [weak self] (defaults, change) in
                    Task { @MainActor in
                        self?.handleIntentOverrideAction(default: defaults, change: change)
                    }
                }
        )
    }

    private func handleIntentOverrideAction(default: UserDefaults, change: NSKeyValueObservedChange<String?>) {
        guard let name = change.newValue??.lowercased(),
              let appGroup = UserDefaults.appGroup else 
        {
            return
        }

        guard let preset = settingsProvider.settings.overridePresets.first(where: {$0.name.lowercased() == name}) else
        {
            log.error("Override Intent: Unable to find override named '%s'", String(describing: name))
            return
        }

        log.default("Override Intent: setting override named '%s'", String(describing: name))
        scheduleOverride = preset.createOverride(enactTrigger: .remote("Siri"))

        // Remove the override from UserDefaults so we don't set it multiple times
        appGroup.intentExtensionOverrideToSet = nil
    }

    public func addTemporaryPresetObserver(_ observer: PresetActivationObserver) {
        presetActivationObservers.append(observer)
    }

    var preMealOverride: TemporaryScheduleOverride? {
        scheduleOverride?.context == .preMeal ? scheduleOverride : nil
    }

    var scheduleOverride: TemporaryScheduleOverride? {
        didSet {
            guard oldValue != scheduleOverride else {
                return
            }
         
            presetHistory.recordOverride(scheduleOverride)

            if let oldPreset = oldValue {
                for observer in self.presetActivationObservers {
                    observer.presetDeactivated(context: oldPreset.context)
                }
                
                if oldPreset.duration == .indefinite {
                    Task { @MainActor in
                        await clearIndefinitePresetReminder(oldPreset)
                    }
                }
            }
            if let newPreset = scheduleOverride {
                for observer in self.presetActivationObservers {
                    observer.presetActivated(context: newPreset.context, duration: newPreset.duration)
                }
                
                scheduleClearOverride(override: newPreset)
                
                if newPreset.duration == .indefinite {
                    Task { @MainActor in
                        await scheduleIndefinitePresetReminder(newPreset)
                    }
                }
            }

            notify(forChange: .preferences)
        }
    }

    public var activeOverride: TemporaryScheduleOverride? {
        if scheduleOverride?.isActive(at: now) == true {
            return scheduleOverride
        } else {
            return nil
        }
    }

    public var activePreset: SelectablePreset? {
        return activeOverride?.createPreset()
    }

    var selectablePresets: [SelectablePreset] {
        var presets: [SelectablePreset] = []

        let settings = settingsProvider.settings

        if let activeOverride, activeOverride.context == .custom {
            presets.append(activePreset!)
        }

        if let preMealTargetRange = settings.preMealTargetRange {
            presets.append(.preMeal(range: preMealTargetRange))
        }

        presets.append(contentsOf: settings.overridePresets.map { override in
            if override.id.hasPrefix("activity-"), let activityPreset = ActivityPreset(preset: override) {
                return .activity(activityPreset)
            } else {
                return .custom(override)
            }
        })
        
        ActivityPreset.ActivityType.allCases.forEach { activityType in
            if !settings.overridePresets.contains(where: { $0.id == activityType.id }) {
                presets.append(.activity(ActivityPreset(activityType: activityType, preset: activityType.completeDefaultPreset)))
            }
        }

        return presets
    }

    var clearOverrideTimer: Timer?
    public func scheduleClearOverride(override: TemporaryScheduleOverride) {
        clearOverrideTimer?.invalidate()
        if override.duration.isInfinite { return }
        if override.scheduledEndDate < now { return }
        
        log.default("Scheduling override end timer %{public}@", String(describing: override))


        clearOverrideTimer = Timer.scheduledTimer(withTimeInterval: override.scheduledEndDate.timeIntervalSince(now), repeats: false, block: { [weak self] _ in
            Task {
                self?.log.default("override end timer fired for %{public}@", String(describing: override))
                await self?.endOverride(override)
            }
        })
    }

    func endOverride(_ override: TemporaryScheduleOverride) {
        if override == scheduleOverride {
            clearOverride()
        }
    }
    
    func scheduleIndefinitePresetReminder(_ override: TemporaryScheduleOverride) async {
        let preset = override.createPreset()
        let indefinitePresetIdentifier = Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: preset.id)
        
        let title = String(format: NSLocalizedString("%1$@ Still Active", comment: "The format title for the preset still active alert. (1: preset name)"), preset.name)

        let foregroundBody = String(
            format: NSLocalizedString("%1$@ has been active for more than 24 hours. Make sure you still want it enabled, or turn it off.", comment: "Active preset reminder alert foreground body. (1: preset name)"),
            preset.name
        )
        
        let backgroundBody = String(
            format: NSLocalizedString("%1$@ has been active for more than 24 hours. Make sure you still want it enabled, or turn it off in the app.", comment: "Active preset reminder alert background body. (1: preset name)"),
            preset.name
        )

        let actions = [
            Alert.UserAlertAction(
                label: NSLocalizedString("OK", comment: "Label for acknowledging the preset has been active for 24 hours"),
                identifier: "ok",
                style: .default
            ),
        ]

        let foregroundContent = Alert.Content(title: title,
                                              body: foregroundBody,
                                              actions: actions)

        let backgroundContent = Alert.Content(title: title,
                                              body: backgroundBody,
                                              actions: actions)

        let metadata: Alert.Metadata = [LoopNotificationUserInfoKey.presetId.rawValue: Alert.MetadataValue(preset.id)]

        let alert = Alert(
            identifier: indefinitePresetIdentifier,
            foregroundContent: foregroundContent,
            backgroundContent: backgroundContent,
            trigger: .repeating(repeatInterval: .hours(24)),
            interruptionLevel: .timeSensitive,
            metadata: metadata,
            categoryIdentifier: LoopNotificationCategory.presetReminder.rawValue
        )

        await alertIssuer?.issueAlert(alert)
    }
    
    func clearIndefinitePresetReminder(_ override: TemporaryScheduleOverride) async {
        let preset = override.createPreset()
        let indefinitePresetIdentifier = Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: preset.id)
        await alertIssuer?.retractAlert(identifier: indefinitePresetIdentifier)
    }

    public func effectiveCorrectionRangeSchedule(presumingMealEntry: Bool = false) -> GlucoseRangeSchedule?  {

        guard let glucoseTargetRangeSchedule = settingsProvider.settings.glucoseTargetRangeSchedule else {
            return nil
        }

        var scheduleOverride = scheduleOverride

        if presumingMealEntry && scheduleOverride?.context == .preMeal {
            scheduleOverride = nil
        }

        if let effectiveOverride = scheduleOverride {
            return glucoseTargetRangeSchedule.applyingOverride(effectiveOverride)
        } else {
            return glucoseTargetRangeSchedule
        }
    }

    public func effectiveCorrectionRange() -> ClosedRange<LoopQuantity>? {
        guard let schedule = settingsProvider.settings.glucoseTargetRangeSchedule else { return nil }

        let scheduledRange = schedule.quantityRange(at: now)

        if let override = activeOverride {
            return override.effectiveCorrectionRangeDuring(scheduledRange: scheduledRange)
        }

        return scheduledRange
    }

    public func isScheduleOverrideActive(at date: Date? = nil) -> Bool {
        return scheduleOverride?.isActive(at: date ?? now) == true
    }

    public func isNonPreMealOverrideActive(at date: Date? = nil) -> Bool {
        return isScheduleOverrideActive(at: date ?? now) == true && scheduleOverride?.context != .preMeal
    }

    public func isPreMealTargetActive(at date: Date? = nil) -> Bool {
        return isScheduleOverrideActive(at: date ?? now) == true && scheduleOverride?.context == .preMeal
    }

    public func futureOverrideEnabled(relativeTo date: Date? = nil) -> Bool {
        guard let scheduleOverride = scheduleOverride else { return false }
        return scheduleOverride.startDate > date ?? now
    }

    public func enablePreMealOverride(at date: Date? = nil, for duration: TimeInterval) {
        scheduleOverride = makePreMealOverride(beginningAt: date ?? now, for: duration)
    }

    private func makePreMealOverride(beginningAt date: Date? = nil, for duration: TimeInterval) -> TemporaryScheduleOverride? {
        guard let preMealTargetRange = settingsProvider.settings.preMealTargetRange else {
            return nil
        }
        return TemporaryScheduleOverride(
            context: .preMeal,
            settings: TemporaryPresetSettings(targetRange: preMealTargetRange),
            startDate: date ?? now,
            duration: .finite(duration),
            enactTrigger: .local,
            syncIdentifier: UUID()
        )
    }

    func startPreset(withIdentifier identifier: String) {
        guard let preset = selectablePresets.first(where: { $0.id == identifier }) else {
            log.error("Unable to find preset with identifier ${public}@", identifier)
            return
        }
        startPreset(preset)
    }


    func startPreset(_ preset: SelectablePreset) {
        scheduleOverride = preset.createOverride()
    }

    public func endPreMealOverride() {
        if let activeOverride = scheduleOverride, activeOverride.isActive(), activeOverride.context == .preMeal {
            scheduleOverride?.scheduledEndDate = .now
            clearOverride()
        }
    }

    public func clearOverride() {
        self.scheduleOverride = nil
    }

    public var basalRateScheduleApplyingOverrideHistory: BasalRateSchedule? {
        if let basalSchedule = settingsProvider.settings.basalRateSchedule {
            return presetHistory.resolvingRecentBasalSchedule(basalSchedule)
        } else {
            return nil
        }
    }

    /// The insulin sensitivity schedule, applying recent overrides relative to the current moment in time.
    public var insulinSensitivityScheduleApplyingOverrideHistory: InsulinSensitivitySchedule? {
        if let insulinSensitivitySchedule = settingsProvider.settings.insulinSensitivitySchedule {
            return presetHistory.resolvingRecentInsulinSensitivitySchedule(insulinSensitivitySchedule)
        } else {
            return nil
        }
    }

    public var carbRatioScheduleApplyingOverrideHistory: CarbRatioSchedule? {
        if let carbRatioSchedule = carbRatioSchedule {
            return presetHistory.resolvingRecentCarbRatioSchedule(carbRatioSchedule)
        } else {
            return nil
        }
    }

    private func notify(forChange context: LoopUpdateContext) {
        NotificationCenter.default.post(name: .LoopDataUpdated,
            object: self,
            userInfo: [
                LoopDataManager.LoopUpdateContextKey: context.rawValue
            ]
        )
    }

    func updateActivePresetDuration(newEndDate: Date) {
        if var scheduleOverride {
            if newEndDate > now {
                scheduleOverride.scheduledEndDate = newEndDate
            } else {
                scheduleOverride.scheduledEndDate = newEndDate.addingTimeInterval(.days(1))
            }
            
            self.scheduleOverride = scheduleOverride
            self.scheduleClearOverride(override: scheduleOverride)
        }
    }

    var lastUsed: [String: Date]?

    func lastUsed(id: String) -> Date? {
        if lastUsed == nil {
            let enacts = presetHistory.getOverrideHistory(startDate: .distantPast, endDate: now)
            lastUsed = [:]
            for enact in enacts {
                var id: String
                switch enact.context {
                    case .preMeal: id = "preMeal"
                    case .activity(let activity): id = activity.id
                    case .preset(let preset): id = preset.id
                    case .custom: continue
                }
                lastUsed![id] = max(lastUsed![id] ?? .distantPast, enact.startDate)
            }
        }
        return lastUsed![id]
    }
    
    // MARK: - Scheduled Preset Auto Start

    /// Returns a scheduled occurrence if this preset was due recently.
    ///
    /// Loop may not execute at the exact scheduled second while the app is in the
    /// background, so we allow a short grace period after the scheduled time.
    private func autoStartOccurrence(
        for preset: TemporaryPreset,
        at date: Date
    ) -> Date? {
        guard preset.autoStartScheduledPreset,
              preset.scheduleStartDate != nil
        else {
            return nil
        }

        // Allow Loop to catch a scheduled preset on a subsequent heartbeat.
        let gracePeriod: TimeInterval = .minutes(10)
        let lookbackDate = date.addingTimeInterval(-gracePeriod)

        guard let occurrence = preset.nextScheduledStartAfter(lookbackDate) else {
            return nil
        }

        // The occurrence is still in the future.
        guard occurrence <= date else {
            return nil
        }

        // Do not start a preset long after its intended scheduled time.
        guard date.timeIntervalSince(occurrence) <= gracePeriod else {
            return nil
        }

        return occurrence
    }

    /// Returns true if this exact scheduled occurrence has already been handled.
    private func alreadyHandledAutoStart(
        preset: TemporaryPreset,
        occurrence: Date
    ) -> Bool {
        // If this same preset is already active, don't restart it.
        if activeOverride?.presetId == preset.id {
            return true
        }

        // Prevent repeated activation on subsequent Loop wakes.
        if let previousOccurrence = lastAutoStartedOccurrence[preset.id],
           abs(previousOccurrence.timeIntervalSince(occurrence)) < 1
        {
            return true
        }

        return false
    }

    /// Starts any scheduled preset whose automatic-start time has recently passed.
    ///
    /// This method needs to be called whenever Loop receives background execution
    /// (for example, as part of the normal Loop wake/update path).
    func startScheduledPresetsIfNeeded(at date: Date? = nil) {
        let checkDate = date ?? now
        let settings = settingsProvider.settings

        for preset in settings.overridePresets {
            guard let occurrence = autoStartOccurrence(
                for: preset,
                at: checkDate
            ) else {
                continue
            }

            guard !alreadyHandledAutoStart(
                preset: preset,
                occurrence: occurrence
            ) else {
                continue
            }

            guard let selectablePreset = selectablePresets.first(
                where: { $0.id == preset.id }
            ) else {
                log.error(
                    "Unable to find scheduled preset for automatic start: %{public}@",
                    preset.id
                )
                continue
            }

            log.default(
                "Automatically starting scheduled preset %{public}@",
                preset.name
            )

            // Mark this occurrence first so another callback cannot immediately
            // start the same preset again.
            lastAutoStartedOccurrence[preset.id] = occurrence

            // Use Loop's existing preset activation path.
            startPreset(selectablePreset)

            // Remove any reminder that may previously have been scheduled for
            // this preset before Auto Start was enabled.
            Task { @MainActor in
                await alertIssuer?.retractAlert(
                    identifier: Alert.Identifier(
                        managerIdentifier: managerIdentifier,
                        alertIdentifier: preset.id
                    )
                )
            }
        }
    }
    
    func unschedulePresetReminderIfNeeded(_ preset: SelectablePreset) async {
        guard preset.isScheduled else { return }
        await alertIssuer?.retractAlert(identifier: Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: preset.id))
    }

    func scheduleNextPresetReminder() async {

        let settings = settingsProvider.settings

        let now = now

        // Auto-start presets should not also display the manual-start reminder.
        // Retract any reminder that may have been scheduled before Auto Start
        // was enabled.
        for preset in settings.overridePresets where preset.autoStartScheduledPreset {
            let identifier = Alert.Identifier(
                managerIdentifier: managerIdentifier,
                alertIdentifier: preset.id
            )

            await alertIssuer?.retractAlert(identifier: identifier)
        }

        // Only manually-started scheduled presets should receive the
        // "Start Scheduled Preset?" notification.
        let preset = settings.overridePresets
            .filter { !$0.autoStartScheduledPreset }
            .reduce(into: nil as TemporaryPreset?) { result, preset in

                if let nextScheduledTime = preset.nextScheduledStartAfter(now) {
                    if result == nil ||
                        nextScheduledTime < (result!.nextScheduledStartAfter(now)!)
                    {
                        result = preset
                    }
                }
            }

        if let preset {

            let nextScheduledPresetReminderIdentifier = Alert.Identifier(
                managerIdentifier: managerIdentifier,
                alertIdentifier: preset.id
            )

            await alertIssuer?.retractAlert(
                identifier: nextScheduledPresetReminderIdentifier
            )

            let nextScheduledTime = preset.nextScheduledStartAfter(now)!

            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short

            let title = NSLocalizedString(
                "Start Scheduled Preset?",
                comment: "Scheduled preset reminder title"
            )

            let body = String(
                format: NSLocalizedString(
                    "Would you like to start your %1$@ preset?\n\nThis will end any active preset.",
                    comment: "Scheduled preset reminder alert body. (1: preset name)"
                ),
                preset.name
            )

            let actions = [
                Alert.UserAlertAction(
                    label: NSLocalizedString(
                        "Don't Start",
                        comment: "Label for do not start preset action on scheduled preset reminder alert"
                    ),
                    identifier: "acknowledge",
                    style: .default
                ),

                Alert.UserAlertAction(
                    label: NSLocalizedString(
                        "Yes, Start Now",
                        comment: "Label for do yes, start preset now action on scheduled preset reminder alert"
                    ),
                    identifier: "startPreset",
                    style: .cancel
                )
            ]

            let content = Alert.Content(
                title: title,
                body: body,
                actions: actions
            )

            let metadata: Alert.Metadata = [
                LoopNotificationUserInfoKey.presetId.rawValue:
                    Alert.MetadataValue(preset.id)
            ]

            let alert = Alert(
                identifier: nextScheduledPresetReminderIdentifier,
                foregroundContent: content,
                backgroundContent: content,
                trigger: .delayed(
                    interval: nextScheduledTime.timeIntervalSince(now)
                ),
                interruptionLevel: .timeSensitive,
                metadata: metadata,
                categoryIdentifier:
                    LoopNotificationCategory.presetReminder.rawValue
            )

            await alertIssuer?.issueAlert(alert)
        }
    }
}

extension TemporaryPresetsManager {
    static var placeholder: TemporaryPresetsManager {
        .init(settingsProvider: SettingsManager.placeholder)
    }
}

extension TemporaryPresetsManager : AlertResponder {
    func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier) async throws {
        
    }

    func handleAlertAction(actionIdentifier: String, from alert: Alert) async throws {
        if actionIdentifier == UNNotificationDismissActionIdentifier { return }

        if actionIdentifier == NotificationManager.Action.startPreset.rawValue,
           let metdata = alert.metadata,
           let presetIdentifier = metdata["presetId"]?.wrapped as? String
        {
            startPreset(withIdentifier: presetIdentifier)
            await alertIssuer?.retractAlert(identifier: Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: presetIdentifier))
        } else {
            log.error("Could not identify preset to activate for alert action: actionIdentifier=%{public}@, alert=%{public}@", actionIdentifier, String(describing: alert))
        }
    }
}

// MARK: - AutoPresets

extension TemporaryPresetsManager: AutoPresets_Delegate {

    func autoPresets(
        _ coordinator: AutoPresets_Coordinator,
        shouldActivatePreset preset: TemporaryPreset
    ) {
        startPreset(withIdentifier: preset.id)
    }

    func autoPresets(
        _ coordinator: AutoPresets_Coordinator,
        shouldDeactivatePreset preset: TemporaryPreset
    ) {
        guard activeOverride?.presetId == preset.id else {
            return
        }

        clearOverride()
    }

    func autoPresetsAvailablePresets(
        _ coordinator: AutoPresets_Coordinator
    ) -> [TemporaryPreset] {
        settingsProvider.settings.overridePresets
    }

    func autoPresetsCurrentOverride(
        _ coordinator: AutoPresets_Coordinator
    ) -> TemporaryScheduleOverride? {
        activeOverride
    }
}

@MainActor
public protocol SettingsWithOverridesProvider {
    var insulinSensitivityScheduleApplyingOverrideHistory: InsulinSensitivitySchedule? { get }
    var carbRatioSchedule: CarbRatioSchedule? { get }
    var maximumBolus: Double? { get }
}

extension TemporaryPresetsManager : SettingsWithOverridesProvider {
    var carbRatioSchedule: LoopKit.CarbRatioSchedule? {
        settingsProvider.settings.carbRatioSchedule
    }

    var maximumBolus: Double? {
        settingsProvider.settings.maximumBolus
    }
}
