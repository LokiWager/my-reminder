import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

@MainActor
final class MouseMoverService {
    private var timer: Timer?
    private var enabled = false
    private var lastMoveDate = Date.distantPast
    private var displaySleepAssertionID: IOPMAssertionID = 0
    private var hasDisplaySleepAssertion = false

    private var idleThresholdSeconds: TimeInterval = 120
    private var minimumMoveGapSeconds: TimeInterval = 60

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            acquireDisplaySleepAssertion()
            start()
        } else {
            stop()
            releaseDisplaySleepAssertion()
        }
    }

    func setConfiguration(idleThresholdSeconds: TimeInterval, minimumMoveGapSeconds: TimeInterval) {
        self.idleThresholdSeconds = max(1, idleThresholdSeconds)
        self.minimumMoveGapSeconds = max(1, minimumMoveGapSeconds)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard enabled else { return }
        guard idleSeconds() >= idleThresholdSeconds else { return }
        guard Date().timeIntervalSince(lastMoveDate) >= minimumMoveGapSeconds else { return }
        guard let originalPoint = safeCurrentMousePoint() else { return }

        performJiggle(from: originalPoint)
        lastMoveDate = .now
    }

    private func idleSeconds() -> TimeInterval {
        let source = CGEventSourceStateID.hidSystemState
        let events: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel,
            .keyDown, .keyUp, .flagsChanged
        ]

        return events
            .map { CGEventSource.secondsSinceLastEventType(source, eventType: $0) }
            .min() ?? 0
    }

    private func safeCurrentMousePoint() -> CGPoint? {
        let frame = NSScreen.screens
            .map(\.frame)
            .reduce(CGRect.null) { partialResult, frame in
                partialResult.union(frame)
            }
        guard !frame.isNull else {
            return nil
        }

        let p = NSEvent.mouseLocation
        let x = min(max(p.x, frame.minX + 2), frame.maxX - 2)
        let y = min(max(p.y, frame.minY + 2), frame.maxY - 2)
        return CGPoint(x: x, y: y)
    }

    private func performJiggle(from originalPoint: CGPoint) {
        let movedPoint = CGPoint(x: originalPoint.x + 1, y: originalPoint.y)
        guard postMouseMovedEvent(at: movedPoint), postMouseMovedEvent(at: originalPoint) else {
            // Fallback for environments where synthetic HID events are blocked.
            CGWarpMouseCursorPosition(movedPoint)
            CGWarpMouseCursorPosition(originalPoint)
            return
        }
    }

    private func postMouseMovedEvent(at point: CGPoint) -> Bool {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    private func acquireDisplaySleepAssertion() {
        guard !hasDisplaySleepAssertion else { return }

        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StandUpReminder mouse mover is active" as CFString,
            &assertionID
        )

        guard result == kIOReturnSuccess else { return }
        displaySleepAssertionID = assertionID
        hasDisplaySleepAssertion = true
    }

    private func releaseDisplaySleepAssertion() {
        guard hasDisplaySleepAssertion else { return }
        IOPMAssertionRelease(displaySleepAssertionID)
        displaySleepAssertionID = 0
        hasDisplaySleepAssertion = false
    }
}
