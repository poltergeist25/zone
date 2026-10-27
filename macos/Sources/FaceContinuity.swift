import Foundation
import CoreGraphics

/// Loss direction inferred from geometry, never an identity or posture claim.
enum FaceLossReason: Equatable {
    case unknown, bottom, side, ambiguous, cameraStale
}

struct FaceCandidate {
    let box: CGRect
    /// Ephemeral, scale-independent landmark ratios. Do not persist as identity data.
    let signature: [Double]
    /// Vision's current head turn, in radians; never persisted as identity data.
    var yaw:Double? = nil
    /// Set only from a usable observation in the calibrated green band.
    var returnAnchorEligible: Bool = false
}

struct FaceSelection {
    let index: Int?
    let loss: FaceLossReason
}

/// Conservative single-subject association in Vision's normalized bottom-left space.
/// A session stays attached to its first subject until reset. Geometry cannot prove
/// identity when two faces overlap with indistinguishable proportions.
struct FaceContinuity {
    private(set) var selectedBox: CGRect?
    private(set) var lastDecision="initial"
    private var anchorBox: CGRect?
    private var seatedReturnBox: CGRect?
    private var seatedSamples: [(box:CGRect,at:Double)] = []
    private var signature: [Double] = []
    private var signatureYaw:Double?
    private var recentBoxes: [(box: CGRect, at: Double)] = []
    private var selectedAt: Double?
    private var processedAt: Double?
    private var inferredLoss: FaceLossReason = .unknown
    private var unresolvedAmbiguity = false
    private var needsReacquisition = false

    mutating func reset() { self = FaceContinuity() }

    mutating func select(_ candidates: [FaceCandidate], at now: Double) -> FaceSelection {
        guard now.isFinite, processedAt.map({ now >= $0 }) ?? true else {
            lastDecision="stale timestamp"
            return FaceSelection(index: nil, loss: .cameraStale)
        }
        processedAt = now
        let valid = candidates.indices.filter { Self.valid(candidates[$0]) }
        lastDecision=valid.isEmpty ? "no usable face boxes":"position or scale mismatch"
        guard let last = selectedBox else {
            return acquire(candidates, indices: valid, at: now)
        }

        let matches: [(Int, Double)] = valid.compactMap { index in
            let item = candidates[index]
            guard let score = association(item, last: last) else { return nil }
            return (index, score)
        }.sorted { $0.1 < $1.1 }

        if let best = matches.first {
            // Two plausible subjects are not permission to pick whichever is larger.
            if matches.count > 1 && matches[1].1 - best.1 < 0.24 {
                lastDecision="ambiguous subjects"
                seatedSamples.removeAll(keepingCapacity:true)
                unresolvedAmbiguity = true;needsReacquisition = true
                return FaceSelection(index: nil, loss: .ambiguous)
            }
            // A unique compatible match resolves a crossing. The hard geometry
            // gates still apply, and CameraModel requires stable reacquisition;
            // a soft ranking cost must never become a permanent recovery lock.
            accept(candidates[best.0], at: now)
            lastDecision="matched subject"
            // A selected partial face may have no usable landmarks. Supply its
            // direction so the caller need not discard positive exit evidence.
            return FaceSelection(index: best.0, loss: directionalLoss(at: now))
        }

        needsReacquisition=true;seatedSamples.removeAll(keepingCapacity:true)
        if inferredLoss == .unknown { inferredLoss = directionalLoss(at: now) }
        // A positively observed bottom/side exit stays latched until the same
        // geometric track is reacquired or explicitly reset. A visitor cannot clear it.
        if inferredLoss != .unknown { return FaceSelection(index: nil, loss: inferredLoss) }
        return FaceSelection(index: nil, loss: unresolvedAmbiguity ? .ambiguous : .unknown)
    }

    private mutating func acquire(_ candidates: [FaceCandidate], indices: [Int], at now: Double) -> FaceSelection {
        let ranked: [(Int, Double)] = indices.compactMap { index in
            let b = candidates[index].box
            // A partial first detection must not freeze a small/clipped box as
            // the session's subject and then reject the complete returning face.
            guard !candidates[index].signature.isEmpty else{return nil}
            // A background or edge face must not silently become the user.
            guard b.width >= 0.075, b.height >= 0.10,
                  abs(b.midX - 0.5) <= 0.30, b.midY >= 0.15, b.midY <= 0.90 else { return nil }
            let centrality = max(0, 1 - abs(b.midX - 0.5) / 0.4)
            let foreground = min(1, sqrt(b.width * b.height) / 0.35)
            return (index, centrality * 0.65 + foreground * 0.35)
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first else {lastDecision="no complete initial face";return FaceSelection(index: nil, loss: .unknown)}
        guard ranked.count == 1 || best.1 - ranked[1].1 >= 0.16 else {
            lastDecision="ambiguous initial subjects"
            return FaceSelection(index: nil, loss: .ambiguous)
        }
        accept(candidates[best.0], at: now)
        lastDecision="acquired subject"
        return FaceSelection(index: best.0, loss: .unknown)
    }

    private mutating func association(_ item: FaceCandidate, last: CGRect) -> Double? {
        let b = item.box
        let widthRatio = Double(b.width / last.width)
        let heightRatio = Double(b.height / last.height)
        let localScaleValid=(0.55...1.70).contains(widthRatio) && (0.55...1.70).contains(heightRatio)
        var sig = Self.signatureDistance(signature, item.signature)
        // A head turn foreshortens eye spacing. Compare a pose-corrected pair
        // as well as the original ratios instead of treating that change as a
        // different person. Vertical proportions and every spatial/ambiguity
        // gate remain in force; missing/extreme yaw cannot enable this path.
        if let held=Self.facingSignature(signature,yaw:signatureYaw),
           let current=Self.facingSignature(item.signature,yaw:item.yaw),
           let adjusted=Self.signatureDistance(held,current) {
            sig=min(sig ?? .infinity,adjusted)
        }
        guard signature.isEmpty || sig != nil else {lastDecision="incomplete returning landmarks";return nil}
        guard sig.map({ $0 <= 0.22 }) ?? true else {lastDecision="landmark proportions mismatch";return nil}
        let dx = Double(abs(b.midX - last.midX))
        let dy = Double(abs(b.midY - last.midY))
        // Time does not make a distant stranger eligible. Vertical movement can
        // be larger than lateral movement because slouching is the measured action.
        let xGate = min(0.18, max(0.065, Double(last.width) * 0.65))
        let yGate = min(0.24, max(0.10, Double(last.height) * 0.85))
        let signatureCost=(sig ?? 0)*1.2
        var match:Double?
        if localScaleValid && dx <= xGate && dy <= yGate {
            let scale=abs(log(widthRatio))+abs(log(heightRatio))
            match=hypot(dx/xGate,dy/yGate)*0.55+scale*0.18+signatureCost
        }
        if needsReacquisition || inferredLoss == .bottom || inferredLoss == .side {
            // Vision can lose a turned/clipped face before seeing a side-edge
            // box. Any loss can recover at the seated anchor, under the same
            // proportions, scale, narrow corridor and ambiguity checks. This
            // never widens a search toward arbitrary visitors over time.
            for anchor in [anchorBox,seatedReturnBox].compactMap({$0}) {
                let adx = Double(abs(b.midX - anchor.midX))
                let aw = Double(b.width / anchor.width), ah = Double(b.height / anchor.height)
                let inReturnHeight = inferredLoss == .bottom
                    ? b.midY <= anchor.midY + anchor.height * 0.35
                    : abs(b.midY - anchor.midY) <= anchor.height * 0.55
                if adx <= min(0.13, max(0.06, Double(anchor.width) * 0.45)),
                   inReturnHeight,
                   (0.65...1.55).contains(aw), (0.65...1.55).contains(ah) {
                    let anchorScale=abs(log(aw))+abs(log(ah))
                    match=min(match ?? .infinity,0.35+adx*2+anchorScale*0.18+signatureCost)
                }
            }
        }
        return match
    }

    private mutating func accept(_ item: FaceCandidate, at now: Double) {
        recentBoxes.append((item.box, now))
        recentBoxes.removeAll { now - $0.at > 1.0 }
        if recentBoxes.count > 8 { recentBoxes.removeFirst(recentBoxes.count - 8) }
        selectedBox = item.box
        selectedAt = now
        if anchorBox == nil { anchorBox = item.box }
        rememberSeatedReturn(item,at:now)
        // Hold the first valid proportions rather than adapting toward a visitor.
        if signature.isEmpty && !item.signature.isEmpty {signature=item.signature;signatureYaw=item.yaw}
        inferredLoss = .unknown
        unresolvedAmbiguity = false;needsReacquisition = false
    }

    private mutating func rememberSeatedReturn(_ item:FaceCandidate,at now:Double) {
        let b=item.box
        guard item.returnAnchorEligible,!item.signature.isEmpty,
              b.minX>0.08,b.maxX<0.92,b.minY>0.12,b.maxY<0.98,
              abs(b.midX-0.5)<=0.30 else {
            seatedSamples.removeAll(keepingCapacity:true);return
        }
        if let last=seatedSamples.last,now-last.at>0.75 {
            seatedSamples.removeAll(keepingCapacity:true)
        }
        seatedSamples.append((b,now))
        seatedSamples.removeAll{now-$0.at>1.6}
        if seatedSamples.count>6 {seatedSamples.removeFirst(seatedSamples.count-6)}
        guard seatedSamples.count>=3,let first=seatedSamples.first,now-first.at>=0.6,
              seatedSamples.allSatisfy({sample in
                  abs(sample.box.midX-b.midX)<=min(0.04,b.width*0.15) &&
                  abs(sample.box.midY-b.midY)<=min(0.05,b.height*0.20) &&
                  (0.90...1.10).contains(sample.box.width/b.width) &&
                  (0.90...1.10).contains(sample.box.height/b.height)
              }) else{return}
        // Retain the original return anchor too. Slouch/edge/unknown frames may
        // never move this extra corridor, and signature/ambiguity gates are shared.
        seatedReturnBox=b
    }

    private func directionalLoss(at now: Double) -> FaceLossReason {
        guard let last = selectedBox, let lastAt = selectedAt,
              now - lastAt <= 1.0 else { return .unknown }
        let recent = recentBoxes.filter { lastAt - $0.at <= 1.0 }
        guard recent.count >= 2, let earliest = recent.first,
              lastAt > earliest.at else { return .unknown }
        let previous = recent[recent.count - 2].box
        let dx = last.midX - earliest.box.midX
        let dy = last.minY - earliest.box.minY
        // A diagonal exit through a side is a side exit, even near the bottom.
        if (last.minX <= 0.06 && dx <= -0.025) || (last.maxX >= 0.94 && dx >= 0.025) {
            return .side
        }
        // Accumulated gentle movement matters: a slow slouch may advance only
        // one hundredth of the frame on each inference. Require an overall fall,
        // no material upward reversal and no dominant lateral trajectory.
        let lastStepY = last.minY - previous.minY
        if last.minY <= 0.12, dy <= -0.015, lastStepY <= 0.002,
           last.minX > 0.08, last.maxX < 0.92,
           abs(dx) <= max(0.035, abs(dy) * 0.70) {
            return .bottom
        }
        return .unknown
    }

    private static func valid(_ item: FaceCandidate) -> Bool {
        let b = item.box
        return !b.isNull && !b.isInfinite && b.width.isFinite && b.height.isFinite &&
            b.origin.x.isFinite && b.origin.y.isFinite && b.width > 0 && b.height > 0 &&
            b.minX >= -0.05 && b.maxX <= 1.05 && b.minY >= -0.05 && b.maxY <= 1.05 &&
            item.signature.allSatisfy { $0.isFinite }
    }

    private static func signatureDistance(_ a: [Double], _ b: [Double]) -> Double? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        let squared = zip(a, b).map { x, y in
            let relative = (x - y) / max(0.05, max(abs(x), abs(y)))
            return relative * relative
        }
        return sqrt(squared.reduce(0, +) / Double(squared.count))
    }

    private static func facingSignature(_ values:[Double],yaw:Double?)->[Double]? {
        guard values.count==2,let yaw,yaw.isFinite,abs(yaw)<=1.05 else{return nil}
        return [values[0]/cos(yaw),values[1]]
    }
}
