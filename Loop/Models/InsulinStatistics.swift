//
//  InsulinStatistics.swift
//  Loop
//
//  Created by Melissa Lin on 9/9/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

struct DailyInsulinTotal: Identifiable, Equatable {
    let date: Date
    let basal: Double
    let bolus: Double

    var id: Date { date }

    var total: Double {
        basal + bolus
    }
}

struct InsulinStatistics: Equatable {
    let dailyTotals: [DailyInsulinTotal]

    var totalBasal: Double {
        dailyTotals.reduce(0) { $0 + $1.basal }
    }

    var totalBolus: Double {
        dailyTotals.reduce(0) { $0 + $1.bolus }
    }

    var totalInsulin: Double {
        totalBasal + totalBolus
    }

    var averageDailyBasal: Double {
        guard !dailyTotals.isEmpty else { return 0 }
        return totalBasal / Double(dailyTotals.count)
    }

    var averageDailyBolus: Double {
        guard !dailyTotals.isEmpty else { return 0 }
        return totalBolus / Double(dailyTotals.count)
    }

    var averageDailyInsulin: Double {
        guard !dailyTotals.isEmpty else { return 0 }
        return totalInsulin / Double(dailyTotals.count)
    }

    var basalPercentage: Double {
        guard totalInsulin > 0 else { return 0 }
        return totalBasal / totalInsulin
    }

    var bolusPercentage: Double {
        guard totalInsulin > 0 else { return 0 }
        return totalBolus / totalInsulin
    }

    init(
        doses: [DoseEntry],
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) {
        guard start < end else {
            dailyTotals = []
            return
        }

        var totals: [Date: (basal: Double, bolus: Double)] = [:]

        // Create each calendar day represented by the selected range.
        //
        // The statistics range is a rolling interval (for example, exactly 7 days
        // before the current time). Starting directly at startOfDay(for: start)
        // would therefore create an extra partial calendar day.
        //
        // Skip that partial first day so a 7-day range contains exactly 7 daily
        // buckets, a 14-day range contains 14, and so on.
        var day = calendar.startOfDay(for: start)

        if start > day,
           let nextDay = calendar.date(byAdding: .day, value: 1, to: day) {
            day = nextDay
        }

        while day < end {
            totals[day] = (0, 0)

            guard let nextDay = calendar.date(
                byAdding: .day,
                value: 1,
                to: day
            ) else {
                break
            }

            day = nextDay
        }

        for dose in doses {
            switch dose.type {
            case .bolus:
                // Prefer confirmed delivered insulin when the pump reports it.
                let units = dose.deliveredUnits ?? dose.programmedUnits

                guard units > 0,
                      dose.startDate >= start,
                      dose.startDate < end
                else {
                    continue
                }

                let doseDay = calendar.startOfDay(for: dose.startDate)

                guard totals[doseDay] != nil else {
                    continue
                }

                totals[doseDay]!.bolus += units

            case .basal, .tempBasal:
                Self.addBasalDose(
                    dose,
                    start: start,
                    end: end,
                    calendar: calendar,
                    totals: &totals
                )

            case .resume, .suspend:
                // These represent delivery state changes rather than insulin.
                continue
            }
        }

        dailyTotals = totals
            .map {
                DailyInsulinTotal(
                    date: $0.key,
                    basal: $0.value.basal,
                    bolus: $0.value.bolus
                )
            }
            .sorted { $0.date < $1.date }
    }

    private static func addBasalDose(
        _ dose: DoseEntry,
        start: Date,
        end: Date,
        calendar: Calendar,
        totals: inout [Date: (basal: Double, bolus: Double)]
    ) {
        let doseStart = max(dose.startDate, start)
        let doseEnd = min(dose.endDate, end)

        guard doseEnd > doseStart else {
            return
        }

        let doseDuration = dose.endDate.timeIntervalSince(dose.startDate)

        guard doseDuration > 0 else {
            return
        }

        // DoseEntry already prefers deliveredUnits when available.
        let completeDoseUnits = dose.unitsInDeliverableIncrements

        guard completeDoseUnits > 0 else {
            return
        }

        var segmentStart = doseStart

        while segmentStart < doseEnd {
            let currentDay = calendar.startOfDay(for: segmentStart)

            guard let nextDay = calendar.date(
                byAdding: .day,
                value: 1,
                to: currentDay
            ) else {
                break
            }

            let segmentEnd = min(nextDay, doseEnd)
            let fraction = segmentEnd.timeIntervalSince(segmentStart) / doseDuration
            let units = completeDoseUnits * fraction

            if totals[currentDay] != nil {
                totals[currentDay]!.basal += units
            }

            segmentStart = segmentEnd
        }
    }
}
