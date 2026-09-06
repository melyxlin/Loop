//
//  ActivePresetBanner.swift
//  Loop
//
//  Created by Cameron Ingham on 8/7/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import LoopKit
import SwiftUI

struct ActivePresetBanner: View {
    
    @Environment(\.temporaryPresetsManager) private var temporaryPresetsManager
    
    let override: TemporaryScheduleOverride
    
    var symbol: Text? {
        switch override.context {
        case .preMeal:
            return Text(Image("Pre-Meal-symbol"))
        case .preset(let preset):
            guard let symbol = preset.symbol else {
                return nil
            }
            
            switch symbol.symbolType {
            case .emoji:
                return Text(symbol.value)
            case .systemImage:
                return Text(Image(systemName: symbol.value))
            case .image:
                return Text(Image(symbol.value))
            }
        case .activity(let activity):
            guard let symbol = activity.preset.symbol else {
                return nil
            }
            
            switch symbol.symbolType {
            case .emoji:
                return Text(symbol.value)
            case .systemImage:
                return Text(Image(systemName: symbol.value))
            case .image:
                return Text(Image(symbol.value))
            }
        case .custom:
            return nil
        }
    }

    var titleText: Text {
        Text(override.createPreset().name)
    }
    
    var accessibilityIdentifier: String {
        switch override.context {
        case .preMeal:
            "text_PreMealPresetCellTitle"
        case .preset:
            "text_CustomPresetCellTitle"
        case .activity:
            "text_ActivityPresetCellTitle"
        case .custom:
            "text_OneTimePresetCellTitle"
        }
    }
    
    @ViewBuilder
    var title: some View {
        Group {
            if let symbol {
                symbol + Text(" ") + titleText
            } else {
                titleText
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
    
    @ViewBuilder
    var subtitle: some View {
        if override.isActive() {
            if let preset = temporaryPresetsManager.selectablePresets.first(where: { $0.id == override.presetId }), case .preMeal(_) = preset {
                Text(NSLocalizedString("on until carbs added", comment: "The format for the description of a premeal preset end date"))
                    .accessibilityIdentifier("text_PresetActiveOn")
            } else {
                switch override.duration {
                case .finite:
                    let endTimeText = DateFormatter.localizedString(from: override.activeInterval.end, dateStyle: .none, timeStyle: .short)
                    Text(String(format: NSLocalizedString("on until %@", comment: "The format for the description of a finite custom preset end date"), endTimeText))
                        .accessibilityIdentifier("text_PresetActiveOn")
                case .indefinite:
                    Text(NSLocalizedString("on until turned off", comment: "The format for the description of an indefinite custom preset end date"))
                        .accessibilityIdentifier("text_PresetActiveOn")
                }
            }
        } else {
            let startTimeText = DateFormatter.localizedString(from: override.startDate, dateStyle: .none, timeStyle: .short)
            Text(String(format: NSLocalizedString("starting at %@", comment: "The format for the description of a custom preset start date"), startTimeText))
        }
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                title
                    .font(.headline)
                    .foregroundStyle(.primary)

                subtitle
                    .font(.subheadline)
                    .foregroundStyle(
                        Color(UIColor.label.withAlphaComponent(0.75))
                    )
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.presets.opacity(0.10))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}
