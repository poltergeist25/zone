import Foundation
import CoreGraphics

/// Top-down image positions; transient live geometry never leaves this Mac.
struct FaceHeightLandmarks:Codable,Equatable {
    var eyesY:Double
    var noseY:Double
    var chinY:Double
    var valid:Bool {
        [eyesY,noseY,chinY].allSatisfy{$0.isFinite && (0...1).contains($0)} &&
        noseY-eyesY>0.003 && chinY>noseY
    }
}

/// Frozen during Set height. At the default levels, nose/eye crossings of
/// referenceLineY are exactly the yellow/red boundaries, including head tilt.
struct LandmarkHeightCalibration:Codable,Equatable {
    var landmarks:FaceHeightLandmarks
    var referenceLineY:Double
    var valid:Bool {landmarks.valid && referenceLineY.isFinite && referenceLineY>landmarks.noseY && referenceLineY<=1}
    static func capture(_ landmarks:FaceHeightLandmarks)->Self? {
        guard landmarks.valid else{return nil}
        // Place the fixed line one-third of the way from nose to chin.
        // This personal green buffer is independent of the eye-to-nose gap.
        let line=landmarks.noseY+(landmarks.chinY-landmarks.noseY)/3
        let calibration=Self(landmarks:landmarks,referenceLineY:line)
        return calibration.valid ? calibration:nil
    }
    func deviation(_ live:FaceHeightLandmarks)->Double? {
        guard valid,live.valid else{return nil}
        let position=(live.noseY-referenceLineY)/(live.noseY-live.eyesY)
        let neutral=(landmarks.noseY-referenceLineY)/(landmarks.noseY-landmarks.eyesY)
        // Below nose crossing, interpolate from the captured comfortable pose.
        // Between nose and eyes, interpolate their actual crossings of the line.
        let value=position<0 ? PostureEngine.defaultYellow*max(0,(position-neutral)/(-neutral)):
            PostureEngine.defaultYellow+position*(PostureEngine.defaultRed-PostureEngine.defaultYellow)
        return value.isFinite ? max(0,value):nil
    }
}

struct PoseFeatures {
    var headX: Double, headY: Double, slope: Double, scale: Double, centerX: Double, centerY: Double
    var heightLandmarks:FaceHeightLandmarks?
    var landmarkHeight:LandmarkHeightCalibration?
    var values: [Double] { [headX, headY, slope, scale, centerX, centerY] }
    var valid: Bool { values.allSatisfy(\.isFinite) && scale > 0.08 && (heightLandmarks?.valid ?? true) && (landmarkHeight?.valid ?? true) }
    init(_ values: [Double]) {
        headX = values[0]; headY = values[1]; slope = values[2]; scale = values[3]; centerX = values[4]; centerY = values[5]
    }
    static func extract(nose: CGPoint, left: CGPoint, right: CGPoint, confidence: Double, aspect: Double) -> PoseFeatures? {
        guard confidence >= 0.4, aspect.isFinite, aspect > 0,
              [nose, left, right].allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return nil }
        // Vision coordinates start at the bottom left; use top-down image geometry.
        let cx = Double(left.x + right.x) / 2 * aspect, cy = 1 - Double(left.y + right.y) / 2
        let dx = Double(left.x - right.x) * aspect, dy = Double(right.y - left.y)
        let width = hypot(dx, dy)
        guard width > 0.08, abs(dx) > 0.06 else { return nil }
        return PoseFeatures([(Double(nose.x) * aspect - cx) / width, (1 - Double(nose.y) - cy) / width, dy / abs(dx), width, cx, cy])
    }
}

struct ZoneResult {
    var state: String
    var score: Double? = nil
    var progress: Double = 0
    var alert: Bool = false
    var calibrated: Bool = false
    var unstable: Bool = false
    var haloSeverity: Double = 0
    var alertProgress: Double = 0
}

// The focus card follows the latched alert; smoke color/depth follows continuous severity.
enum ZoneAppearance:Equatable {
    case hidden,greenHalo,yellowHalo,redFocus
    static func resolve(_ result:ZoneResult,monitoring:Bool,paused:Bool,tracking:Bool)->ZoneAppearance {
        guard monitoring,!paused,tracking,result.score?.isFinite == true,
              ["inside","yellow","outside","alert"].contains(result.state) else{return .hidden}
        if result.state == "inside" {return .hidden}
        if result.alert{return .redFocus}
        return .yellowHalo
    }
}

final class PostureEngine {
    static let defaultYellow=0.45
    static let defaultRed=0.85
    var delay: Double = 2
    var sensitivity: Double = 1
    var yellowThreshold: Double = 0.6
    var redThreshold: Double = 1
    static func validThresholds(yellow: Double, red: Double) -> Bool {
        yellow.isFinite && red.isFinite && yellow >= 0.15 && red >= yellow * 1.25 && red >= yellow + 0.15
    }
    private(set) var baseline: PoseFeatures?
    private(set) var calibrating = false
    private(set) var paused = false
    private(set) var alert = false
    private var samples: [(Double, PoseFeatures)] = []
    private var lastTime: Double?
    private var score: Double?
    private var outSince: Double?
    func clearTiming() { outSince = nil; alert = false; score = nil }
    func reset() { baseline = nil; calibrating = false; paused = false; samples = []; lastTime = nil; clearTiming() }
    func calibrate() { reset(); calibrating = true }
    func pause() { paused = true; lastTime = nil; clearTiming() }
    func resume() { paused = false; lastTime = nil; clearTiming() }
    @discardableResult
    func restoreValidated(baseline:PoseFeatures,yellow:Double,red:Double,delay:Double)->Bool {
        guard baseline.valid,Self.validThresholds(yellow:yellow,red:red),delay.isFinite,(1...5).contains(delay)else{return false}
        reset();self.baseline=baseline;yellowThreshold=yellow;redThreshold=red;self.delay=delay;sensitivity=1
        return true
    }
    static func haloSeverity(score: Double, yellow: Double, red: Double) -> Double {
        guard score.isFinite, validThresholds(yellow: yellow, red: red) else { return 0 }
        let value = max(0, score)
        if value <= yellow { return value / yellow }
        return min(3, 1 + (value - yellow) / (red - yellow))
    }
    func update(_ pose: PoseFeatures?, at now: Double) -> ZoneResult {
        if paused { return ZoneResult(state: "paused") }
        guard now.isFinite else { clearTiming(); samples = []; return ZoneResult(state: "lost") }
        let dt = lastTime.map { now - $0 } ?? 0
        if dt > 0.65 || dt < 0 { clearTiming(); samples = [] }
        lastTime = now
        guard let pose, pose.valid else { clearTiming(); samples = []; return ZoneResult(state: "lost") }
        if calibrating {
            samples.append((now, pose))
            let means = (0..<6).map { index in samples.reduce(0) { $0 + $1.1.values[index] } / Double(samples.count) }
            let limits = [0.025, 0.025, 0.025, means[3] * 0.025, means[3] * 0.025, means[3] * 0.025]
            let unstable = [3, 5].contains { index in sqrt(samples.reduce(0) { $0 + pow($1.1.values[index] - means[index], 2) } / Double(samples.count)) > limits[index] }
            let observedLandmarks=samples.compactMap{$0.1.heightLandmarks}
            let anatomicalUnstable:Bool
            if observedLandmarks.isEmpty {anatomicalUnstable=false}
            else if observedLandmarks.count != samples.count {anatomicalUnstable=true}
            else {
                let coordinates:[KeyPath<FaceHeightLandmarks,Double>]=[\.eyesY,\.noseY,\.chinY]
                anatomicalUnstable=coordinates.contains {coordinate in
                    let mean=observedLandmarks.reduce(0){$0+$1[keyPath:coordinate]}/Double(observedLandmarks.count)
                    let variance=observedLandmarks.reduce(0){$0+pow($1[keyPath:coordinate]-mean,2)}/Double(observedLandmarks.count)
                    return sqrt(variance)>means[3]*0.025
                }
            }
            if unstable || anatomicalUnstable { samples = [(now, pose)]; return ZoneResult(state: "calibrating", unstable: true) }
            let elapsed = now - samples[0].0
            if elapsed >= 3 && samples.count >= 20 {
                var captured=PoseFeatures(means)
                let landmarks=samples.compactMap{$0.1.heightLandmarks}
                if landmarks.count==samples.count {
                    let count=Double(landmarks.count)
                    let averaged=FaceHeightLandmarks(eyesY:landmarks.reduce(0){$0+$1.eyesY}/count,
                        noseY:landmarks.reduce(0){$0+$1.noseY}/count,chinY:landmarks.reduce(0){$0+$1.chinY}/count)
                    guard let personal=LandmarkHeightCalibration.capture(averaged) else {
                        samples=[];return ZoneResult(state:"calibrating",unstable:true)
                    }
                    captured.landmarkHeight=personal
                }
                baseline=captured;calibrating=false;samples=[];score=0
                return ZoneResult(state: "inside", score: 0, calibrated: true)
            }
            return ZoneResult(state: "calibrating", progress: min(0.99, elapsed / 3))
        }
        guard let baseline else { return ZoneResult(state: "ready") }
        let raw = Self.deviation(pose, from: baseline) * sensitivity
        guard raw.isFinite else{clearTiming();return ZoneResult(state:"lost")}
        let alpha = dt <= 0 || dt > 0.65 ? 1 : 1 - exp(-dt / 0.2)
        // Improvement reaches the renderer on this frame. Only worsening is filtered;
        // otherwise an old high score can keep smoke advancing after recovery.
        score = score.map { raw < $0 ? raw : $0 + alpha * (raw - $0) } ?? raw
        // A valid recovered frame clears immediately, without smoothing lag or a hold timer.
        if raw < redThreshold {
            outSince = nil
            if alert { alert = false; score = raw }
        } else if !alert {
            if score! >= redThreshold {
                if outSince == nil { outSince = now }
                if now - outSince! >= delay { alert = true }
            } else { outSince = nil }
        }
        return ZoneResult(state: alert ? "alert" : score! >= redThreshold ? "outside" : score! >= yellowThreshold ? "yellow" : "inside", score: score, alert: alert, haloSeverity: Self.haloSeverity(score: score!, yellow: yellowThreshold, red: redThreshold), alertProgress: alert ? 1 : outSince.map { min(1,max(0,(now-$0)/max(0.01,delay))) } ?? 0)
    }
    /// Only a positively observed bottom exit may continue an already-red timer.
    /// This is reminder continuity, never a measured posture sample.
    func holdBottomExit(at now:Double)->ZoneResult? {
        guard !paused,baseline != nil,now.isFinite,let previous=lastTime,
              now >= previous,now-previous <= 0.65,let score,score >= redThreshold,
              let outSince else{return nil}
        lastTime=now
        if now-outSince >= delay {alert=true}
        return ZoneResult(state:alert ? "alert":"outside",score:score,alert:alert,
                          haloSeverity:Self.haloSeverity(score:score,yellow:yellowThreshold,red:redThreshold),
                          alertProgress:alert ? 1:min(1,max(0,(now-outSince)/max(0.01,delay))))
    }
    static func deviation(_ p: PoseFeatures, from b: PoseFeatures) -> Double {
        if let calibration=b.landmarkHeight {
            guard let live=p.heightLandmarks,let value=calibration.deviation(live) else{return .nan}
            return value
        }
        // A vertical thermometer: only downward image movement counts. The
        // baseline face width stays fixed, so moving closer cannot rescale a score.
        return max(0, (p.centerY - b.centerY) / (b.scale * 0.22))
    }
}

final class BoundarySampler {
    private var samples: [(Double, PoseFeatures)] = []
    func reset() { samples=[] }
    func add(_ pose: PoseFeatures?, at now: Double, baseline: PoseFeatures) -> (progress: Double, value: Double?) {
        guard let pose, pose.valid else { reset(); return (0,nil) }
        if let last=samples.last, now-last.0 > 0.65 || now < last.0 { reset() }
        samples.append((now,pose))
        let means=(0..<6).map { index in samples.reduce(0) { $0+$1.1.values[index] }/Double(samples.count) }
        let limits=[0.04,0.04,0.04,means[3]*0.04,means[3]*0.04,means[3]*0.04]
        let unstable=[3,5].contains { index in sqrt(samples.reduce(0) { $0+pow($1.1.values[index]-means[index],2) }/Double(samples.count)) > limits[index] }
        if unstable { samples=[(now,pose)]; return (0,nil) }
        let elapsed=now-samples[0].0
        if elapsed >= 2 && samples.count >= 12 { let value=PostureEngine.deviation(PoseFeatures(means),from:baseline); reset(); return (1,value) }
        return (min(0.99,elapsed/2),nil)
    }
}
