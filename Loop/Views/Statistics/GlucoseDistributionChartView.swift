//
//  GlucoseDistributionChartView.swift
//  Loop
//
//  Created by Melissa Lin on 9/8/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//

import SwiftUI
import LoopUI

struct GlucoseDistributionChartView: View {
    @State private var selectedPoint: HourlyGlucoseDistribution?
    
    let distribution: [HourlyGlucoseDistribution]
    
    private let leftInset: CGFloat = 34
    private let bottomInset: CGFloat = 18
    private let topInset: CGFloat = 6
    private let rightInset: CGFloat = 6
    private let bucketDuration: TimeInterval = .minutes(30)

    private func fraction(
        _ band: GlucoseBand,
        in point: HourlyGlucoseDistribution
    ) -> Double {
        point.fractions?[band] ?? 0
    }
    
    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let plot = CGRect(
                    x: leftInset,
                    y: topInset,
                    width: size.width - leftInset - rightInset,
                    height: size.height - topInset - bottomInset
                )
                
                guard plot.width > 0,
                      plot.height > 0
                else {
                    return
                }
                
                let points = distribution.sorted {
                    $0.timeOfDay < $1.timeOfDay
                }
                
                let segments: [[HourlyGlucoseDistribution]] = {
                    var result: [[HourlyGlucoseDistribution]] = []
                    var current: [HourlyGlucoseDistribution] = []
                    
                    for point in points {
                        if point.fractions != nil {
                            current.append(point)
                        } else if !current.isEmpty {
                            result.append(current)
                            current = []
                        }
                    }
                    
                    if !current.isEmpty {
                        result.append(current)
                    }
                    
                    return result
                }()
                
                guard !points.isEmpty else {
                    return
                }
                
                func x(_ secondsOfDay: TimeInterval) -> CGFloat {
                    plot.minX
                    + CGFloat(secondsOfDay / .hours(24))
                    * plot.width
                }
                
                func y(_ fraction: Double) -> CGFloat {
                    plot.minY
                    + CGFloat(1 - fraction)
                    * plot.height
                }
                
                func cumulativeFraction(
                    through band: GlucoseBand,
                    for point: HourlyGlucoseDistribution
                ) -> Double {
                    GlucoseBand.allCases
                        .filter { $0 <= band }
                        .reduce(0) {
                            $0 + fraction($1, in: point)
                        }
                }
                
                func lowerFraction(
                    for band: GlucoseBand,
                    at point: HourlyGlucoseDistribution
                ) -> Double {
                    GlucoseBand.allCases
                        .filter { $0 < band }
                        .reduce(0) {
                            $0 + fraction($1, in: point)
                        }
                }
                
                func areaPath(
                    for band: GlucoseBand,
                    points: [HourlyGlucoseDistribution]
                ) -> Path {
                    guard let firstPoint = points.first,
                          let lastPoint = points.last
                    else {
                        return Path()
                    }
                    
                    func upperFraction(
                        at point: HourlyGlucoseDistribution
                    ) -> Double {
                        min(
                            1,
                            max(
                                0,
                                cumulativeFraction(
                                    through: band,
                                    for: point
                                )
                            )
                        )
                    }
                    
                    func lowerFractionValue(
                        at point: HourlyGlucoseDistribution
                    ) -> Double {
                        min(
                            1,
                            max(
                                0,
                                lowerFraction(
                                    for: band,
                                    at: point
                                )
                            )
                        )
                    }
                    
                    let halfBucket = bucketDuration / 2
                    
                    let startTime = max(
                        0,
                        firstPoint.timeOfDay - halfBucket
                    )
                    
                    let endTime = min(
                        .hours(24),
                        lastPoint.timeOfDay + halfBucket
                    )
                    
                    let upperPoints =
                    [
                        CGPoint(
                            x: x(startTime),
                            y: y(upperFraction(at: firstPoint))
                        )
                    ]
                    + points.map {
                        CGPoint(
                            x: x($0.timeOfDay),
                            y: y(upperFraction(at: $0))
                        )
                    }
                    + [
                        CGPoint(
                            x: x(endTime),
                            y: y(upperFraction(at: lastPoint))
                        )
                    ]
                    
                    let lowerPoints =
                    [
                        CGPoint(
                            x: x(endTime),
                            y: y(lowerFractionValue(at: lastPoint))
                        )
                    ]
                    + points.reversed().map {
                        CGPoint(
                            x: x($0.timeOfDay),
                            y: y(lowerFractionValue(at: $0))
                        )
                    }
                    + [
                        CGPoint(
                            x: x(startTime),
                            y: y(lowerFractionValue(at: firstPoint))
                        )
                    ]
                    
                    var path = Path()
                    
                    path.move(to: upperPoints[0])
                    
                    for point in upperPoints.dropFirst() {
                        path.addLine(to: point)
                    }
                    
                    path.addLine(to: lowerPoints[0])
                    
                    for point in lowerPoints.dropFirst() {
                        path.addLine(to: point)
                    }
                    
                    path.closeSubpath()
                    
                    return path
                }
                // MARK: Y gridlines
                
                for value in [0.0, 0.25, 0.50, 0.75, 1.0] {
                    var grid = Path()
                    
                    grid.move(
                        to: CGPoint(
                            x: plot.minX,
                            y: y(value)
                        )
                    )
                    
                    grid.addLine(
                        to: CGPoint(
                            x: plot.maxX,
                            y: y(value)
                        )
                    )
                    
                    ctx.stroke(
                        grid,
                        with: .color(.gray.opacity(0.25)),
                        lineWidth: 0.5
                    )
                }
                
                // MARK: Distribution areas
                
                for segment in segments {
                    guard segment.count >= 2 else {
                        continue
                    }
                    
                    for band in GlucoseBand.allCases {
                        ctx.fill(
                            areaPath(
                                for: band,
                                points: segment
                            ),
                            with: .color(
                                band.agpColor.opacity(0.85)
                            )
                        )
                    }
                }
                
                // MARK: Y-axis labels
                
                for value in [0.0, 0.25, 0.50, 0.75, 1.0] {
                    ctx.draw(
                        Text("\(Int(value * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary),
                        at: CGPoint(
                            x: plot.minX - 4,
                            y: y(value)
                        ),
                        anchor: .trailing
                    )
                }
                
                // MARK: X-axis labels
                
                for (hour, label) in [
                    (0, "12a"),
                    (6, "6a"),
                    (12, "12p"),
                    (18, "6p"),
                    (24, "12a")
                ] {
                    ctx.draw(
                        Text(label)
                            .font(.caption2)
                            .foregroundColor(.secondary),
                        at: CGPoint(
                            x: plot.minX
                            + CGFloat(Double(hour) / 24)
                            * plot.width,
                            y: plot.maxY + 9
                        ),
                        anchor: .center
                    )
                }
            } // end Canvas

            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                updateSelection(
                                    at: value.location.x,
                                    width: geometry.size.width
                                )
                            }
                            .onEnded { _ in
                                selectedPoint = nil
                            }
                    )
            }

            if let selectedPoint {
                selectionLine(for: selectedPoint)
                selectionOverlay(for: selectedPoint)
            }
        } // end ZStack
        .accessibilityLabel(
            Text(
                NSLocalizedString(
                    "Glucose distribution by time",
                    comment: "Accessibility label for glucose distribution by time chart"
                )
            )
        )
    }
    
    private func updateSelection(
        at locationX: CGFloat,
        width: CGFloat
    ) {
        let plotWidth = width - leftInset - rightInset

        guard plotWidth > 0 else {
            selectedPoint = nil
            return
        }

        let clampedX = min(
            max(locationX, leftInset),
            width - rightInset
        )

        let fractionOfDay =
            Double((clampedX - leftInset) / plotWidth)

        let secondsOfDay =
            fractionOfDay * TimeInterval.hours(24)

        // Find the actual 30-minute bucket under the user's finger,
        // including buckets that contain no usable data.
        guard let nearestPoint = distribution.min(by: {
            abs($0.timeOfDay - secondsOfDay)
                < abs($1.timeOfDay - secondsOfDay)
        }) else {
            selectedPoint = nil
            return
        }

        // Don't jump across a missing-data region to another valid bucket.
        guard nearestPoint.fractions != nil else {
            selectedPoint = nil
            return
        }

        selectedPoint = nearestPoint
    }
    
    @ViewBuilder
    private func selectionOverlay(
        for point: HourlyGlucoseDistribution
    ) -> some View {
        if let fractions = point.fractions {
            VStack(alignment: .leading, spacing: 4) {
                Text(timeRangeLabel(for: point))
                    .font(.caption.weight(.semibold))

                ForEach(GlucoseBand.allCases, id: \.self) { band in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(band.agpColor)
                            .frame(width: 7, height: 7)

                        Text(bandLabel(band))
                            .font(.caption2)

                        Spacer()

                        Text(
                            "\(Int(((fractions[band] ?? 0) * 100).rounded()))%"
                        )
                        .font(.caption2.monospacedDigit())
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                )
                .fill(Color(.secondarySystemGroupedBackground))
            )
            .padding(.horizontal, 44)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 10)
            .allowsHitTesting(false)
        }
    }
    
    private func bandLabel(_ band: GlucoseBand) -> String {
        switch band {
        case .veryLow:
            return "Very Low"
        case .low:
            return "Low"
        case .target:
            return "Target"
        case .high:
            return "High"
        case .veryHigh:
            return "Very High"
        }
    }

    private func timeRangeLabel(
        for point: HourlyGlucoseDistribution
    ) -> String {
        let halfBucket = bucketDuration / 2

        let start =
            point.timeOfDay - halfBucket

        let end =
            point.timeOfDay + halfBucket

        func label(_ seconds: TimeInterval) -> String {
            let totalMinutes =
                Int(seconds / 60)

            let hour =
                (totalMinutes / 60) % 24

            let minute =
                totalMinutes % 60

            let suffix =
                hour < 12 ? "AM" : "PM"

            let displayHour = {
                let h = hour % 12
                return h == 0 ? 12 : h
            }()

            return String(
                format: "%d:%02d %@",
                displayHour,
                minute,
                suffix
            )
        }

        return "\(label(start))–\(label(end))"
    }
    
    @ViewBuilder
    private func selectionLine(
        for point: HourlyGlucoseDistribution
    ) -> some View {
        GeometryReader { geometry in
            let plotWidth =
                geometry.size.width - leftInset - rightInset

            let x =
                leftInset
                + CGFloat(
                    point.timeOfDay / TimeInterval.hours(24)
                ) * plotWidth

            Path { path in
                path.move(
                    to: CGPoint(
                        x: x,
                        y: topInset
                    )
                )

                path.addLine(
                    to: CGPoint(
                        x: x,
                        y: geometry.size.height - bottomInset
                    )
                )
            }
            .stroke(
                Color.primary.opacity(0.7),
                style: StrokeStyle(
                    lineWidth: 1,
                    dash: [3, 3]
                )
            )
        }
        .allowsHitTesting(false)
    }
}



#if DEBUG

#Preview {
    let distribution: [HourlyGlucoseDistribution] = (0..<48).map { index in
        let hour = Double(index) / 2
        let target = 0.65
            + 0.15
            * sin(
                (hour - 4)
                / 24
                * 2
                * .pi
            )

        let high = max(
            0.05,
            0.18
                + 0.08
                * sin(
                    (hour - 10)
                    / 24
                    * 2
                    * .pi
                )
        )

        let veryHigh = 0.06
        let low = 0.07
        let veryLow = max(
            0,
            1 - target - high - veryHigh - low
        )

        return HourlyGlucoseDistribution(
            timeOfDay: (Double(index) + 0.5) * .minutes(30),
            fractions: [
                .veryLow: veryLow,
                .low: low,
                .target: target,
                .high: high,
                .veryHigh: veryHigh
            ]
        )
    }

    return GlucoseDistributionChartView(
        distribution: distribution
    )
    .frame(height: 260)
    .padding()
}

#endif
