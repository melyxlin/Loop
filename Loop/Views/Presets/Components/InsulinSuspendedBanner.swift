//
//  InsulinSuspendedBanner.swift
//  Loop
//
//  Created by Melissa Lin on 9/6/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
import SwiftUI

struct InsulinSuspendedBanner: View {

    let resuming: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    resuming
                        ? NSLocalizedString(
                            "Resuming Insulin",
                            comment: "Title while insulin delivery is being resumed"
                        )
                        : NSLocalizedString(
                            "Insulin Suspended",
                            comment: "Title while insulin delivery is suspended"
                        )
                )
                .font(.headline)
                .foregroundStyle(.primary)

                Text(
                    resuming
                        ? NSLocalizedString(
                            "Restoring basal delivery…",
                            comment: "Subtitle while insulin delivery is being resumed"
                        )
                        : NSLocalizedString(
                            "Tap to Resume",
                            comment: "Subtitle for suspended insulin delivery"
                        )
                )
                .font(.subheadline)
                .foregroundStyle(
                    Color(UIColor.label.withAlphaComponent(0.75))
                )
            }

            Spacer()

            if resuming {
                ProgressView()
            } else {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.insulin)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.insulin.opacity(0.10))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("text_InsulinTapToResume")
    }
}
