//
//  AlarmSchedulerTests.swift
//  WhoZupTests
//
//  Unit tests for the AlarmKit-backed AlarmScheduler. A fake AlarmScheduling
//  stands in for AlarmManager so no real system alarms are scheduled and no
//  authorization prompt appears.
//

import AlarmKit
import XCTest
@testable import WhoZup

@MainActor
final class FakeAlarmManager: AlarmScheduling {
    var authorizationState: AlarmManager.AuthorizationState = .authorized
    var authorizationStateAfterRequest: AlarmManager.AuthorizationState = .authorized

    private(set) var requestAuthorizationCallCount = 0
    private(set) var scheduledIDs: [UUID] = []
    private(set) var stoppedIDs: [UUID] = []
    private(set) var countdownIDs: [UUID] = []
    private(set) var cancelledIDs: [UUID] = []

    // `AlarmKit.Alarm` has no public initializer, so a fake can only ever
    // report an empty system alarm list.
    var alarms: [Alarm] {
        get throws { [] }
    }

    func requestAuthorization() async throws -> AlarmManager.AuthorizationState {
        requestAuthorizationCallCount += 1
        authorizationState = authorizationStateAfterRequest
        return authorizationStateAfterRequest
    }

    func scheduleAlarm(id: UUID, configuration: AlarmManager.AlarmConfiguration<WhoZupAlarmMetadata>) async throws {
        scheduledIDs.append(id)
    }

    func stop(id: UUID) throws { stoppedIDs.append(id) }
    func countdown(id: UUID) throws { countdownIDs.append(id) }
    func cancel(id: UUID) throws { cancelledIDs.append(id) }
}

@MainActor
final class AlarmSchedulerTests: XCTestCase {

    // MARK: Authorization

    func testEnsureAuthorizedWhenAlreadyAuthorizedDoesNotPrompt() async throws {
        let fake = FakeAlarmManager()
        fake.authorizationState = .authorized
        let scheduler = AlarmScheduler(manager: fake)

        let authorized = try await scheduler.ensureAuthorized()

        XCTAssertTrue(authorized)
        XCTAssertEqual(fake.requestAuthorizationCallCount, 0)
    }

    func testEnsureAuthorizedWhenDeniedReturnsFalseWithoutPrompting() async throws {
        let fake = FakeAlarmManager()
        fake.authorizationState = .denied
        let scheduler = AlarmScheduler(manager: fake)

        let authorized = try await scheduler.ensureAuthorized()

        XCTAssertFalse(authorized)
        XCTAssertEqual(fake.requestAuthorizationCallCount, 0)
    }

    func testEnsureAuthorizedWhenNotDeterminedPromptsAndReturnsGrantResult() async throws {
        let fake = FakeAlarmManager()
        fake.authorizationState = .notDetermined
        fake.authorizationStateAfterRequest = .authorized
        let scheduler = AlarmScheduler(manager: fake)

        let authorized = try await scheduler.ensureAuthorized()

        XCTAssertTrue(authorized)
        XCTAssertEqual(fake.requestAuthorizationCallCount, 1)
    }

    // MARK: Scheduling

    func testScheduleAlarmSchedulesWithGivenID() async throws {
        let fake = FakeAlarmManager()
        let scheduler = AlarmScheduler(manager: fake)
        let id = UUID()

        try await scheduler.scheduleAlarm(id: id, date: Date().addingTimeInterval(60))

        XCTAssertEqual(fake.scheduledIDs, [id])
    }

    func testCancelAlarmCancelsWithGivenID() async throws {
        let fake = FakeAlarmManager()
        let scheduler = AlarmScheduler(manager: fake)
        let id = UUID()

        try scheduler.cancelAlarm(id: id)

        XCTAssertEqual(fake.cancelledIDs, [id])
    }

    // MARK: Presentation building

    func testPresentationUsesCountdownBehaviorForSnooze() {
        let presentation = AlarmScheduler.makePresentation(label: "Alarm")

        XCTAssertEqual(presentation.alert.secondaryButtonBehavior, .countdown)
        XCTAssertNotNil(presentation.alert.secondaryButton, "Snooze button should exist")
        XCTAssertNotNil(presentation.countdown, "Snooze countdown presentation should exist")
    }

    func testCountdownDurationUsesSnoozeIntervalAsPostAlert() {
        let duration = AlarmScheduler.makeCountdownDuration(snoozeInterval: 3 * 60)

        XCTAssertEqual(duration.postAlert, 3 * 60)
        XCTAssertNil(duration.preAlert, "No pre-alarm countdown should be configured")
    }
}
