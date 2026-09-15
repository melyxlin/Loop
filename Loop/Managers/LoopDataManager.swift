//
//  LoopDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/12/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Combine
import Foundation
import LoopAlgorithm
import LoopCore
import LoopKit
import LoopKitUI
import OSLog
import WidgetKit

struct AlgorithmDisplayState {
    var input: StoredDataAlgorithmInput?
    var output: AlgorithmOutput<StoredCarbEntry>?

    var activeInsulin: InsulinValue? {
        guard let input, let value = output?.activeInsulin else {
            return nil
        }
        return InsulinValue(startDate: input.predictionStart, value: value)
    }

    var activeCarbs: CarbValue? {
        guard let input, let value = output?.activeCarbs else {
            return nil
        }
        return CarbValue(startDate: input.predictionStart, value: value)
    }

    var asTuple:
        (
            algoInput: StoredDataAlgorithmInput?,
            algoOutput: AlgorithmOutput<StoredCarbEntry>?
        )
    {
        return (algoInput: input, algoOutput: output)
    }
}

protocol DeliveryDelegate: AnyObject {
    var isSuspended: Bool { get }
    var isManualTempBasalRunning: Bool { get }
    var pumpInsulinType: InsulinType? { get }
    var basalDeliveryState: PumpManagerStatus.BasalDeliveryState? { get }
    var isPumpConfigured: Bool { get }
    var pumpManagerStatus: PumpManagerStatus? { get }
    var pumpStatusHighlight: DeviceStatusHighlight? { get }
    var cgmManagerStatus: CGMManagerStatus? { get }

    func enact(
        bolus: Double?,
        tempBasal: TempBasalRecommendation?,
        decisionId: UUID?
    ) async throws
    func enactBolus(
        units: Double,
        decisionId: UUID?,
        activationType: BolusActivationType
    ) async throws
    func roundBasalRate(unitsPerHour: Double) -> Double
    func roundBolusVolume(units: Double) -> Double
}

extension PumpManagerStatus.BasalDeliveryState {
    var currentTempBasal: DoseEntry? {
        switch self {
        case .tempBasal(let dose):
            return dose
        default:
            return nil
        }
    }

    func currentBasalRate(currentScheduledBasalRate: Double) -> Double? {
        switch self {
        case .tempBasal(let dose):
            return dose.unitsPerHour
        case .suspended:
            return 0
        case .pumpInoperable:
            return nil
        default:
            return currentScheduledBasalRate
        }
    }
}

protocol DosingManagerDelegate {
    func didMakeDosingDecision(_ decision: StoredDosingDecision)
}

enum LoopUpdateContext: Int {
    case insulin
    case carbs
    case glucose
    case preferences
    case forecast
}

@MainActor
final class LoopDataManager: ObservableObject {
    nonisolated static let LoopUpdateContextKey =
        "com.loudnate.Loop.LoopDataManager.LoopUpdateContext"

    // Represents the current state of the loop algorithm for display
    var displayState = AlgorithmDisplayState()

    // Display state convenience accessors
    var predictedGlucose: [PredictedGlucoseValue]? {
        displayState.output?.predictedGlucose
    }

    var tempBasalRecommendation: TempBasalRecommendation? {
        displayState.output?.recommendation?.automatic?.basalAdjustment
    }

    var automaticBolusRecommendation: Double? {
        displayState.output?.recommendation?.automatic?.bolusUnits
    }

    var automaticRecommendation: AutomaticDoseRecommendation? {
        displayState.output?.recommendation?.automatic
    }

    @Published private(set) var lastLoopCompleted: Date?
    @Published private(set) var publishedMostRecentGlucoseDataDate: Date?
    @Published private(set) var publishedMostRecentPumpDataDate: Date?
    @Published private(set) var lastManualBolus: LastManualBolus?
    private var lastDynamicISFShadowGlucoseDate: Date?
    private var lastDynamicISFState: DynamicISFState = .inactive
    private var dynamicISFConcernEpisode: DynamicISFConcernEpisode?
    private var dynamicISFRecoveryObservationStartDate: Date?
    // Tracks confirmed resistance within the current Dynamic ISF episode.
    //
    // An episode may continue through:
    // waitingForResponse → resistant → recovering → waitingForResponse → resistant
    //
    // The episode ends when the state reaches .observing or .inactive.
    private var dynamicISFHasConfirmedResistanceInEpisode = false

    // Highest shadow strength reached while resistance was confirmed
    // during the current episode.
    //
    // This remains remembered during .recovering and reconfirmation,
    // but is not active unless the current state is .resistant.
    private var dynamicISFRememberedResistanceStrength: Double = 0
    // Number of distinct resistant confirmations within the current
    // Dynamic ISF episode.
    //
    // Increment only when transitioning INTO .resistant.
    // Reset when the episode ends.
    private var dynamicISFResistanceConfirmationCount = 0

    private let dynamicISFLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Loop",
        category: "DynamicISF"
    )

    var deliveryDelegate: DeliveryDelegate?

    let analyticsServicesManager: AnalyticsServicesManager?
    let carbStore: CarbStoreProtocol
    let doseStore: DoseStoreProtocol
    let temporaryPresetsManager: TemporaryPresetsManager
    let settingsProvider: SettingsProvider
    let dosingDecisionStore: DosingDecisionStoreProtocol
    let glucoseStore: GlucoseStoreProtocol
    let crashRecoveryManager: CrashRecoveryManager

    let logger = DiagnosticLog(category: "LoopDataManager")

    private let widgetLog = DiagnosticLog(category: "LoopWidgets")

    private let trustedTimeOffset: () async -> TimeInterval

    private var now: Date { TestingDate.currentTestingDate() }

    // References to registered notification center observers
    private var notificationObservers: [Any] = []
    private var overrideIntentObserver: NSKeyValueObservation? = nil

    var activeInsulin: InsulinValue? {
        displayState.activeInsulin
    }
    var activeCarbs: CarbValue? {
        displayState.activeCarbs
    }

    var latestGlucose: GlucoseSampleValue? {
        displayState.input?.glucoseHistory.last
    }

    private var insulinOnBoard: InsulinValue?

    private var liveActivityManager: LiveActivityManagerProxy?
    var lastReservoirValue: ReservoirValue? {
        doseStore.lastReservoirValue
    }

    var carbAbsorptionModel: CarbAbsorptionModel

    private var lastManualBolusRecommendation: ManualBolusRecommendation?

    private(set) var dosingStrategySelectionEnabled: Bool

    var usePositiveMomentumAndRCForManualBoluses: Bool

    var automationHistory: [AutomationHistoryEntry] {
        didSet {
            UserDefaults.standard.automationHistory = automationHistory
        }
    }

    lazy private var cancellables = Set<AnyCancellable>()

    init(
        lastLoopCompleted: Date?,
        temporaryPresetsManager: TemporaryPresetsManager,
        settingsProvider: SettingsProvider,
        doseStore: DoseStoreProtocol,
        glucoseStore: GlucoseStoreProtocol,
        carbStore: CarbStoreProtocol,
        crashRecoveryManager: CrashRecoveryManager,
        dosingDecisionStore: DosingDecisionStoreProtocol,
        trustedTimeOffset: @escaping () async -> TimeInterval,
        analyticsServicesManager: AnalyticsServicesManager?,
        carbAbsorptionModel: CarbAbsorptionModel,
        usePositiveMomentumAndRCForManualBoluses: Bool = true,
        dosingStrategySelectionEnabled: Bool = true,
    ) {

        self.lastLoopCompleted = lastLoopCompleted
        self.temporaryPresetsManager = temporaryPresetsManager
        self.settingsProvider = settingsProvider
        self.doseStore = doseStore
        self.glucoseStore = glucoseStore
        self.carbStore = carbStore
        self.crashRecoveryManager = crashRecoveryManager
        self.dosingDecisionStore = dosingDecisionStore
        self.trustedTimeOffset = trustedTimeOffset
        self.analyticsServicesManager = analyticsServicesManager
        self.carbAbsorptionModel = carbAbsorptionModel
        self.usePositiveMomentumAndRCForManualBoluses =
            usePositiveMomentumAndRCForManualBoluses
        self.automationHistory = UserDefaults.standard.automationHistory
        self.publishedMostRecentGlucoseDataDate =
            glucoseStore.latestGlucose?.startDate
        self.dosingStrategySelectionEnabled = dosingStrategySelectionEnabled
        self.publishedMostRecentPumpDataDate = mostRecentPumpDataDate
        _ = SiteAtlas_Coordinator.shared

        if #available(iOS 16.2, *) {
            self.liveActivityManager = LiveActivityManager(
                glucoseStore: self.glucoseStore,
                doseStore: self.doseStore
            )
        }

        overrideIntentObserver = UserDefaults.appGroup?.observe(
            \.intentExtensionOverrideToSet,
            options: [.new],
            changeHandler: { [weak self] (defaults, change) in
                guard let name = change.newValue??.lowercased(),
                    let appGroup = UserDefaults.appGroup
                else {
                    return
                }

                guard
                    let preset = self?.settings.overridePresets.first(where: {
                        $0.name.lowercased() == name
                    })
                else {
                    self?.logger.error(
                        "Override Intent: Unable to find override named '%s'",
                        String(describing: name)
                    )
                    return
                }

                self?.logger.default(
                    "Override Intent: setting override named '%s'",
                    String(describing: name)
                )
                // TemporaryPresetsManager handles presetActivated/Deactivated observers automatically
                self?.temporaryPresetsManager.scheduleOverride =
                    preset.createOverride(enactTrigger: .remote("Siri"))
                Task { @MainActor in
                    await self?.updateDisplayState()
                }
                // Remove the override from UserDefaults so we don't set it multiple times
                appGroup.intentExtensionOverrideToSet = nil
            }
        )

        // Required for device settings in stored dosing decisions
        UIDevice.current.isBatteryMonitoringEnabled = true

        // Observe changes
        notificationObservers = [
            NotificationCenter.default.addObserver(
                forName: CarbStore.carbEntriesDidChange,
                object: self.carbStore,
                queue: nil
            ) { (note) -> Void in
                Task { @MainActor in
                    await self.updateDisplayState()
                    self.notify(forChange: .carbs)
                }
            },
            NotificationCenter.default.addObserver(
                forName: GlucoseStore.glucoseSamplesDidChange,
                object: self.glucoseStore,
                queue: nil
            ) { (note) in
                Task { @MainActor in
                    self.restartGlucoseValueStalenessTimer()
                    self.temporaryPresetsManager.startScheduledPresetsIfNeeded()
                    await self.updateDisplayState()
                    self.notify(forChange: .glucose)
                }
            },
            NotificationCenter.default.addObserver(
                forName: DoseStore.valuesDidChange,
                object: self.doseStore,
                queue: OperationQueue.main
            ) { (note) in
                Task { @MainActor in
                    await self.updateDisplayState()
                    self.notify(forChange: .insulin)
                }
            },
            NotificationCenter.default.addObserver(
                forName: .LoopDataUpdated,
                object: nil,
                queue: nil
            ) { (note) in
                let context =
                    note.userInfo?[LoopDataManager.LoopUpdateContextKey]
                    as! LoopUpdateContext.RawValue
                if case .preferences = LoopUpdateContext(rawValue: context) {
                    Task { @MainActor in
                        await self.updateDisplayState()
                        self.notify(forChange: .forecast)
                    }
                }
            },
        ]

        // Turn off preMeal when going into closed loop off mode
        // Cancel any active temp basal when going into closed loop off mode
        // The dispatch is necessary in case this is coming from a didSet already on the settings struct.

        withObservationTracking(of: settingsProvider.dosingEnabled) {
            [weak self] enabled in
            if let self, self.automationHistory.last?.enabled != enabled {
                self.automationHistory.append(
                    AutomationHistoryEntry(
                        startDate: self.now,
                        enabled: enabled
                    )
                )

                // Clean up entries older than 36 hours; we should not be interpolating basal data before then.
                let now = now
                self.automationHistory = self.automationHistory.filter({
                    entry in
                    now.timeIntervalSince(entry.startDate) < .hours(36)
                })

                Task {
                    await self.updateDisplayState()
                }
            }

            if !enabled {
                temporaryPresetsManager.endPreMealOverride()
                Task {
                    try? await self?.cancelActiveTempBasal(
                        for: .automaticDosingDisabled
                    )
                }
            }
        }
    }

    // MARK: - Calculation state
    // Note: settings are now accessed via settingsProvider.settings (StoredSettings)
    // and overrides via temporaryPresetsManager. DIY's lockedSettings/mutateSettings
    // were removed as part of the Swift Concurrency migration.

    fileprivate let dataAccessQueue: DispatchQueue = DispatchQueue(
        label: "com.loudnate.Naterade.LoopDataManager.dataAccessQueue",
        qos: .utility
    )

    // MARK: - Background task management

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func startBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "PersistenceController save"
        ) {
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func insulinModel(for type: InsulinType?) -> InsulinModel {
        switch type {
        case .fiasp:
            return ExponentialInsulinModelPreset.fiasp
        case .lyumjev:
            return ExponentialInsulinModelPreset.lyumjev
        case .afrezza:
            return ExponentialInsulinModelPreset.afrezza
        default:
            return settings.defaultRapidActingModel?
                .presetForRapidActingInsulin?.model
                ?? ExponentialInsulinModelPreset.rapidActingAdult
        }
    }

    // MARK: Negative Insulin Damper (algorithm experiment)

    static func calculateNegativeInsulinDamperAlpha(
        _ anchorAlpha: Double,
        _ anchorPoint: Double,
        _ marginalSlope: Double,
        _ posDeltaSum: Double
    ) -> Double {
        let linearScaleSlope = (1.0 - anchorAlpha) / anchorPoint  // how alpha scales down in the linear scale region

        // the slope in the linear scale region of alpha * posDeltaSum is 1 - 2*linearScaleSlope*posDeltaSum.
        // the transitionPoint is where we transition from linear scale region to marginalSlope. The slope is continuous at this point
        let transitionPoint = (1 - marginalSlope) / (2 * linearScaleSlope)

        if posDeltaSum < transitionPoint {  // linear scaling region
            return 1 - linearScaleSlope * posDeltaSum
        } else {  // marginal slope region
            let transitionValue =
                (1 - linearScaleSlope * transitionPoint) * transitionPoint
            return
                (transitionValue + marginalSlope
                * (posDeltaSum - transitionPoint)) / posDeltaSum
        }
    }

    /// Computes the Negative Insulin Damper coefficient in [0,1] for the given algorithm input, or nil.
    /// Mirrors the dev/main computation: the predicted future rise attributable to negative insulin
    /// (delivery below scheduled basal, up to 15 minutes ago) sets the damper strength.
    private func computeNegativeInsulinDamper(
        for input: StoredDataAlgorithmInput
    ) -> Double? {
        guard let latestGlucose = input.glucoseHistory.last else { return nil }
        let anchorDate = latestGlucose.startDate
        let lastDoseStartDate = anchorDate.addingTimeInterval(.minutes(-15))

        // Predicted insulin glucose-effect of everything delivered up to 15 minutes ago
        // (doses starting later are dropped, basal-type doses trimmed at t-15, boluses kept whole).
        let annotatedDoses = input.doses
            .trimmed(to: lastDoseStartDate)
            .annotated(with: input.basal)

        // Fail safe (disable the damper) rather than trip glucoseEffects' ISF-coverage
        // preconditionFailure, which would crash automated dosing.
        for dose in annotatedDoses {
            guard let isf = input.sensitivity.closestPrior(to: dose.startDate),
                isf.endDate >= dose.startDate
            else {
                return nil
            }
        }

        let effects = annotatedDoses.glucoseEffects(
            insulinSensitivityHistory: input.sensitivity,
            from: anchorDate.addingTimeInterval(.minutes(-5))
        )

        // Sum of positive 5-min deltas — the predicted future rise from negative insulin.
        var posDeltaSum = 0.0
        for (offset, effect) in effects.enumerated() where offset > 0 {
            let delta =
                effect.quantity.doubleValue(for: .milligramsPerDeciliter)
                - effects[offset - 1].quantity.doubleValue(
                    for: .milligramsPerDeciliter
                )
            posDeltaSum += max(0, delta)
        }

        guard let isf = input.sensitivity.closestPrior(to: anchorDate)?.value,
            let basalRate = input.basal.closestPrior(to: anchorDate)?.value
        else {
            return nil
        }

        // anchorScale is ~1 hour for rapid-acting adult, ~44 min for ultra-rapid insulins.
        let anchorScale: Double
        if let expModel = input.recommendationInsulinModel
            as? ExponentialInsulinModel
        {
            anchorScale = 0.8 * expModel.peakActivityTime.hours
        } else if let preset = input.recommendationInsulinModel
            as? ExponentialInsulinModelPreset
        {
            anchorScale = 0.8 * preset.peakActivity.hours
        } else {
            anchorScale = 1.0
        }

        let marginalSlope = 0.05
        let anchorAlpha = 0.75
        // anchorPoint is unaffected by overrides (the basal and ISF multipliers cancel out).
        let anchorPoint =
            anchorScale * basalRate
            * isf.doubleValue(for: .milligramsPerDeciliter)

        // A 0 U/hr basal segment would make anchorPoint 0 → NaN → constant 95% damping; disable instead.
        guard anchorPoint > 0 else { return nil }

        let alpha = LoopDataManager.calculateNegativeInsulinDamperAlpha(
            anchorAlpha,
            anchorPoint,
            marginalSlope,
            posDeltaSum
        )
        // alpha should never be less than marginalSlope
        return max(0, 1 - max(marginalSlope, alpha))
    }

    func fetchData(
        for baseTime: Date? = nil,
        presumePresetEndingNow: Bool = false,
        ensureDosingCoverageStart: Date? = nil,
        projectOngoingDoses: Bool = false
    ) async throws -> StoredDataAlgorithmInput {
        // Need to fetch doses back as far as t - (DIA + DCA) for Dynamic carbs
        let dosesInputHistory =
            CarbMath.maximumAbsorptionTimeInterval
            + InsulinMath.defaultInsulinActivityDuration

        let baseTime = baseTime ?? now

        var dosesStart = baseTime.addingTimeInterval(-dosesInputHistory)

        // Ensure dosing data goes back before ensureDosingCoverageStart, if specified
        if let ensureDosingCoverageStart {
            dosesStart = min(ensureDosingCoverageStart, dosesStart)
        }

        // When projectOngoingDoses is true (display path), pass end:nil so DoseStore
        // extends a mutable suspend to its insulin-activity-duration fallback. Doses
        // already in flight (e.g. a manual temp basal) keep their actual endDate
        // either way; only the suspend extension is gated on this flag.
        let doses = try await doseStore.getNormalizedDoseEntries(
            start: dosesStart,
            end: projectOngoingDoses ? nil : baseTime
        )

        // Doses that were included because they cover dosesStart might have a start time earlier than dosesStart
        // This moves the start time back to ensure basal covers
        dosesStart = min(
            dosesStart,
            doses.map { $0.startDate }.min() ?? dosesStart
        )

        // Doses with a start time before baseTime might still end after baseTime
        let dosesEnd = max(baseTime, doses.map { $0.endDate }.max() ?? baseTime)

        let rawBasal = try await settingsProvider.getBasalHistory(
            startDate: dosesStart,
            endDate: dosesEnd
        )

        guard !rawBasal.isEmpty else {
            throw LoopError.configurationError(.basalRateSchedule)
        }

        // Collapse contiguous same-rate basal entries. getBasalHistory projects the
        // daily BasalRateSchedule onto absolute time and splits at every local
        // midnight even when the rate doesn't change; InsulinDose.annotated(with:)
        // then splits the suspend (or any long basal-typed dose) at each of those
        // boundaries, and the continuous-delivery IOB integrator doesn't join the
        // resulting sub-doses perfectly across the boundary -- visible as a small
        // bump in Active Insulin at midnight even with a single-rate schedule.
        let basal: [AbsoluteScheduleValue<Double>] = rawBasal.reduce(into: []) {
            acc,
            entry in
            if let last = acc.last, last.value == entry.value,
                last.endDate == entry.startDate
            {
                acc[acc.count - 1] = AbsoluteScheduleValue(
                    startDate: last.startDate,
                    endDate: entry.endDate,
                    value: last.value
                )
            } else {
                acc.append(entry)
            }
        }

        let forecastEndTime = baseTime.addingTimeInterval(
            InsulinMath.defaultInsulinActivityDuration
        ).dateCeiledToTimeInterval(GlucoseMath.defaultDelta)

        let carbsStart = baseTime.addingTimeInterval(
            LoopConstants.maxCarbEntryPastTime + .minutes(-1)
        )  // additional minute to handle difference in seconds between carb entry and carb ratio

        // Include future carbs in query, but filter out ones entered after basetime. The filtering is only applicable when running in a retrospective situation.
        let carbEntries = try await carbStore.getCarbEntries(
            start: carbsStart,
            end: forecastEndTime
        ).filter {
            $0.userCreatedDate ?? $0.startDate < baseTime
        }

        let carbRatio = try await settingsProvider.getCarbRatioHistory(
            startDate: carbsStart,
            endDate: forecastEndTime
        )

        guard !carbRatio.isEmpty else {
            throw LoopError.configurationError(.carbRatioSchedule)
        }

        let glucose = try await glucoseStore.getGlucoseSamples(
            start: carbsStart,
            end: baseTime
        )

        let dosesWithModel = doses.map {
            $0.simpleDose(with: insulinModel(for: $0.insulinType))
        }

        let recommendationInsulinModel = insulinModel(
            for: deliveryDelegate?.pumpInsulinType ?? .novolog
        )

        let recommendationEffectInterval = DateInterval(
            start: baseTime,
            duration: recommendationInsulinModel.effectDuration
        )
        let neededSensitivityTimeline =
            LoopAlgorithm.timelineIntervalForSensitivity(
                doses: dosesWithModel,
                glucoseHistoryStart: glucose.first?.startDate ?? baseTime,
                recommendationEffectInterval: recommendationEffectInterval
            )

        // Carb entries (and a backdated manual-bolus entry) can extend back to carbsStart, and
        // CarbMath.map(to:) preconditionFailures if the ISF/carb-ratio timelines don't cover every
        // carb entry's start date. timelineIntervalForSensitivity derives its window from dose and
        // glucose history only — which can be more recent than carbsStart (e.g. after a CGM gap) —
        // so extend the ISF (and override) window back to cover the carb window, matching carbRatio.
        let sensitivityStart = min(neededSensitivityTimeline.start, carbsStart)

        let sensitivity =
            try await settingsProvider.getInsulinSensitivityHistory(
                startDate: sensitivityStart,
                endDate: neededSensitivityTimeline.end
            )

        let dosingLimits = try await settingsProvider.getDosingLimits(
            at: baseTime
        )

        guard let maxBolus = dosingLimits.maxBolus else {
            throw LoopError.configurationError(.maximumBolus)
        }

        guard let maxBasalRate = dosingLimits.maxBasalRate else {
            throw LoopError.configurationError(.maximumBasalRatePerHour)
        }

        var overrides = temporaryPresetsManager.presetHistory
            .getOverrideHistory(
                startDate: sensitivityStart,
                endDate: forecastEndTime
            )

        // For recommendation, we should consider preMeal override to be ending at time of dose
        if presumePresetEndingNow,
            let activeOverride = temporaryPresetsManager.activeOverride,
            let index = overrides.lastIndex(of: activeOverride)
        {
            overrides[index].scheduledEndDate = baseTime
        }

        guard !sensitivity.isEmpty else {
            throw LoopError.configurationError(.insulinSensitivitySchedule)
        }

        let sensitivityWithOverrides = overrides.applySensitivity(
            over: sensitivity
        )

        guard !basal.isEmpty else {
            throw LoopError.configurationError(.basalRateSchedule)
        }
        let basalWithOverrides = overrides.applyBasal(over: basal)

        guard !carbRatio.isEmpty else {
            throw LoopError.configurationError(.carbRatioSchedule)
        }
        let carbRatioWithOverrides = overrides.applyCarbRatio(over: carbRatio)

        var target: [AbsoluteScheduleValue<ClosedRange<LoopQuantity>>]

        guard var suspendThreshold = dosingLimits.suspendThreshold else {
            throw LoopError.configurationError(.suspendThreshold)
        }

        // If we have an active override, and it's not a preMeal override that should be disabled,
        // or ended for other reasons (like comparing effects without preset), then override the
        // target for the entire forecast.
        if let activeOverride = temporaryPresetsManager.activeOverride,
            !presumePresetEndingNow
        {
            guard
                let schedule = settingsProvider.settings
                    .glucoseTargetRangeSchedule
            else {
                throw LoopError.configurationError(.glucoseTargetRangeSchedule)
            }
            let scheduledRange = schedule.quantityRange(at: baseTime)
            let overriddenTargetRange =
                activeOverride.effectiveCorrectionRangeDuring(
                    scheduledRange: scheduledRange
                )
            target = [
                AbsoluteScheduleValue(
                    startDate: baseTime,
                    endDate: forecastEndTime,
                    value: overriddenTargetRange
                )
            ]

            if activeOverride.veryHighInsulinNeeds {
                suspendThreshold = max(
                    TemporaryScheduleOverride
                        .highInsulinNeedsMitigationCorrectionRangeLimit,
                    suspendThreshold
                )
            }

        } else {
            target = try await settingsProvider.getTargetRangeHistory(
                startDate: baseTime,
                endDate: forecastEndTime
            )
        }

        guard !target.isEmpty else {
            throw LoopError.configurationError(.glucoseTargetRangeSchedule)
        }

        // Create dosing strategy based on user setting
        let applicationFactorStrategy: ApplicationFactorStrategy =
            UserDefaults.standard.glucoseBasedApplicationFactorEnabled
            ? GlucoseBasedApplicationFactorStrategy()
            : ConstantApplicationFactorStrategy()

        let correctionRange = target.closestPrior(to: baseTime)?.value

        let effectiveBolusApplicationFactor: Double?

        if let latestGlucose = glucose.last {
            effectiveBolusApplicationFactor =
                applicationFactorStrategy.calculateDosingFactor(
                    for: latestGlucose.quantity,
                    correctionRange: correctionRange!
                )
        } else {
            effectiveBolusApplicationFactor = nil
        }

        var input = StoredDataAlgorithmInput(
            glucoseHistory: glucose,
            doses: dosesWithModel,
            carbEntries: carbEntries,
            predictionStart: baseTime,
            basal: basalWithOverrides,
            sensitivity: sensitivityWithOverrides,
            carbRatio: carbRatioWithOverrides,
            target: target,
            suspendThreshold: suspendThreshold,
            maxBolus: maxBolus,
            maxBasalRate: maxBasalRate,
            useIntegralRetrospectiveCorrection: UserDefaults.standard
                .integralRetrospectiveCorrectionEnabled,
            includePositiveVelocityAndRC: true,
            carbAbsorptionModel: carbAbsorptionModel,
            recommendationInsulinModel: recommendationInsulinModel,
            recommendationType: .manualBolus,
            automaticBolusApplicationFactor: effectiveBolusApplicationFactor
        )

        if UserDefaults.standard.negativeInsulinDamperEnabled {
            input.negativeInsulinDamper = computeNegativeInsulinDamper(
                for: input
            )
        }

        return input
    }

    func loopingReEnabled() async {
        await updateDisplayState()
        self.notify(forChange: .forecast)
    }

    func updateDisplayState(forceStoreRemoteRecommendation: Bool = false) async
    {

        var newState = AlgorithmDisplayState()
        do {
            let lastManualBolusVisibilityWindowStartDate =
                now.addingTimeInterval(.days(-1))

            var input = try await fetchData(
                for: now,
                ensureDosingCoverageStart:
                    lastManualBolusVisibilityWindowStartDate,
                projectOngoingDoses: true
            )
            input.recommendationType = .manualBolus
            newState.input = input
            newState.output = await runAlgorithm(input: input)

            dynamicISFLog.log(
                "DYNAMIC ISF DEBUG | updateDisplayState | enabled=\(UserDefaults.standard.dynamicISFEnabled) | output=\(newState.output != nil)"
            )

            if UserDefaults.standard.dynamicISFEnabled,
                let output = newState.output
            {
                dynamicISFLog.log("DYNAMIC ISF DEBUG | calling shadow logger")
                logDynamicISFShadowResponse(input: input, output: output)
            }

            let lastStoredManualBolus = input.doses.last(
                where: {
                    $0.startDate >= lastManualBolusVisibilityWindowStartDate
                        && $0.deliveryType == .bolus && $0.automatic == false
                })

            // Reflect the most recent user-entered bolus still present in the store. This
            // both updates to a newer bolus and clears/downgrades the value when the shown
            // bolus is no longer there (e.g. the user deleted it) — the previous logic only
            // ever moved forward, so a deleted bolus lingered in the "Last Bolus" footer.
            // A just-enacted bolus that the store may not have persisted yet is preserved.
            let recentlyEnactedCutoff = now.addingTimeInterval(-.minutes(1))
            if let lastStoredManualBolus {
                let shownIsNewerThanStored =
                    (self.lastManualBolus?.startDate).map {
                        $0 > lastStoredManualBolus.startDate
                    } ?? false
                let shownWasJustEnacted =
                    (self.lastManualBolus?.startDate).map {
                        $0 >= recentlyEnactedCutoff
                    } ?? false
                if !(shownIsNewerThanStored && shownWasJustEnacted) {
                    self.lastManualBolus = LastManualBolus(
                        amount: lastStoredManualBolus.volume,
                        startDate: lastStoredManualBolus.startDate
                    )
                }
            } else if let lastManualBolus = self.lastManualBolus,
                lastManualBolus.startDate < recentlyEnactedCutoff
            {
                self.lastManualBolus = nil
            }
        } catch {
            let loopError = error as? LoopError ?? .unknownError(error)
            logger.error(
                "Error updating Loop state: %{public}@",
                String(describing: loopError)
            )
        }
        displayState = newState
        publishedMostRecentGlucoseDataDate =
            glucoseStore.latestGlucose?.startDate
        publishedMostRecentPumpDataDate = mostRecentPumpDataDate

        // DIY: Update Live Activity with current override and target range state
        liveActivityManager?.update(
            scheduleOverride: temporaryPresetsManager.scheduleOverride,
            preMealOverride: temporaryPresetsManager.preMealOverride,
            glucoseTargetRangeSchedule: settingsProvider.settings
                .glucoseTargetRangeSchedule,
            activeInsulin: displayState.activeInsulin
        )

        await updateRemoteRecommendation(force: forceStoreRemoteRecommendation)
    }

    private func logDynamicISFShadowResponse(
        input: StoredDataAlgorithmInput,
        output: AlgorithmOutput<StoredCarbEntry>
    ) {
        let observationEnd = input.predictionStart
        let observationStart = observationEnd.addingTimeInterval(-.minutes(30))

        let glucoseSamples = input.glucoseHistory
            .filter {
                $0.startDate >= observationStart
                    && $0.startDate <= observationEnd
            }
            .sorted {
                $0.startDate < $1.startDate
            }

        guard
            let firstGlucose = glucoseSamples.first,
            let lastGlucose = glucoseSamples.last
        else {
            print("DYNAMIC ISF DEBUG | insufficient glucose history")
            return
        }

        print(
            "DYNAMIC ISF TIMESTAMP DEBUG | "
            + "current=\(lastGlucose.startDate) | "
            + "previous=\(String(describing: lastDynamicISFShadowGlucoseDate))"
        )

        guard lastGlucose.startDate != lastDynamicISFShadowGlucoseDate else {
            print("DYNAMIC ISF TIMESTAMP DEBUG | duplicate glucose timestamp — returning")
            return
        }

        lastDynamicISFShadowGlucoseDate = lastGlucose.startDate


        let observationDuration =
            lastGlucose.startDate.timeIntervalSince(firstGlucose.startDate)

        guard observationDuration >= .minutes(25) else {
            print(
                "DYNAMIC ISF SHADOW | observation window immature | "
                    + "duration=\(String(format: "%.1f", observationDuration / 60))m"
            )
            return
        }

        let glucoseUnit = LoopUnit.milligramsPerDeciliter
        let observedGlucoseChange =
            lastGlucose.quantity.doubleValue(for: glucoseUnit)
            - firstGlucose.quantity.doubleValue(for: glucoseUnit)

        let recentTargetStart =
            lastGlucose.startDate.addingTimeInterval(-.minutes(10))

        let recentStartWindowStart =
            recentTargetStart.addingTimeInterval(-.minutes(3))

        let recentStartWindowEnd =
            recentTargetStart.addingTimeInterval(.minutes(3))

        let recentStartGlucose = input.glucoseHistory
            .filter {
                $0.startDate >= recentStartWindowStart
                    && $0.startDate <= recentStartWindowEnd
            }
            .min {
                abs($0.startDate.timeIntervalSince(recentTargetStart))
                    < abs($1.startDate.timeIntervalSince(recentTargetStart))
            }

        let recentGlucoseChange: Double? = {
            guard let recentStartGlucose else {
                return nil
            }

            return lastGlucose.quantity.doubleValue(for: glucoseUnit)
                - recentStartGlucose.quantity.doubleValue(for: glucoseUnit)
        }()

        let historicalInsulinEffects =
            output.dosesRelativeToBasal.glucoseEffectsMidAbsorptionISF(
                insulinSensitivityHistory: input.sensitivity,
                from: observationStart.dateFlooredToTimeInterval(
                    GlucoseMath.defaultDelta
                ),
                to: observationEnd
            )

        let unwrappedExpectedInsulinEffect = effectChange(
            historicalInsulinEffects,
            from: observationStart,
            to: observationEnd,
            unit: glucoseUnit
        )

        // Reconstruct historical carb effects using the same dynamic-carb
        // machinery Loop uses for carb absorption.

        let carbHistoryStart =
            observationStart
            .addingTimeInterval(-CarbMath.maximumAbsorptionTimeInterval)
            .dateFlooredToTimeInterval(GlucoseMath.defaultDelta)

        let insulinEffectsForCarbHistory =
            output.dosesRelativeToBasal.glucoseEffectsMidAbsorptionISF(
                insulinSensitivityHistory: input.sensitivity,
                from: carbHistoryStart,
                to: observationEnd
            )

        let glucoseForCarbHistory = input.glucoseHistory
            .filter {
                $0.startDate >= carbHistoryStart
                    && $0.startDate <= observationEnd
            }
            .sorted {
                $0.startDate < $1.startDate
            }

        let insulinCounteractionEffects =
            glucoseForCarbHistory.counteractionEffects(
                to: insulinEffectsForCarbHistory
            )

        let carbEntriesForHistory = input.carbEntries.filter {
            $0.startDate <= observationEnd
        }

        let historicalCarbStatus = carbEntriesForHistory.map(
            to: insulinCounteractionEffects,
            carbRatio: input.carbRatio,
            insulinSensitivity: input.sensitivity
        )

        let historicalCarbEffects =
            historicalCarbStatus.dynamicGlucoseEffects(
                from: observationStart,
                to: observationEnd,
                carbRatios: input.carbRatio,
                insulinSensitivities: input.sensitivity,
                absorptionModel: input.carbAbsorptionModel.model
            )

        let expectedCarbEffect =
            effectChange(
                historicalCarbEffects,
                from: observationStart,
                to: observationEnd,
                unit: glucoseUnit
            ) ?? 0

        let unwrappedRemainingInsulinEffect = effectChange(
            output.effects.insulin,
            from: observationEnd,
            to: output.effects.insulin.last?.startDate ?? observationEnd,
            unit: glucoseUnit
        )

        if unwrappedExpectedInsulinEffect == nil
            || unwrappedRemainingInsulinEffect == nil
        {
            print(
                "DYNAMIC ISF SHADOW | incomplete effect data | "
                    + "insulin30m=\(unwrappedExpectedInsulinEffect.map { String(format: "%.1f", $0) } ?? "nil") | "
                    + "carbs30m=\(String(format: "%.1f", expectedCarbEffect)) | "
                    + "remainingInsulin=\(unwrappedRemainingInsulinEffect.map { String(format: "%.1f", $0) } ?? "nil") | "
                    + "insulinEffects=\(historicalInsulinEffects.count) | "
                    + "carbEffects=\(historicalCarbEffects.count) | "
                    + "futureInsulinEffects=\(output.effects.insulin.count)"
            )
            return
        }
        guard
            let unwrappedExpectedInsulinEffect = unwrappedExpectedInsulinEffect,
            let unwrappedRemainingInsulinEffect =
                unwrappedRemainingInsulinEffect
        else {
            return
        }

        let expectedNetEffect =
            unwrappedExpectedInsulinEffect + expectedCarbEffect

        let responseDiscrepancy =
            observedGlucoseChange - expectedNetEffect

        let currentGlucose =
            lastGlucose.quantity.doubleValue(for: glucoseUnit)

        let previousDynamicISFState = lastDynamicISFState

        let dynamicISFResponse = classifyDynamicISFResponse(
            previousState: previousDynamicISFState,
            evaluationDate: lastGlucose.startDate,
            concernEpisode: dynamicISFConcernEpisode,
            hasConfirmedResistanceInEpisode: dynamicISFHasConfirmedResistanceInEpisode,
            resistanceConfirmationCount: dynamicISFResistanceConfirmationCount,
            currentGlucose: currentGlucose,
            observedGlucoseChange: observedGlucoseChange,
            recentGlucoseChange: recentGlucoseChange,
            expectedInsulinEffect: unwrappedExpectedInsulinEffect,
            expectedCarbEffect: expectedCarbEffect,
            responseDiscrepancy: responseDiscrepancy,
            remainingInsulinEffect: unwrappedRemainingInsulinEffect
        )

        // Phase 4 Dynamic ISF candidate-strength experiment.
        //
        // This is SHADOW ONLY. It does not alter the sensitivity passed to
        // LoopAlgorithm, the correction recommendation, or insulin delivery.
        //
        // A strength of 0 means no Dynamic ISF adjustment would be considered.
        // A strength approaching 1 means the measured response deficit is large,
        // but this value is NOT itself an ISF multiplier.
        let dynamicISFShadowStrength: Double

        if dynamicISFResponse.state == .resistant {
            let minimumDeficitForAdjustment = 0.50

            let currentEvidenceStrength = min(
                1,
                max(
                    0,
                    (dynamicISFResponse.responseDeficitFraction - minimumDeficitForAdjustment)
                        / (1 - minimumDeficitForAdjustment)
                )
            )

            // If resistance has already been confirmed in this episode,
            // do not restart a reconfirmed resistant period below the
            // strongest previously confirmed resistance strength.
            //
            // This remembered strength is inactive during .recovering and
            // .waitingForResponse because this block only runs in .resistant.
            if dynamicISFHasConfirmedResistanceInEpisode {
                dynamicISFShadowStrength = max(
                    currentEvidenceStrength,
                    dynamicISFRememberedResistanceStrength
                )
            } else {
                dynamicISFShadowStrength = currentEvidenceStrength
            }

        } else {
            dynamicISFShadowStrength = 0
        }

        let scheduledISFAtPredictionStart =
            input.sensitivity.first {
                $0.startDate <= input.predictionStart &&
                $0.endDate >= input.predictionStart
            }?.value.doubleValue(for: glucoseUnit)

        let scheduledISFString =
            scheduledISFAtPredictionStart.map {
                String(format: "%.1f", $0)
            } ?? "nil"
        
        // Phase 4B Dynamic ISF candidate experiment.
        //
        // SHADOW ONLY: this value is logged for evaluation and is not passed
        // into LoopAlgorithm or used for insulin delivery.
        //
        // Even at maximum resistance evidence, Dynamic ISF may reduce the
        // scheduled ISF by no more than 20%.
        let maximumISFReductionFraction = 0.20

        let dynamicISFShadowReductionFraction =
            dynamicISFShadowStrength * maximumISFReductionFraction

        let dynamicISFCandidateISF =
            scheduledISFAtPredictionStart.map {
                $0 * (1 - dynamicISFShadowReductionFraction)
            }

        let dynamicISFCandidateISFString =
            dynamicISFCandidateISF.map {
                String(format: "%.1f", $0)
            } ?? "nil"

        dynamicISFLog.log(
            level: .default,
            "DYNAMIC ISF CANDIDATE | state=\(dynamicISFResponse.state.rawValue) | responseDeficit=\(dynamicISFResponse.responseDeficitFraction * 100)% | shadowStrength=\(dynamicISFShadowStrength * 100)% | shadowReduction=\(dynamicISFShadowReductionFraction * 100)% | scheduledISF=\(scheduledISFString) | candidateISF=\(dynamicISFCandidateISFString) | midAbsorptionISF=\(input.useMidAbsorptionISF)"
        )
        if dynamicISFResponse.state == .resistant {

            // Increment only when entering a new resistant period.
            if previousDynamicISFState != .resistant {
                dynamicISFResistanceConfirmationCount += 1
            }

            dynamicISFHasConfirmedResistanceInEpisode = true

            dynamicISFRememberedResistanceStrength = max(
                dynamicISFRememberedResistanceStrength,
                dynamicISFShadowStrength
            )

        } else if dynamicISFResponse.state == .inactive {

            // .inactive is always a hard episode boundary.
            dynamicISFHasConfirmedResistanceInEpisode = false
            dynamicISFRememberedResistanceStrength = 0
            dynamicISFResistanceConfirmationCount = 0
            dynamicISFRecoveryObservationStartDate = nil

        } else if dynamicISFResponse.state == .observing {

            // After confirmed resistance, .observing does not immediately end
            // the episode. Give recovery time to prove that it is sustained.
            //
            // SHADOW ONLY: temporary threshold for validating episode behavior.
            let recoveryObservationGracePeriod: TimeInterval = 15 * 60

            if dynamicISFHasConfirmedResistanceInEpisode {

                if let recoveryObservationStartDate =
                    dynamicISFRecoveryObservationStartDate
                {
                    let recoveryObservationDuration =
                        lastGlucose.startDate.timeIntervalSince(
                            recoveryObservationStartDate
                        )

                    if recoveryObservationDuration >= recoveryObservationGracePeriod {
                        dynamicISFHasConfirmedResistanceInEpisode = false
                        dynamicISFRememberedResistanceStrength = 0
                        dynamicISFResistanceConfirmationCount = 0
                        dynamicISFRecoveryObservationStartDate = nil
                    }
                } else {
                    dynamicISFRecoveryObservationStartDate = lastGlucose.startDate
                }

            } else {
                dynamicISFRecoveryObservationStartDate = nil
            }

        } else {

            // waitingForResponse / resistant / recovering means we are no
            // longer continuously observing recovery.
            dynamicISFRecoveryObservationStartDate = nil
        }

        dynamicISFLog.log(
            level: .default,
            """
            DYNAMIC ISF EPISODE | \
            confirmed=\(self.dynamicISFHasConfirmedResistanceInEpisode) | \
            confirmationCount=\(self.dynamicISFResistanceConfirmationCount) | \
            rememberedStrength=\(self.dynamicISFRememberedResistanceStrength * 100)%
            """
        )

        let hasActiveConcern =
            dynamicISFResponse.state == .waitingForResponse ||
            dynamicISFResponse.state == .resistant

        if hasActiveConcern {
            if dynamicISFConcernEpisode == nil {
                dynamicISFConcernEpisode = DynamicISFConcernEpisode(
                    startDate: lastGlucose.startDate,
                    startEffectProgress: dynamicISFResponse.insulinEffectProgress,
                    startDiscrepancy: dynamicISFResponse.responseDiscrepancy
                )

                dynamicISFLog.log(
                    level: .default,
                    "DYNAMIC ISF CONCERN START | glucose=\(currentGlucose) | effectProgress=\(dynamicISFResponse.insulinEffectProgress) | discrepancy=\(dynamicISFResponse.responseDiscrepancy)"
                )
            }
        } else {
            if dynamicISFConcernEpisode != nil {
                dynamicISFLog.log(
                    level: .default,
                    "DYNAMIC ISF CONCERN END | state=\(dynamicISFResponse.state.rawValue) | reason=\(dynamicISFResponse.reason.rawValue)"
                )
            }

            dynamicISFConcernEpisode = nil
        }

        if let concernEpisode = dynamicISFConcernEpisode {
            let concernDuration =
                lastGlucose.startDate.timeIntervalSince(concernEpisode.startDate)

            let progressSinceConcern =
                max(
                    0,
                    dynamicISFResponse.insulinEffectProgress -
                    concernEpisode.startEffectProgress
                )

            let discrepancyChange =
                dynamicISFResponse.responseDiscrepancy -
                concernEpisode.startDiscrepancy

            dynamicISFLog.log(
                level: .default,
                "DYNAMIC ISF CONCERN | duration=\(concernDuration / 60) min | progressSinceStart=\(progressSinceConcern * 100)% | discrepancyChange=\(discrepancyChange)"
            )
        }

        lastDynamicISFState = dynamicISFResponse.state

        dynamicISFLog.log(
            level: .default,
            "DYNAMIC ISF STATE | previous=\(previousDynamicISFState.rawValue) | state=\(dynamicISFResponse.state.rawValue) | reason=\(dynamicISFResponse.reason.rawValue)"
        )

        let recentGlucoseString =
            recentGlucoseChange.map {
                String(format: "%+.1f", $0)
            } ?? "nil"

        let insulinEffectProgressPercent =
            dynamicISFResponse.insulinEffectProgress * 100

        dynamicISFLog.log(
            level: .default,
            "DYNAMIC ISF SHADOW | glucose=\(currentGlucose) | observed30m=\(observedGlucoseChange) | insulin30m=\(unwrappedExpectedInsulinEffect) | carbs30m=\(expectedCarbEffect) | expected30m=\(expectedNetEffect) | discrepancy=\(responseDiscrepancy) | recent10m=\(recentGlucoseString) | remainingInsulin=\(unwrappedRemainingInsulinEffect)| effectProgress=\(insulinEffectProgressPercent)%"
        )
    }

    private func effectChange(
        _ effects: [GlucoseEffect],
        from start: Date,
        to end: Date,
        unit: LoopUnit
    ) -> Double? {
        guard !effects.isEmpty else {
            return nil
        }

        let startEffect =
            effects.last(where: { $0.startDate <= start }) ?? effects.first

        let endEffect =
            effects.last(where: { $0.startDate <= end }) ?? effects.first

        guard
            let startEffect,
            let endEffect
        else {
            return nil
        }

        return endEffect.quantity.doubleValue(for: unit)
            - startEffect.quantity.doubleValue(for: unit)
    }

    private func classifyDynamicISFResponse(
        previousState: DynamicISFState,
        evaluationDate: Date,
        concernEpisode: DynamicISFConcernEpisode?,
        hasConfirmedResistanceInEpisode: Bool,
        resistanceConfirmationCount: Int,
        currentGlucose: Double,
        observedGlucoseChange: Double,
        recentGlucoseChange: Double?,
        expectedInsulinEffect: Double,
        expectedCarbEffect: Double,
        responseDiscrepancy: Double,
        remainingInsulinEffect: Double
    ) -> DynamicISFResponse {
        let expectedNetEffect =
            expectedInsulinEffect + expectedCarbEffect

        let state: DynamicISFState
        let reason: DynamicISFReason

        // Temporary SHADOW thresholds.
        // These do not affect insulin delivery.
        let minimumEvaluationGlucose = 140.0

        // Shadow-only thresholds used to determine whether there is enough
        // modeled insulin activity to begin evaluating glucose response.
        let minimumInsulinExposure = 0.1
        let minimumEffectProgress = 0.03

        // Shadow-only response thresholds.
        //
        // Require a minimum amount of historical modeled insulin effect before
        // judging whether the observed glucose response is meaningfully weaker
        // than expected.
        let minimumExpectedInsulinEffectForResponse = 3.0

        // Fraction of the modeled historical insulin effect that may be "missing"
        // before we consider the response meaningfully below expectation.
        //
        // Example:
        // modeled insulin effect = -4 mg/dL
        // discrepancy = +4 mg/dL
        // response deficit fraction = 1.0 (100% of expected lowering missing)
        //
        // These values are test scaffolding only and do not affect insulin delivery.
        let minimumResponseDeficitFraction = 0.50
        let recoveringRecentChange = -2.0

        let minimumConcernDuration: TimeInterval
        let minimumProgressSinceConcern: Double

        switch resistanceConfirmationCount {
        case 0:
            // First confirmation in this episode.
            minimumConcernDuration = 10 * 60
            minimumProgressSinceConcern = 0.03

        case 1:
            // First reconfirmation / relapse.
            minimumConcernDuration = 5 * 60
            minimumProgressSinceConcern = 0.02

        default:
            // Second and later reconfirmations.
            minimumConcernDuration = 2.5 * 60
            minimumProgressSinceConcern = 0.01
        }

        // If discrepancy has improved by more than this amount since concern began,
        // continue waiting rather than classifying the response as resistant.
        let maximumAllowedDiscrepancyImprovement = 5.0

        let pastInsulinEffect = abs(expectedInsulinEffect)
        let futureInsulinEffect = abs(remainingInsulinEffect)
        let totalModeledInsulinEffect = pastInsulinEffect + futureInsulinEffect

        let insulinEffectProgress: Double

        if totalModeledInsulinEffect > 0 {
            insulinEffectProgress =
                pastInsulinEffect / totalModeledInsulinEffect
        } else {
            insulinEffectProgress = 0
        }

        let hasMeaningfulInsulinExposure =
            totalModeledInsulinEffect >= minimumInsulinExposure

        let insulinResponseIsEvaluable =
            pastInsulinEffect >= minimumInsulinExposure
            && insulinEffectProgress >= minimumEffectProgress
        let positiveResponseDiscrepancy =
            max(0, responseDiscrepancy)

        let responseDeficitFraction: Double

        if pastInsulinEffect > 0 {
            responseDeficitFraction =
                positiveResponseDiscrepancy / pastInsulinEffect
        } else {
            responseDeficitFraction = 0
        }

        let hasEnoughExpectedInsulinEffectForResponse =
            pastInsulinEffect >= minimumExpectedInsulinEffectForResponse

        let responseIsMeaningfullyBelowExpected =
            hasEnoughExpectedInsulinEffectForResponse &&
            responseDeficitFraction >= minimumResponseDeficitFraction

        let concernDuration: TimeInterval?
        let progressSinceConcern: Double?
        let discrepancyChangeSinceConcern: Double?

        if let concernEpisode {
            concernDuration = max(
                0,
                evaluationDate.timeIntervalSince(concernEpisode.startDate)
            )

            progressSinceConcern = max(
                0,
                insulinEffectProgress - concernEpisode.startEffectProgress
            )

            discrepancyChangeSinceConcern =
                responseDiscrepancy - concernEpisode.startDiscrepancy
        } else {
            concernDuration = nil
            progressSinceConcern = nil
            discrepancyChangeSinceConcern = nil
        }

        if currentGlucose < minimumEvaluationGlucose {
            state = .inactive
            reason = .glucoseNotElevated
        } else if !hasMeaningfulInsulinExposure {
            state = .observing
            reason = .insufficientInsulinExposure
        } else if !insulinResponseIsEvaluable {
            state = .observing
            reason = .insulinResponseTooEarly
        } else if let recentGlucoseChange,
                       recentGlucoseChange <= recoveringRecentChange,
                       previousState == .waitingForResponse ||
                       previousState == .resistant ||
                       previousState == .recovering
             {
                 state = .recovering
                 reason = .glucoseRecovering
             } else if let recentGlucoseChange,
                       recentGlucoseChange <= recoveringRecentChange
             {
                 state = .observing
                 reason = .glucoseResponding
             } else if !responseIsMeaningfullyBelowExpected {
                 state = .observing
                 reason = .responseMatchesExpected
             } else if let concernDuration,
                       let progressSinceConcern,
                       let discrepancyChangeSinceConcern
             {
                 let concernHasPersisted =
                     concernDuration >= minimumConcernDuration

                 let enoughAdditionalEffectHasOccurred =
                     progressSinceConcern >= minimumProgressSinceConcern

                 let responseDeficitStillMeaningful =
                     responseIsMeaningfullyBelowExpected

                 let discrepancyIsNotMeaningfullyImproving =
                     discrepancyChangeSinceConcern >= -maximumAllowedDiscrepancyImprovement
                 dynamicISFLog.log(
                     level: .default,
                     """
                     DYNAMIC ISF RESISTANCE CHECK | duration=\(concernDuration / 60) min | \
                     progressSinceStart=\(progressSinceConcern * 100)% | \
                     expectedInsulinEffect=\(expectedInsulinEffect) | \
                     discrepancy=\(responseDiscrepancy) | \
                     responseDeficit=\(responseDeficitFraction * 100)% | \
                     discrepancyChange=\(discrepancyChangeSinceConcern) | \
                     durationOK=\(concernHasPersisted) | \
                     progressOK=\(enoughAdditionalEffectHasOccurred) | \
                     responseDeficitOK=\(responseDeficitStillMeaningful) | \
                     notImproving=\(discrepancyIsNotMeaningfullyImproving)
                     """
                 )

                 if concernHasPersisted &&
                    enoughAdditionalEffectHasOccurred &&
                    responseDeficitStillMeaningful &&
                    discrepancyIsNotMeaningfullyImproving
                 {
                     state = .resistant
                     reason = .responseBelowExpected
                 } else {
                     state = .waitingForResponse
                     reason = .insulinEffectPending
                 }
             } else {
                 state = .waitingForResponse
                 reason = .insulinEffectPending
             }

        return DynamicISFResponse(
            state: state,
            reason: reason,
            observedGlucoseChange: observedGlucoseChange,
            recentGlucoseChange: recentGlucoseChange,
            expectedInsulinEffect: expectedInsulinEffect,
            expectedCarbEffect: expectedCarbEffect,
            expectedNetEffect: expectedInsulinEffect + expectedCarbEffect,
            responseDiscrepancy: responseDiscrepancy,
            responseDeficitFraction: responseDeficitFraction,
            remainingInsulinEffect: remainingInsulinEffect,
            insulinEffectProgress: insulinEffectProgress
        )
    }

    private nonisolated func runAlgorithm(input: StoredDataAlgorithmInput) async
        -> AlgorithmOutput<StoredCarbEntry>
    {
        LoopAlgorithm.run(input: input)
    }

    /// Cancel the active temp basal if it was automatically issued
    func cancelActiveTempBasal(for reason: CancelActiveTempBasalReason)
        async throws
    {
        guard case .tempBasal(let dose) = deliveryDelegate?.basalDeliveryState,
            dose.automatic ?? true
        else { return }

        logger.default(
            "Cancelling active temp basal for reason: %{public}@",
            String(describing: reason)
        )

        let recommendation = AutomaticDoseRecommendation(
            basalAdjustment: .cancel,
            direction: .decrease
        )

        var dosingDecision = StoredDosingDecision(reason: reason.rawValue)
        dosingDecision.settings = StoredDosingDecision.Settings(
            settingsProvider.settings
        )
        dosingDecision.automaticDoseRecommendation = recommendation

        do {
            crashRecoveryManager.dosingStarted(dose: recommendation)
            try await deliveryDelegate?.enact(
                bolus: recommendation.bolusUnits,
                tempBasal: recommendation.basalAdjustment,
                decisionId: dosingDecision.id
            )
            self.crashRecoveryManager.dosingFinished()
        } catch {
            dosingDecision.appendError(
                error as? LoopError ?? .unknownError(error)
            )
            if reason == .maximumBasalRateChanged {
                throw CancelTempBasalFailedMaximumBasalRateChangedError(
                    reason: error
                )
            } else {
                throw error
            }
        }

        await dosingDecisionStore.storeDosingDecision(dosingDecision)

        // DIY: refresh post-dose forecast and persist an "updateRemoteRecommendation"
        // decision so Nightscout sees the post-cancel state.
        await updateDisplayState(forceStoreRemoteRecommendation: true)
    }

    func loop() async {
        temporaryPresetsManager.startScheduledPresetsIfNeeded()
        let loopBaseTime = now

        var dosingDecision = StoredDosingDecision(
            date: loopBaseTime,
            reason: "loop",
            settings: StoredDosingDecision.Settings(settingsProvider.settings)
        )

        do {
            guard let deliveryDelegate else {
                preconditionFailure("Unable to dose without dosing delegate.")
            }

            logger.debug(
                "Running Loop at %{public}@",
                String(describing: loopBaseTime)
            )
            NotificationCenter.default.post(name: .LoopRunning, object: self)

            var input = try await fetchData(for: loopBaseTime)

            // Trim future basal
            input.doses = input.doses.trimmed(to: loopBaseTime)

            var dosingStrategy: AutomaticDosingStrategy = .automaticBolus

            if dosingStrategySelectionEnabled {
                dosingStrategy =
                    settingsProvider.settings.automaticDosingStrategy
            }
            input.recommendationType = dosingStrategy.recommendationType

            guard let latestGlucose = input.glucoseHistory.last else {
                throw LoopError.missingDataError(.glucose)
            }

            guard
                loopBaseTime.timeIntervalSince(latestGlucose.startDate)
                    <= LoopAlgorithm.inputDataRecencyInterval
            else {
                throw LoopError.glucoseTooOld(date: latestGlucose.startDate)
            }

            guard
                latestGlucose.startDate.timeIntervalSince(loopBaseTime)
                    <= LoopAlgorithm.inputDataRecencyInterval
            else {
                throw LoopError.invalidFutureGlucose(
                    date: latestGlucose.startDate
                )
            }

            guard
                loopBaseTime.timeIntervalSince(doseStore.lastAddedPumpData)
                    <= LoopAlgorithm.inputDataRecencyInterval
            else {
                throw LoopError.pumpDataTooOld(
                    date: doseStore.lastAddedPumpData
                )
            }

            var output = LoopAlgorithm.run(input: input)

            switch output.recommendationResult {
            case .success(let recommendation):
                // Round delivery amounts to pump supported amounts,
                // And determine if a change in dosing should be made.

                let algoRecommendation = recommendation.automatic!
                logger.default(
                    "Algorithm recommendation: %{public}@",
                    String(describing: algoRecommendation)
                )

                var recommendationToEnact = algoRecommendation
                // Round bolus recommendation based on pump bolus precision
                if let bolus = algoRecommendation.bolusUnits, bolus > 0 {
                    recommendationToEnact.bolusUnits =
                        deliveryDelegate.roundBolusVolume(units: bolus)
                }

                var basal = algoRecommendation.basalAdjustment

                basal.unitsPerHour = deliveryDelegate.roundBasalRate(
                    unitsPerHour: basal.unitsPerHour
                )

                let scheduledBasalRate = input.basal.closestPrior(
                    to: loopBaseTime
                )!.value
                let activeOverride = temporaryPresetsManager.presetHistory
                    .activeOverride(at: loopBaseTime)

                // Basal Lock: while glucose is above the threshold, don't let the temp basal
                // drop below the scheduled rate.
                let shouldApplyBasalLock =
                    Preferences.shared.isBasalLockEnabled
                    && latestGlucose.quantity
                        > Preferences.shared.basalLockThreshold
                    && basal.unitsPerHour < scheduledBasalRate
                if shouldApplyBasalLock {
                    // unrounded on purpose: must equal the neutralBasalRate passed below
                    basal = TempBasalRecommendation(
                        unitsPerHour: scheduledBasalRate,
                        duration: LoopAlgorithm.tempBasalDuration
                    )
                }

                let basalAdjustment = basal.adjustForCurrentDelivery(
                    at: loopBaseTime,
                    neutralBasalRate: scheduledBasalRate,
                    currentTempBasal: deliveryDelegate.basalDeliveryState?
                        .currentTempBasal,
                    continuationInterval: .minutes(11),
                    neutralBasalRateMatchesPump: activeOverride == nil
                )

                if let basalAdjustment {
                    recommendationToEnact.basalAdjustment = basalAdjustment
                    if shouldApplyBasalLock {
                        recommendationToEnact.direction = .neutral  // no longer a reduction
                    }
                }

                output.recommendationResult = .success(
                    .init(automatic: recommendationToEnact)
                )

                if recommendationToEnact != algoRecommendation {
                    logger.default(
                        "Recommendation changed to: %{public}@",
                        String(describing: recommendationToEnact)
                    )
                }

                dosingDecision.updateFrom(input: input, output: output)

                if self.settingsProvider.dosingEnabled {
                    if deliveryDelegate.basalDeliveryState == .pumpInoperable {
                        throw LoopError.pumpInoperable
                    }

                    if deliveryDelegate.isSuspended {
                        throw LoopError.pumpSuspended
                    }

                    if deliveryDelegate.isManualTempBasalRunning {
                        throw LoopError.manualTempBasalRunning
                    }

                    logger.default(
                        "Enacting: %{public}@",
                        String(describing: recommendationToEnact)
                    )

                    try await deliveryDelegate.enact(
                        bolus: recommendationToEnact.bolusUnits,
                        tempBasal: basalAdjustment,
                        decisionId: dosingDecision.id
                    )

                    logger.default("loop() completed successfully.")
                    lastLoopCompleted = now
                    let duration = lastLoopCompleted!.timeIntervalSince(
                        loopBaseTime
                    )

                    dosingDecision.enactedTempBasal = basalAdjustment
                    dosingDecision.enactedBolusAmount =
                        recommendationToEnact.bolusUnits

                    analyticsServicesManager?.loopDidSucceed(duration)
                } else {
                    self.logger.default(
                        "Not adjusting dosing during open loop."
                    )
                }

                await dosingDecisionStore.storeDosingDecision(dosingDecision)
                NotificationCenter.default.post(
                    name: .LoopCycleCompleted,
                    object: self
                )

            case .failure(let error):
                throw error
            }
        } catch {
            logger.error(
                "loop() did error: %{public}@",
                String(describing: error)
            )
            let loopError = error as? LoopError ?? .unknownError(error)
            dosingDecision.appendError(loopError)
            await dosingDecisionStore.storeDosingDecision(dosingDecision)
            analyticsServicesManager?.loopDidError(error: loopError)
            NotificationCenter.default.post(
                name: .LoopCycleCompleted,
                object: self
            )
        }

        // DIY: refresh post-dose forecast and persist an "updateRemoteRecommendation"
        // decision (Nightscout's Loop pill + forecast source — paired with the just-stored
        // "loop" decision by NightscoutService). Runs for both success and error paths.
        await updateDisplayState(forceStoreRemoteRecommendation: true)

        logger.default("Loop ended")
    }

    func recommendManualBolus(
        manualGlucoseSample: NewGlucoseSample? = nil,
        potentialCarbEntry: NewCarbEntry? = nil,
        originalCarbEntry: StoredCarbEntry? = nil,
        truncatingActiveOverride: Bool = false
    ) async throws -> ManualBolusRecommendation? {
        let result = try await recommendManualBolusWithDetails(
            manualGlucoseSample: manualGlucoseSample,
            potentialCarbEntry: potentialCarbEntry,
            originalCarbEntry: originalCarbEntry,
            truncatingActiveOverride: truncatingActiveOverride
        )

        return result.recommendation
    }

    func recommendManualBolusWithDetails(
        manualGlucoseSample: NewGlucoseSample?,
        potentialCarbEntry: NewCarbEntry?,
        originalCarbEntry: StoredCarbEntry?,
        truncatingActiveOverride: Bool
    ) async throws -> ManualBolusRecommendationResult {

        let now = self.now

        var endingPremealOverride = false

        if potentialCarbEntry != nil,
            let activeOverride = temporaryPresetsManager.activeOverride,
            activeOverride.context == .preMeal
        {
            endingPremealOverride = true
        }

        var input = try await self.fetchData(
            for: now,
            presumePresetEndingNow:
                truncatingActiveOverride || endingPremealOverride
        )
        .addingGlucoseSample(
            sample: manualGlucoseSample?.asStoredGlucoseSample
        )
        .removingCarbEntry(
            carbEntry: originalCarbEntry
        )
        .addingCarbEntry(
            carbEntry: potentialCarbEntry?.asStoredCarbEntry
        )

        input.includePositiveVelocityAndRC =
            usePositiveMomentumAndRCForManualBoluses

        input.recommendationType = .manualBolus

        let output = LoopAlgorithm.run(input: input)

        let momentumEffect =
            output.effects.momentum.last?.quantity.doubleValue(
                for: .milligramsPerDeciliter
            )

        let retrospectiveCorrectionEffect =
            output.effects.totalRetrospectiveCorrectionEffect?.doubleValue(
                for: .milligramsPerDeciliter
            )

        switch output.recommendationResult {

        case .success(let prediction):
            guard var manualBolusRecommendation = prediction.manual else {
                return ManualBolusRecommendationResult(
                    recommendation: nil,
                    calculatedBolus: nil,
                    momentumEffect: momentumEffect,
                    retrospectiveCorrectionEffect: retrospectiveCorrectionEffect
                )
            }
            let calculatedBolus = manualBolusRecommendation.amount

            if let roundedAmount =
                deliveryDelegate?.roundBolusVolume(
                    units: manualBolusRecommendation.amount
                )
            {
                manualBolusRecommendation.amount = roundedAmount
            }

            return ManualBolusRecommendationResult(
                recommendation: manualBolusRecommendation,
                calculatedBolus: calculatedBolus,
                momentumEffect: momentumEffect,
                retrospectiveCorrectionEffect:
                    retrospectiveCorrectionEffect
            )

        case .failure(let error):
            throw error
        }
    }

    public func totalDeliveredToday() async -> InsulinValue? {
        guard let data = displayState.input else {
            return nil
        }

        let now = data.predictionStart
        let midnight = Calendar.current.startOfDay(for: now)

        let annotatedDoses = data.doses.annotated(
            with: data.basal,
            fillBasalGaps: true
        )
        let trimmed = annotatedDoses.map { $0.trimmed(from: midnight, to: now) }

        return InsulinValue(
            startDate: midnight,
            value: trimmed.reduce(0.0) { $0 + $1.volume }
        )
    }

    var iobValues: [InsulinValue] {
        dosesRelativeToBasal.insulinOnBoardTimeline()
    }

    var dosesRelativeToBasal: [BasalRelativeDose] {
        displayState.output?.dosesRelativeToBasal ?? []
    }

    func updateRemoteRecommendation(force: Bool = false) async {
        if lastManualBolusRecommendation == nil {
            lastManualBolusRecommendation =
                displayState.output?.recommendation?.manual
        }

        let recommendationChanged =
            lastManualBolusRecommendation
            != displayState.output?.recommendation?.manual

        // DIY: post-dose "updateRemoteRecommendation" decisions are also Nightscout's
        // Loop pill + forecast source (NightscoutService pairs them with the cached "loop"
        // decision). Force-store after every Loop cycle and temp basal cancel so NS stays
        // current even when the manual bolus recommendation hasn't changed.
        guard force || recommendationChanged else {
            return
        }

        lastManualBolusRecommendation =
            displayState.output?.recommendation?.manual

        if let output = displayState.output {
            var dosingDecision = StoredDosingDecision(
                date: now,
                reason: "updateRemoteRecommendation"
            )
            dosingDecision.predictedGlucose = output.predictedGlucose
            dosingDecision.insulinOnBoard = displayState.activeInsulin
            dosingDecision.carbsOnBoard = displayState.activeCarbs
            switch output.recommendationResult {
            case .success(let recommendation):
                dosingDecision.automaticDoseRecommendation =
                    recommendation.automatic
                if let recommendationDate = displayState.input?.predictionStart,
                    let manualRec = recommendation.manual
                {
                    dosingDecision.manualBolusRecommendation =
                        ManualBolusRecommendationWithDate(
                            recommendation: manualRec,
                            date: recommendationDate
                        )
                }
            case .failure(let error):
                if let loopError = error as? LoopError {
                    dosingDecision.errors.append(loopError.issue)
                } else {
                    dosingDecision.errors.append(
                        .init(
                            id: "error",
                            details: ["description": error.localizedDescription]
                        )
                    )
                }
            }

            dosingDecision.controllerStatus = UIDevice.current.controllerStatus

            // Device status for the Nightscout devicestatus.pump payload.
            dosingDecision.pumpManagerStatus =
                deliveryDelegate?.pumpManagerStatus
            if let pumpStatusHighlight = deliveryDelegate?.pumpStatusHighlight {
                dosingDecision.pumpStatusHighlight =
                    StoredDosingDecision.StoredDeviceHighlight(
                        localizedMessage: pumpStatusHighlight.localizedMessage,
                        imageName: pumpStatusHighlight.imageName,
                        state: pumpStatusHighlight.state
                    )
            }
            dosingDecision.cgmManagerStatus = deliveryDelegate?.cgmManagerStatus
            dosingDecision.lastReservoirValue =
                StoredDosingDecision.LastReservoirValue(
                    doseStore.lastReservoirValue
                )

            self.logger.debug(
                "Manual bolus rec = %{public}@",
                String(describing: dosingDecision.manualBolusRecommendation)
            )
            await self.dosingDecisionStore.storeDosingDecision(dosingDecision)
        }
    }

    // MARK: - Glucose Staleness

    private var glucoseValueStalenessTimer: Timer?

    private func restartGlucoseValueStalenessTimer() {
        stopGlucoseValueStalenessTimer()
        startGlucoseValueStalenessTimerIfNeeded()
    }

    private func stopGlucoseValueStalenessTimer() {
        glucoseValueStalenessTimer?.invalidate()
        glucoseValueStalenessTimer = nil
    }

    func startGlucoseValueStalenessTimerIfNeeded() {
        guard let fireDate = glucoseValueStaleDate,
            glucoseValueStalenessTimer == nil
        else { return }

        glucoseValueStalenessTimer = Timer(
            fire: fireDate,
            interval: 0,
            repeats: false
        ) { (_) in
            Task { @MainActor in
                self.notify(forChange: .glucose)
            }
        }
        RunLoop.main.add(glucoseValueStalenessTimer!, forMode: .default)
    }

    private var glucoseValueStaleDate: Date? {
        guard let latestGlucoseDataDate = glucoseStore.latestGlucose?.startDate
        else { return nil }
        return latestGlucoseDataDate.addingTimeInterval(
            LoopAlgorithm.inputDataRecencyInterval
        )
    }
}

// MARK: - Background task management
extension LoopDataManager: PersistenceControllerDelegate {
    nonisolated func persistenceControllerWillSave(
        _ controller: PersistenceController
    ) {
        Task {
            await startBackgroundTask()
        }
    }

    nonisolated func persistenceControllerDidSave(
        _ controller: PersistenceController,
        error: PersistenceController.PersistenceControllerError?
    ) {
        Task {
            await endBackgroundTask()
        }
    }
}

// MARK: - Intake
extension LoopDataManager {
    /// Adds and stores glucose samples
    ///
    /// - Parameters:
    ///   - samples: The new glucose samples to store
    ///   - completion: A closure called once upon completion
    ///   - result: The stored glucose values
    func addGlucose(_ samples: [NewGlucoseSample]) async throws
        -> [StoredGlucoseSample]
    {
        return try await glucoseStore.addGlucoseSamples(samples)
    }

    /// Adds and stores carb data, and recommends a bolus if needed
    ///
    /// - Parameters:
    ///   - carbEntry: The new carb value
    ///   - completion: A closure called once upon completion
    ///   - result: The bolus recommendation
    func addCarbEntry(
        _ carbEntry: NewCarbEntry,
        replacing replacingEntry: StoredCarbEntry? = nil
    ) async throws -> StoredCarbEntry {
        let storedCarbEntry: StoredCarbEntry
        if let replacingEntry = replacingEntry {
            storedCarbEntry = try await carbStore.replaceCarbEntry(
                replacingEntry,
                withEntry: carbEntry
            )
        } else {
            storedCarbEntry = try await carbStore.addCarbEntry(carbEntry)
        }
        self.temporaryPresetsManager.endPreMealOverride()
        return storedCarbEntry
    }

    func getCarbEntry(withUUID uuid: UUID) async throws -> StoredCarbEntry? {
        let entries = try await carbStore.getCarbEntries(
            start: nil,
            end: nil
        )

        return entries.first { $0.uuid == uuid }
    }

    @discardableResult
    func deleteCarbEntry(_ oldEntry: StoredCarbEntry) async throws -> Bool {
        let secondaryIdentifier =
            BolusProMealStore.shared.secondaryIdentifier(for: oldEntry)

        if let secondaryIdentifier {
            let entries = try await carbStore.getCarbEntries(
                start: nil,
                end: nil
            )

            let secondaryEntry: StoredCarbEntry?

            if secondaryIdentifier.hasPrefix("sync:") {
                let syncIdentifier = String(
                    secondaryIdentifier.dropFirst("sync:".count)
                )

                secondaryEntry = entries.first {
                    $0.syncIdentifier == syncIdentifier
                }
            } else if secondaryIdentifier.hasPrefix("uuid:") {
                let uuidString = String(
                    secondaryIdentifier.dropFirst("uuid:".count)
                )

                if let uuid = UUID(uuidString: uuidString) {
                    secondaryEntry = entries.first {
                        $0.uuid == uuid
                    }
                } else {
                    secondaryEntry = nil
                }
            } else {
                secondaryEntry = nil
            }

            if let secondaryEntry {
                _ = try await carbStore.deleteCarbEntry(secondaryEntry)
            }
        }

        let deleted = try await carbStore.deleteCarbEntry(oldEntry)

        if deleted {
            BolusProMealStore.shared.remove(for: oldEntry)
        }

        return deleted
    }

    /// Logs a new external bolus insulin dose in the DoseStore and HealthKit
    ///
    /// - Parameters:
    ///   - startDate: The date the dose was started at.
    ///   - value: The number of Units in the dose.
    ///   - insulinModel: The type of insulin model that should be used for the dose.
    func addManuallyEnteredDose(
        startDate: Date,
        units: Double,
        insulinType: InsulinType? = nil
    ) async {
        let syncIdentifier = Data(UUID().uuidString.utf8).hexadecimalString
        let dose = DoseEntry(
            type: .bolus,
            startDate: startDate,
            value: units,
            unit: .units,
            decisionId: nil,
            syncIdentifier: syncIdentifier,
            insulinType: insulinType,
            manuallyEntered: true
        )

        do {
            try await doseStore.addDoses([dose], from: nil)
            self.notify(forChange: .insulin)
        } catch {
            logger.error(
                "Error storing manual dose: %{public}@",
                error.localizedDescription
            )
        }
    }

    func storeManualBolusDosingDecision(
        _ bolusDosingDecision: BolusDosingDecision,
        withDate date: Date
    ) async {
        let dosingDecision = StoredDosingDecision(
            id: bolusDosingDecision.id,
            date: date,
            reason: bolusDosingDecision.reason.rawValue,
            settings: StoredDosingDecision.Settings(settingsProvider.settings),
            scheduleOverride: bolusDosingDecision.scheduleOverride,
            controllerStatus: UIDevice.current.controllerStatus,
            pumpManagerStatus: deliveryDelegate?.pumpManagerStatus,
            cgmManagerStatus: deliveryDelegate?.cgmManagerStatus,
            lastReservoirValue: StoredDosingDecision.LastReservoirValue(
                doseStore.lastReservoirValue
            ),
            historicalGlucose: bolusDosingDecision.historicalGlucose,
            originalCarbEntry: bolusDosingDecision.originalCarbEntry,
            carbEntry: bolusDosingDecision.carbEntry,
            manualGlucoseSample: bolusDosingDecision.manualGlucoseSample,
            carbsOnBoard: bolusDosingDecision.carbsOnBoard,
            insulinOnBoard: bolusDosingDecision.insulinOnBoard,
            glucoseTargetRangeSchedule: bolusDosingDecision
                .glucoseTargetRangeSchedule,
            predictedGlucose: bolusDosingDecision.predictedGlucose,
            manualBolusRecommendation: bolusDosingDecision
                .manualBolusRecommendation,
            manualBolusRequested: bolusDosingDecision.manualBolusRequested
        )
        Task { await dosingDecisionStore.storeDosingDecision(dosingDecision) }
    }

    private func notify(forChange context: LoopUpdateContext) {
        NotificationCenter.default.post(
            name: .LoopDataUpdated,
            object: self,
            userInfo: [
                type(of: self).LoopUpdateContextKey: context.rawValue
            ]
        )
    }

    /// Estimate glucose effects of suspending insulin delivery over duration of insulin action starting at the specified date
    func insulinDeliveryEffect(at date: Date, insulinType: InsulinType)
        async throws -> [GlucoseEffect]
    {
        let startSuspend = date
        let insulinEffectDuration = insulinModel(for: insulinType)
            .effectDuration
        let endSuspend = startSuspend.addingTimeInterval(insulinEffectDuration)

        var suspendDoses: [BasalRelativeDose] = []

        let basal = try await settingsProvider.getBasalHistory(
            startDate: startSuspend,
            endDate: endSuspend
        )
        let sensitivity =
            try await settingsProvider.getInsulinSensitivityHistory(
                startDate: startSuspend,
                endDate: endSuspend
            )

        // Iterate over basal entries during suspension of insulin delivery
        for (index, basalItem) in basal.enumerated() {
            var startSuspendDoseDate: Date
            var endSuspendDoseDate: Date

            guard
                basalItem.endDate > startSuspend
                    && basalItem.startDate < endSuspend
            else {
                continue
            }

            if index == 0 {
                startSuspendDoseDate = startSuspend
            } else {
                startSuspendDoseDate = basalItem.startDate
            }

            if index == basal.count - 1 {
                endSuspendDoseDate = endSuspend
            } else {
                endSuspendDoseDate = basal[index + 1].startDate
            }

            let suspendDose = BasalRelativeDose(
                type: .basal(scheduledRate: basalItem.value),
                startDate: startSuspendDoseDate,
                endDate: endSuspendDoseDate,
                volume: 0
            )

            suspendDoses.append(suspendDose)
        }

        // Calculate predicted glucose effect of suspending insulin delivery
        return suspendDoses.glucoseEffects(
            insulinSensitivityHistory: sensitivity
        ).filterDateRange(startSuspend, endSuspend)
    }

    func computeSimpleBolusRecommendation(
        at date: Date,
        mealCarbs: LoopQuantity?,
        manualGlucose: LoopQuantity?
    ) -> BolusDosingDecision? {

        var dosingDecision = BolusDosingDecision(for: .simpleBolus)

        // Determine activeInsulin
        let activeInsulin: LoopQuantity
        if let iob = displayState.activeInsulin?.value {
            activeInsulin = LoopQuantity.init(
                unit: .internationalUnit,
                doubleValue: iob
            )
        } else if let input = displayState.input {
            let basal = input.basal
            let dosesRelativeToBasal: [BasalRelativeDose] = input.doses
                .annotated(with: basal)
            let iob = dosesRelativeToBasal.insulinOnBoard(at: date)
            activeInsulin = LoopQuantity.init(
                unit: .internationalUnit,
                doubleValue: iob
            )
        } else {
            return nil
        }

        guard
            let suspendThreshold = settingsProvider.settings.suspendThreshold?
                .quantity,
            let carbRatioSchedule = temporaryPresetsManager
                .carbRatioScheduleApplyingOverrideHistory,
            let correctionRangeSchedule =
                temporaryPresetsManager.effectiveCorrectionRangeSchedule(
                    presumingMealEntry: mealCarbs != nil
                ),
            let sensitivitySchedule = temporaryPresetsManager
                .insulinSensitivityScheduleApplyingOverrideHistory
        else {
            // Settings incomplete; should never get here; remove when therapy settings non-optional
            return nil
        }

        if let scheduleOverride = temporaryPresetsManager.scheduleOverride,
            !scheduleOverride.hasFinished()
        {
            dosingDecision.scheduleOverride =
                temporaryPresetsManager.scheduleOverride
        }

        dosingDecision.glucoseTargetRangeSchedule = correctionRangeSchedule

        var notice: BolusRecommendationNotice? = nil
        if let manualGlucose = manualGlucose {
            let glucoseValue = SimpleGlucoseValue(
                startDate: date,
                quantity: manualGlucose
            )
            if manualGlucose < suspendThreshold {
                notice = .glucoseBelowSuspendThreshold(minGlucose: glucoseValue)
            } else {
                let correctionRange = correctionRangeSchedule.quantityRange(
                    at: date
                )
                if manualGlucose < correctionRange.lowerBound {
                    notice = .currentGlucoseBelowTarget(glucose: glucoseValue)
                }
            }
        }

        let bolusAmount = SimpleBolusCalculator.recommendedInsulin(
            mealCarbs: mealCarbs,
            manualGlucose: manualGlucose,
            activeInsulin: activeInsulin,
            carbRatioSchedule: carbRatioSchedule,
            correctionRangeSchedule: correctionRangeSchedule,
            sensitivitySchedule: sensitivitySchedule,
            at: date
        )

        dosingDecision.manualBolusRecommendation =
            ManualBolusRecommendationWithDate(
                recommendation: ManualBolusRecommendation(
                    amount: bolusAmount.doubleValue(for: .internationalUnit),
                    notice: notice
                ),
                date: now
            )

        return dosingDecision
    }

}

extension NewCarbEntry {
    var asStoredCarbEntry: StoredCarbEntry {
        StoredCarbEntry(
            startDate: startDate,
            quantity: quantity,
            foodType: foodType,
            absorptionTime: absorptionTime,
            userCreatedDate: date
        )
    }
}

extension NewGlucoseSample {
    var asStoredGlucoseSample: StoredGlucoseSample {
        StoredGlucoseSample(
            syncIdentifier: syncIdentifier,
            syncVersion: syncVersion,
            startDate: date,
            quantity: quantity,
            condition: condition,
            trend: trend,
            trendRate: trendRate,
            isDisplayOnly: isDisplayOnly,
            wasUserEntered: wasUserEntered,
            device: device
        )
    }
}

extension StoredDataAlgorithmInput {

    func addingDose(dose: InsulinDoseType?) -> StoredDataAlgorithmInput {
        var rval = self
        if let dose {
            rval.doses = doses + [dose]
        }
        return rval
    }

    func addingGlucoseSample(sample: GlucoseType?) -> StoredDataAlgorithmInput {
        var rval = self
        if let sample {
            rval.glucoseHistory.append(sample)
        }
        return rval
    }

    func addingCarbEntry(carbEntry: CarbType?) -> StoredDataAlgorithmInput {
        var rval = self
        if let carbEntry {
            rval.carbEntries = carbEntries + [carbEntry]
        }
        return rval
    }

    func removingCarbEntry(carbEntry: CarbType?) -> StoredDataAlgorithmInput {
        guard let carbEntry else {
            return self
        }
        var rval = self
        var currentEntries = self.carbEntries
        if let index = currentEntries.firstIndex(of: carbEntry) {
            currentEntries.remove(at: index)
        }
        rval.carbEntries = currentEntries
        return rval
    }

    func predictGlucose(
        effectsOptions: AlgorithmEffectsOptions = .all,
        applyNegativeInsulinDamper: Bool = true
    ) throws -> [PredictedGlucoseValue] {
        let prediction = LoopAlgorithm.generatePrediction(
            start: predictionStart,
            glucoseHistory: glucoseHistory,
            doses: doses,
            carbEntries: carbEntries,
            basal: basal,
            sensitivity: sensitivity,
            carbRatio: carbRatio,
            algorithmEffectsOptions: effectsOptions,
            useIntegralRetrospectiveCorrection: self
                .useIntegralRetrospectiveCorrection,
            useMidAbsorptionISF: true,
            carbAbsorptionModel: self.carbAbsorptionModel.model,
            negativeInsulinDamper: applyNegativeInsulinDamper
                ? negativeInsulinDamper : nil
        )
        return prediction.glucose
    }
}

extension Notification.Name {
    static let LoopDataUpdated = Notification.Name(
        rawValue: "com.loopkit.Loop.LoopDataUpdated"
    )
    static let LoopRunning = Notification.Name(
        rawValue: "com.loopkit.Loop.LoopRunning"
    )
    static let LoopCycleCompleted = Notification.Name(
        rawValue: "com.loopkit.Loop.LoopCycleCompleted"
    )
}

protocol BolusDurationEstimator: AnyObject {
    func estimateBolusDuration(bolusUnits: Double) -> TimeInterval?
}

extension TemporaryScheduleOverride {
    fileprivate func isBasalRateScheduleOverriden(at date: Date) -> Bool {
        guard isActive(at: date),
            let basalRateMultiplier = settings.basalRateMultiplier
        else {
            return false
        }
        return abs(basalRateMultiplier - 1.0) >= .ulpOfOne
    }
}

extension StoredDosingDecision.LastReservoirValue {
    fileprivate init?(_ reservoirValue: ReservoirValue?) {
        guard let reservoirValue = reservoirValue else {
            return nil
        }
        self.init(
            startDate: reservoirValue.startDate,
            unitVolume: reservoirValue.unitVolume
        )
    }
}

extension ManualBolusRecommendationWithDate {
    init?(
        _ bolusRecommendationDate: (
            recommendation: ManualBolusRecommendation, date: Date
        )?
    ) {
        guard let bolusRecommendationDate = bolusRecommendationDate else {
            return nil
        }
        self.init(
            recommendation: bolusRecommendationDate.recommendation,
            date: bolusRecommendationDate.date
        )
    }
}

extension StoredDosingDecision.Settings {
    fileprivate init?(_ settings: StoredSettings?) {
        guard let settings = settings else {
            return nil
        }
        self.init(syncIdentifier: settings.syncIdentifier)
    }
}

extension LoopDataManager: ServicesManagerDelegate {

    // Remote Overrides
    func enactOverride(
        name: String,
        duration: TemporaryScheduleOverride.Duration?,
        remoteAddress: String
    ) async throws {

        guard
            let preset = settingsProvider.settings.overridePresets.first(
                where: { $0.name == name })
        else {
            throw EnactOverrideError.unknownPreset(name)
        }

        var remoteOverride = preset.createOverride(
            enactTrigger: .remote(remoteAddress)
        )

        if let duration {
            remoteOverride.duration = duration
        }

        temporaryPresetsManager.scheduleOverride = remoteOverride
    }

    func cancelCurrentOverride() async throws {
        temporaryPresetsManager.scheduleOverride = nil
    }

    enum EnactOverrideError: LocalizedError {

        case unknownPreset(String)

        var errorDescription: String? {
            switch self {
            case .unknownPreset(let presetName):
                return String(
                    format: NSLocalizedString(
                        "Unknown preset: %1$@",
                        comment:
                            "Override error description: unknown preset (1: preset name)."
                    ),
                    presetName
                )
            }
        }
    }

    //Carb Entry

    func deliverCarbs(
        amountInGrams: Double,
        absorptionTime: TimeInterval?,
        foodType: String?,
        startDate: Date?
    ) async throws {

        let absorptionTime =
            absorptionTime
            ?? LoopCoreConstants.defaultCarbAbsorptionTimes.medium
        if absorptionTime < LoopConstants.minCarbAbsorptionTime
            || absorptionTime > LoopConstants.maxCarbAbsorptionTime
        {
            throw CarbActionError.invalidAbsorptionTime(absorptionTime)
        }

        guard amountInGrams > 0.0 else {
            throw CarbActionError.invalidCarbs
        }

        guard
            amountInGrams
                <= LoopConstants.maxCarbEntryQuantity.doubleValue(for: .gram)
        else {
            throw CarbActionError.exceedsMaxCarbs
        }

        if let startDate = startDate {
            let maxStartDate = now.addingTimeInterval(
                LoopConstants.maxCarbEntryFutureTime
            )
            let minStartDate = now.addingTimeInterval(
                LoopConstants.maxCarbEntryPastTime
            )
            guard startDate <= maxStartDate && startDate >= minStartDate else {
                throw CarbActionError.invalidStartDate(startDate)
            }
        }

        let quantity = LoopQuantity(unit: .gram, doubleValue: amountInGrams)
        let candidateCarbEntry = NewCarbEntry(
            quantity: quantity,
            startDate: startDate ?? now,
            foodType: foodType,
            absorptionTime: absorptionTime
        )

        let _ = try await carbStore.addCarbEntry(candidateCarbEntry)
    }

    enum CarbActionError: LocalizedError {

        case invalidAbsorptionTime(TimeInterval)
        case invalidStartDate(Date)
        case exceedsMaxCarbs
        case invalidCarbs

        var errorDescription: String? {
            switch self {
            case .exceedsMaxCarbs:
                return NSLocalizedString(
                    "Exceeds maximum allowed carbs",
                    comment:
                        "Carb error description: carbs exceed maximum amount."
                )
            case .invalidCarbs:
                return NSLocalizedString(
                    "Invalid carb amount",
                    comment: "Carb error description: invalid carb amount."
                )
            case .invalidAbsorptionTime(let absorptionTime):
                let absorptionHoursFormatted =
                    Self.numberFormatter.string(from: absorptionTime.hours)
                    ?? ""
                return String(
                    format: NSLocalizedString(
                        "Invalid absorption time: %1$@ hours",
                        comment:
                            "Carb error description: invalid absorption time. (1: Input duration in hours)."
                    ),
                    absorptionHoursFormatted
                )
            case .invalidStartDate(let startDate):
                let startDateFormatted = Self.dateFormatter.string(
                    from: startDate
                )
                return String(
                    format: NSLocalizedString(
                        "Start time is out of range: %@",
                        comment:
                            "Carb error description: invalid start time is out of range."
                    ),
                    startDateFormatted
                )
            }
        }

        static var numberFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter
        }()

        static var dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            return formatter
        }()
    }
}

extension LoopDataManager: SimpleBolusViewModelDelegate {

    func insulinOnBoard(at date: Date) async -> InsulinValue? {
        displayState.activeInsulin
    }

    var maximumBolus: Double? {
        settingsProvider.settings.maximumBolus
    }

    var suspendThreshold: LoopQuantity? {
        settingsProvider.settings.suspendThreshold?.quantity
    }

    func enactBolus(
        units: Double,
        decisionId: UUID?,
        activationType: BolusActivationType
    ) async throws {
        let startDate = now
        try await deliveryDelegate?.enactBolus(
            units: units,
            decisionId: decisionId,
            activationType: activationType
        )
        lastManualBolus = LastManualBolus(amount: units, startDate: startDate)
    }

}

extension LoopDataManager: BolusEntryViewModelDelegate {
    func getCarbEntry(
        withSyncIdentifier syncIdentifier: String
    ) async throws -> StoredCarbEntry? {
        let entries = try await carbStore.getCarbEntries(
            start: nil,
            end: nil
        )

        return entries.first {
            $0.syncIdentifier == syncIdentifier
        }
    }

    func saveGlucose(sample: LoopKit.NewGlucoseSample) async throws
        -> LoopKit.StoredGlucoseSample
    {
        let storedSamples = try await addGlucose([sample])
        let storedSample = storedSamples.first!

        await loop()

        return storedSample
    }

    var preMealOverride: TemporaryScheduleOverride? {
        temporaryPresetsManager.preMealOverride
    }

    var mostRecentGlucoseDataDate: Date? {
        displayState.input?.glucoseHistory.last?.startDate
    }

    var mostRecentPumpDataDate: Date? {
        return doseStore.lastAddedPumpData
    }

    func effectiveGlucoseTargetRangeSchedule(presumingMealEntry: Bool)
        -> GlucoseRangeSchedule?
    {
        temporaryPresetsManager.effectiveCorrectionRangeSchedule(
            presumingMealEntry: presumingMealEntry
        )
    }

    func generatePrediction(
        originalCarbEntry: StoredCarbEntry?,
        potentialCarbEntry: NewCarbEntry?,
        potentialDose: SimpleInsulinDose?,
        manualGlucose: NewGlucoseSample?
    ) async throws -> (
        historicGlucose: [StoredGlucoseSample],
        predictedGlucose: [PredictedGlucoseValue]
    ) {

        var endingPremealOverride = false

        if potentialCarbEntry != nil,
            let activeOverride = temporaryPresetsManager.activeOverride,
            activeOverride.context == .preMeal
        {
            endingPremealOverride = true
        }

        var input = try await fetchData(
            for: now,
            presumePresetEndingNow: endingPremealOverride,
            ensureDosingCoverageStart: nil
        )

        // Add potential bolus, carbs, manual glucose
        input =
            input
            .addingDose(dose: potentialDose)
            .addingGlucoseSample(sample: manualGlucose?.asStoredGlucoseSample)
            .removingCarbEntry(carbEntry: originalCarbEntry)
            .addingCarbEntry(carbEntry: potentialCarbEntry?.asStoredCarbEntry)

        let prediction = try input.predictGlucose()

        return (
            historicGlucose: input.glucoseHistory, predictedGlucose: prediction
        )
    }
}

extension LoopDataManager: CarbEntryViewModelDelegate {
    func isScheduleOverrideActive(at date: Date) -> Bool {
        temporaryPresetsManager.isScheduleOverrideActive(at: date)
    }

    var defaultAbsorptionTimes: DefaultAbsorptionTimes {
        LoopCoreConstants.defaultCarbAbsorptionTimes
    }
    func getGlucoseSamples(start: Date?, end: Date?) async throws
        -> [StoredGlucoseSample]
    {
        try await glucoseStore.getGlucoseSamples(start: start, end: end)
    }
}

extension LoopDataManager: FavoriteFoodInsightsViewModelDelegate {
    func selectedFavoriteFoodLastEaten(_ favoriteFood: StoredFavoriteFood)
        async throws -> Date?
    {
        try await carbStore.getCarbEntries(
            start: nil,
            end: nil,
            dateAscending: false,
            fetchLimit: 1,
            with: favoriteFood.id
        ).first?.startDate
    }

    func getFavoriteFoodCarbEntries(_ favoriteFood: StoredFavoriteFood)
        async throws -> [LoopKit.StoredCarbEntry]
    {
        try await carbStore.getCarbEntries(
            start: nil,
            end: nil,
            dateAscending: false,
            fetchLimit: nil,
            with: favoriteFood.id
        )
    }

    func getHistoricalChartsData(start: Date, end: Date) async throws
        -> HistoricalChartsData
    {
        // Need to get insulin data from any active doses that might affect this time range
        var dosesStart = start.addingTimeInterval(
            -InsulinMath.defaultInsulinActivityDuration
        )
        let doses = try await doseStore.getNormalizedDoseEntries(
            start: dosesStart,
            end: end
        )

        dosesStart = doses.map { $0.startDate }.min() ?? dosesStart

        let basal = try await settingsProvider.getBasalHistory(
            startDate: dosesStart,
            endDate: end
        )

        let carbEntries = try await carbStore.getCarbEntries(
            start: start,
            end: end
        )

        let carbRatio = try await settingsProvider.getCarbRatioHistory(
            startDate: start,
            endDate: end
        )

        let glucose = try await glucoseStore.getGlucoseSamples(
            start: start,
            end: end
        )

        let sensitivityStart = min(start, dosesStart)

        let sensitivity =
            try await settingsProvider.getInsulinSensitivityHistory(
                startDate: sensitivityStart,
                endDate: end
            )

        let overrides = temporaryPresetsManager.presetHistory
            .getOverrideHistory(startDate: sensitivityStart, endDate: end)

        guard !sensitivity.isEmpty else {
            throw LoopError.configurationError(.insulinSensitivitySchedule)
        }

        let sensitivityWithOverrides = overrides.applySensitivity(
            over: sensitivity
        )

        guard !basal.isEmpty else {
            throw LoopError.configurationError(.basalRateSchedule)
        }
        let basalWithOverrides = overrides.applyBasal(over: basal)

        guard !carbRatio.isEmpty else {
            throw LoopError.configurationError(.carbRatioSchedule)
        }
        let carbRatioWithOverrides = overrides.applyCarbRatio(over: carbRatio)

        // Overlay basal history on basal doses, splitting doses to get amount delivered relative to basal.
        // annotated() can emit segments out of startDate order when input doses overlap (e.g. a bolus
        // during a temp basal, or overlapping pending/committed doses), so sort for downstream
        // binary-search filterDateRange.
        let annotatedDoses =
            doses
            .map({ $0.simpleDose(with: insulinModel(for: $0.insulinType)) })
            .annotated(with: basalWithOverrides)
            .sorted { $0.startDate < $1.startDate }

        // Standard mid-absorption ISF model, matching LoopAlgorithm's prediction
        // path — keeps this review's carb absorption consistent with the
        // algorithm (dose-time `glucoseEffects` is legacy backwards-compat).
        let insulinEffects = annotatedDoses.glucoseEffectsMidAbsorptionISF(
            insulinSensitivityHistory: sensitivityWithOverrides,
            from: start.addingTimeInterval(
                -CarbMath.maximumAbsorptionTimeInterval
            ).dateFlooredToTimeInterval(GlucoseMath.defaultDelta),
            to: nil
        )

        // ICE
        let insulinCounteractionEffects = glucose.counteractionEffects(
            to: insulinEffects
        )

        // Carb Effects
        let carbStatus = carbEntries.map(
            to: insulinCounteractionEffects,
            carbRatio: carbRatioWithOverrides,
            insulinSensitivity: sensitivityWithOverrides
        )

        let carbEffects = carbStatus.dynamicGlucoseEffects(
            from: start,
            to: end.addingTimeInterval(
                InsulinMath.defaultInsulinActivityDuration
            ),
            carbRatios: carbRatioWithOverrides,
            insulinSensitivities: sensitivityWithOverrides,
            absorptionModel: CarbAbsorptionModel.piecewiseLinear.model
        )

        let carbAbsorptionReview = CarbAbsorptionReview(
            carbEntries: carbEntries,
            carbStatuses: carbStatus,
            effectsVelocities: insulinCounteractionEffects,
            carbEffects: carbEffects
        )

        let trimmedDoses = annotatedDoses.filterDateRange(start, end)
        let trimmedIOBValues = annotatedDoses.insulinOnBoardTimeline()
            .filterDateRange(start, end)

        let historicalChartsData = HistoricalChartsData(
            glucoseValues: glucose,
            carbEntries: carbEntries,
            doses: trimmedDoses,
            rawDoses: doses,
            iobValues: trimmedIOBValues,
            carbAbsorptionReview: carbAbsorptionReview
        )

        return historicalChartsData
    }
}

extension LoopDataManager: ManualDoseViewModelDelegate {
    var pumpInsulinType: InsulinType? {
        deliveryDelegate?.pumpInsulinType
    }

    var settings: StoredSettings {
        settingsProvider.settings
    }

    var scheduleOverride: TemporaryScheduleOverride? {
        temporaryPresetsManager.scheduleOverride
    }

    func insulinActivityDuration(for type: InsulinType?) -> TimeInterval {
        return insulinModel(for: type).effectDuration
    }

    var algorithmDisplayState: AlgorithmDisplayState {
        get async { return displayState }
    }

}

extension AutomaticDosingStrategy {
    var recommendationType: DoseRecommendationType {
        switch self {
        case .tempBasalOnly:
            return .tempBasal
        case .automaticBolus:
            return .automaticBolus
        }
    }
}

extension StoredDosingDecision {
    mutating func updateFrom(
        input: StoredDataAlgorithmInput,
        output: AlgorithmOutput<StoredCarbEntry>
    ) {
        self.historicalGlucose = input.glucoseHistory.map {
            HistoricalGlucoseValue(
                startDate: $0.startDate,
                quantity: $0.quantity
            )
        }
        switch output.recommendationResult {
        case .success(let recommendation):
            self.automaticDoseRecommendation = recommendation.automatic
        case .failure(let error):
            self.appendError(error as? LoopError ?? .unknownError(error))
        }
        if let activeInsulin = output.activeInsulin {
            self.insulinOnBoard = InsulinValue(
                startDate: input.predictionStart,
                value: activeInsulin
            )
        }
        if let activeCarbs = output.activeCarbs {
            self.carbsOnBoard = CarbValue(
                startDate: input.predictionStart,
                value: activeCarbs
            )
        }
        self.predictedGlucose = output.predictedGlucose
    }
}

enum CancelActiveTempBasalReason: String {
    case automaticDosingDisabled
    case unreliableCGMData
    case maximumBasalRateChanged
}

extension LoopDataManager: AlgorithmDisplayStateProvider {
    var algorithmState: AlgorithmDisplayState {
        return displayState
    }
}

extension LoopDataManager: DiagnosticReportGenerator {
    func generateDiagnosticReport() async -> String {
        let (algoInput, algoOutput) = displayState.asTuple

        var loopError: Error?
        var doseRecommendation: LoopAlgorithmDoseRecommendation?

        if let algoOutput {
            switch algoOutput.recommendationResult {
            case .success(let recommendation):
                doseRecommendation = recommendation
            case .failure(let error):
                loopError = error
            }
        }

        let entries: [String] = [
            "## LoopDataManager",
            "settings: \(String(reflecting: settingsProvider.settings))",

            "* presetHistory: \(temporaryPresetsManager.presetHistory.recentEvents.map(String.init(describing:)))",

            "insulinCounteractionEffects: [",
            "* GlucoseEffectVelocity(start, end, mg/dL/min)",
            (algoOutput?.effects.insulinCounteraction ?? []).reduce(
                into: "",
                { (entries, entry) in
                    entries.append(
                        "* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: GlucoseEffectVelocity.unit))\n"
                    )
                }
            ),
            "]",

            "insulinEffect: [",
            "* GlucoseEffect(start, mg/dL)",
            (algoOutput?.effects.insulin ?? []).reduce(
                into: "",
                { (entries, entry) in
                    entries.append(
                        "* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n"
                    )
                }
            ),
            "]",

            "carbEffect: [",
            "* GlucoseEffect(start, mg/dL)",
            (algoOutput?.effects.carbs ?? []).reduce(
                into: "",
                { (entries, entry) in
                    entries.append(
                        "* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n"
                    )
                }
            ),
            "]",

            "predictedGlucose: [",
            "* PredictedGlucoseValue(start, mg/dL)",
            (algoOutput?.predictedGlucose ?? []).reduce(
                into: "",
                { (entries, entry) in
                    entries.append(
                        "* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n"
                    )
                }
            ),
            "]",

            "integralRetrospectiveCorrectionEnabled: \(UserDefaults.standard.integralRetrospectiveCorrectionEnabled)",

            "retrospectiveCorrection: [",
            "* GlucoseEffect(start, mg/dL)",
            (algoOutput?.effects.retrospectiveCorrection ?? []).reduce(
                into: "",
                { (entries, entry) in
                    entries.append(
                        "* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n"
                    )
                }
            ),
            "]",

            "glucoseMomentumEffect: \(algoOutput?.effects.momentum ?? [])",
            "recommendedAutomaticDose: \(String(describing: doseRecommendation))",
            "lastLoopCompleted: \(String(describing: lastLoopCompleted))",
            "carbsOnBoard: \(String(describing: algoOutput?.activeCarbs))",
            "insulinOnBoard: \(String(describing: algoOutput?.activeInsulin))",
            "error: \(String(describing: loopError))",
            "overrideInUserDefaults: \(String(describing: UserDefaults.appGroup?.intentExtensionOverrideToSet))",
            "glucoseBasedApplicationFactorEnabled: \(UserDefaults.standard.glucoseBasedApplicationFactorEnabled)",
            "integralRetrospectiveCorrectionEanbled: \(String(describing: algoInput?.useIntegralRetrospectiveCorrection))",
            "",
        ]
        return entries.joined(separator: "\n")

    }
}

extension LoopDataManager: LoopControl {

    func scheduledBasalRate(at date: Date? = nil) -> Double? {
        settings.basalRateSchedule?.value(at: date ?? now)
    }

    func currentBasalRate(at date: Date? = nil) -> Double? {
        guard let scheduledBasalRate = scheduledBasalRate(at: date ?? now)
        else {
            return nil
        }

        return deliveryDelegate?.basalDeliveryState?.currentBasalRate(
            currentScheduledBasalRate: scheduledBasalRate
        )
    }

    var automatedTreatmentState: AutomatedTreatmentState? {
        guard let input = displayState.input else {
            return nil
        }

        let now = now

        // need to compare amounts that the pump can actually deliver, instead of calculated amounts
        guard let neutralBasal = input.basal.closestPrior(to: now)?.value,
            let deliverableNeutralBasal = deliveryDelegate?.roundBolusVolume(
                units: neutralBasal
            ),
            let currentlyDeliveredBasalRate = currentBasalRate(at: now)
        else {
            return nil
        }

        if currentlyDeliveredBasalRate > deliverableNeutralBasal {
            return .increasedInsulin
        } else if currentlyDeliveredBasalRate < deliverableNeutralBasal {
            if currentlyDeliveredBasalRate == 0 {
                return .minimumDelivery
            } else {
                return .decreasedInsulin
            }
        } else {
            let recentAutomaticBoluses = input.doses.filter({ dose in
                dose.deliveryType == .bolus && dose.automatic
                    && dose.startDate.addingTimeInterval(.minutes(5)) > now
            })
            if !recentAutomaticBoluses.isEmpty {
                return .increasedInsulin
            }
            return scheduledBasalRate(at: now) != deliverableNeutralBasal
                ? .neutralOverride : .neutralNoOverride
        }
    }
}

extension LoopDataManager: AutomationHistoryProvider {
    func automationHistory(from start: Date, to end: Date) async throws
        -> [AbsoluteScheduleValue<Bool>]
    {
        return automationHistory.toTimeline(from: start, to: end)
    }
}
