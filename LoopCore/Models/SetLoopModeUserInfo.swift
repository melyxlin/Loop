//
//  SetLoopModeUserInfo.swift
//  Loop
//
//  Created by Melissa Lin on 9/11/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

public struct SetLoopModeUserInfo {
    public let dosingEnabled: Bool

    public init(dosingEnabled: Bool) {
        self.dosingEnabled = dosingEnabled
    }
}

extension SetLoopModeUserInfo: RawRepresentable {
    public typealias RawValue = [String: Any]

    public static let version = 1
    public static let name = "SetLoopModeUserInfo"

    public init?(rawValue: RawValue) {
        guard
            rawValue["v"] as? Int == Self.version,
            rawValue["name"] as? String == Self.name,
            let dosingEnabled = rawValue["de"] as? Bool
        else {
            return nil
        }

        self.dosingEnabled = dosingEnabled
    }

    public var rawValue: RawValue {
        [
            "v": Self.version,
            "name": Self.name,
            "de": dosingEnabled
        ]
    }
}
