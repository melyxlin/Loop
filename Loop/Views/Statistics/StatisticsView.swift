//
//  StatisticsView.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import LoopAlgorithm
import LoopUI

private enum StatisticsCategory: String, CaseIterable, Identifiable {
    case glucose
    case insulin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glucose:
            return NSLocalizedString(
                "Glucose",
                comment: "Statistics category picker glucose option"
            )

        case .insulin:
            return NSLocalizedString(
                "Insulin",
                comment: "Statistics category picker insulin option"
            )
        }
    }
}

/// "How am I doing?" overview — an Ambulatory Glucose Profile report: summary
/// metrics, a time-in-range breakdown, and the 24-hour percentile AGP chart,
/// over a selectable look-back window.
struct StatisticsView: View {
    @StateObject private var viewModel: StatisticsViewModel
    @State private var selectedCategory: StatisticsCategory = .glucose
    @State private var selectedInsulinDay: DailyInsulinTotal?
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    
    // Statistics Range Settings
    
    @AppStorage(StatisticsRangeSettings.targetLowKey)
    private var targetLow: Double = StatisticsRangeSettings.defaultTargetLow

    @AppStorage(StatisticsRangeSettings.targetHighKey)
    private var targetHigh: Double = StatisticsRangeSettings.defaultTargetHigh

    @AppStorage(StatisticsRangeSettings.veryHighKey)
    private var veryHigh: Double = StatisticsRangeSettings.defaultVeryHigh

    @State private var editingRange: EditableStatisticsRange?

    init(
        glucoseStore: GlucoseStoreProtocol,
        doseStore: DoseStoreProtocol? = nil
    ) {
        _viewModel = StateObject(
            wrappedValue: StatisticsViewModel(
                glucoseStore: glucoseStore,
                doseStore: doseStore
            )
        )
    }
    
    var body: some View {
        List {
            Section {
                Picker(
                    NSLocalizedString(
                        "Range",
                        comment: "Statistics date-range picker label"
                    ),
                    selection: $viewModel.selectedRange
                ) {
                    ForEach(StatisticsViewModel.DateRange.allCases) { range in
                        Text("\(range.days)d").tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.selectedRange) { _ in
                    selectedInsulinDay = nil
                }

                Picker(
                    NSLocalizedString(
                        "Category",
                        comment: "Statistics category picker label"
                    ),
                    selection: $selectedCategory
                ) {
                    ForEach(StatisticsCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)
            }

            switch selectedCategory {
            case .glucose:
                glucoseStatisticsContent

            case .insulin:
                insulinStatisticsContent
            }
        }
        .navigationTitle(Text(NSLocalizedString("Statistics", comment: "Statistics screen title")))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingRange) { range in
            StatisticsRangeEditor(
                range: range,
                targetLow: $targetLow,
                targetHigh: $targetHigh,
                veryHigh: $veryHigh
            ) {
                Task {
                    await viewModel.load()
                }
            }
        }
        .task { await viewModel.load() }
    }
    
    private func rangeRow(
           title: String,
           value: Double,
           action: @escaping () -> Void
       ) -> some View {
           Button(action: action) {
               HStack {
                   Text(title)
                       .foregroundColor(.primary)

                   Spacer()

                   Text("\(Int(value.rounded())) mg/dL")
                       .foregroundColor(.secondary)
                       .monospacedDigit()

                   Image(systemName: "chevron.right")
                       .font(.caption.weight(.semibold))
                       .foregroundColor(.secondary)
               }
           }
       }


    // MARK: - Sections

    private func metricsSection(_ stats: GlucoseStatistics) -> some View {
        let averageGoal = displayGlucosePreference.format(LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 154))
        return Section(header: Text(NSLocalizedString("Glucose Metrics", comment: "Glucose metrics section header"))) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                metric(NSLocalizedString("GMI", comment: "Glucose Management Indicator metric title"),
                       value: stats.gmi.map { String(format: "%.1f%%", $0) },
                       goal: NSLocalizedString("Goal: <7%", comment: "GMI goal"))
                metric(NSLocalizedString("Average", comment: "Average glucose metric title"),
                       value: stats.averageGlucose.map {
                           displayGlucosePreference.format(LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: $0))
                       },
                       goal: String(format: NSLocalizedString("Goal: <%@", comment: "Average glucose goal"), averageGoal))
                metric(NSLocalizedString("Variability", comment: "Coefficient of variation metric title"),
                       value: stats.coefficientOfVariation.map { String(format: "%.0f%%", $0) },
                       goal: NSLocalizedString("Goal: ≤36%", comment: "Glucose variability goal"))
                metric(NSLocalizedString("CGM Active", comment: "Percent of time CGM data present metric title"),
                       value: String(format: "%.0f%%", stats.percentActive * 100),
                       goal: NSLocalizedString("Goal: >70%", comment: "CGM active goal"))
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    private func metric(_ title: String, value: String?, goal: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(value ?? "–")
                .font(.system(.title, design: .rounded).weight(.bold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(goal)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func timeInRangeSection(_ stats: GlucoseStatistics) -> some View {
        Section(header: Text(NSLocalizedString("Time in Range", comment: "Time-in-range section header"))) {
            TimeInRangeBar(timeInRange: stats.timeInRange)
                .padding(.vertical, 8)
        }
    }
    
    @ViewBuilder
    private var glucoseStatisticsContent: some View {
        Section(header: Text("Statistics Ranges")) {
            rangeRow(
                title: "Low",
                value: targetLow
            ) {
                editingRange = .low
            }

            rangeRow(
                title: "High",
                value: targetHigh
            ) {
                editingRange = .high
            }

            rangeRow(
                title: "Very High",
                value: veryHigh
            ) {
                editingRange = .veryHigh
            }

            HStack {
                Text("Very Low")
                Spacer()
                Text("<54 mg/dL")
                    .foregroundColor(.secondary)
            }
        }

        if !viewModel.dataNotices.isEmpty {
            Section {
                ForEach(viewModel.dataNotices, id: \.self) { line in
                    Label {
                        Text(line)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
            }
        }

        if let stats = viewModel.statistics,
           stats.sampleCount > 0 {
            metricsSection(stats)
            timeInRangeSection(stats)
            agpSection(stats)
            glucoseDistributionSection(stats)

        } else if viewModel.isLoading {
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }

        } else {
            Section {
                Text(
                    NSLocalizedString(
                        "No glucose data for this period.",
                        comment: "Statistics empty state"
                    )
                )
                .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private var insulinStatisticsContent: some View {
        if let stats = viewModel.insulinStatistics,
           stats.totalInsulin > 0 {

            insulinUsageSection(stats)

        } else if viewModel.isLoading {
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }

        } else {
            Section {
                Text(
                    NSLocalizedString(
                        "No insulin data for this period.",
                        comment: "Insulin statistics empty state"
                    )
                )
                .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private func insulinUsageSection(_ stats: InsulinStatistics) -> some View {
        Section(
            header: Text(
                NSLocalizedString(
                    "Insulin Usage",
                    comment: "Insulin statistics section header"
                )
            ),
            footer: Text(
                NSLocalizedString(
                    "Daily insulin delivery split between basal and bolus.",
                    comment: "Insulin usage chart explanation"
                )
            )
        ) {
            InsulinUsageChartView(
                dailyTotals: stats.dailyTotals,
                selectedDay: $selectedInsulinDay
            )
            .frame(height: 240)
            .padding(.vertical, 8)
            if let selectedDay = selectedInsulinDay {
                dailyInsulinCard(selectedDay)
            }

            HStack(spacing: 20) {
                insulinLegend(
                    title: NSLocalizedString(
                        "Basal",
                        comment: "Insulin statistics basal legend"
                    ),
                    color: .blue
                )

                insulinLegend(
                    title: NSLocalizedString(
                        "Bolus",
                        comment: "Insulin statistics bolus legend"
                    ),
                    color: .purple
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 4)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                insulinMetric(
                    NSLocalizedString(
                        "Average / Day",
                        comment: "Average daily insulin metric title"
                    ),
                    value: stats.averageDailyInsulin
                )

                insulinMetric(
                    NSLocalizedString(
                        "Total",
                        comment: "Total insulin metric title"
                    ),
                    value: stats.totalInsulin
                )

                insulinMetric(
                    NSLocalizedString(
                        "Basal / Day",
                        comment: "Average daily basal insulin metric title"
                    ),
                    value: stats.averageDailyBasal,
                    percentage: stats.basalPercentage
                )

                insulinMetric(
                    NSLocalizedString(
                        "Bolus / Day",
                        comment: "Average daily bolus insulin metric title"
                    ),
                    value: stats.averageDailyBolus,
                    percentage: stats.bolusPercentage
                )
            }
            .listRowInsets(
                EdgeInsets(
                    top: 8,
                    leading: 16,
                    bottom: 8,
                    trailing: 16
                )
            )
            .listRowBackground(Color.clear)
        }
    }

    private func insulinMetric(
        _ title: String,
        value: Double,
        percentage: Double? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Text(String(format: "%.1f U", value))
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            if let percentage {
                Text(String(format: "%.0f%% of insulin", percentage * 100))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text(" ")
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
            .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func insulinLegend(
        title: String,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 12, height: 12)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    private func dailyInsulinCard(
        _ day: DailyInsulinTotal
    ) -> some View {
        let total = day.total

        let basalPercentage = total > 0
            ? day.basal / total
            : 0

        let bolusPercentage = total > 0
            ? day.bolus / total
            : 0

        return VStack(alignment: .leading, spacing: 12) {
            Text(
                day.date.formatted(
                    .dateTime
                        .weekday(.wide)
                        .month(.wide)
                        .day()
                )
            )
            .font(.headline)

            HStack {
                Text(
                    NSLocalizedString(
                        "Total",
                        comment: "Daily insulin total label"
                    )
                )

                Spacer()

                Text(String(format: "%.1f U", total))
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        NSLocalizedString(
                            "Basal",
                            comment: "Daily insulin basal label"
                        )
                    )
                    .font(.subheadline.weight(.semibold))

                    Text(
                        String(
                            format: "%.0f%%",
                            basalPercentage * 100
                        )
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                Text(String(format: "%.1f U", day.basal))
                    .monospacedDigit()
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        NSLocalizedString(
                            "Bolus",
                            comment: "Daily insulin bolus label"
                        )
                    )
                    .font(.subheadline.weight(.semibold))

                    Text(
                        String(
                            format: "%.0f%%",
                            bolusPercentage * 100
                        )
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                Text(String(format: "%.1f U", day.bolus))
                    .monospacedDigit()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
            .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private func agpSection(_ stats: GlucoseStatistics) -> some View {
        Section(header: Text(NSLocalizedString("Daily Glucose Pattern", comment: "Daily glucose pattern (AGP) section header")),
                footer: Text(NSLocalizedString("Median (line) with 25–75% and 5–95% bands, by time of day.", comment: "AGP chart explanation"))) {
            if stats.agpProfile.isEmpty {
                Text(NSLocalizedString("Not enough data to plot a profile.", comment: "AGP empty state"))
                    .foregroundColor(.secondary)
            } else {
                AGPChartView(profile: stats.agpProfile, unit: displayGlucosePreference.unit)
                    .frame(height: 240)
                    .padding(.vertical, 8)
            }
        }
    }
}

@ViewBuilder
private func glucoseDistributionSection(_ stats: GlucoseStatistics) -> some View {
    Section(
        header: Text(
            NSLocalizedString(
                "Distribution by Time",
                comment: "Glucose distribution by time section header"
            )
        ),
        footer: Text(
            NSLocalizedString(
                "Percentage of glucose readings in each range, by time of day.",
                comment: "Glucose distribution by time chart explanation"
            )
        )
    ) {
        if !stats.glucoseDistribution.contains(where: { $0.fractions != nil }) {
            Text(
                NSLocalizedString(
                    "Not enough data to plot a distribution.",
                    comment: "Glucose distribution empty state"
                )
            )
            .foregroundColor(.secondary)
        } else {
            GlucoseDistributionChartView(
                distribution: stats.glucoseDistribution
            )
            .frame(height: 240)
            .padding(.vertical, 8)
        }
    }
}

#if DEBUG
/// Generates a daily glucose pattern with day-to-day spread so the AGP bands and
/// metrics populate in the canvas. Deterministic (seeded) so previews are stable.
private final class PreviewGlucoseStore: GlucoseStoreProtocol {
    private let samples: [StoredGlucoseSample]

    init() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func unit01() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        let cal = Calendar.current
        let now = Date()
        let cadence: TimeInterval = 15 * 60
        var t = now.addingTimeInterval(-14 * 24 * 60 * 60)
        var out: [StoredGlucoseSample] = []
        while t < now {
            let hour = t.timeIntervalSince(cal.startOfDay(for: t)) / 3600
            let base = 140.0 + 40 * sin((hour - 4) / 24 * 2 * .pi)
            let value = max(45, base + (unit01() - 0.5) * 70)
            out.append(StoredGlucoseSample(startDate: t, quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: value)))
            t = t.addingTimeInterval(cadence)
        }
        samples = out
    }

    var latestGlucose: GlucoseSampleValue? { samples.last }

    func getGlucoseSamples(start: Date?, end: Date?) async throws -> [StoredGlucoseSample] {
        samples.filter { (start == nil || $0.startDate >= start!) && (end == nil || $0.startDate < end!) }
    }

    func addGlucoseSamples(_ samples: [NewGlucoseSample]) async throws -> [StoredGlucoseSample] { [] }
}

#Preview {
    NavigationView {
        StatisticsView(glucoseStore: PreviewGlucoseStore())
            .environmentObject(DisplayGlucosePreference(displayGlucoseUnit: .milligramsPerDeciliter))
    }
}
#endif
