//
//  OpenLoopBanner.swift
//  Loop
//
//  Created by Melissa Lin on 9/11/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

struct OpenLoopBanner: View {
    let canResume: Bool
    let resume: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    NSLocalizedString(
                        "Open Loop",
                        comment: "Title shown when automatic dosing is disabled"
                    )
                )
                .font(.headline)
                .foregroundStyle(.primary)

                Text(
                    NSLocalizedString(
                        "Automatic dosing is paused",
                        comment: "Description shown when automatic dosing is disabled"
                    )
                )
                .font(.subheadline)
                .foregroundStyle(
                    Color(UIColor.label.withAlphaComponent(0.75))
                )
            }

            Spacer()

            Button(
                NSLocalizedString(
                    "Resume",
                    comment: "Button to resume Closed Loop"
                )
            ) {
                resume()
            }
            .buttonStyle(.bordered)
            .font(.subheadline.weight(.semibold))
            .disabled(!canResume)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}
