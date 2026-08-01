//
//  PhoneCountry.swift
//  WhoZup
//
//  Country dial codes for the phone sign-in flow, plus a searchable picker.
//  The E.164 number handed to Firebase is `dialCode + nationalDigits`.
//

import SwiftUI

struct PhoneCountry: Identifiable, Hashable {
    let name: String
    let flag: String
    let dialCode: String   // includes leading "+", e.g. "+91"
    let digits: Int        // expected national number length

    var id: String { flag + dialCode }

    /// Default for new sessions — the userbase is in India.
    static let `default` = all.first { $0.dialCode == "+91" } ?? all[0]

    /// Curated list, most-likely markets first. Lengths are the common national
    /// number length; countries with truly variable lengths use the typical one.
    static let all: [PhoneCountry] = [
        .init(name: "India", flag: "🇮🇳", dialCode: "+91", digits: 10),
        .init(name: "United States", flag: "🇺🇸", dialCode: "+1", digits: 10),
        .init(name: "United Kingdom", flag: "🇬🇧", dialCode: "+44", digits: 10),
        .init(name: "Canada", flag: "🇨🇦", dialCode: "+1", digits: 10),
        .init(name: "United Arab Emirates", flag: "🇦🇪", dialCode: "+971", digits: 9),
        .init(name: "Australia", flag: "🇦🇺", dialCode: "+61", digits: 9),
        .init(name: "Singapore", flag: "🇸🇬", dialCode: "+65", digits: 8),
        .init(name: "Saudi Arabia", flag: "🇸🇦", dialCode: "+966", digits: 9),
        .init(name: "Pakistan", flag: "🇵🇰", dialCode: "+92", digits: 10),
        .init(name: "Bangladesh", flag: "🇧🇩", dialCode: "+880", digits: 10),
        .init(name: "Nepal", flag: "🇳🇵", dialCode: "+977", digits: 10),
        .init(name: "Sri Lanka", flag: "🇱🇰", dialCode: "+94", digits: 9),
        .init(name: "Germany", flag: "🇩🇪", dialCode: "+49", digits: 10),
        .init(name: "France", flag: "🇫🇷", dialCode: "+33", digits: 9),
        .init(name: "Netherlands", flag: "🇳🇱", dialCode: "+31", digits: 9),
        .init(name: "Ireland", flag: "🇮🇪", dialCode: "+353", digits: 9),
        .init(name: "Spain", flag: "🇪🇸", dialCode: "+34", digits: 9),
        .init(name: "Italy", flag: "🇮🇹", dialCode: "+39", digits: 10),
        .init(name: "Nigeria", flag: "🇳🇬", dialCode: "+234", digits: 10),
        .init(name: "South Africa", flag: "🇿🇦", dialCode: "+27", digits: 9),
        .init(name: "Kenya", flag: "🇰🇪", dialCode: "+254", digits: 9),
        .init(name: "Egypt", flag: "🇪🇬", dialCode: "+20", digits: 10),
        .init(name: "Indonesia", flag: "🇮🇩", dialCode: "+62", digits: 10),
        .init(name: "Malaysia", flag: "🇲🇾", dialCode: "+60", digits: 9),
        .init(name: "Philippines", flag: "🇵🇭", dialCode: "+63", digits: 10),
        .init(name: "Japan", flag: "🇯🇵", dialCode: "+81", digits: 10),
        .init(name: "China", flag: "🇨🇳", dialCode: "+86", digits: 11),
        .init(name: "Brazil", flag: "🇧🇷", dialCode: "+55", digits: 11),
        .init(name: "Mexico", flag: "🇲🇽", dialCode: "+52", digits: 10),
        .init(name: "New Zealand", flag: "🇳🇿", dialCode: "+64", digits: 9),
        .init(name: "Qatar", flag: "🇶🇦", dialCode: "+974", digits: 8),
        .init(name: "Kuwait", flag: "🇰🇼", dialCode: "+965", digits: 8),
        .init(name: "Oman", flag: "🇴🇲", dialCode: "+968", digits: 8),
        .init(name: "Bahrain", flag: "🇧🇭", dialCode: "+973", digits: 8),
    ]

    /// A placeholder like "00000 00000" or "000 000 0000" sized to `digits`.
    var placeholder: String {
        PhoneCountry.group(String(repeating: "0", count: digits))
    }

    /// Groups digits for readable display: 10 → "00000 00000", others space every 3.
    static func group(_ digits: String) -> String {
        if digits.count == 10 {
            let mid = digits.index(digits.startIndex, offsetBy: 5)
            return digits[..<mid] + " " + digits[mid...]
        }
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && i % 3 == 0 { out += " " }
            out.append(c)
        }
        return out
    }
}

/// Searchable country picker presented as a sheet.
struct CountryPickerSheet: View {
    @Binding var selection: PhoneCountry
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [PhoneCountry] {
        guard !query.isEmpty else { return PhoneCountry.all }
        let q = query.lowercased()
        return PhoneCountry.all.filter {
            $0.name.lowercased().contains(q) || $0.dialCode.contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List(results) { country in
                Button {
                    selection = country
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(country.flag).font(.system(size: 22))
                        Text(country.name).foregroundStyle(RT.ink)
                        Spacer()
                        Text(country.dialCode).foregroundStyle(RT.inkMuted)
                        if country.id == selection.id {
                            Image(systemName: "checkmark").foregroundStyle(Color(hex: "#3f6fa3"))
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search country or code")
            .navigationTitle("Choose country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
