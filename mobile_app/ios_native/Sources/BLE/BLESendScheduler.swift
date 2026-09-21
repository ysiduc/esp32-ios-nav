//
//  BLESendScheduler.swift
//  Pure scheduling policy for BLE navigation packets:
//  deduplication, rate limiting (5Hz), flow control backpressure, and latest-value coalescing.
//

import CoreBluetooth
import Foundation

public enum BLESendAction: Equatable, Sendable {
    case send(Data, CBCharacteristicWriteType)
    case suppressedDuplicate
    case queuedRateLimited
    case queuedBackpressure
}

public enum BLETransportEventAction: Equatable, Sendable {
    case flush(Data, CBCharacteristicWriteType)
    case armTimer(delay: TimeInterval)
    case idle
}

/// Pure BLE send scheduling policy engine.
@MainActor
public final class BLESendScheduler {

    public var minSendInterval: TimeInterval
    public var lastSentTime: Date?
    public var lastSentData: Data?
    public var lastSentManeuver: ManeuverType?

    public var isTransportReady: Bool = true
    public var inFlightWithResponseWrite: Bool = false

    /// At most one newest pending packet is coalesced while transport is blocked or rate-limited.
    public private(set) var pendingPacket: (data: Data, writeType: CBCharacteristicWriteType, progress: NavigationProgress)?

    // Diagnostics
    public var packetsGenerated: Int = 0
    public var writesPerformed: Int = 0
    public var duplicatesSuppressed: Int = 0
    public var packetsCoalesced: Int = 0

    public init(minSendInterval: TimeInterval = 0.2) { // 5 Hz cap
        self.minSendInterval = minSendInterval
    }

    /// Reset state (e.g. on disconnect or session stop).
    public func reset() {
        lastSentTime = nil
        lastSentData = nil
        lastSentManeuver = nil
        isTransportReady = true
        inFlightWithResponseWrite = false
        pendingPacket = nil
    }

    /// Evaluate whether a navigation progress update should be sent immediately or coalesced.
    public func schedule(
        progress: NavigationProgress,
        writeType: CBCharacteristicWriteType,
        canSendWithoutResponse: Bool,
        now: Date = Date()
    ) -> BLESendAction {
        packetsGenerated += 1
        let packetData = BLEPacket.serialize(progress: progress)

        // 1. Check urgent change: maneuver change, arrival, or stop bypasses duplicate suppression
        let isUrgent = (lastSentManeuver != progress.maneuver) || (progress.maneuver == .arrive)

        // 2. Duplicate suppression (unless urgent)
        if !isUrgent, let last = lastSentData, last == packetData {
            duplicatesSuppressed += 1
            return .suppressedDuplicate
        }

        // 3. Flow control readiness check
        if writeType == .withoutResponse {
            self.isTransportReady = canSendWithoutResponse
            if !canSendWithoutResponse {
                queuePending(data: packetData, writeType: writeType, progress: progress)
                return .queuedBackpressure
            }
        } else if writeType == .withResponse {
            if inFlightWithResponseWrite {
                queuePending(data: packetData, writeType: writeType, progress: progress)
                return .queuedBackpressure
            }
        }

        // 4. Rate-limiting check (unless urgent arrival or maneuver change)
        if !isUrgent, let lastTime = lastSentTime, now.timeIntervalSince(lastTime) < minSendInterval {
            queuePending(data: packetData, writeType: writeType, progress: progress)
            return .queuedRateLimited
        }

        // 5. Send immediately
        recordSent(data: packetData, progress: progress, writeType: writeType, now: now)
        return .send(packetData, writeType)
    }

    /// Transport signaled readiness to send without response.
    public func transportBecameReady(now: Date = Date()) -> (Data, CBCharacteristicWriteType)? {
        isTransportReady = true
        return flushPendingIfEligible(now: now)
    }

    /// Evaluates the action when transport signals ready for write-without-response.
    public func handleTransportBecameReady(now: Date = Date()) -> BLETransportEventAction {
        if let (data, writeType) = transportBecameReady(now: now) {
            return .flush(data, writeType)
        } else if let delay = nextEligibleFlushDelay(now: now) {
            return .armTimer(delay: delay)
        }
        return .idle
    }

    /// Peripheral acknowledged previous .withResponse write.
    public func withResponseWriteCompleted(now: Date = Date()) -> (Data, CBCharacteristicWriteType)? {
        inFlightWithResponseWrite = false
        return flushPendingIfEligible(now: now)
    }

    /// Evaluates the action when peripheral acknowledges a write-with-response.
    public func handleWithResponseWriteCompleted(now: Date = Date()) -> BLETransportEventAction {
        if let (data, writeType) = withResponseWriteCompleted(now: now) {
            return .flush(data, writeType)
        } else if let delay = nextEligibleFlushDelay(now: now) {
            return .armTimer(delay: delay)
        }
        return .idle
    }

    /// Timer tick or flush when rate-limit interval expires.
    public func rateLimitTimerFired(now: Date = Date()) -> (Data, CBCharacteristicWriteType)? {
        return flushPendingIfEligible(now: now)
    }

    /// Returns the remaining time-interval before a pending rate-limited packet becomes eligible
    /// to flush. Returns nil when there is no pending packet or when the packet is blocked by
    /// flow-control (not rate-limit) — the caller should not schedule a rate-limit timer then.
    public func nextEligibleFlushDelay(now: Date = Date()) -> TimeInterval? {
        guard let pending = pendingPacket else { return nil }

        // If blocked by flow-control (not just rate-limit), the transport events handle flushing.
        if pending.writeType == .withoutResponse && !isTransportReady { return nil }
        if pending.writeType == .withResponse && inFlightWithResponseWrite { return nil }

        guard let lastTime = lastSentTime else { return 0 }
        let elapsed = now.timeIntervalSince(lastTime)
        let remaining = minSendInterval - elapsed
        return remaining > 0 ? remaining : nil
    }

    // MARK: - Private Helpers

    private func queuePending(data: Data, writeType: CBCharacteristicWriteType, progress: NavigationProgress) {
        if pendingPacket != nil {
            packetsCoalesced += 1
        }
        pendingPacket = (data, writeType, progress)
    }

    private func recordSent(data: Data, progress: NavigationProgress, writeType: CBCharacteristicWriteType, now: Date) {
        lastSentTime = now
        lastSentData = data
        lastSentManeuver = progress.maneuver
        writesPerformed += 1
        if writeType == .withResponse {
            inFlightWithResponseWrite = true
        }
        pendingPacket = nil
    }

    private func flushPendingIfEligible(now: Date) -> (Data, CBCharacteristicWriteType)? {
        guard let pending = pendingPacket else { return nil }

        if pending.writeType == .withoutResponse && !isTransportReady {
            return nil
        }
        if pending.writeType == .withResponse && inFlightWithResponseWrite {
            return nil
        }

        let isUrgent = (lastSentManeuver != pending.progress.maneuver) || (pending.progress.maneuver == .arrive)
        if !isUrgent, let lastTime = lastSentTime, now.timeIntervalSince(lastTime) < minSendInterval {
            return nil
        }

        recordSent(data: pending.data, progress: pending.progress, writeType: pending.writeType, now: now)
        return (pending.data, pending.writeType)
    }
}
