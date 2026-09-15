import Foundation

/// Pure logic for deciding when to spawn a new ripple ring based on audio level.
/// Extracted from RippleView for testability.
public final class RippleTrigger {
    /// Audio level must cross this threshold (low → high) to trigger a ripple.
    public let threshold: Float = 0.25
    /// Minimum seconds between consecutive ripple triggers.
    public let minInterval: TimeInterval = 0.3
    /// If audio level stays below this for `silenceTimeout`, stop producing ripples.
    public let silenceFloor: Float = 0.1
    public let silenceTimeout: TimeInterval = 1.0

    private var previousLevel: Float = 0
    private var lastTriggerTime: TimeInterval?
    private var silenceSince: TimeInterval?

    public init() {}

    /// Call every frame with the current audio level and timestamp.
    /// Returns true if a new ripple ring should be spawned.
    public func update(level: Float, time: TimeInterval) -> Bool {
        defer { previousLevel = level }

        // Check silence BEFORE clearing silenceSince — if we've been
        // silent long enough, suppress even if level just jumped up
        if let since = silenceSince, (time - since) >= silenceTimeout {
            // Still silent — keep suppressing
            if level < silenceFloor { return false }
            // Level came back but we were in prolonged silence — suppress this frame,
            // clear silence state so NEXT crossing can trigger
            silenceSince = nil
            return false
        }

        // Track silence duration
        if level < silenceFloor {
            if silenceSince == nil { silenceSince = time }
        } else {
            silenceSince = nil
        }

        // Check threshold crossing (low → high)
        let crossed = previousLevel < threshold && level >= threshold
        // Also trigger on sustained loud audio (above threshold) at regular intervals
        let sustained = level >= threshold && (lastTriggerTime.map { time - $0 >= 0.6 } ?? false)
        let satisfiesMinInterval = lastTriggerTime.map { time - $0 >= minInterval } ?? true

        if (crossed || sustained) && satisfiesMinInterval {
            lastTriggerTime = time
            return true
        }

        return false
    }

    public func reset() {
        previousLevel = 0
        lastTriggerTime = nil
        silenceSince = nil
    }
}
