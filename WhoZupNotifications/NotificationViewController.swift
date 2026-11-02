//
//  NotificationViewController.swift
//  WhoZupNotificationContent
//
//  A custom notification content extension for event RSVPs. When an event push
//  is long-pressed / expanded, iOS renders this view instead of the plain
//  banner, giving a 2-on-top / 3-on-bottom button grid:
//
//        [  Coming  ] [ Can't make it ]
//        [ +15m ] [ +30m ] [ +45m ]
//
//  Tapping a button writes the RSVP straight to Firestore from the extension
//  process — no app launch. That requires the signed-in Firebase session to be
//  shared with this extension via a Keychain access group (see
//  `SharedAuth.accessGroup` and the target's entitlements), and this target must
//  include `GoogleService-Info.plist`.
//

import UIKit
import UserNotifications
import UserNotificationsUI
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

// MARK: - Shared config

enum SharedAuth {
    /// Keychain access group shared between the app and this extension so the
    /// extension sees the same signed-in Firebase user. Must match the
    /// `keychain-access-groups` entitlement on BOTH targets.
    ///
    /// `<AppIdentifierPrefix (Team ID)>.Akshay.WhoZup.shared`.
    static let accessGroup = "7H4B5RGM9Y.Akshay.WhoZup.shared"
}

/// Idempotent Firebase setup for the extension process. Mirrors the app's
/// `FirebaseBootstrap`, plus opting Auth into the shared Keychain group so
/// `Auth.auth().currentUser` is the user signed in on the app side.
enum ExtensionFirebase {
    static func ensureConfigured() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        try? Auth.auth().useUserAccessGroup(SharedAuth.accessGroup)
    }
}

// MARK: - Response model

private enum RSVP {
    case coming
    case cantMakeIt
    case late(String)  // eta, e.g. "+15"

    var storageKey: String {
        switch self {
        case .coming: return "coming"
        case .cantMakeIt: return "cant_make_it"
        case .late: return "running_late"
        }
    }

    /// Matches `GroupRepository.recordEventResponse` so a notification RSVP and
    /// an in-app RSVP write exactly the same shape.
    var detail: String {
        switch self {
        case .coming: return "coming"
        case .cantMakeIt: return "can't make it"
        case .late(let eta): return "ETA \(eta)"
        }
    }

    var verb: String {
        switch self {
        case .coming: return "is coming"
        case .cantMakeIt: return "can't make it"
        case .late(let eta): return "is running late (\(eta))"
        }
    }

    var eta: String? {
        if case .late(let eta) = self { return eta }
        return nil
    }

    var confirmation: String {
        switch self {
        case .coming: return "You're coming ✓"
        case .cantMakeIt: return "Marked can't make it ✓"
        case .late(let eta): return "Running late \(eta) ✓"
        }
    }
}

// MARK: - Palette
//
// Light/dark adaptive so the extension blends with the notification (clear
// background) in both themes, using the SAME day/night values as Android's
// values/ + values-night/ colors so the design matches across platforms.

private enum Palette {
    private static func hex(_ v: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255,
            alpha: 1
        )
    }
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? hex(dark) : hex(light) }
    }

    static let accent = dyn(0xC57A22, 0xE8A659)
    static let comingFg = dyn(0x1F6A8C, 0x7FC6E6)
    static let comingBg = dyn(0xE0EFF5, 0x1B3A48)
    static let cantFg = dyn(0xA83F2E, 0xEBA593)
    static let cantBg = dyn(0xF7E0DA, 0x46231B)
    static let lateFg = dyn(0x9A6410, 0xE6B863)
    static let lateBg = dyn(0xFBEED6, 0x3E3115)
}

// MARK: - View controller

class NotificationViewController: UIViewController, UNNotificationContentExtension {

    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let confirmationLabel = UILabel()

    private var primaryRow: UIStackView!
    private var lateRow: UIStackView!
    private var rootStack: UIStackView!

    private var groupId: String?
    private var isSubmitting = false

    override func viewDidLoad() {
        super.viewDidLoad()
        ExtensionFirebase.ensureConfigured()
        view.backgroundColor = .clear   // blend with the notification material
        buildUI()
    }

    // Called by the system with the notification to render.
    func didReceive(_ notification: UNNotification) {
        let info = notification.request.content.userInfo
        groupId = info["groupId"] as? String

        let title = (info["title"] as? String)
            ?? notification.request.content.title
        let body = (info["body"] as? String)
            ?? notification.request.content.body

        titleLabel.text = title.isEmpty ? "Event" : title
        bodyLabel.text = body.isEmpty ? "How are you arriving?" : body

        // Without a shared signed-in session (or without a groupId) we can't
        // write the response here; steer the user to open the app instead.
        let canRespond = groupId != nil && Auth.auth().currentUser != nil
        if !canRespond {
            eyebrowLabel.text = "OPEN WHOZUP TO RESPOND"
            setControlsEnabled(false)
        }
    }

    // MARK: UI

    private func buildUI() {
        eyebrowLabel.text = "EVENT · RSVP"
        eyebrowLabel.font = .systemFont(ofSize: 11, weight: .heavy)
        eyebrowLabel.textColor = Palette.accent
        eyebrowLabel.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.font = .systemFont(ofSize: 19, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1

        bodyLabel.font = .systemFont(ofSize: 14, weight: .regular)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 2

        confirmationLabel.font = .systemFont(ofSize: 16, weight: .bold)
        confirmationLabel.textColor = Palette.comingFg
        confirmationLabel.textAlignment = .center
        confirmationLabel.isHidden = true

        // Top row: the two decisive responses.
        let comingBtn = makeButton(
            title: "Coming", fg: Palette.comingFg, bg: Palette.comingBg
        ) { [weak self] in self?.submit(.coming) }
        let cantBtn = makeButton(
            title: "Can't make it", fg: Palette.cantFg, bg: Palette.cantBg
        ) { [weak self] in self?.submit(.cantMakeIt) }
        primaryRow = UIStackView(arrangedSubviews: [comingBtn, cantBtn])
        primaryRow.axis = .horizontal
        primaryRow.distribution = .fillEqually
        primaryRow.spacing = 10

        // Bottom row: the three "running late" ETA options.
        let late15 = makeButton(title: "+15m", fg: Palette.lateFg, bg: Palette.lateBg) { [weak self] in self?.submit(.late("+15")) }
        let late30 = makeButton(title: "+30m", fg: Palette.lateFg, bg: Palette.lateBg) { [weak self] in self?.submit(.late("+30")) }
        let late45 = makeButton(title: "+45m", fg: Palette.lateFg, bg: Palette.lateBg) { [weak self] in self?.submit(.late("+45")) }
        lateRow = UIStackView(arrangedSubviews: [late15, late30, late45])
        lateRow.axis = .horizontal
        lateRow.distribution = .fillEqually
        lateRow.spacing = 8

        let lateCaption = UILabel()
        lateCaption.text = "Running late?"
        lateCaption.font = .systemFont(ofSize: 12, weight: .semibold)
        lateCaption.textColor = .secondaryLabel

        rootStack = UIStackView(arrangedSubviews: [
            eyebrowLabel, titleLabel, bodyLabel,
            primaryRow, lateCaption, lateRow, confirmationLabel,
        ])
        rootStack.axis = .vertical
        rootStack.spacing = 8
        rootStack.setCustomSpacing(14, after: bodyLabel)
        rootStack.setCustomSpacing(12, after: primaryRow)
        rootStack.setCustomSpacing(6, after: lateCaption)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
    }

    private func makeButton(
        title: String, fg: UIColor, bg: UIColor, action: @escaping () -> Void
    ) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = fg
        config.baseBackgroundColor = bg
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 15, weight: .bold)
            return out
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    private func setControlsEnabled(_ enabled: Bool) {
        [primaryRow, lateRow].forEach { row in
            row?.arrangedSubviews.forEach { ($0 as? UIButton)?.isEnabled = enabled }
        }
    }

    // MARK: Submit

    private func submit(_ rsvp: RSVP) {
        guard !isSubmitting, let groupId else { return }
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else {
            eyebrowLabel.text = "OPEN WHOZUP TO RESPOND"
            return
        }
        isSubmitting = true
        setControlsEnabled(false)

        let db = Firestore.firestore()
        var payload: [String: Any] = [
            "status": rsvp.storageKey,
            "detail": rsvp.detail,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let eta = rsvp.eta { payload["eta"] = eta }

        db.collection("groups").document(groupId)
            .collection("statuses").document(uid)
            .setData(payload) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.isSubmitting = false
                    self.setControlsEnabled(true)
                    self.eyebrowLabel.text = "COULDN'T SEND — TRY IN APP"
                    NSLog("RSVP write failed: \(error.localizedDescription)")
                    return
                }
                self.writeActivity(db: db, groupId: groupId, uid: uid, verb: rsvp.verb)
                self.showConfirmation(rsvp.confirmation)
            }
    }

    private func writeActivity(db: Firestore, groupId: String, uid: String, verb: String) {
        db.collection("users").document(uid).getDocument { snap, _ in
            let name = snap?.data()?["displayName"] as? String ?? "Someone"
            db.collection("groups").document(groupId)
                .collection("activity")
                .addDocument(data: [
                    "actorUid": uid,
                    "kind": "response",
                    "message": "\(name) \(verb)",
                    "timestamp": FieldValue.serverTimestamp(),
                ])
        }
    }

    private func showConfirmation(_ text: String) {
        confirmationLabel.text = text
        UIView.animate(withDuration: 0.2) {
            self.primaryRow.isHidden = true
            self.lateRow.isHidden = true
            self.confirmationLabel.isHidden = false
        }
        // Collapse the expanded notification shortly after confirming.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.extensionContext?.dismissNotificationContentExtension()
        }
    }
}
