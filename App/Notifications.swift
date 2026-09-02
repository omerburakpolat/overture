import AppKit
import SwiftData
import UserNotifications
import OvertureKit

/// System notifications for agent moments (spec 02 §8.1): posted only when
/// Overture is not frontmost; "View card" focuses the card, "Reply…" sends
/// straight to the session (the coordinator respawns-resumes if needed).
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let categoryID = "overture.card"
    private let onView: (UUID) -> Void
    private let onReply: (UUID, String) -> Void

    init(onView: @escaping (UUID) -> Void,
         onReply: @escaping (UUID, String) -> Void) {
        self.onView = onView
        self.onReply = onReply
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: "reply", title: "Reply…", options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message the agent")
        let view = UNNotificationAction(
            identifier: "view", title: "View Card", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID,
                                   actions: [view, reply],
                                   intentIdentifiers: []),
        ])
        Task {
            _ = try? await center.requestAuthorization(
                options: [.alert, .sound, .badge])
        }
    }

    func post(_ notice: SessionCoordinator.Notice) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.cardTitle
        content.body = notice.body
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["cardID": notice.cardID.uuidString]
        switch notice.kind {
        case .needsInput:
            content.subtitle = "Agent needs your input"
            content.interruptionLevel = .timeSensitive
        case .agentFinished:
            content.subtitle = "Agent finished"
        case .agentErrored:
            content.subtitle = "Run failed"
        case .testsFailed:
            content.subtitle = "Tests failed"
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let idString = info["cardID"] as? String,
              let cardID = UUID(uuidString: idString) else { return }
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            if action == "reply", let text, !text.isEmpty {
                onReply(cardID, text)
            } else {
                onView(cardID)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

extension AppState {
    /// Wires notifications after init (needs self for the callbacks).
    func enableNotifications() {
        let manager = NotificationManager(
            onView: { [weak self] cardID in self?.focusCard(cardID) },
            onReply: { [weak self] cardID, text in
                guard let self,
                      let card = self.card(cardID) else { return }
                Task { await self.coordinator.sendChat(text, to: card) }
            })
        notificationManager = manager
        coordinator.onNotice = { [weak manager] notice in
            manager?.post(notice)
        }
    }

    /// Brings the app forward, navigates to the card's board, opens it.
    func focusCard(_ cardID: UUID) {
        NSApp.activate()
        guard let card = card(cardID), let project = card.project else {
            return
        }
        if navigationPath.isEmpty {
            navigationPath.append(project.id)
        }
        pendingCardFocus = cardID
    }

    func card(_ id: UUID) -> Card? {
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? services.container.mainContext.fetch(descriptor).first
    }
}
