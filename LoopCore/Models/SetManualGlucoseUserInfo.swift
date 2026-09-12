//
//  SetManualGlucoseUserInfo.swift
//  LoopCore
//

import Foundation

public struct SetManualGlucoseUserInfo {

    public let valueInMgDL: Double
    public let date: Date
    public let syncIdentifier: String

    public init(
        valueInMgDL: Double,
        date: Date,
        syncIdentifier: String
    ) {
        self.valueInMgDL = valueInMgDL
        self.date = date
        self.syncIdentifier = syncIdentifier
    }
}

extension SetManualGlucoseUserInfo: RawRepresentable {

    public typealias RawValue = [String: Any]

    public static let version = 1
    public static let name = "SetManualGlucoseUserInfo"

    public init?(rawValue: RawValue) {
        guard
            rawValue["v"] as? Int == Self.version,
            rawValue["name"] as? String == Self.name,
            let valueInMgDL = rawValue["gv"] as? Double,
            let date = rawValue["date"] as? Date,
            let syncIdentifier = rawValue["si"] as? String
        else {
            return nil
        }

        self.valueInMgDL = valueInMgDL
        self.date = date
        self.syncIdentifier = syncIdentifier
    }

    public var rawValue: RawValue {
        [
            "v": Self.version,
            "name": Self.name,
            "gv": valueInMgDL,
            "date": date,
            "si": syncIdentifier
        ]
    }
}
