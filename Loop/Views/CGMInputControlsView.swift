//
//  CGMInputControlsView.swift
//  Loop
//
//  Created by Melissa Lin on 9/7/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
import SwiftUI
import LoopKitUI

struct CGMInputControlsView: View {
    @Environment(\.dismissAction) private var dismiss

    let isPaused: Binding<Bool>
    let showCGMSettings: () -> Void

    var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle(isOn: isPaused) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pause CGM Input")

                            Text("Ignore new CGM glucose readings in Loop without disconnecting your sensor.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityIdentifier("cgmInputControlsPauseToggle")
                } header: {
                    Text("Loop")
                }

                Section {
                    Button(action: showCGMSettings) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("CGM Settings")
                                    .foregroundColor(.primary)

                                Text("View sensor information and settings")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("CGM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
