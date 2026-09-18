//
//  TrioUAMSelectionView.swift
//  Loop
//
//  Created by Melissa Lin on 9/17/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Trio UAM algorithm experiment settings.
//

import SwiftUI

struct TrioUAMSelectionView: View {
    @Binding var isTrioUAMEnabled: Bool

    var body: some View {
        List {
            Section {
                Toggle(
                    NSLocalizedString(
                        "Enable Trio UAM",
                        comment: "Toggle to enable the Trio UAM algorithm experiment"
                    ),
                    isOn: $isTrioUAMEnabled
                )
            }

            Section {
                Text(
                    NSLocalizedString(
                        "Trio UAM uses unannounced meal prediction to recognize glucose behavior that is not adequately explained by known carbohydrates and expected insulin effects.",
                        comment: "Description of the Trio UAM algorithm experiment"
                    )
                )

                Text(
                    NSLocalizedString(
                        "This experiment is currently shadow-only. Enabling it does not change Loop's glucose prediction or insulin delivery.",
                        comment: "Shadow-only warning for the Trio UAM algorithm experiment"
                    )
                )
            }
        }
        .navigationTitle(
            NSLocalizedString(
                "Trio UAM",
                comment: "Navigation title for the Trio UAM algorithm experiment"
            )
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}
