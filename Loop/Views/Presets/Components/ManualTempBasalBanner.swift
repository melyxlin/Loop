//
//  ManualTempBasalBanner.swift
//  Loop
//
//  Created by Melissa Lin on 9/6/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
import LoopKit
import SwiftUI

struct ManualTempBasalBanner: View {

    let dose: DoseEntry

    private var durationMinutes: Int {
        Int(round(dose.duration / 60.0))
    }

    private var endTimeText: String {
        DateFormatter.localizedString(
            from: dose.endDate,
            dateStyle: .none,
            timeStyle: .short
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {

            VStack(alignment: .leading, spacing: 3) {

                Text(NSLocalizedString(
                    "Temporary Basal",
                    comment: "Title for an active manually programmed temporary basal"
                ))
                .font(.headline)
                .foregroundStyle(.primary)

                Text(
                    String(
                        format: NSLocalizedString(
                            "%.2f U/hr for %d min · until %@",
                            comment: "Description of an active manually programmed temporary basal"
                        ),
                        dose.unitsPerHour,
                        durationMinutes,
                        endTimeText
                    )
                )
                .font(.subheadline)
                .foregroundStyle(
                    Color(UIColor.label.withAlphaComponent(0.75))
                )
            }

            Spacer()

            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.insulin)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.insulin.opacity(0.10))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}
