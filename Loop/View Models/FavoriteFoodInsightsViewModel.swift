//
//  FavoriteFoodInsightsViewModel.swift
//  Loop
//
//  Created by Noah Brauner on 7/15/24.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import LoopKit
import LoopKitUI
import LoopAlgorithm
import os.log
import Combine

protocol FavoriteFoodInsightsViewModelDelegate: AnyObject {
    func selectedFavoriteFoodLastEaten(_ favoriteFood: StoredFavoriteFood) async throws -> Date?
    func getFavoriteFoodCarbEntries(_ favoriteFood: StoredFavoriteFood) async throws -> [StoredCarbEntry]
    func getHistoricalChartsData(start: Date, end: Date) async throws -> HistoricalChartsData
}

struct HistoricalChartsData {
    let glucoseValues: [GlucoseValue]
    let carbEntries: [StoredCarbEntry]
    let doses: [BasalRelativeDose]
    let rawDoses: [DoseEntry]
    let iobValues: [InsulinValue]
    let carbAbsorptionReview: CarbAbsorptionReview?
}

class FavoriteFoodInsightsViewModel: ObservableObject {
    let food: StoredFavoriteFood
    var carbEntries: [StoredCarbEntry] = []
    @Published var carbEntryIndex = 0
    var carbEntry: StoredCarbEntry? {
        let entryExistsForIndex = 0..<carbEntries.count ~= carbEntryIndex
        return entryExistsForIndex ? carbEntries[carbEntryIndex] : nil
    }
    
    static var minTimeIntervalPrecedingFoodEaten: TimeInterval = .hours(1)
    static var minTimeIntervalFollowingFoodEaten: TimeInterval = .hours(6)
    var historyLength: TimeInterval { FavoriteFoodInsightsViewModel.minTimeIntervalPrecedingFoodEaten + FavoriteFoodInsightsViewModel.minTimeIntervalFollowingFoodEaten }

    // Updates each time carbEntry updates
    @Published var historicalGlucoseValues: [GlucoseValue] = []
    @Published var historicalCarbEntries: [StoredCarbEntry] = []
    @Published var historicalDoses: [BasalRelativeDose] = []
    @Published var historicalRawDoses: [DoseEntry] = []
    private var originalHistoricalCarbEntries: [StoredCarbEntry] = []
    @Published var historicalIOBValues: [InsulinValue] = []
    @Published var historicalCarbAbsorptionReview: CarbAbsorptionReview? = nil
    
    @Published var startDate = Date()
    var endDate: Date {
        startDate.addingTimeInterval(historyLength)
    }
    var dateInterval: DateInterval {
        DateInterval(start: startDate, end: endDate)
    }
    var now = Date()
    
    private var postMealGlucoseValues: [GlucoseValue] {
        guard let mealDate = carbEntry?.startDate,
              let responseEndDate
        else {
            return []
        }

        return historicalGlucoseValues
            .filter {
                $0.startDate >= mealDate &&
                $0.startDate < responseEndDate
            }
            .sorted {
                $0.startDate < $1.startDate
            }
    }
    var startingGlucose: LoopQuantity? {
        guard let mealDate = carbEntry?.startDate else {
            return nil
        }

        return historicalGlucoseValues
            .filter { $0.startDate < mealDate }
            .max { $0.startDate < $1.startDate }?
            .quantity
    }

    var peakGlucose: LoopQuantity? {
        postMealGlucoseValues.max {
            $0.quantity.doubleValue(for: .milligramsPerDeciliter)
                < $1.quantity.doubleValue(for: .milligramsPerDeciliter)
        }?.quantity
    }

    var lowestGlucose: LoopQuantity? {
        postMealGlucoseValues.min {
            $0.quantity.doubleValue(for: .milligramsPerDeciliter)
                < $1.quantity.doubleValue(for: .milligramsPerDeciliter)
        }?.quantity
    }

    var glucoseRise: Double? {
        guard let startingGlucose,
              let peakGlucose
        else {
            return nil
        }

        return peakGlucose.doubleValue(for: .milligramsPerDeciliter)
            - startingGlucose.doubleValue(for: .milligramsPerDeciliter)
    }

    var timeToPeak: TimeInterval? {
        guard let mealDate = carbEntry?.startDate,
              let peak = postMealGlucoseValues.max(by: {
                  $0.quantity.doubleValue(for: .milligramsPerDeciliter)
                      < $1.quantity.doubleValue(for: .milligramsPerDeciliter)
              })
        else {
            return nil
        }

        return peak.startDate.timeIntervalSince(mealDate)
    }
    
    var startingIOB: Double? {
        guard let mealDate = carbEntry?.startDate else {
            return nil
        }

        return historicalIOBValues.min(by: {
            abs($0.startDate.timeIntervalSince(mealDate)) <
            abs($1.startDate.timeIntervalSince(mealDate))
        })?.value
    }

    private var mealBolusWindow: DateInterval? {
        guard let mealDate = carbEntry?.startDate else {
            return nil
        }

        return DateInterval(
            start: mealDate.addingTimeInterval(.minutes(-30)),
            end: mealDate.addingTimeInterval(.minutes(5))
        )
    }

//    private var postMealBolusWindow: DateInterval? {
//        guard let mealDate = carbEntry?.startDate else {
//            return nil
//       }
//
//        return DateInterval(
//            start: mealDate.addingTimeInterval(.minutes(5)),
//            end: mealDate.addingTimeInterval(
//                FavoriteFoodInsightsViewModel.minTimeIntervalFollowingFoodEaten
//            )
//        )
//    }

    private var bolusDoses: [DoseEntry] {
        historicalRawDoses.filter {
            $0.type == .bolus
        }
    }

    var mealBolus: Double {
        guard let window = mealBolusWindow else {
            return 0
        }

        return bolusDoses
            .filter {
                window.contains($0.startDate) &&
                $0.automatic != true
            }
            .map {
                $0.deliveredUnits ?? $0.programmedUnits
            }
            .reduce(0, +)
    }

    var additionalBolus: Double {
        guard let mealDate = carbEntry?.startDate,
              let responseEndDate
        else {
            return 0
        }

        let mealBolusWindowEnd = mealDate.addingTimeInterval(.minutes(5))

        return bolusDoses
            .filter {
                $0.startDate > mealBolusWindowEnd &&
                $0.startDate < responseEndDate
            }
            .map {
                $0.deliveredUnits ?? $0.programmedUnits
            }
            .reduce(0, +)
    }

    var totalBolus: Double {
        mealBolus + additionalBolus
    }
    
    private var defaultResponseEndDate: Date? {
        guard let mealDate = carbEntry?.startDate else {
            return nil
        }

        return mealDate.addingTimeInterval(
            FavoriteFoodInsightsViewModel.minTimeIntervalFollowingFoodEaten
        )
    }

    var nextCarbEntryAfterMeal: StoredCarbEntry? {
        guard let mealDate = carbEntry?.startDate,
              let defaultEnd = defaultResponseEndDate
        else {
            return nil
        }

        return originalHistoricalCarbEntries
            .filter {
                $0.startDate > mealDate &&
                $0.startDate < defaultEnd &&
                $0.foodType != "🥩"
            }
            .min {
                $0.startDate < $1.startDate
            }
    }

    private var responseEndDate: Date? {
        guard let defaultEnd = defaultResponseEndDate else {
            return nil
        }

        if let nextCarbEntryAfterMeal {
            return min(defaultEnd, nextCarbEntryAfterMeal.startDate)
        }

        return defaultEnd
    }

    var hasOverlappingFood: Bool {
        nextCarbEntryAfterMeal != nil
    }

    var timeUntilOverlappingFood: TimeInterval? {
        guard let mealDate = carbEntry?.startDate,
              let nextCarbEntryAfterMeal
        else {
            return nil
        }

        return nextCarbEntryAfterMeal.startDate.timeIntervalSince(mealDate)
    }
    
    var preferredCarbUnit = LoopUnit.gram
    lazy var carbFormatter = QuantityFormatter(for: preferredCarbUnit)
    lazy var absorptionTimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    lazy var dateFormater: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .short
        return formatter
    }()
    lazy var relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    lazy var dateIntervalFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.timeStyle = .short
        formatter.dateTemplate = "MMMMd h:mm a"
        return formatter
    }()
    
    private let log = OSLog(category: "FavoriteFoodInsightsViewModel")
    
    let chartManager: ChartsManager = {
        let glucoseChart = GlucoseCarbChart(yAxisStepSizeMGDLOverride: FeatureFlags.predictedGlucoseChartClampEnabled ? 40 : nil)
        glucoseChart.glucoseDisplayRange = LoopConstants.glucoseChartDefaultDisplayRangeWide
        let iobChart = IOBChart()
        let doseChart = LegacyDoseChart()
        let carbEffectChart = CarbEffectChart()
        carbEffectChart.glucoseDisplayRange = LoopConstants.glucoseChartDefaultDisplayBound
        return ChartsManager(colors: .primary, settings: .default, charts: [glucoseChart, iobChart, doseChart, carbEffectChart], traitCollection: .current)
    }()
    
    private weak var delegate: FavoriteFoodInsightsViewModelDelegate?
    
    private lazy var cancellables = Set<AnyCancellable>()

    init(delegate: FavoriteFoodInsightsViewModelDelegate?, food: StoredFavoriteFood) {
        self.delegate = delegate
        self.food = food
        fetchCarbEntries(food)
        observeCarbEntryIndexChange()
    }
    
    private func fetchCarbEntries(_ food: StoredFavoriteFood) {
        Task { @MainActor in
            do {
                if let entries = try await delegate?.getFavoriteFoodCarbEntries(food), !entries.isEmpty {
                    self.carbEntries = entries
                    updateStartDateAndRefreshCharts(from: entries.first!)
                }
            }
            catch {
                log.error("Failed to fetch carb entries for favorite food: %{public}@", String(describing: error))
            }
        }
    }
    
    private func updateStartDateAndRefreshCharts(from entry: StoredCarbEntry) {
        var components = DateComponents()
        components.minute = 0
        let minimumStartDate = entry.startDate.addingTimeInterval(-FavoriteFoodInsightsViewModel.minTimeIntervalPrecedingFoodEaten)
        let hourRoundedStartDate = Calendar.current.nextDate(after: minimumStartDate, matching: components, matchingPolicy: .strict, direction: .backward) ?? minimumStartDate
        
        startDate = hourRoundedStartDate
        refreshCharts()
    }
    
    private func refreshCharts() {
        Task { @MainActor in
            do {
                if let historicalChartsData = try await delegate?.getHistoricalChartsData(start: dateInterval.start, end: dateInterval.end) {
                    self.originalHistoricalCarbEntries = historicalChartsData.carbEntries
                    var carbEntriesWithCorrectedFavoriteFoods = historicalChartsData.carbEntries.map({ historicalCarbEntry in
                        // only show a favorite food icon in the glcuose-carb chart if carb entry is currently viewed favorite food
                        StoredCarbEntry(
                            startDate: historicalCarbEntry.startDate,
                            quantity: historicalCarbEntry.quantity,
                            favoriteFoodID: historicalCarbEntry.uuid == carbEntry?.uuid ? historicalCarbEntry.favoriteFoodID : nil
                        )
                    })
                    self.historicalGlucoseValues = historicalChartsData.glucoseValues
                    self.historicalCarbEntries = carbEntriesWithCorrectedFavoriteFoods
                    self.historicalDoses = historicalChartsData.doses
                    self.historicalRawDoses = historicalChartsData.rawDoses
                    self.historicalIOBValues = historicalChartsData.iobValues
                    self.historicalCarbAbsorptionReview = historicalChartsData.carbAbsorptionReview
                }
            } catch {
                log.error("Failed to fetch historical data in date interval: %{public}@, %{public}@", String(describing: dateInterval), String(describing: error))
            }
        }
    }
    
    private func observeCarbEntryIndexChange() {
        $carbEntryIndex
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] index in
                guard let strongSelf = self else { return }
                strongSelf.updateStartDateAndRefreshCharts(from: strongSelf.carbEntries[strongSelf.carbEntryIndex])
            }
            .store(in: &cancellables)
    }
}
