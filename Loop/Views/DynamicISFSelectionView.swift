//
//  DynamicISFSelectionView.swift
//  Loop
//
//  Created by Melissa Lin on 9/7/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
import SwiftUI

struct DynamicISFSelectionView: View {
    @Binding var isDynamicISFEnabled: Bool

    var body: some View {
        List {
            Section {
                Toggle(
                    NSLocalizedString(
                        "Enable Dynamic ISF",
                        comment: "Toggle to enable the Dynamic ISF algorithm experiment"
                    ),
                    isOn: $isDynamicISFEnabled
                )
            }

            Section {
                Text(
                    NSLocalizedString(
                        "Dynamic ISF detects persistent high glucose that is not responding as expected and may adjust correction sensitivity. This is an experimental feature.",
                        comment: "Description of the Dynamic ISF algorithm experiment"
                    )
                )
                .foregroundColor(.secondary)
            }
        }
        .navigationTitle(
            NSLocalizedString(
                "Dynamic ISF",
                comment: "Navigation title for Dynamic ISF experiment settings"
            )
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}
