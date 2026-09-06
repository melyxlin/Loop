//
//  NoActiveAdjustmentBanner.swift
//  Loop
//
//  Created by Melissa Lin on 9/6/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
import SwiftUI

struct NoActiveAdjustmentBanner: View {
    let profileName: String?
    
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

    var body: some View {
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

            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}
