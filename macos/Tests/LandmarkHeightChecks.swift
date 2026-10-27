import Foundation

@main struct LandmarkHeightChecks {
    static func main() throws {
        func near(_ a:Double,_ b:Double){precondition(abs(a-b)<0.000001)}
        for points in [
            FaceHeightLandmarks(eyesY:0.35,noseY:0.42,chinY:0.60),
            FaceHeightLandmarks(eyesY:0.2,noseY:0.4,chinY:0.7),
            FaceHeightLandmarks(eyesY:0.4,noseY:0.42,chinY:0.68),
            FaceHeightLandmarks(eyesY:0.7,noseY:0.8,chinY:0.98)
        ] {
            let capture=LandmarkHeightCalibration.capture(points)!
            let fraction=(capture.referenceLineY-points.noseY)/(points.chinY-points.noseY)
            near(fraction,1.0/3);precondition((0.25...0.5).contains(fraction))
            near(capture.deviation(points)!,0)
            let line=capture.referenceLineY
            let gap=points.noseY-points.eyesY
            let noseCrossing=FaceHeightLandmarks(eyesY:line-gap,noseY:line,chinY:min(1,line+0.01))
            let eyesCrossing=FaceHeightLandmarks(eyesY:line,noseY:line+gap/3,chinY:min(1,line+gap/3+0.01))
            near(capture.deviation(noseCrossing)!,PostureEngine.defaultYellow)
            near(capture.deviation(eyesCrossing)!,PostureEngine.defaultRed)
            precondition(capture.referenceLineY==line,"A live reading never moves the captured line")
        }
        let points=FaceHeightLandmarks(eyesY:0.35,noseY:0.42,chinY:0.60)
        var pose=PoseFeatures([0,0.4,0,0.3,0.6,0.43]);pose.heightLandmarks=points
        let engine=PostureEngine();engine.calibrate()
        for i in 0...32 {_=engine.update(pose,at:Double(i)/10)}
        let baseline=engine.baseline!
        near(baseline.landmarkHeight!.referenceLineY,0.48)
        near(baseline.centerY,pose.centerY)
        let saved=SavedCalibration(cameraID:"synthetic",baseline:baseline.values,yellow:0.45,red:0.85,landmarkHeight:baseline.landmarkHeight)
        let decoded=try JSONDecoder().decode(SavedCalibration.self,from:JSONEncoder().encode(saved))
        precondition(decoded.valid && decoded.landmarkHeight==saved.landmarkHeight)
        near(decoded.poseFeatures.landmarkHeight!.referenceLineY,0.48)
        var old=saved;old.landmarkHeight?.referenceLineY=0.4375
        let oldDecoded=try JSONDecoder().decode(SavedCalibration.self,from:JSONEncoder().encode(old))
        near(oldDecoded.poseFeatures.landmarkHeight!.referenceLineY,0.4375)
        precondition(LandmarkHeightCalibration.capture(FaceHeightLandmarks(eyesY:0.4,noseY:0.3,chinY:0.6))==nil)
        print("PASS: one-third nose-to-chin reference across face proportions, exact nose/eye crossings, frozen reference, stable engine capture, saved restoration and retained older line")
    }
}
