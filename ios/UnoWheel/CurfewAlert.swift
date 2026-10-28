import AlarmKit
import OnewheelKit
import SwiftUI
import UserNotifications

/// Gets a curfew warning noticed: an alarm that rings until stopped where
/// AlarmKit allows, a time-sensitive notification otherwise.
@MainActor
final class CurfewAlert {
    var log: (String) -> Void = { _ in }
    private var ringing: UUID?

    func requestPermission() async {
        let notifications = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        if !notifications { log("curfew warnings need notification permission") }
        if #available(iOS 26.1, *), AlarmManager.shared.authorizationState == .notDetermined {
            _ = try? await AlarmManager.shared.requestAuthorization()
        }
    }

    func sound(_ status: Curfew.Status) async {
        log("curfew: \(status.headline), \(status.detail)")
        silence()
        if #available(iOS 26.1, *), AlarmManager.shared.authorizationState == .authorized {
            do {
                try await ring(status)
                return
            } catch {
                log("curfew alarm failed, sending a notification: \(error.localizedDescription)")
            }
        }
        let content = UNMutableNotificationContent()
        content.title = status.headline
        content.body = status.detail
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "curfew", content: content, trigger: nil))
        } catch {
            log("curfew warning failed: \(error.localizedDescription)")
        }
    }

    func silence() {
        guard let id = ringing else { return }
        ringing = nil
        if #available(iOS 26.1, *) {
            try? AlarmManager.shared.stop(id: id)
            try? AlarmManager.shared.cancel(id: id)
        }
    }

    @available(iOS 26.1, *)
    private func ring(_ status: Curfew.Status) async throws {
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: "\(status.headline): \(status.detail)"))
        let attributes = AlarmAttributes<CurfewAlarmMetadata>(presentation: AlarmPresentation(alert: alert), tintColor: .orange)
        let id = UUID()
        ringing = id
        _ = try await AlarmManager.shared.schedule(id: id, configuration: .alarm(schedule: .fixed(.now.addingTimeInterval(1)), attributes: attributes))
    }
}

@available(iOS 26.0, *)
private struct CurfewAlarmMetadata: AlarmMetadata {}

/// One wording for the banner, the alarm and the notification.
extension Curfew.Status {
    var headline: String {
        switch warning {
        case .late: "You'll be late"
        case .leave: "Head home now"
        case nil: "Leave by \(leaveBy.formatted(date: .omitted, time: .shortened))"
        }
    }

    var detail: String {
        "About \(rideMinutes) min to \(home.name ?? "home") · curfew \(deadline.formatted(date: .omitted, time: .shortened))"
    }
}
