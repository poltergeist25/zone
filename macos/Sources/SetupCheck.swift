import Foundation

/// Optional practice gives feedback on the chosen levels without blocking monitoring.
struct SetupCheck {
    private(set) var phase = "lower"
    private var lowerSince: Double?
    private var lastTime: Double?
    var complete: Bool { phase == "done" }
    mutating func reset() { phase = "lower"; lowerSince = nil; lastTime = nil }
    mutating func interrupt() { lowerSince = nil; lastTime = nil }
    mutating func update(score: Double, yellow: Double, red: Double, at now: Double) {
        guard score.isFinite, now.isFinite else { interrupt(); return }
        if let lastTime, now < lastTime || now-lastTime > 0.65 { lowerSince = nil }
        lastTime = now
        if phase == "lower" {
            if score >= red {
                if lowerSince == nil { lowerSince = now }
                if now-lowerSince! >= 0.4 { phase = "return"; lowerSince = nil }
            } else { lowerSince = nil }
        } else if phase == "return", score < yellow { phase = "done" }
    }
}

/// Worker-side admission plus main-thread callback checks keep stopped runs stale.
final class CameraRunToken {
    private let lock = NSLock()
    private var value = 0
    @discardableResult func advance() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func accepts(_ token: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return token == value }
}
