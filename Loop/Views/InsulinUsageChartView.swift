//
//  InsulinUsageChartView.swift
//  Loop
//
//  Created by Melissa Lin on 9/9/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

struct InsulinUsageChartView: View {
    let dailyTotals: [DailyInsulinTotal]

    @Binding var selectedDay: DailyInsulinTotal?
    private let leftInset: CGFloat = 34
    private let bottomInset: CGFloat = 24
    private let topInset: CGFloat = 8
    private let rightInset: CGFloat = 8
    
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let plot = CGRect(
                    x: leftInset,
                    y: topInset,
                    width: size.width - leftInset - rightInset,
                    height: size.height - topInset - bottomInset
                )

                guard plot.width > 0,
                      plot.height > 0,
                      !dailyTotals.isEmpty
                else {
                    return
                }

                let maximum = dailyTotals.map(\.total).max() ?? 0

                guard maximum > 0 else {
                    return
                }

                // Give the tallest bar a little breathing room.
                let yMaximum = maximum * 1.15

                func y(_ units: Double) -> CGFloat {
                    plot.maxY
                        - CGFloat(units / yMaximum)
                        * plot.height
                }

                // MARK: - Gridlines

                for fraction in [0.0, 0.25, 0.50, 0.75, 1.0] {
                    let units = yMaximum * fraction
                    let yPosition = y(units)

                    var line = Path()

                    line.move(
                        to: CGPoint(
                            x: plot.minX,
                            y: yPosition
                        )
                    )

                    line.addLine(
                        to: CGPoint(
                            x: plot.maxX,
                            y: yPosition
                        )
                    )

                    context.stroke(
                        line,
                        with: .color(.gray.opacity(0.25)),
                        lineWidth: 0.5
                    )

                    context.draw(
                        Text(String(format: "%.0f", units))
                            .font(.caption2)
                            .foregroundColor(.secondary),
                        at: CGPoint(
                            x: plot.minX - 4,
                            y: yPosition
                        ),
                        anchor: .trailing
                    )
                }

                // MARK: - Stacked daily bars

                let slotWidth = plot.width / CGFloat(dailyTotals.count)

                let barWidth = max(
                    2,
                    min(
                        22,
                        slotWidth * 0.68
                    )
                )

                for (index, day) in dailyTotals.enumerated() {
                    let centerX = plot.minX
                        + slotWidth * (CGFloat(index) + 0.5)

                    let basalTop = y(day.basal)
                    let totalTop = y(day.total)

                    if day.basal > 0 {
                        let basalRect = CGRect(
                            x: centerX - barWidth / 2,
                            y: basalTop,
                            width: barWidth,
                            height: plot.maxY - basalTop
                        )

                        context.fill(
                            Path(basalRect),
                            with: .color(.blue.opacity(0.75))
                        )
                    }

                    if day.bolus > 0 {
                        let bolusRect = CGRect(
                            x: centerX - barWidth / 2,
                            y: totalTop,
                            width: barWidth,
                            height: basalTop - totalTop
                        )

                        context.fill(
                            Path(bolusRect),
                            with: .color(.purple.opacity(0.85))
                        )
                    }

                    // Highlight the selected day's bar.
                    if selectedDay?.id == day.id {
                        let selectedRect = CGRect(
                            x: centerX - barWidth / 2 - 2,
                            y: totalTop - 2,
                            width: barWidth + 4,
                            height: plot.maxY - totalTop + 4
                        )

                        context.stroke(
                            Path(selectedRect),
                            with: .color(.primary.opacity(0.8)),
                            lineWidth: 2
                        )
                    }
                }

                // MARK: - X-axis labels

                let desiredLabelCount: Int

                switch dailyTotals.count {
                case ...7:
                    desiredLabelCount = dailyTotals.count

                case 8...14:
                    desiredLabelCount = 7

                case 15...30:
                    desiredLabelCount = 6

                default:
                    desiredLabelCount = 5
                }

                let labelStride = max(
                    1,
                    Int(
                        ceil(
                            Double(dailyTotals.count)
                                / Double(max(desiredLabelCount, 1))
                        )
                    )
                )

                for (index, day) in dailyTotals.enumerated()
                where index % labelStride == 0 || index == dailyTotals.count - 1 {
                    let centerX = plot.minX
                        + slotWidth * (CGFloat(index) + 0.5)

                    context.draw(
                        Text(
                            day.date,
                            format: .dateTime
                                .month(.abbreviated)
                                .day()
                        )
                        .font(.caption2)
                        .foregroundColor(.secondary),
                        at: CGPoint(
                            x: centerX,
                            y: plot.maxY + 11
                        ),
                        anchor: .center
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        selectDay(
                            at: value.location,
                            size: geometry.size
                        )
                    }
            )
            .accessibilityLabel(
                Text(
                    NSLocalizedString(
                        "Daily insulin usage",
                        comment: "Accessibility label for daily insulin usage chart"
                    )
                )
            )
        }
    }
    private func selectDay(
        at location: CGPoint,
        size: CGSize
    ) {
        guard !dailyTotals.isEmpty else {
            return
        }

        let plotWidth = size.width - leftInset - rightInset

        guard plotWidth > 0,
              location.x >= leftInset,
              location.x <= leftInset + plotWidth
        else {
            return
        }

        let slotWidth = plotWidth / CGFloat(dailyTotals.count)

        let index = Int(
            (location.x - leftInset) / slotWidth
        )

        guard dailyTotals.indices.contains(index) else {
            return
        }

        selectedDay = dailyTotals[index]
    }

}


