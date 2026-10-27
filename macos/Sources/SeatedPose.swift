import Foundation
import CoreGraphics
import Vision

/// A consistent geometry for seated desk use. Never mixes face and shoulder coordinates.
struct SeatedGeometry {
    /// Box margins bound local propagation. Primary patch support, jaw bounds,
    /// subject association and same-frame band verification are checked separately.
    static func permitsLocalTracking(face:CGRect)->Bool {
        face.minX>0.06 && face.maxX<0.94 && face.minY>0.02 && face.maxY<0.98
    }
    static func features(face: CGRect, leftEye: CGPoint, rightEye: CGPoint, nose: CGPoint, chin: CGPoint? = nil,
                         confidence: Double, aspect: Double) -> PoseFeatures? {
        let points=[leftEye,rightEye,nose] + (chin.map {[$0]} ?? [])
        guard confidence >= 0.7, aspect.isFinite, aspect > 0,
              face.width.isFinite, face.height.isFinite, face.width > 0.05, face.height > 0.08,
              points.allSatisfy({$0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)}) else {return nil}
        let dx=abs(Double(leftEye.x-rightEye.x))*aspect
        let dy=Double(leftEye.y-rightEye.y)
        guard dx > 0.025 else {return nil}
        let eyeX=Double(leftEye.x+rightEye.x)/2, eyeY=Double(leftEye.y+rightEye.y)/2
        // Sort eyes by image x, keeping roll independent of Vision's anatomical naming.
        let slope=Double(leftEye.x < rightEye.x ? rightEye.y-leftEye.y : leftEye.y-rightEye.y)/dx
        let width=Double(face.width)*aspect
        // The face model supplies four anchors (jaw is projected between full
        // audits); each contributes the same weight. The optional chin keeps existing synthetic callers valid.
        let anchorY=1-points.reduce(0.0) {$0+Double($1.y)}/Double(points.count)
        var value=PoseFeatures([(Double(nose.x)-eyeX)*aspect/hypot(dx,dy),
                                (eyeY-Double(nose.y))/hypot(dx,dy),slope,width,
                                Double(face.midX)*aspect,anchorY])
        if let chin {
            value.heightLandmarks=FaceHeightLandmarks(eyesY:1-eyeY,noseY:1-Double(nose.y),chinY:1-Double(chin.y))
        }
        return value.valid ? value:nil
    }
}

struct SeatedDetection {
    let features:PoseFeatures?
    let guidance:String
    var points:[CGPoint]=[]
    var loss:FaceLossReason = .unknown
}

final class SeatedPoseDetector {
    private let request=VNDetectFaceLandmarksRequest()
    private var continuity=FaceContinuity()
    private var lastVerifiedYaw:Double?
    var lastDecision:String {continuity.lastDecision}
    private var patches=LandmarkPatchTracker()
    private(set) var patchRadius=7
    private let lightweight:Bool
    private var reference:(baseline:PoseFeatures,yellow:Double,red:Double)?
    private var verifiedBand:Int?
    private(set) var fullPasses=0
    private(set) var lastFaceCount=0
    private(set) var seedFailureCounts:[String:Int]=[:]
    private(set) var patchPasses=0
    private(set) var lastPath="full"
    private(set) var lastFallback="initial"
    private(set) var lastSeedFailure:String?
    private(set) var fallbackCounts:[String:Int]=[:]
    init(lightweight:Bool=true){self.lightweight=lightweight}
    func reset(){request.inputFaceObservations=nil;continuity.reset();patches.reset();reference=nil;verifiedBand=nil;lastVerifiedYaw=nil}
    /// Temporary local qualification only. A size change forces a fresh full
    /// model while retaining the selected subject and the user's calibration.
    func setPatchRadius(_ value:Int) {
        let next=[7,10,12].contains(value) ? value:7
        guard next != patchRadius else{return}
        patchRadius=next;patches=LandmarkPatchTracker(radius:next);verifiedBand=nil
    }
    /// Queue-confined snapshot; changing camera calibration or thresholds forces
    /// a full observation without changing the selected-person association.
    func setReference(baseline:PoseFeatures?,yellow:Double,red:Double){
        guard let baseline,baseline.valid,PostureEngine.validThresholds(yellow:yellow,red:red) else {
            if reference != nil {patches.reset();verifiedBand=nil};reference=nil;return
        }
        if reference?.baseline.values != baseline.values || reference?.baseline.landmarkHeight != baseline.landmarkHeight || reference?.yellow != yellow || reference?.red != red {
            patches.reset();verifiedBand=nil
        }
        reference=(baseline,yellow,red)
    }
    private func band(_ features:PoseFeatures?)->Int? {
        guard let reference,let features else{return nil}
        let score=PostureEngine.deviation(features,from:reference.baseline)
        guard score.isFinite else{return nil}
        return score>=reference.red ? 2:score>=reference.yellow ? 1:0
    }
    func detect(_ buffer:CVPixelBuffer,aspect:Double,at now:Double=ProcessInfo.processInfo.systemUptime,allowLightweight:Bool=true) throws -> SeatedDetection {
        var reason="full policy"
        if lightweight,allowLightweight,reference != nil {
            if let track=patches.track(buffer,at:now) {
                let box=track.box,points=track.points
                if SeatedGeometry.permitsLocalTracking(face:box),
                   points.count==4,let features=SeatedGeometry.features(face:box,leftEye:points[0],rightEye:points[1],nose:points[2],chin:points[3],confidence:track.confidence,aspect:aspect) {
                    if let verifiedBand,band(features)==verifiedBand {
                        let eyesY=(points[0].y+points[1].y)/2
                        let signature=[Double(abs(points[0].x-points[1].x)/box.width),Double((eyesY-points[3].y)/box.height)]
                        var trial=continuity
                        let match=trial.select([FaceCandidate(box:box,signature:signature,yaw:lastVerifiedYaw,returnAnchorEligible:verifiedBand==0)],at:now)
                        if match.index==0,match.loss == .unknown {
                            continuity=trial;patchPasses += 1;lastPath="patch";lastFallback=""
                            return SeatedDetection(features:features,guidance:"Tracking your height.",points:points)
                        }
                        reason="subject mismatch"
                    } else {reason="zone transition"}
                } else {reason="geometry or edge"}
            } else {reason=patches.lastFailure ?? "no template"}
        }
        lastFallback=reason;fallbackCounts[reason,default:0] += 1
        let result=try full(VNImageRequestHandler(cvPixelBuffer:buffer,orientation:.up,options:[:]),aspect:aspect,at:now)
        // Multiple people or missing/partial faces disable the shortcut. Every
        // audit and fallback still runs the existing all-face continuity logic.
        if lightweight,allowLightweight,reference != nil,(request.results ?? []).filter({$0.confidence>=0.7}).count==1,
           result.features != nil,result.points.count==4,let box=continuity.selectedBox {
            lastSeedFailure=patches.remember(buffer,box:box,points:result.points,at:now) ? nil:patches.lastFailure
            if let lastSeedFailure {seedFailureCounts[lastSeedFailure,default:0] += 1}
        } else {patches.reset();lastSeedFailure=nil}
        return result
    }
    func detect(_ handler:VNImageRequestHandler,aspect:Double) throws -> SeatedDetection {
        patches.reset()
        return try full(handler,aspect:aspect,at:ProcessInfo.processInfo.systemUptime)
    }
    private func full(_ handler:VNImageRequestHandler,aspect:Double,at now:Double)throws->SeatedDetection {
        patches.reset();verifiedBand=nil
        request.inputFaceObservations=nil
        try handler.perform([request]);fullPasses += 1;lastPath="full"
        let faces=(request.results ?? []).filter {$0.confidence >= 0.7}
        lastFaceCount=faces.count
        let result=select(faces,aspect:aspect,at:now)
        verifiedBand=band(result.features)
        return result
    }
    private func select(_ faces:[VNFaceObservation],aspect:Double,at now:Double)->SeatedDetection {
        let decoded=faces.map { landmarks($0,aspect:aspect) }
        let candidates=faces.indices.map {index -> FaceCandidate in
            let points=decoded[index].points,box=faces[index].boundingBox
            let signature:[Double]
            if points.count == 4 {
                let eyesY=(points[0].y+points[1].y)/2
                signature=[Double(abs(points[0].x-points[1].x)/box.width),Double((eyesY-points[3].y)/box.height)]
            } else {signature=[]}
            return FaceCandidate(box:box,signature:signature,yaw:faces[index].yaw?.doubleValue,returnAnchorEligible:band(decoded[index].features)==0)
        }
        let selection=continuity.select(candidates,at:now)
        guard let index=selection.index else {
            return SeatedDetection(features:nil,guidance:selection.loss == .ambiguous
                ? "Keep the person setting their height centered. Waiting for a clear match."
                : "Looking for your face. Keep your eyes, nose and chin visible.",loss:selection.loss)
        }
        var result=decoded[index];result.loss=selection.loss
        if result.features != nil {lastVerifiedYaw=faces[index].yaw?.doubleValue}
        return result
    }
    private func landmarks(_ face:VNFaceObservation,aspect:Double)->SeatedDetection {
        func center(_ region:VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region,region.pointCount > 0 else{return nil}
            let points=region.normalizedPoints
            let x=(0..<region.pointCount).reduce(CGFloat.zero){$0+points[$1].x}/CGFloat(region.pointCount)
            let y=(0..<region.pointCount).reduce(CGFloat.zero){$0+points[$1].y}/CGFloat(region.pointCount)
            return CGPoint(x:face.boundingBox.minX+x*face.boundingBox.width,y:face.boundingBox.minY+y*face.boundingBox.height)
        }
        func lowestContourPoint(_ region:VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region,region.pointCount > 0 else{return nil}
            let points=region.normalizedPoints
            guard let point=(0..<region.pointCount).map({points[$0]}).min(by:{$0.y<$1.y}) else{return nil}
            return CGPoint(x:face.boundingBox.minX+point.x*face.boundingBox.width,y:face.boundingBox.minY+point.y*face.boundingBox.height)
        }
        guard let chin=lowestContourPoint(face.landmarks?.faceContour),
              let left=center(face.landmarks?.leftEye),let right=center(face.landmarks?.rightEye),
              let nose=center(face.landmarks?.noseCrest ?? face.landmarks?.nose) else {
            return SeatedDetection(features:nil,guidance:"Keep your eyes, nose and chin visible to the camera. A little more light may help.")
        }
        let features=SeatedGeometry.features(face:face.boundingBox,leftEye:left,rightEye:right,nose:nose,chin:chin,confidence:Double(face.confidence),aspect:aspect)
        return SeatedDetection(features:features,guidance:features == nil ? "Move a little closer and face the camera." : "Tracking measures how far your face drops below your comfortable height.",points:features == nil ? []:[left,right,nose,chin])
    }
}
