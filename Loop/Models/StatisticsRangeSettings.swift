//
//  StatisticsRangeSettings.swift
//  Loop
//
//  Created by Melissa Lin on 8/24/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

enum StatisticsRangeSettings {
    static let targetLowKey = "statisticsTargetLow"
    static let targetHighKey = "statisticsTargetHigh"
    static let veryHighKey = "statisticsVeryHigh"
    
    static let veryLow: Double = 54
    
    static let defaultTargetLow: Double = 70
    static let defaultTargetHigh: Double = 180
    static let defaultVeryHigh: Double = 250
    
    static var targetLow: Double {
           (UserDefaults.standard.object(forKey: targetLowKey) as? NSNumber)?.doubleValue
               ?? defaultTargetLow
       }

       static var targetHigh: Double {
           (UserDefaults.standard.object(forKey: targetHighKey) as? NSNumber)?.doubleValue
               ?? defaultTargetHigh
       }

       static var veryHigh: Double {
           (UserDefaults.standard.object(forKey: veryHighKey) as? NSNumber)?.doubleValue
               ?? defaultVeryHigh
       }
}
