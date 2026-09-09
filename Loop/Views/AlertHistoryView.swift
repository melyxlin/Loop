//
//  AlertHistoryView.swift
//  Loop
//
//  Created by Melissa Lin on 9/9/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

struct AlertHistoryView: View {
    private enum AlertDateSection: String, CaseIterable, Identifiable {
        case today = "Today"
        case yesterday = "Yesterday"
        case earlier = "Earlier"

        var id: String { rawValue }
    }
    
    @State private var selectedDate: Date?
    @State private var showingDatePicker = false
    @State private var selectedCategory: AlertCategory = .all
    @StateObject private var viewModel: AlertsViewModel

    init(alertStore: AlertStore?) {
        _viewModel = StateObject(
            wrappedValue: AlertsViewModel(alertStore: alertStore)
        )
    }
    
    private var displayedAlerts: [AlertHistoryItem] {
        viewModel.alerts.filter { alert in

            let matchesDate: Bool

            if let selectedDate {
                matchesDate = Calendar.current.isDate(
                    alert.issuedDate,
                    inSameDayAs: selectedDate
                )
            } else {
                matchesDate = true
            }

            let matchesCategory =
                selectedCategory == .all ||
                alert.category == selectedCategory

            return matchesDate && matchesCategory
        }
    }

    var body: some View {
        List {
            if viewModel.isLoading && displayedAlerts.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "Unable to Load Alerts",
                            systemImage: "exclamationmark.triangle.fill"
                        )

                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(
                header: Text("History").textCase(nil)
            ) {
                if viewModel.alerts.isEmpty && !viewModel.isLoading {
                    Section {
                        Text("No alert history")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(AlertDateSection.allCases) { section in
                        let sectionAlerts = alerts(in: section)

                        if !sectionAlerts.isEmpty {
                            Section(
                                header: Text(section.rawValue).textCase(nil)
                            ) {
                                ForEach(sectionAlerts) { alert in
                                    alertRow(alert)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Alert History")
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingDatePicker = true
                } label: {
                    Image(systemName: "calendar")
                }
                .accessibilityLabel("Filter by date")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(AlertCategory.allCases) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            if selectedCategory == category {
                                Label(
                                    category.rawValue,
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(category.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(
                        systemName:
                            selectedCategory == .all
                                ? "line.3.horizontal.decrease.circle"
                                : "line.3.horizontal.decrease.circle.fill"
                    )
                }
                .accessibilityLabel("Filter alerts")
            }

            if selectedDate != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        selectedDate = nil
                    }
                }
            }
        }
        .sheet(isPresented: $showingDatePicker) {
            NavigationStack {
                VStack {
                    DatePicker(
                        "Select Date",
                        selection: Binding(
                            get: {
                                selectedDate ?? Date()
                            },
                            set: {
                                selectedDate = $0
                            }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .padding()

                    Spacer()
                }
                .navigationTitle("Filter by Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showingDatePicker = false
                        }
                    }

                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showingDatePicker = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func alertRow(
        _ alert: AlertHistoryItem
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {

            Image(systemName: iconName(for: alert))
                .foregroundStyle(
                    iconColor(for: alert)
                )
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {

                Text(alert.title)
                    .font(.body)

                if let body = alert.body,
                   !body.isEmpty
                {
                    Text(body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text(
                    Calendar.current.isDateInToday(alert.issuedDate) ||
                    Calendar.current.isDateInYesterday(alert.issuedDate)
                        ? alert.issuedDate.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                        : alert.issuedDate.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                #if DEBUG
                Text(
                    "\(alert.managerIdentifier) / \(alert.alertIdentifier)"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                #endif
            }
        }
        .padding(.vertical, 2)
    }

    private func iconName(
        for alert: AlertHistoryItem
    ) -> String {
        switch alert.interruptionLevel {
        case .critical:
            return "exclamationmark.octagon.fill"

        case .timeSensitive:
            return "exclamationmark.triangle.fill"

        case .active:
            return "bell.fill"
        }
    }

    private func iconColor(
        for alert: AlertHistoryItem
    ) -> Color {
        switch alert.interruptionLevel {
        case .critical:
            return .red

        case .timeSensitive:
            return .orange

        case .active:
            return .secondary
        }
    }
    private func alerts(
        in section: AlertDateSection
    ) -> [AlertHistoryItem] {
        let calendar = Calendar.current

        return displayedAlerts.filter { alert in
            switch section {
            case .today:
                return calendar.isDateInToday(alert.issuedDate)

            case .yesterday:
                return calendar.isDateInYesterday(alert.issuedDate)

            case .earlier:
                return !calendar.isDateInToday(alert.issuedDate) &&
                       !calendar.isDateInYesterday(alert.issuedDate)
            }
        }
    }
}
