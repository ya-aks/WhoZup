//
//  AlarmTestSection.swift
//  WhoZup
//
//  Minimal demo UI for scheduling a test alarm "N seconds from now" so the
//  AlarmKit scheduling/alerting/snooze mechanism built for issue #2 can be
//  exercised on a device or simulator. Not a polished feature UI — that's
//  the job of later issues building the real alarm-setup flow.
//

import SwiftUI

struct AlarmTestSection: View {
    let alarmScheduler: AlarmScheduler
    @ObservedObject var alarmStatusRecorder: AlarmStatusRecorder

    @State private var secondsFromNow: Double = 10
    @State private var statusMessage: String?
    @State private var scheduledAlarmID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(value: $secondsFromNow, in: 5...300, step: 5) {
                Text("Fire in \(Int(secondsFromNow))s")
            }

            Button("Schedule Test Alarm") {
                Task { await scheduleTestAlarm() }
            }

            Button("Cancel Test Alarm", role: .destructive) {
                cancelTestAlarm()
            }
            .disabled(scheduledAlarmID == nil)

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let lastResult = alarmStatusRecorder.lastResult {
                Text("Last action: \(String(describing: lastResult.action.kind)) → \(String(describing: lastResult.status))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func scheduleTestAlarm() async {
        do {
            guard try await alarmScheduler.ensureAuthorized() else {
                statusMessage = "Alarm permission denied — enable it in Settings."
                return
            }

            let id = UUID()
            let fireDate = Date().addingTimeInterval(secondsFromNow)
            alarmStatusRecorder.registerScheduled(id: id, scheduledTime: fireDate)
            try await alarmScheduler.scheduleAlarm(id: id, date: fireDate, label: "Test Alarm")
            scheduledAlarmID = id
            statusMessage = "Scheduled for \(fireDate.formatted(date: .omitted, time: .standard))."
        } catch {
            statusMessage = "Failed to schedule: \(error.localizedDescription)"
        }
    }

    private func cancelTestAlarm() {
        guard let id = scheduledAlarmID else { return }
        // Unregister first so the cancellation isn't misread as a dismiss.
        alarmStatusRecorder.unregister(id: id)
        do {
            try alarmScheduler.cancelAlarm(id: id)
            statusMessage = "Cancelled."
        } catch {
            statusMessage = "Failed to cancel: \(error.localizedDescription)"
        }
        scheduledAlarmID = nil
    }
}

#Preview {
    List {
        AlarmTestSection(
            alarmScheduler: AlarmScheduler(),
            alarmStatusRecorder: AlarmStatusRecorder()
        )
    }
}
