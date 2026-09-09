//
//  AlertsViewModel.swift
//  Loop
//
//  Created by Melissa Lin on 9/9/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

@MainActor
final class AlertsViewModel: ObservableObject {

    @Published private(set) var alerts: [AlertHistoryItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let alertStore: AlertStore?

    init(alertStore: AlertStore?) {
        self.alertStore = alertStore
    }

    var activeAlerts: [AlertHistoryItem] {
        alerts.filter(\.isActive)
    }

    var resolvedAlerts: [AlertHistoryItem] {
        alerts.filter { !$0.isActive }
    }

    func load() async {
        guard let alertStore else {
            alerts = []
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let startDate =
                Calendar.current.date(
                    byAdding: .day,
                    value: -90,
                    to: Date()
                ) ?? Date.distantPast

            let storedAlerts = try await alertStore.lookupAlertHistory(
                since: startDate
            )

            alerts = storedAlerts.map(AlertHistoryItem.init)
        } catch {
            alerts = []
            errorMessage = error.localizedDescription
        }
    }
}
