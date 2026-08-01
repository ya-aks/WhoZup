//
//  InviteLink.swift
//  WhoZup
//
//  Parsing and short-term storage for invite deep links.
//
//  A tapped invite link can arrive while the user is signed out, in which case
//  `WhoZupApp` is showing `AuthView` and there is nowhere to present the join
//  confirmation. `PendingInviteStore` lives above that switch, so the code
//  simply waits there until `RTRootView` appears after sign-in and picks it up.
//

import Foundation
import Observation

enum InviteLink {
    /// The Firebase Hosting site that serves the AASA file. Must match the
    /// `applinks:` entry in WhoZup.entitlements.
    static let host = "whozup-725a6.web.app"

    /// Custom URL scheme (registered in Info.plist). Used by the web landing
    /// page's "Open in whoZup" button: a browser won't hand an https Universal
    /// Link back to the app on a same-page tap, but `whozup://join?code=…` opens
    /// the installed app reliably. This is what makes the QR-scan path work.
    static let scheme = "whozup"

    /// Builds the shareable invite URL. `groupName` and `invitedBy` are used
    /// only by the web landing page (the app reads nothing but `code`), so
    /// they're display hints, not trusted input.
    static func url(code: String, groupName: String, invitedBy: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/join"
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "g", value: groupName),
            URLQueryItem(name: "by", value: invitedBy),
        ]
        return components.url!
    }

    /// Extracts an invite code from a tapped link, or nil if this isn't one.
    /// Accepts both `/join?code=ABC123` and `/join/ABC123`.
    static func code(from url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // Custom scheme: whozup://join?code=ABC123  or  whozup://join/ABC123
        if url.scheme?.lowercased() == scheme {
            guard url.host()?.lowercased() == "join" else { return nil }
            let raw = components?.queryItems?.first { $0.name == "code" }?.value
                ?? components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return normalize(raw)
        }

        // Universal Link: https://<host>/join?code=ABC123  or  /join/ABC123
        guard url.host()?.lowercased() == host else { return nil }
        guard let path = components?.path, path == "/join" || path.hasPrefix("/join/") else {
            return nil
        }

        let raw = components?.queryItems?.first { $0.name == "code" }?.value
            ?? String(path.dropFirst("/join/".count))

        return normalize(raw)
    }

    /// Pulls a code out of pasted text, which may be either a bare code or a
    /// whole invite URL — the web landing page stages the bare code on the
    /// clipboard, but a user forwarding an invite copies the full link.
    static func code(fromPastedText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let fromURL = code(from: url) {
            return fromURL
        }
        return normalize(trimmed)
    }

    /// Normalizes a user- or link-supplied code to the alphabet used by
    /// `GroupRepository.makeInviteCode()`. Returns nil if nothing usable remains.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.count >= 4 && cleaned.count <= 12 ? cleaned : nil
    }
}

/// An invite code in `Identifiable` form, so it can drive a `sheet(item:)`.
struct PendingInviteCode: Identifiable {
    let id: String
    init(_ code: String) { id = code }
}

/// Holds an invite code between the moment a link is tapped and the moment
/// there's a signed-in UI able to present the confirmation sheet.
@MainActor
@Observable
final class PendingInviteStore {
    var code: String?

    func set(_ code: String) { self.code = code }
    func clear() { code = nil }
}
