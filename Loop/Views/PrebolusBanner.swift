//
//  PrebolusBanner.swift
//  Loop
//
//  Created by Melissa Lin on 9/18/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

struct PrebolusBanner: View {
    let endDate: Date?
    let isComplete: Bool
    let onStop: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isComplete ? "Prebolus Complete" : "Prebolus")
                    .font(.headline.bold())

                if !isComplete, let endDate {
                    Text(
                        timerInterval: Date()...endDate,
                        countsDown: true
                    )
                    .font(.subheadline.monospacedDigit())
                }
            }

            Spacer()

            if !isComplete {
                Button("Stop") {
                    onStop()
                }
                .font(.headline)
            }
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
