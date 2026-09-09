//
//  AlertHistoryItem.swift
//  Loop
//
//  Created by Melissa Lin on 9/9/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

enum AlertCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case glucose = "Glucose"
    case pump = "Pump"
    case cgm = "CGM"
    case loop = "Loop"
    case insulin = "Insulin"
    case system = "System"

    var id: String { rawValue }
}

struct AlertHistoryItem: Identifiable {
    
    let id: UUID

    let managerIdentifier: String
    let alertIdentifier: String

    let title: String
    let body: String?

    let issuedDate: Date
    let acknowledgedDate: Date?
    let retractedDate: Date?

    let interruptionLevel: Alert.InterruptionLevel

    var isActive: Bool {
        retractedDate == nil
    }

    var duration: TimeInterval? {
        guard let retractedDate else {
            return nil
        }

        return retractedDate.timeIntervalSince(issuedDate)
    }
    
    var category: AlertCategory {
        switch managerIdentifier {
        case "GlucoseAlertManager":
            return .glucose

        case "Omni":
            return .pump

        case "Loop":
            switch alertIdentifier {
            case "loopNotLooping":
                return .loop

            case "bluetoothPoweredOff":
                return .system

            default:
                return .loop
            }

        default:
            return .system
        }
    }

    init(storedAlert: StoredAlert) {
        id = storedAlert.syncIdentifier ?? UUID()

        managerIdentifier = storedAlert.managerIdentifier
        alertIdentifier = storedAlert.alertIdentifier

        title = storedAlert.title ?? alertIdentifier
        body = storedAlert.body

        issuedDate = storedAlert.issuedDate
        acknowledgedDate = storedAlert.acknowledgedDate
        retractedDate = storedAlert.retractedDate

        interruptionLevel = storedAlert.interruptionLevel
    }
}
