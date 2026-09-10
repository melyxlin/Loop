//
//  NoActiveAdjustmentBanner.swift
//  Loop
//
//  Created by Melissa Lin on 9/6/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopAlgorithm

struct NoActiveAdjustmentBanner: View {
    let profileName: String?
    let basalRate: Double?
    let carbRatio: Double?
    let insulinSensitivity: LoopQuantity?
    let glucoseUnit: LoopUnit

    @State private var showingDetails = false
    @State private var sheetContentHeight: Double = 0

    private var profileText: String {
        guard let profileName,
              !profileName.isEmpty
        else {
            return NSLocalizedString(
                "Profile at 100%",
                comment: "Subtitle when no custom therapy profile is active"
            )
        }

        return String(
            format: NSLocalizedString(
                "Profile %@ Activated",
                comment: "Subtitle showing the currently active therapy profile"
            ),
            profileName
        )
    }

    private var detailTitle: String {
        guard let profileName,
              !profileName.isEmpty
        else {
            return NSLocalizedString(
                "Current Profile",
                comment: "Title for current therapy profile details"
            )
        }

        return profileName
    }

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        NSLocalizedString(
                            "No Active Adjustment",
                            comment: "Title when no dosing adjustment is active"
                        )
                    )
                    .font(.headline)
                    .foregroundStyle(.primary)

                    Text(profileText)
                        .font(.subheadline)
                        .foregroundStyle(
                            Color(UIColor.label.withAlphaComponent(0.75))
                        )
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                VStack(spacing: 24) {
                    VStack(spacing: 4) {
                        Text(detailTitle)
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(
                            NSLocalizedString(
                                "Current Therapy Settings",
                                comment: "Subtitle for current profile therapy settings"
                            )
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(spacing: 16) {
                        settingRow(
                            title: NSLocalizedString(
                                "Basal Rate",
                                comment: "Current profile basal rate"
                            ),
                            value: basalRateText
                        )

                        settingRow(
                            title: NSLocalizedString(
                                "Carb Ratio",
                                comment: "Current profile carbohydrate ratio"
                            ),
                            value: carbRatioText
                        )

                        settingRow(
                            title: NSLocalizedString(
                                "Insulin Sensitivity",
                                comment: "Current profile insulin sensitivity"
                            ),
                            value: insulinSensitivityText
                        )
                    }
                    .padding(.horizontal)

                    Button(
                        NSLocalizedString(
                            "Close",
                            comment: "Button to close current profile details"
                        )
                    ) {
                        showingDetails = false
                    }
                    .tint(.accentColor)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("button_close")
                }
                .toolbar(.hidden)
                .padding(.top)
                .padding(16)
                .readContentHeight(to: $sheetContentHeight)
            }
            .sheetDetent(height: sheetContentHeight)
        }
    }

    private func settingRow(
        title: String,
        value: String
    ) -> some View {
        HStack {
            Text(title)

            Spacer()

            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var basalRateText: String {
        guard let basalRate else {
            return "—"
        }

        return String(
            format: "%.2f U/hr",
            basalRate
        )
    }

    private var carbRatioText: String {
        guard let carbRatio else {
            return "—"
        }

        return String(
            format: "1:%.1f g",
            carbRatio
        )
    }

    private var insulinSensitivityText: String {
        guard let insulinSensitivity else {
            return "—"
        }

        let value = insulinSensitivity.doubleValue(for: glucoseUnit)

        if glucoseUnit == .millimolesPerLiter {
            return String(
                format: "%.1f mmol/L/U",
                value
            )
        } else {
            return String(
                format: "%.0f mg/dL/U",
                value
            )
        }
    }

}
