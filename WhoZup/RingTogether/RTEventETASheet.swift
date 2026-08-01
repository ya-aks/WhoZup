//
//  RTEventETASheet.swift
//  WhoZup
//
//  Created by Antigravity on 01/08/26.
//
//  ETA delay bottom sheet for event "Running Late" responses.
//  Offers quick delay actions (+5m, +15m, +30m, +45m, +1h) and a custom
//  Hours & Minutes selector.
//

import SwiftUI

struct RTEventETASheet: View {
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedMinutes: Int = 15
    @State private var customHours: Int = 0
    @State private var customMinutes: Int = 15
    @State private var isCustom = false

    private let quickOptions: [(label: String, minutes: Int)] = [
        ("+15 min", 15),
        ("+30 min", 30),
        ("+45 min", 45),
    ]

    private var formattedETALabel: String {
        if isCustom {
            var parts: [String] = []
            if customHours > 0 {
                parts.append("\(customHours) hr\(customHours == 1 ? "" : "s")")
            }
            if customMinutes > 0 || customHours == 0 {
                parts.append("\(customMinutes) min\(customMinutes == 1 ? "" : "s")")
            }
            return parts.joined(separator: " ")
        } else {
            if selectedMinutes >= 60 {
                let hrs = selectedMinutes / 60
                let mins = selectedMinutes % 60
                return mins == 0 ? "\(hrs) hr\(hrs == 1 ? "" : "s")" : "\(hrs) hr \(mins) min"
            }
            return "\(selectedMinutes) min"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(RT.cardBorder).frame(width: 40, height: 5).padding(.top, 10)

            Text("Running Late ETA")
                .font(.rtDisplay(22, .bold))
                .foregroundStyle(RT.ink)
                .padding(.top, 16)

            Text("Select your estimated delay so the group knows when to expect you.")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(RT.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 6)

            // Quick action chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(quickOptions, id: \.minutes) { option in
                        let isSelected = !isCustom && selectedMinutes == option.minutes
                        Button {
                            isCustom = false
                            selectedMinutes = option.minutes
                        } label: {
                            Text(option.label)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(isSelected ? .white : RT.ink)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 14).fill(isSelected ? Color(hex: "#9a6410") : RT.card))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Color(hex: "#9a6410") : RT.cardBorder, lineWidth: 1))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            // Custom Hours & Minutes selector toggle
            Toggle(isOn: $isCustom) {
                Text("Custom Delay")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RT.ink)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            if isCustom {
                HStack(spacing: 20) {
                    VStack {
                        Text("Hours")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(RT.inkMuted)
                        Stepper("\(customHours)", value: $customHours, in: 0...12)
                            .labelsHidden()
                            .font(.rtDisplay(18, .bold))
                        Text("\(customHours) hr")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(RT.ink)
                    }

                    VStack {
                        Text("Minutes")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(RT.inkMuted)
                        Stepper("\(customMinutes)", value: $customMinutes, in: 0...59, step: 5)
                            .labelsHidden()
                            .font(.rtDisplay(18, .bold))
                        Text("\(customMinutes) min")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(RT.ink)
                    }
                }
                .padding(.top, 14)
            }

            // Confirm button
            Button {
                onConfirm(formattedETALabel)
                dismiss()
            } label: {
                Text("Set ETA (\(formattedETALabel))")
                    .font(.rtDisplay(16, .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: "#9a6410")))
            }
            .buttonStyle(RTPressStyle())
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(RT.canvas)
        .presentationDetents([.height(isCustom ? 360 : 260)])
        .presentationDragIndicator(.hidden)
    }
}
