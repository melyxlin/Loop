//
//  GraphDetailViewModel.swift
//  Loop
//
//  GraphDetailView — Data aggregation for a specific chart timestamp.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Combine
import Foundation
import HealthKit
import LoopKit
import LoopAlgorithm

// MARK: - GraphDetailViewModel

final class GraphDetailViewModel: ObservableObject {
    @Published var data: GraphDetailData

    private let deviceManager: DeviceDataManager
    private let loopManager: LoopDataManager
    private var scrubThrottleTimer: Timer?

    init(
        date: Date,
        glucoseUnit: LoopUnit,
        deviceManager: DeviceDataManager,
        loopManager: LoopDataManager
    ) {
        self.deviceManager = deviceManager
        self.loopManager = loopManager
        self.data = GraphDetailData(date: date, glucoseUnit: glucoseUnit)
        loadData()
    }

    /// Update to a new date and reload all data (throttled during scrub/drag)
    func update(for date: Date) {
        // Update the date immediately — keep existing data values visible until new ones arrive
        data.date = date

        // Throttle the expensive data queries to avoid flooding HealthKit/DoseStore
        scrubThrottleTimer?.invalidate()
        scrubThrottleTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Clear stale values and reload for the current date
            let currentDate = self.data.date
            self.data = GraphDetailData(date: currentDate, glucoseUnit: self.data.glucoseUnit)
            self.loadData()
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        loadGlucose()
        loadIOB()
        loadCOB()
        loadBolus()
        loadBasalRate()
        loadOverride()
        loadAutoPreset()
        loadHeartRate()
    }

    private func loadGlucose() {
        let targetDate = data.date
        let window: TimeInterval = 5 * 60
        let start = targetDate.addingTimeInterval(-window)
        let end = targetDate.addingTimeInterval(window)

        Task { [weak self] in
            guard let self else { return }

            do {
                let samples = try await deviceManager.glucoseStore.getGlucoseSamples(
                    start: start,
                    end: end
                )

                let closest = samples.min {
                    abs($0.startDate.timeIntervalSince(targetDate)) <
                    abs($1.startDate.timeIntervalSince(targetDate))
                }

                if let sample = closest {
                    let value = sample.quantity.doubleValue(for: self.data.glucoseUnit)

                    await MainActor.run {
                        guard self.data.date == targetDate else { return }
                        self.data.glucoseValue = value
                    }
                }
            } catch {
                // Leave glucose empty if the historical query fails.
            }
        }
    }

    private func loadIOB() {
        let targetDate = data.date
        let start = targetDate.addingTimeInterval(-5 * 60)
        let end = targetDate.addingTimeInterval(5 * 60)

        Task { [weak self] in
            guard let self else { return }

            do {
                let historicalData = try await loopManager.getHistoricalChartsData(
                    start: start,
                    end: end
                )

                let closest = historicalData.iobValues.min {
                    abs($0.startDate.timeIntervalSince(targetDate)) <
                    abs($1.startDate.timeIntervalSince(targetDate))
                }

                if let closest {
                    await MainActor.run {
                        guard self.data.date == targetDate else { return }
                        self.data.insulinOnBoard = closest.value
                    }
                }
            } catch {
                // Leave IOB empty when historical calculation is unavailable.
            }
        }
    }

    private func loadCOB() {
        // COB requires counteraction effects from loop state, so we use a simpler approach
        // Query carb entries near this time to estimate
//        deviceManager.loopManager.getLoopState { [weak self] (_, state) in
//            guard let self = self else { return }
//            if let cobValue = state.carbsOnBoard {
//                // This is current COB — for historical, we approximate from the values array
//                DispatchQueue.main.async {
//                    // Only show if the date is recent (within last few minutes)
//                    if abs(self.data.date.timeIntervalSinceNow) < 10 * 60 {
//                        self.data.carbsOnBoard = cobValue.quantity.doubleValue(for: .gram())
//                    }
//                }
//            }
//        }
        // TODO: Port to next-dev historical carb absorption data.
        let targetDate = data.date

            // Include enough history to capture carbs that may still be absorbing
            // at the selected chart timestamp.
            let start = targetDate.addingTimeInterval(
                -CarbMath.maximumAbsorptionTimeInterval
            )
            let end = targetDate

            Task { [weak self] in
                guard let self else { return }

                do {
                    let review = try await loopManager.fetchCarbAbsorptionReview(
                        start: start,
                        end: end
                    )

                    let cob = review.carbStatuses.dynamicCarbsOnBoard(
                        at: targetDate,
                        absorptionModel: CarbAbsorptionModel.piecewiseLinear.model
                    )

                    await MainActor.run {
                        guard self.data.date == targetDate else { return }
                        self.data.carbsOnBoard = cob
                    }
                } catch {
                    // Leave COB empty if historical absorption cannot be calculated.
                }
            }
    }

    private func loadBolus() {
        let targetDate = data.date
        let window: TimeInterval = 15 * 60
        let start = targetDate.addingTimeInterval(-window)
        let end = targetDate.addingTimeInterval(window)

        Task { [weak self] in
            guard let self else { return }

            do {
                let entries = try await deviceManager.doseStore.getNormalizedDoseEntries(
                    start: start,
                    end: end
                )

                let boluses = entries.filter { $0.type == .bolus }

                let closest = boluses.min {
                    abs($0.startDate.timeIntervalSince(targetDate)) <
                    abs($1.startDate.timeIntervalSince(targetDate))
                }

                if let bolus = closest {
                    let units = bolus.deliveredUnits ?? bolus.programmedUnits

                    guard units > 0 else { return }

                    await MainActor.run {
                        guard self.data.date == targetDate else { return }

                        self.data.recentBolus = (
                            units: units,
                            date: bolus.startDate
                        )
                    }
                }
            } catch {
                // Leave bolus empty if the historical query fails.
            }
        }
    }
    private func loadBasalRate() {
        let targetDate = data.date

        Task { @MainActor [weak self] in
            guard let self else { return }

            if let schedule = self.loopManager.settings.basalRateSchedule {
                self.data.basalRate = schedule.value(at: targetDate)
            }
        }
    }

    private func loadOverride() {
        let targetDate = data.date

        Task { @MainActor [weak self] in
            guard let self else { return }

            if let override = self.loopManager.scheduleOverride,
               override.isActive(at: targetDate) {

                let name: String

                switch override.context {
                case .preset(let preset):
                    name = "\(preset.symbol) \(preset.name)"

                case .activity(let activity):
                    name = "\(activity.preset.symbol) \(activity.preset.name)"

                case .preMeal:
                    name = "🍽 Pre-Meal"

                case .custom:
                    name = "⚙️ Custom Override"
                }

                self.data.activePreset = name
            }
        }
    }

    private func loadAutoPreset() {
        // Read AutoPresets activity log directly from UserDefaults (no compile-time dependency)
        guard let defaults = UserDefaults(suiteName: "com.loopkit.Loop.AutoPresets"),
              let settingsData = defaults.data(forKey: "settings") else { return }

        // Decode only the fields we need
        struct MinimalLogEntry: Decodable {
            let date: Date
            let event: String
            let presetName: String?
        }
        struct MinimalSettings: Decodable {
            let recentActivityLog: [MinimalLogEntry]?
        }

        guard let settings = try? JSONDecoder().decode(MinimalSettings.self, from: settingsData),
              let entries = settings.recentActivityLog else { return }

        var lastActivation: (name: String, date: Date)?
        var lastDeactivation: Date?

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard entry.date <= data.date else { break }
            if entry.event == "presetActivated" {
                lastActivation = (entry.presetName ?? "Active", entry.date)
            } else if entry.event == "presetDeactivated" {
                lastDeactivation = entry.date
            }
        }

        if let activation = lastActivation {
            let isStillActive = lastDeactivation == nil || lastDeactivation! < activation.date
            if isStillActive {
                DispatchQueue.main.async {
                    self.data.activeAutoPreset = activation.name
                }
            }
        }
    }

    private func loadHeartRate() {
        let healthStore = HKHealthStore()
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let window: TimeInterval = 5 * 60
        let start = data.date.addingTimeInterval(-window)
        let end = data.date.addingTimeInterval(window)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        let query = HKSampleQuery(
            sampleType: heartRateType,
            predicate: predicate,
            limit: 10,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { [weak self] _, samples, _ in
            guard let self = self,
                  let samples = samples as? [HKQuantitySample],
                  !samples.isEmpty else { return }

            // Find closest to target date
            let closest = samples.min(by: {
                abs($0.startDate.timeIntervalSince(self.data.date)) < abs($1.startDate.timeIntervalSince(self.data.date))
            })
            if let hr = closest {
                let bpm = hr.quantity.doubleValue(for: HKUnit(from: "count/min"))
                DispatchQueue.main.async {
                    self.data.heartRate = bpm
                }
            }
        }
        healthStore.execute(query)
    }
}
